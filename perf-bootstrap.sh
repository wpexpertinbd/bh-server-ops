#!/bin/bash
# ================================================================
#  Universal Web Server Performance Bootstrap (v3.6)
#
#  v3.6 (2026-05-25) — User-spool + watchdog (visibility + safety)
#    - Monitor crons back in /var/spool/cron/root so CWP/cPanel UI shows
#      them alongside other root jobs. v3.5 hid them in /etc/cron.d/
#      which broke single-pane visibility.
#    - Always installs /usr/local/sbin/bh-crontab-watchdog.sh + an hourly
#      /etc/cron.d/bh-crontab-watchdog entry. The watchdog hourly
#      snapshots root's user-spool crontab to /root/.crontab-backups/
#      and AUTO-RESTORES from the latest snapshot if the crontab shrinks
#      by >30% (the v3.4 wipe symptom). Watchdog itself lives in
#      /etc/cron.d/ so it can't be wiped along with the spool.
#    - Cleans up legacy /etc/cron.d/bh-perf-monitors from v3.5.
#    - Idempotent: safe to re-run.
#
#  v3.5 (2026-05-25) — Moved crons to /etc/cron.d/ (superseded by v3.6).
#
#  Works on: CWP, cPanel/EA4, RHEL/AlmaLinux/Rocky, Debian/Ubuntu
#  Scales: 1-2 GB tiny VPS up to 64+ GB dedicated. All settings
#          (Apache MPM, FPM children, OPcache, Redis) auto-tier
#          based on /proc/meminfo so a 4 GB box doesn't get 64 GB
#          defaults that OOM the kernel.
#  Idempotent. Safe to re-run.
#
#  Run modes:
#    bash perf-bootstrap.sh        → interactive (asks for HEAVY_USERS, crons, etc.)
#    bash perf-bootstrap.sh -y     → non-interactive (use built-in defaults)
#    curl ... | bash               → non-interactive (no TTY)
#
#  Installs:
#    1. Server-wide perf tuning (kernel, OPcache, FPM, MPM, Redis)
#    2. /usr/local/sbin/tenant-cap         — quick noisy-neighbor cap
#    3. /usr/local/sbin/saturation-monitor — TTFB watcher (cron 5min)
#    4. /usr/local/sbin/auto-recovery      — auto-reload on saturation (cron 3min)
# ================================================================

set -e

#################### DEFAULTS (used in non-interactive mode) ####################
HEAVY_USERS="${HEAVY_USERS:-}"               # Force HEAVY tier (Laravel/CodeIgniter/Symfony) — dynamic, full pool
MEDIUM_USERS="${MEDIUM_USERS:-}"             # Force MEDIUM tier (WP/Woo/OpenCart/Magento) — ondemand, 50% pool
SKIP_USERS="${SKIP_USERS:-nobody}"           # System users to skip
APPLY_APACHE_MPM="${APPLY_APACHE_MPM:-1}"
APPLY_REDIS="${APPLY_REDIS:-1}"
TARGET_RAM_GB="${TARGET_RAM_GB:-auto}"       # 'auto' = detect from /proc/meminfo

INSTALL_HELPERS="${INSTALL_HELPERS:-1}"
ENABLE_MONITOR_CRON="${ENABLE_MONITOR_CRON:-1}"
ENABLE_AUTO_RECOVERY_CRON="${ENABLE_AUTO_RECOVERY_CRON:-1}"
MONITOR_SITES="${MONITOR_SITES:-}"           # auto-discover if empty
TTFB_WARN_THRESHOLD="${TTFB_WARN_THRESHOLD:-10}"
TTFB_RECOVER_THRESHOLD="${TTFB_RECOVER_THRESHOLD:-20}"
APPLY_APACHE_HARDENING="${APPLY_APACHE_HARDENING:-1}"  # global hardening conf
# CWP ships an ancient Monsta FTP 1.4.5 web file-manager at htdocs/webftp_simple,
# Alias'd to /webftp /WebFTP /webftp_simple on EVERY domain — unmaintained,
# broken (HTTP 500), publicly exposed attack surface (Monsta's 2.x line took the
# 9.3 RCE CVE-2025-34299). Remove the files AND deny the URLs so a CWP rebuild
# can't silently re-expose it. Clients have CWP's own File Manager + SFTP.
APPLY_REMOVE_WEBFTP="${APPLY_REMOVE_WEBFTP:-1}"  # 1 = remove + permanently deny CWP webftp
# ⚠ DEFAULT 0 ON PURPOSE: enabling this with the wrong IP list locks the panel owner out.
# BiswasHost fleet (biswashost + s1-s4) runs it as:  APPLY_CWP_ADMIN_IPLOCK=1 bash perf-bootstrap.sh -y
# On a CLIENT-owned server, set CWP_ADMIN_TRUSTED_IPS to THEIR IPs or leave this at 0.
APPLY_CWP_ADMIN_IPLOCK="${APPLY_CWP_ADMIN_IPLOCK:-0}"   # 1 = restrict CWP ADMIN panel (/login,/admin,/api) to trusted IPs
CWP_ADMIN_TRUSTED_IPS="${CWP_ADMIN_TRUSTED_IPS:-103.173.106.4 103.173.106.3 54.38.92.25 127.0.0.1}"
ENABLE_HTTP3="${ENABLE_HTTP3:-1}"            # 1 = swap nginx for codeit's QUIC-capable build + patch CWP templates
# clamd (ClamAV daemon, used by amavis for mail AV) is a known resource hog:
# spikes CPU (observed 167% / 1.6 cores) and leaks RAM (>1.3GB) during scans,
# starving web/mysql. Cap it via a systemd drop-in. MemoryMax stays well above
# the ~700MB-1GB signature-DB load peak so clamd never OOM-loops.
# MariaDB InnoDB buffer pool, sized from the REAL data size — NOT from server RAM.
# Both directions are wrong in practice and both were found live on 2026-08-10:
#   OVERSIZED (s1 48G/s4 24G for ~9G of data) → the reservation adds memory
#     pressure and mariadbd gets SWAPPED (s1 had 10.5G in swap). A buffer-pool
#     page living in swap is WORSE than no cache: a "hit" that faults from disk.
#   UNDERSIZED (s3 had NO setting at all → MariaDB's 128M default for 7.76G of
#     data) → 1.02 TB read from disk, hit ratio 96.2% vs 99.99% elsewhere.
# So: size = data x MARIADB_POOL_FACTOR, floored, and capped at a % of RAM.
# NOTE a MISSING directive is invisible to a "value looks wrong" check — this
# step appends the line when absent rather than only sed-replacing it.
APPLY_MARIADB_TUNING="${APPLY_MARIADB_TUNING:-1}"  # 1 = size the InnoDB buffer pool (set 0 to skip)
MARIADB_POOL_FACTOR="${MARIADB_POOL_FACTOR:-13}"   # tenths: 13 = data x 1.3 (30% growth headroom)
MARIADB_POOL_MIN_GB="${MARIADB_POOL_MIN_GB:-2}"    # never go below this
MARIADB_POOL_RAM_PCT="${MARIADB_POOL_RAM_PCT:-35}" # hard ceiling as % of total RAM
APPLY_CLAMD_LIMITS="${APPLY_CLAMD_LIMITS:-1}"   # 1 = cap clamd CPU/RAM/IO (set 0 to skip)
CLAMD_CPUQUOTA="${CLAMD_CPUQUOTA:-50%}"         # half a core hard cap
CLAMD_MEMMAX="${CLAMD_MEMMAX:-1536M}"           # hard RAM cap (safe above DB-load peak)
CLAMD_MEMHIGH="${CLAMD_MEMHIGH:-1024M}"         # soft throttle (cgroup v2 only; EL8 v1 ignores, harmless)
# CWP backs up each account into /home/tmp_bak/.backup_temp<user>, tars it off,
# then is SUPPOSED to delete the temp dir — but often doesn't, so staging piles
# up hundreds of GB every run (seen 325G/98 dirs filling a disk to 97%). This
# janitor cron clears STALE temp dirs while protecting any in-progress backup.
APPLY_TMPBAK_JANITOR="${APPLY_TMPBAK_JANITOR:-1}"        # 1 = install the staging-cleanup cron
TMPBAK_DIR="${TMPBAK_DIR:-/home/tmp_bak}"               # CWP backup staging dir
TMPBAK_JANITOR_INTERVAL="${TMPBAK_JANITOR_INTERVAL:-30}" # cron interval (minutes)
TMPBAK_JANITOR_MINAGE="${TMPBAK_JANITOR_MINAGE:-10}"    # only delete dirs untouched N+ min (active-backup guard)
APPLY_DOMLOGS_ROTATE="${APPLY_DOMLOGS_ROTATE:-1}"        # 1 = rotate CWP per-domain Apache logs (they are NOT rotated by anything)
DOMLOGS_ROTATE_KEEP="${DOMLOGS_ROTATE_KEEP:-7}"          # days of per-domain logs to keep
DOMLOGS_ROTATE_MAXSIZE="${DOMLOGS_ROTATE_MAXSIZE:-100M}" # rotate early if one domain floods
# WordPress edge guard (nginx 6c): hard-block wp-cron.php over HTTP globally +
# rate-limit wp-login.php per real-client-IP — kills bot floods on these
# endpoints at the edge before they spawn PHP workers, country-independent
# (complements CC_IGNORE without un-whitelisting BD customers). SAFE: wp-cron
# runs via php-CLI cron (not HTTP) so blocking HTTP wp-cron doesn't touch it;
# CF real_ip is already set on CWP so the rate-limit keys on the true visitor.
# xmlrpc.php is already hard-blocked (return 444) in the anti-bot snippet.
APPLY_WP_EDGE_GUARD="${APPLY_WP_EDGE_GUARD:-1}"
WPLOGIN_RATE="${WPLOGIN_RATE:-10r/m}"   # per-IP wp-login.php rate (10/min = brute-force throttle, generous for humans)
WPLOGIN_BURST="${WPLOGIN_BURST:-5}"     # immediate attempts allowed before throttling kicks in
APPLY_CRAWLER_THROTTLE="${APPLY_CRAWLER_THROTTLE:-1}"  # 1 = cap aggressive-but-legitimate crawlers (facebookexternalhit etc)
CRAWLER_RATE="${CRAWLER_RATE:-60r/m}"   # SHARED across ALL crawler IPs (they crawl from hundreds) = 1 req/sec total
CRAWLER_BURST="${CRAWLER_BURST:-20}"    # spare capacity for genuine share-preview bursts
# Space-separated IPs that bypass nginx anti-bot rules. Use this to allowlist
# your other fleet servers (DNS slave, monitoring, Blesta, etc.) so server-
# to-server API calls don't get caught by the bot filter. Example:
#   TRUSTED_IPS="<ip1> <ip2> <ip3>" bash perf-bootstrap.sh -y
TRUSTED_IPS="${TRUSTED_IPS:-}"

# IS_SLAVE_SERVER=1 → server runs an API-only app (CWP DNS slave portal,
# monitoring backend, Blesta API node, etc.) where every request comes
# from machine clients with unusual UAs. The anti-bot WAF and Apache
# hardening rules will block legitimate API traffic. Skip them.
# Kernel/OPcache/MPM/fail2ban-SSH still apply.
IS_SLAVE_SERVER="${IS_SLAVE_SERVER:-0}"
#################################################################################

# CLI flag: -y / --yes → skip interactive prompts
NON_INTERACTIVE=0
case "${1:-}" in
  -y|--yes|--non-interactive) NON_INTERACTIVE=1 ;;
esac

# Auto-detect TARGET_RAM_GB if not explicitly set
if [ "$TARGET_RAM_GB" = "auto" ]; then
  TARGET_RAM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 8)
fi

# ────────────────────────────────────────────────
# RAM TIER → SIZING (all memory-hungry settings scale together)
# ────────────────────────────────────────────────
# Compute proportional values so a 4 GB VPS doesn't get 64 GB defaults.
# Format: <comment shows expected peak Apache+OPcache+Redis baseline>
# Tier thresholds are 2 GB below their nominal value because /proc/meminfo
# always reports less than installed (kernel + firmware reserve ~2 GB on
# big boxes, ~1 GB on small VPS). 64 GB box → 62 GB, 16 GB → 15 GB, etc.
# NOTE: only HEAVY_CHILDREN is set per RAM class. MEDIUM (75%) and LIGHT (25%)
# are DERIVED from it below — do not set them here, they would be overwritten.
if   [ "$TARGET_RAM_GB" -ge 240 ]; then  # 256 GB-class (reports ~245-250)
  MAX_WORKERS=5000;  THREADS_PER_CHILD=50;  SERVER_LIMIT=100
  HEAVY_CHILDREN=48
  OPCACHE_MB=512;    OPCACHE_FILES=50000;   INTERNED_MB=32
  REDIS_MAX=8gb
elif [ "$TARGET_RAM_GB" -ge 120 ]; then  # 128 GB-class (reports ~125-126)
  MAX_WORKERS=3200;  THREADS_PER_CHILD=50;  SERVER_LIMIT=64
  HEAVY_CHILDREN=40
  OPCACHE_MB=384;    OPCACHE_FILES=30000;   INTERNED_MB=24
  REDIS_MAX=4gb
elif [ "$TARGET_RAM_GB" -ge 60 ]; then  # 64 GB-class (reports ~62)
  MAX_WORKERS=1600;  THREADS_PER_CHILD=50;  SERVER_LIMIT=32
  HEAVY_CHILDREN=32
  OPCACHE_MB=256;    OPCACHE_FILES=20000;   INTERNED_MB=16
  REDIS_MAX=2gb
elif [ "$TARGET_RAM_GB" -ge 30 ]; then  # 32 GB-class (reports ~30-31)
  MAX_WORKERS=800;   THREADS_PER_CHILD=50;  SERVER_LIMIT=16
  HEAVY_CHILDREN=24
  OPCACHE_MB=256;    OPCACHE_FILES=20000;   INTERNED_MB=16
  REDIS_MAX=1gb
elif [ "$TARGET_RAM_GB" -ge 14 ]; then  # 16 GB-class (reports ~15)
  MAX_WORKERS=400;   THREADS_PER_CHILD=50;  SERVER_LIMIT=8
  HEAVY_CHILDREN=20
  OPCACHE_MB=192;    OPCACHE_FILES=15000;   INTERNED_MB=12
  REDIS_MAX=512mb
elif [ "$TARGET_RAM_GB" -ge 7 ];  then  # 8 GB-class (reports ~7)
  MAX_WORKERS=200;   THREADS_PER_CHILD=40;  SERVER_LIMIT=5
  HEAVY_CHILDREN=14
  OPCACHE_MB=128;    OPCACHE_FILES=10000;   INTERNED_MB=8
  REDIS_MAX=384mb
elif [ "$TARGET_RAM_GB" -ge 3 ];  then  # 4 GB-class (reports ~3.5)
  MAX_WORKERS=100;   THREADS_PER_CHILD=25;  SERVER_LIMIT=4
  HEAVY_CHILDREN=10
  OPCACHE_MB=96;     OPCACHE_FILES=8000;    INTERNED_MB=8
  REDIS_MAX=256mb
else                                       # tiny VPS (1-3 GB)
  MAX_WORKERS=50;    THREADS_PER_CHILD=25;  SERVER_LIMIT=2
  HEAVY_CHILDREN=6
  OPCACHE_MB=64;     OPCACHE_FILES=5000;    INTERNED_MB=4
  REDIS_MAX=128mb
fi

# OPcache floor (boss directive 2026-07-04): every PHP version gets at least
# 256 MB / 20000 files / 16 MB interned (busy WP/Woo sites were hitting the
# 128 MB default full at ~31% hit rate). Higher-RAM tiers keep their bigger
# 384/512 MB values; only sub-256 tiers (≤16 GB) are lifted to 256.
# ⚠ DEPRECATED as of 2026-08-09: OPCACHE_MB / OPCACHE_FILES / INTERNED_MB are no
# longer used for OPcache. Step [3/11] now sizes each PHP version from its REAL
# site+file count instead of from server RAM — scaling off RAM gave the busiest
# version the same slice as versions serving zero sites. Kept only so any external
# override that still sets them does not error.
if [ "${OPCACHE_MB:-0}" -lt 256 ]; then
  OPCACHE_MB=256; OPCACHE_FILES=20000; INTERNED_MB=16
fi

# ────────────────────────────────────────────────
# 3-TIER FPM SIZING — derive MEDIUM + LIGHT from HEAVY_CHILDREN
# ────────────────────────────────────────────────
# Tiering policy: only real PHP frameworks (Laravel/CodeIgniter/Symfony) get
# the FULL heavy pool. CMS/cart apps (WordPress/WooCommerce/OpenCart/Magento)
# are MEDIUM. Static/basic sites are LIGHT.
#
# Ratios (2026-07-11): bumped MEDIUM 50% → 75% of HEAVY after production
# evidence that busy WooCommerce sites (136k hits/hour on s4) needed manual
# heavy promotion just to serve real customer + admin traffic concurrently.
# At 75%, a MEDIUM WordPress tenant naturally gets enough workers to absorb
# admin activity during peak customer traffic without queuing. On 64GB s4
# this means MEDIUM=15 (was 10) — enough for a busy WooCommerce store.
# LIGHT stays at 25% (static sites don't need concurrency).
#
# These supersede any LIGHT_CHILDREN set in the RAM-tier table above — the
# value is always derived from HEAVY_CHILDREN so ratios hold on every box.
# Floors keep small VPS usable (never CWP's too-low defaults):
#   MEDIUM floor 3, LIGHT floor 2.
MEDIUM_CHILDREN=$(( HEAVY_CHILDREN * 3 / 4 )); [ "$MEDIUM_CHILDREN" -lt 3 ] && MEDIUM_CHILDREN=3
LIGHT_CHILDREN=$(( HEAVY_CHILDREN / 4 ));      [ "$LIGHT_CHILDREN"  -lt 2 ] && LIGHT_CHILDREN=2

# Detect interactive TTY
INTERACTIVE=0
[ "$NON_INTERACTIVE" = "0" ] && [ -t 0 ] && INTERACTIVE=1

# ────────────────────────────────────────────────
# PROMPT HELPER
# ────────────────────────────────────────────────
ask() {
  # ask "prompt" "default" → returns answer in $REPLY
  local prompt="$1" default="$2"
  if [ "$INTERACTIVE" = "0" ]; then REPLY="$default"; return; fi
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " REPLY < /dev/tty
    [ -z "$REPLY" ] && REPLY="$default"
  else
    read -r -p "$prompt: " REPLY < /dev/tty
  fi
}

ask_yn() {
  # ask_yn "prompt" "y" → returns 1/0 in $REPLY based on default y/n
  local prompt="$1" default="$2"
  local yn_disp
  case "$default" in y|Y|1) yn_disp="Y/n" ;; *) yn_disp="y/N" ;; esac

  if [ "$INTERACTIVE" = "0" ]; then
    case "$default" in y|Y|1) REPLY=1 ;; *) REPLY=0 ;; esac
    return
  fi

  read -r -p "$prompt [$yn_disp]: " ANS < /dev/tty
  [ -z "$ANS" ] && ANS="$default"
  case "$ANS" in y|Y|yes|YES|1) REPLY=1 ;; *) REPLY=0 ;; esac
}

# ────────────────────────────────────────────────
# ENVIRONMENT DETECTION
# ────────────────────────────────────────────────
PANEL=""
APACHE_BIN=""
APACHE_SERVICE=""
APACHE_MPM_CONF=""
declare -a PHP_INI_DIRS=()
declare -a PHP_FPM_USER_DIRS=()
declare -a PHP_FPM_SERVICES=()
CWP_TPL_DIR=""

# Security stack detection (cpGuard / CSF / mod_security / fail2ban / Imunify)
HAS_CPGUARD=0
HAS_CSF=0
HAS_MODSEC=0
HAS_FAIL2BAN=0
HAS_IMUNIFY=0
MODSEC_RULESET=""

detect() {
  if [ -x /usr/local/apache/bin/httpd ]; then
    PANEL="cwp"
    APACHE_BIN=/usr/local/apache/bin/httpd
    APACHE_SERVICE=httpd
    APACHE_MPM_CONF=/usr/local/apache/conf/extra/httpd-mpm.conf
    CWP_TPL_DIR=/usr/local/cwpsrv/htdocs/resources/conf/web_servers/vhosts/php-fpm
  elif [ -x /usr/sbin/httpd ] && [ -d /etc/httpd ]; then
    PANEL="rhel"
    APACHE_BIN=/usr/sbin/httpd
    APACHE_SERVICE=httpd
    APACHE_MPM_CONF=/etc/httpd/conf.modules.d/00-mpm.conf
  elif [ -x /usr/sbin/apache2 ] && [ -d /etc/apache2 ]; then
    PANEL="debian"
    APACHE_BIN=/usr/sbin/apache2
    APACHE_SERVICE=apache2
    APACHE_MPM_CONF=/etc/apache2/mods-enabled/mpm_event.conf
    [ ! -f "$APACHE_MPM_CONF" ] && APACHE_MPM_CONF=/etc/apache2/mods-available/mpm_event.conf
  fi

  for D in /opt/alt/php-fpm*/usr/etc/php-fpm.d/users; do
    [ -d "$D" ] || continue
    PHP_FPM_USER_DIRS+=("$D")
    V=$(echo "$D" | grep -oE 'php-fpm[0-9]+' | grep -oE '[0-9]+')
    # Auto-detect actual systemd unit name — CWP CloudLinux uses 'php-fpm83'
    # (no hyphen between 'fpm' and version), some other distros may use
    # 'php-fpm-83'. Pick whichever exists.
    if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^php-fpm${V}\.service"; then
      PHP_FPM_SERVICES+=("php-fpm${V}")
    elif systemctl list-unit-files --type=service 2>/dev/null | grep -q "^php-fpm-${V}\.service"; then
      PHP_FPM_SERVICES+=("php-fpm-${V}")
    fi
    INI_DIR="/opt/alt/php-fpm${V}/usr/php/php.d"
    [ -d "$INI_DIR" ] && PHP_INI_DIRS+=("$INI_DIR")
  done

  for D in /opt/cpanel/ea-php*/root/etc/php-fpm.d/users; do
    [ -d "$D" ] || continue
    PHP_FPM_USER_DIRS+=("$D")
    V=$(echo "$D" | grep -oE 'ea-php[0-9]+' | grep -oE '[0-9]+')
    PHP_FPM_SERVICES+=("ea-php${V}-php-fpm")
    INI_DIR="/opt/cpanel/ea-php${V}/root/etc/php.d"
    [ -d "$INI_DIR" ] && PHP_INI_DIRS+=("$INI_DIR")
  done

  if [ -d /etc/php-fpm.d ] && [ ${#PHP_FPM_USER_DIRS[@]} -eq 0 ]; then
    PHP_FPM_USER_DIRS+=("/etc/php-fpm.d")
    PHP_FPM_SERVICES+=("php-fpm")
    [ -d /etc/php.d ] && PHP_INI_DIRS+=("/etc/php.d")
  fi

  for D in /etc/php/*/fpm/pool.d; do
    [ -d "$D" ] || continue
    PHP_FPM_USER_DIRS+=("$D")
    V=$(echo "$D" | grep -oE '/[0-9.]+/' | tr -d '/')
    PHP_FPM_SERVICES+=("php${V}-fpm")
    CONF_DIR=$(dirname "$D")/conf.d
    [ -d "$CONF_DIR" ] && PHP_INI_DIRS+=("$CONF_DIR")
  done

  # ── Security stack detection ──
  # cpGuard (CWP plugin / standalone)
  if [ -d /etc/cpguard ] || systemctl is-active --quiet cpguard 2>/dev/null; then
    HAS_CPGUARD=1
  fi

  # CSF firewall
  if command -v csf >/dev/null 2>&1 || [ -f /etc/csf/csf.conf ]; then
    HAS_CSF=1
  fi

  # mod_security (any flavor)
  if [ -n "$APACHE_BIN" ] && $APACHE_BIN -M 2>/dev/null | grep -q "security2_module"; then
    HAS_MODSEC=1
    # Identify which ruleset is active
    if grep -rq "comodo" /etc/modsecurity* /usr/local/apache/conf/extra/modsec* /etc/cpguard* 2>/dev/null; then
      MODSEC_RULESET="Comodo CRS"
    elif grep -rq "OWASP" /etc/modsecurity* /usr/local/apache/conf/extra/modsec* 2>/dev/null; then
      MODSEC_RULESET="OWASP CRS"
    else
      MODSEC_RULESET="generic"
    fi
  fi

  # fail2ban
  if systemctl is-active --quiet fail2ban 2>/dev/null || command -v fail2ban-client >/dev/null 2>&1; then
    HAS_FAIL2BAN=1
  fi

  # Imunify360 / ImunifyAV (CloudLinux/cPanel)
  if [ -d /etc/imunify360 ] || systemctl is-active --quiet imunify360 2>/dev/null; then
    HAS_IMUNIFY=1
  fi
}

detect

echo "=============================================="
echo "  Universal Perf Bootstrap v3.4"
echo "  $(date)"
echo "=============================================="
echo "Detected:"
echo "  Panel/Distro: $PANEL"
echo "  Apache binary: ${APACHE_BIN:-(not found)}"
echo "  Apache service: ${APACHE_SERVICE:-(not found)}"
echo "  Apache MPM conf: ${APACHE_MPM_CONF:-(not found)}"
echo "  CWP template dir: ${CWP_TPL_DIR:-(not CWP)}"
echo "  PHP-FPM user pool dirs (${#PHP_FPM_USER_DIRS[@]}):"
for D in "${PHP_FPM_USER_DIRS[@]}"; do echo "    $D"; done
echo "  PHP-FPM services: ${PHP_FPM_SERVICES[*]}"
echo "  PHP ini.d dirs: ${PHP_INI_DIRS[*]}"
echo "  RAM (TARGET_RAM_GB): ${TARGET_RAM_GB} GB"
echo ""
echo "Security stack detected:"
echo "  cpGuard:       $([ "$HAS_CPGUARD" = 1 ] && echo "✓ active" || echo "✗ not installed")"
echo "  CSF firewall:  $([ "$HAS_CSF" = 1 ] && echo "✓ active" || echo "✗ not installed")"
echo "  mod_security:  $([ "$HAS_MODSEC" = 1 ] && echo "✓ active ($MODSEC_RULESET)" || echo "✗ not loaded")"
echo "  fail2ban:      $([ "$HAS_FAIL2BAN" = 1 ] && echo "✓ active" || echo "✗ not running")"
echo "  Imunify360:    $([ "$HAS_IMUNIFY" = 1 ] && echo "✓ active" || echo "✗ not installed")"
echo ""

# Advisory: warn if NO dynamic-threat protection found
if [ "$HAS_CPGUARD" = 0 ] && [ "$HAS_CSF" = 0 ] && [ "$HAS_FAIL2BAN" = 0 ] && [ "$HAS_IMUNIFY" = 0 ]; then
  echo "⚠ WARNING: No firewall / login-bruteforce protection detected."
  echo "  This script applies STATIC hardening (file blocks, bot UA filters)."
  echo "  For DYNAMIC threats (login bruteforce, scrapers rotating IPs):"
  echo "    - Install CSF firewall:  https://configserver.com/csf/"
  echo "    - Or install fail2ban:   yum install fail2ban / apt install fail2ban"
  echo "    - cpGuard (CWP):         https://cpguard.com/"
  echo ""
elif [ "$HAS_CPGUARD" = 0 ] && [ "$HAS_MODSEC" = 0 ] && [ "$HAS_IMUNIFY" = 0 ]; then
  echo "ℹ No WAF (mod_security/cpGuard/Imunify) detected — bots get blocked"
  echo "  by Apache hardening conf only. Consider adding mod_security with"
  echo "  Comodo CRS or OWASP CRS for dynamic WAF rules."
  echo ""
fi

if [ -z "$APACHE_BIN" ] && [ ${#PHP_FPM_USER_DIRS[@]} -eq 0 ]; then
  echo "✗ No Apache or PHP-FPM detected. Nothing to do."
  exit 1
fi

# ────────────────────────────────────────────────
# CLI MODE SELECTION (Install / Rollback / Quit)
# ────────────────────────────────────────────────
MODE="install"
case "${1:-}" in
  -r|--rollback) MODE="rollback"; NON_INTERACTIVE=1 ;;
  -y|--yes|--non-interactive) MODE="install"; NON_INTERACTIVE=1 ;;
esac

if [ "$INTERACTIVE" = "1" ]; then
  echo "─── Choose action ───"
  echo "  [I]nstall   Apply / re-apply tuning + helpers (default)"
  echo "  [R]ollback  Restore all .bak-pre-tune backups, remove helpers + cron"
  echo "  [Q]uit     Exit without changes"
  read -r -p "Action [I/r/q]: " ACT < /dev/tty
  case "$ACT" in
    r|R|rollback) MODE="rollback" ;;
    q|Q|quit|exit) echo "Aborted."; exit 0 ;;
    *) MODE="install" ;;
  esac
  echo ""
fi

# ────────────────────────────────────────────────
# ROLLBACK PATH
# ────────────────────────────────────────────────
if [ "$MODE" = "rollback" ]; then
  if [ "$INTERACTIVE" = "1" ]; then
    echo "⚠ This will restore ALL .bak-pre-tune backups under /opt /etc /usr/local"
    echo "  remove /usr/local/sbin/{tenant-cap,saturation-monitor,auto-recovery}"
    echo "  remove cron entries for monitor + auto-recovery"
    echo "  reload Apache + PHP-FPM"
    ask_yn "Proceed with rollback?" "n"
    [ "$REPLY" = "0" ] && { echo "Aborted."; exit 0; }
  fi

  echo ""
  echo "─── Rolling back ───"

  # Unfreeze frozen files
  [ -f "$APACHE_MPM_CONF" ] && chattr -i "$APACHE_MPM_CONF" 2>/dev/null || true
  [ -n "$CWP_TPL_DIR" ] && [ -d "$CWP_TPL_DIR" ] && \
    chattr -i "$CWP_TPL_DIR"/*.tpl 2>/dev/null || true

  # Restore backups
  RESTORED=0
  while IFS= read -r BAK; do
    [ -z "$BAK" ] && continue
    ORIG="${BAK%.bak-pre-tune}"
    mv "$BAK" "$ORIG" && RESTORED=$((RESTORED+1))
  done < <(find /opt /etc /usr/local -name '*.bak-pre-tune' 2>/dev/null)
  echo "✓ Restored $RESTORED backup files"

  # Remove our drop-in OPcache + sysctl + hardening
  for INI_DIR in "${PHP_INI_DIRS[@]}"; do
    rm -f "$INI_DIR/99-opcache-tuned.ini" "$INI_DIR/zz-opcache-tuned.ini"
  done
  rm -f /etc/sysctl.d/99-performance.conf

  # Remove Apache hardening drop-in (any of the supported paths)
  for HF in /usr/local/apache/conf.d/99-global-hardening.conf \
            /etc/httpd/conf.d/99-global-hardening.conf \
            /etc/apache2/conf-enabled/99-global-hardening.conf \
            /etc/apache2/conf-available/99-global-hardening.conf; do
    if [ -f "$HF" ]; then
      chattr -i "$HF" 2>/dev/null || true
      rm -f "$HF"
    fi
  done

  # Strip our wp-cron/xmlrpc block from main httpd.conf (between markers)
  for HC in /usr/local/apache/conf/httpd.conf \
            /etc/httpd/conf/httpd.conf \
            /etc/apache2/apache2.conf; do
    if [ -f "$HC" ] && grep -q "BH-OPS-HARDENING-MARKER" "$HC"; then
      sed -i '/# ── BH-OPS-HARDENING-MARKER ──/,/# ── END BH-OPS-HARDENING-MARKER ──/d' "$HC"
      echo "✓ Removed BH-OPS hardening block from $HC"
    fi
  done

  echo "✓ Removed drop-in configs (sysctl, OPcache 99-tuned, hardening, httpd.conf patches)"

  # Remove helpers
  rm -f /usr/local/sbin/tenant-cap /usr/local/sbin/saturation-monitor /usr/local/sbin/auto-recovery
  echo "✓ Removed /usr/local/sbin/{tenant-cap,saturation-monitor,auto-recovery}"

  # Remove watchdog + any /etc/cron.d/ leftovers from older versions
  rm -f /etc/cron.d/bh-perf-monitors /etc/cron.d/bh-crontab-watchdog /etc/cron.d/bh-cron-shell-heal
  rm -f /usr/local/sbin/bh-crontab-watchdog.sh /usr/local/sbin/bh-cron-shell-heal.sh
  echo "✓ Removed watchdog + legacy /etc/cron.d/ files"

  # Remove monitor entries from root's user-spool crontab.
  # Safety guard: only rewrite the spool if `crontab -l` succeeded AND
  # produced non-empty output. This prevents the v3.4 wipe bug where a
  # failed `crontab -l` would nuke the entire crontab.
  if EXISTING_CRON=$(crontab -l 2>/dev/null) && [ -n "$EXISTING_CRON" ]; then
    FILTERED_CRON=$(printf '%s\n' "$EXISTING_CRON" | grep -v 'saturation-monitor' | grep -v 'auto-recovery' | grep -v 'BH-PERF-MONITORS' || true)
    if [ "$FILTERED_CRON" != "$EXISTING_CRON" ]; then
      printf '%s\n' "$FILTERED_CRON" | crontab -
      echo "✓ Cleaned legacy monitor/auto-recovery lines from root user-spool crontab"
    fi
  fi

  # Reload services
  for S in "${PHP_FPM_SERVICES[@]}"; do
    systemctl is-active --quiet "$S" 2>/dev/null && systemctl reload "$S" && echo "✓ reloaded $S"
  done
  [ -n "$APACHE_SERVICE" ] && systemctl is-active --quiet "$APACHE_SERVICE" 2>/dev/null && \
    systemctl reload "$APACHE_SERVICE" && echo "✓ reloaded $APACHE_SERVICE"

  echo ""
  echo "=============================================="
  echo "  Rollback complete on $(hostname)"
  echo "=============================================="
  exit 0
fi

# ────────────────────────────────────────────────
# INSTALL PATH — interactive prompts
# ────────────────────────────────────────────────
if [ "$INTERACTIVE" = "1" ]; then
  echo "─── Configuration ───"
  echo "(Press Enter to accept the default in [brackets])"
  echo ""

  ask "TARGET_RAM_GB (used to size Apache MPM workers)" "$TARGET_RAM_GB"
  TARGET_RAM_GB="$REPLY"

  ask "Heavy app users (Laravel/Symfony, space-separated, blank for none)" "$HEAVY_USERS"
  HEAVY_USERS="$REPLY"

  ask_yn "Is this a SLAVE / API-only server (DNS slave, monitoring backend, Blesta API)?
  Y skips anti-bot + Apache hardening (which break server-to-server API auth).
  N runs the full WAF stack (right answer for shared hosting / sites)" "n"
  IS_SLAVE_SERVER="$REPLY"

  ask_yn "Apply Apache MPM tuning?" "y"
  APPLY_APACHE_MPM="$REPLY"

  ask_yn "Apply Redis cap (2GB + LRU)?" "y"
  APPLY_REDIS="$REPLY"

  if [ "$IS_SLAVE_SERVER" != "1" ]; then
    ask_yn "Apply Apache global hardening (block bad bots, sensitive files, PHP-in-uploads)?" "y"
    APPLY_APACHE_HARDENING="$REPLY"
  fi

  ask_yn "Enable real HTTP/3 (swap nginx for codeit's QUIC-capable build + patch CWP vhost templates)?" "y"
  ENABLE_HTTP3="$REPLY"

  ask_yn "Install /usr/local/sbin/{tenant-cap,saturation-monitor,auto-recovery}?" "y"
  INSTALL_HELPERS="$REPLY"

  if [ "$INSTALL_HELPERS" = "1" ]; then
    ask_yn "Enable saturation-monitor cron (every 5 min, logs slow sites)?" "y"
    ENABLE_MONITOR_CRON="$REPLY"

    ask_yn "Enable auto-recovery cron (every 3 min, auto-reloads on saturation)?" "y"
    ENABLE_AUTO_RECOVERY_CRON="$REPLY"

    if [ "$ENABLE_MONITOR_CRON" = "1" ] || [ "$ENABLE_AUTO_RECOVERY_CRON" = "1" ]; then
      echo ""
      echo "  Sites to monitor — hostname only, space-separated."
      echo "  Examples: www.example.com api.example.com shop.example.com"
      echo "  (Full URLs like https://… work too — protocol + trailing slash auto-stripped)"
      echo "  (Blank = auto-discover from CWP user_data)"
      ask "Sites" "$MONITOR_SITES"
      MONITOR_SITES="$REPLY"
    fi
  fi

  echo ""
  echo "─── Summary ───"
  echo "  TARGET_RAM_GB:             $TARGET_RAM_GB"
  echo "  HEAVY_USERS:               ${HEAVY_USERS:-(none)}"
  echo "  Apache MPM tuning:         $([ "$APPLY_APACHE_MPM" = "1" ] && echo yes || echo no)"
  echo "  Redis cap:                 $([ "$APPLY_REDIS" = "1" ] && echo yes || echo no)"
  echo "  Apache global hardening:   $([ "$APPLY_APACHE_HARDENING" = "1" ] && echo yes || echo no)"
  echo "  Remove exposed webftp:     $([ "$APPLY_REMOVE_WEBFTP" = "1" ] && echo yes || echo no)"
  echo "  HTTP/3 (codeit nginx):     $([ "$ENABLE_HTTP3" = "1" ] && echo yes || echo no)"
  echo "  clamd resource cap:        $([ "$APPLY_CLAMD_LIMITS" = "1" ] && echo "yes (CPU $CLAMD_CPUQUOTA / RAM $CLAMD_MEMMAX)" || echo no)"
  echo "  tmp_bak janitor cron:      $([ "$APPLY_TMPBAK_JANITOR" = "1" ] && echo "yes (every ${TMPBAK_JANITOR_INTERVAL}min)" || echo no)"
  echo "  WP edge guard:             $([ "$APPLY_WP_EDGE_GUARD" = "1" ] && echo "yes (wp-cron HTTP blocked, wp-login $WPLOGIN_RATE)" || echo no)"
  echo "  Install helpers:           $([ "$INSTALL_HELPERS" = "1" ] && echo yes || echo no)"
  echo "  Saturation-monitor cron:   $([ "$ENABLE_MONITOR_CRON" = "1" ] && echo yes || echo no)"
  echo "  Auto-recovery cron:        $([ "$ENABLE_AUTO_RECOVERY_CRON" = "1" ] && echo yes || echo no)"
  echo "  Sites to monitor:          ${MONITOR_SITES:-(auto-discover)}"
  echo ""
  ask_yn "Proceed with these settings?" "y"
  [ "$REPLY" = "0" ] && { echo "Aborted."; exit 0; }
  echo ""
fi

# Slave-mode safety overrides — apply in BOTH interactive AND non-interactive
# (-y / curl|bash) modes. Without this, IS_SLAVE_SERVER=1 had no effect when
# the interactive block was skipped, and Apache hardening got re-applied
# (which silently breaks API auth on slave servers). Found in production.
if [ "$IS_SLAVE_SERVER" = "1" ]; then
  APPLY_APACHE_HARDENING=0
  echo "  → slave/API mode active: Apache hardening forced OFF"
fi

# ────────────────────────────────────────────────
# 1. Kernel tunables
# ────────────────────────────────────────────────
echo "─── [1/11] Kernel tunables ───"
cat > /etc/sysctl.d/99-performance.conf <<'EOF'
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 10000 65535
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
vm.swappiness = 10
EOF
sysctl -p /etc/sysctl.d/99-performance.conf > /dev/null
echo "✓ /etc/sysctl.d/99-performance.conf applied"

# ────────────────────────────────────────────────
# 2. Create swap if none exists (small VPS often ship without)
# ────────────────────────────────────────────────
echo ""
echo "─── [2/11] Swap setup ───"
EXISTING_SWAP_KB=$(awk '/SwapTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
if [ "${EXISTING_SWAP_KB:-0}" -gt 0 ]; then
  echo "⊘ Swap already present ($((EXISTING_SWAP_KB / 1024)) MB) — skipping"
else
  # Decide swap size: 2× RAM up to 4 GB, then RAM up to 8 GB, then 8 GB ceiling
  if   [ "$TARGET_RAM_GB" -le 2 ];  then SWAP_GB=$(( TARGET_RAM_GB * 2 ))
  elif [ "$TARGET_RAM_GB" -le 8 ];  then SWAP_GB=$TARGET_RAM_GB
  elif [ "$TARGET_RAM_GB" -le 32 ]; then SWAP_GB=8
  else                                   SWAP_GB=4; fi

  # Check disk free on /
  DISK_FREE_GB=$(df -BG / 2>/dev/null | awk 'NR==2 {gsub("G",""); print $4}')
  if [ -z "$DISK_FREE_GB" ] || [ "$DISK_FREE_GB" -lt $((SWAP_GB + 5)) ]; then
    echo "⊘ Not enough free disk on / to create ${SWAP_GB}GB swap (free: ${DISK_FREE_GB:-?}GB) — skipping"
  else
    echo "Creating /swapfile (${SWAP_GB} GB)..."
    fallocate -l "${SWAP_GB}G" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB * 1024)) status=none
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null
    swapon /swapfile
    # Persist via fstab
    if ! grep -q '^/swapfile' /etc/fstab; then
      echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
    echo "✓ Created + activated ${SWAP_GB} GB swap (persistent in /etc/fstab)"
  fi
fi

# ────────────────────────────────────────────────
# 3. OPcache bump for every PHP-FPM ini.d found
# ────────────────────────────────────────────────
echo ""
echo "─── [3/11] OPcache tuning (per-version, scaled to REAL workload) ───"
# ⚠ THE BUG THIS REPLACES (found 2026-08-09): this step used to write ONE
# RAM-derived size (e.g. 256M/20000) to EVERY PHP version. That ignores how many
# sites each version actually serves. On s4 the busiest version (php83: 23 sites,
# 201,918 .php files) got the SAME 256M as eight versions serving ZERO sites —
# 10.2 MB/site, with slots for only ~10% of the code. OPcache has NO LRU
# eviction: once full it simply stops caching and everything else recompiles on
# EVERY request, which is both slow and CPU-expensive (it looked like a CPU
# shortage). s2's php85 had already logged 2 out-of-memory restarts.
#
# Sizing basis (measured live, not guessed): a cached WooCommerce script averages
# ~29.4 KB of opcode, and a warm cache holds roughly half a site's files, so the
# budget is files*15KB. Slots = files+30% (they're cheap; memory fills first —
# the busiest pool measured used only 7.3% of its slots). Versions with no sites
# drop to 64M, which reclaims enough to fund the busy ones. Total is capped at
# OPCACHE_RAM_PCT of system RAM (default 25%) so this can never eat the box.
OPCACHE_RAM_PCT="${OPCACHE_RAM_PCT:-25}"
if [ ${#PHP_INI_DIRS[@]} -eq 0 ]; then
  echo "⊘ No PHP ini directories detected — skipping"
else
  _oc_vhosts=/usr/local/apache/conf.d/vhosts
  _oc_ram=$(free -m | awk '/^Mem:/{print $2}')
  _oc_budget=$(( _oc_ram * OPCACHE_RAM_PCT / 100 ))
  _oc_plan=""; _oc_total=0

  for INI_DIR in "${PHP_INI_DIRS[@]}"; do
    _v=$(echo "$INI_DIR" | grep -oE 'php-fpm[0-9]+' | grep -oE '[0-9]+$')
    _sites=0; _files=0
    if [ -n "$_v" ] && [ -d "$_oc_vhosts" ]; then
      for _f in $(grep -lE "php-fpm$_v/usr/var/sockets" "$_oc_vhosts"/*.ssl.conf 2>/dev/null); do
        _d=$(grep -hoE 'DocumentRoot [^ ]+' "$_f" 2>/dev/null | head -1 | awk '{print $2}')
        [ -d "$_d" ] || continue
        _sites=$(( _sites + 1 ))
        _files=$(( _files + $(find "$_d" -name '*.php' -type f 2>/dev/null | wc -l) ))
      done
    fi
    if [ "$_sites" -eq 0 ]; then
      _mb=64; _slots=10000; _int=8
    else
      _slots=$(( ((_files * 13 / 10) / 10000 + 1) * 10000 )); [ "$_slots" -lt 20000 ] && _slots=20000
      _mb=$(( _files * 15 / 1024 )); _mb=$(( (_mb / 128 + 1) * 128 )); [ "$_mb" -lt 256 ] && _mb=256
      if   [ "$_sites" -ge 20 ]; then _int=64
      elif [ "$_sites" -ge 10 ]; then _int=48
      elif [ "$_sites" -ge 5 ];  then _int=32
      else _int=16; fi
    fi
    _oc_total=$(( _oc_total + _mb ))
    _oc_plan="${_oc_plan}${INI_DIR}|${_v}|${_sites}|${_files}|${_mb}|${_slots}|${_int}
"
  done

  # Scale active versions back proportionally if the plan exceeds the RAM budget.
  if [ "$_oc_total" -gt "$_oc_budget" ] && [ "$_oc_budget" -gt 0 ]; then
    echo "⚠ plan ${_oc_total}M exceeds ${OPCACHE_RAM_PCT}% RAM budget (${_oc_budget}M) — scaling back"
    _new=""; _tot2=0
    while IFS='|' read -r _dir _v _s _fl _mb _sl _in; do
      [ -z "$_dir" ] && continue
      if [ "$_s" -gt 0 ]; then
        _mb=$(( _mb * _oc_budget / _oc_total )); _mb=$(( (_mb / 128 + 1) * 128 ))
        [ "$_mb" -lt 256 ] && _mb=256
      fi
      _tot2=$(( _tot2 + _mb )); _new="${_new}${_dir}|${_v}|${_s}|${_fl}|${_mb}|${_sl}|${_in}
"
    done <<< "$_oc_plan"
    _oc_plan="$_new"; _oc_total=$_tot2
  fi

  while IFS='|' read -r _dir _v _s _fl _mb _sl _in; do
    [ -z "$_dir" ] && continue
    # ⚠ Filename MUST sort AFTER the stock alt-php "opcache.ini". PHP parses the
    # scan dir ALPHABETICALLY and the LAST file wins. "99-*" (digit) sorts BEFORE
    # "opcache.ini" (letter) → our tune was silently overridden by the stock
    # 128 MB defaults on every alt-php version. "zz-*" sorts after → it applies.
    rm -f "$_dir/99-opcache-tuned.ini"   # drop the old ineffective name
    cat > "$_dir/zz-opcache-tuned.ini" <<EOF
; BH OPcache — sized to this version's ACTUAL workload, not to server RAM.
; sites=${_s}  php_files=${_fl}  (measured on this server at bootstrap time)
opcache.memory_consumption=${_mb}
opcache.max_accelerated_files=${_sl}
opcache.interned_strings_buffer=${_in}
opcache.revalidate_freq=60
opcache.validate_timestamps=1
opcache.max_wasted_percentage=10
EOF
    printf "✓ php%-3s sites=%-3s files=%-7s → %sM / %s slots\n" "${_v:-?}" "$_s" "$_fl" "$_mb" "$_sl"
  done <<< "$_oc_plan"
  echo "  total ${_oc_total}M of ${_oc_budget}M budget (${OPCACHE_RAM_PCT}% of ${_oc_ram}M RAM)"
  echo "  ⚠ new sizes need a php-fpm restart to take effect (opcache shm is allocated at startup)"
fi

# ── OPcache health monitor: read-only, once daily, zero per-request cost ──
# opcache lives in each php-fpm MASTER's shared memory, so a CLI opcache_get_status
# reads a DIFFERENT cache (and the 8.1/8.2/8.3 CLI binaries segfault on CWP boxes).
# The only honest read is from inside an FPM worker, so this drops a tiny status
# file into one docroot per version, fetches it once, and deletes it.
cat > /usr/local/sbin/bh-opcache-monitor.sh <<'BHOCMON'
#!/bin/bash
set -uo pipefail
QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1
VHOSTS=/usr/local/apache/conf.d/vhosts
ALERTLOG=/var/log/bh-opcache-monitor.log
SRVIP=$(hostname -I 2>/dev/null | cut -d' ' -f1)
STAMP=$(date '+%F %H:%M:%S'); HOST=$(hostname -s); PROBE=""
trap '[ -n "$PROBE" ] && rm -f "$PROBE" 2>/dev/null' EXIT
emit(){ [ "$QUIET" = 0 ] && echo "$*"; }
alert(){ echo "$STAMP $HOST $*" | tee -a "$ALERTLOG" >&2; }
emit "=== opcache health on $HOST ($STAMP) ==="
[ "$QUIET" = 0 ] && printf "  %-5s %-6s %-9s %-9s %-7s %-8s %-6s %s\n" VER FULL USED FREE WASTED SCRIPTS HIT% STATE
for V in $(ls -d /opt/alt/php-fpm* 2>/dev/null | grep -oE '[0-9]+$' | sort -n); do
  vh=$(grep -lE "php-fpm$V/usr/var/sockets" "$VHOSTS"/*.ssl.conf 2>/dev/null | head -1)
  [ -n "$vh" ] || continue
  D=$(grep -hoE 'DocumentRoot [^ ]+' "$vh" | head -1 | awk '{print $2}')
  DOM=$(grep -hoE 'ServerName [^ ]+' "$vh" | head -1 | awk '{print $2}')
  U=$(grep -hoE 'suPHP_UserGroup [a-z0-9_]+' "$vh" | head -1 | awk '{print $2}')
  [ -d "$D" ] && [ -n "$DOM" ] || continue
  PROBE="$D/bh-ocp-$$-${RANDOM}.php"
  cat > "$PROBE" <<'PHPPROBE'
<?php $s=@opcache_get_status(false); if(!$s){echo '{"err":1}';exit;}
$m=$s['memory_usage'];$t=$s['opcache_statistics'];$tot=$m['used_memory']+$m['free_memory']+$m['wasted_memory'];
echo json_encode(['full'=>$s['cache_full']?1:0,'oom'=>$t['oom_restarts'],
'used'=>round($m['used_memory']/1048576),'free'=>round($m['free_memory']/1048576),
'freepct'=>round(100*$m['free_memory']/max(1,$tot),1),'wasted'=>round($m['current_wasted_percentage'],1),
'scripts'=>$t['num_cached_scripts'],
'hit'=>round(100*$t['hits']/max(1,$t['hits']+$t['misses']),1)]);
PHPPROBE
  [ -n "$U" ] && chown "$U":"$U" "$PROBE" 2>/dev/null
  out=$(curl -sk --max-time 20 --resolve "$DOM:443:${SRVIP:-127.0.0.1}" "https://$DOM/$(basename "$PROBE")?x=$RANDOM" 2>/dev/null)
  rm -f "$PROBE"; PROBE=""
  g(){ echo "$out" | grep -oE "\"$1\":[0-9.]+" | grep -oE '[0-9.]+$'; }
  full=$(g full); oom=$(g oom); used=$(g used); free=$(g free); fpct=$(g freepct); wst=$(g wasted); scr=$(g scripts); hit=$(g hit)
  [ -z "$full" ] && { emit "  php$V  (no reading from $DOM)"; continue; }
  state="ok"
  [ "${full:-0}" = "1" ] && state="FULL"
  [ "${oom:-0}" -gt 0 ] 2>/dev/null && state="OOM($oom)"
  awk "BEGIN{exit !(${fpct:-100}<10)}" && [ "$state" = "ok" ] && state="LOW(${fpct}%)"
  [ "$QUIET" = 0 ] && printf "  php%-2s %-6s %-9s %-9s %-7s %-8s %-6s %s\n" "$V" "${full:-?}" "${used}M" "${free}M" "$wst" "$scr" "$hit" "$state"
  [ "$state" != "ok" ] && alert "php$V $state used=${used}M free=${free}M(${fpct}%) scripts=$scr hit=${hit}% oom=$oom"
done
BHOCMON
chmod +x /usr/local/sbin/bh-opcache-monitor.sh
cat > /etc/cron.d/bh-opcache-monitor <<'EOF'
# BH opcache health check — read-only, once daily (~0.4s), no per-request cost.
# Alerts land in /var/log/bh-opcache-monitor.log. Delete this file to disable.
17 6 * * * root /bin/bash /usr/local/sbin/bh-opcache-monitor.sh --quiet
EOF
chmod 644 /etc/cron.d/bh-opcache-monitor
echo "✓ /usr/local/sbin/bh-opcache-monitor.sh + daily cron 06:17 (alerts on FULL / OOM / <10% free)"

# ────────────────────────────────────────────────
# 2c. CSF: exclude php-fpm from process-tracking (VSZ false alarms)
# ────────────────────────────────────────────────
# CSF's PT_USERMEM alerts on a process's VIRTUAL memory (VSZ). php-fpm workers
# legitimately carry a huge VSZ — the OPcache SHM (256 MB above) + shared libs
# are all mmap'd in — while real RSS stays ~40-80 MB. So lfd fires endless
# "Virtual Memory Size Exceeded" emails on perfectly healthy pools (and the
# OPcache bump makes it worse). CWP ships php-fpm exclusions but never adds NEW
# versions — php-fpm84/85 from cwp-custom-php were missing on the fleet → alerts.
# Add every installed alt-php + cwp php-fpm exe to csf.pignore so php-fpm is
# never process-tracked. Idempotent; reload lfd only (it reads csf.pignore).
if [ "$HAS_CSF" = 1 ] && [ -f /etc/csf/csf.pignore ]; then
  echo ""
  echo "─── CSF: exclude php-fpm from process-tracking (VSZ false alarms) ───"
  PIG=/etc/csf/csf.pignore; pig_added=0
  for f in /opt/alt/php-fpm*/usr/sbin/php-fpm /usr/local/cwp/php*/sbin/php-fpm; do
    [ -x "$f" ] || continue
    grep -qxF "exe:$f" "$PIG" 2>/dev/null || { echo "exe:$f" >> "$PIG"; pig_added=$((pig_added+1)); }
  done
  if [ "$pig_added" -gt 0 ]; then
    csf --lfd restart >/dev/null 2>&1 || csf -ra >/dev/null 2>&1   # lfd reload needed; --lfd restart avoids a firewall reload
    echo "✓ added $pig_added php-fpm exclusion(s) to csf.pignore + reloaded lfd"
  else
    echo "✓ all installed php-fpm versions already excluded from PT tracking"
  fi
fi

# ────────────────────────────────────────────────
# 3. Per-user FPM pool tuning + request_terminate_timeout
# ────────────────────────────────────────────────
echo ""
echo "─── [4/11] Per-user FPM pool tuning ───"
TOUCHED=0; SKIPPED=0; HEAVY_TOUCHED=0; MEDIUM_TOUCHED=0

# Auto-detect app tier by filesystem fingerprint. Saves maintaining the
# HEAVY_USERS list by hand — works in -y / curl|bash mode too.
# SKIP_USERS is a hard escape hatch: any user listed there is NEVER tuned.
#
# 3-tier classification (tier decided purely by app type — DB size is NOT a
# signal any more):
#   HEAVY  → real PHP frameworks: Laravel(artisan), CodeIgniter(spark /
#            system/core/CodeIgniter.php), Symfony(config/bundles.php).
#   MEDIUM → CMS/cart apps: WordPress(wp-load/wp-config), WooCommerce,
#            OpenCart(system/library/cart/cart.php), Magento(env.php/Mage.php).
#   LIGHT  → everything else (static HTML / basic PHP).
#
# bh_classify_user <homedir> → echoes: heavy | medium | light
# NOTE: the heal cron (heredoc below) carries an IDENTICAL copy of this logic —
# keep the two in sync if you change a fingerprint.
bh_classify_user() {
  local H="$1"
  # ── HEAVY: PHP frameworks ──
  find "$H" -maxdepth 4 -name artisan -type f 2>/dev/null | head -1 | grep -q . && { echo heavy; return; }
  find "$H" -maxdepth 4 -name spark   -type f 2>/dev/null | head -1 | grep -q . && { echo heavy; return; }
  find "$H" -maxdepth 5 -type f -path "*/system/core/CodeIgniter.php" 2>/dev/null | head -1 | grep -q . && { echo heavy; return; }
  find "$H" -maxdepth 5 -type f -path "*/config/bundles.php"          2>/dev/null | head -1 | grep -q . && { echo heavy; return; }
  # ── MEDIUM: CMS / cart ──
  find "$H" -maxdepth 5 -type f \( -name wp-load.php -o -name wp-config.php \) 2>/dev/null | head -1 | grep -q . && { echo medium; return; }
  find "$H" -maxdepth 5 -type f -path "*/system/library/cart/cart.php"         2>/dev/null | head -1 | grep -q . && { echo medium; return; }
  find "$H" -maxdepth 5 -type f \( -path "*/app/etc/env.php" -o -path "*/app/Mage.php" \) 2>/dev/null | head -1 | grep -q . && { echo medium; return; }
  echo light
}

DETECTED_HEAVY=""
DETECTED_MEDIUM=""
for HOMEDIR in /home/*; do
  [ -d "$HOMEDIR" ] || continue
  USER=$(basename "$HOMEDIR")
  case " $HEAVY_USERS $SKIP_USERS " in *" $USER "*) continue ;; esac
  TIER=$(bh_classify_user "$HOMEDIR")
  case "$TIER" in
    heavy)  echo "  ✓ $USER: framework → heavy pool";   DETECTED_HEAVY="$DETECTED_HEAVY $USER" ;;
    medium) echo "  ✓ $USER: CMS/cart → medium pool";   DETECTED_MEDIUM="$DETECTED_MEDIUM $USER" ;;
    # light: no announce (the silent majority)
  esac
done
if [ -n "$DETECTED_HEAVY" ]; then
  HEAVY_USERS="$HEAVY_USERS$DETECTED_HEAVY"
fi
MEDIUM_USERS="${MEDIUM_USERS:-}$DETECTED_MEDIUM"

ensure_kv() {
  # Set key=value in a php-fpm-style INI file. Anchors on `=` so writing
  # short keys like `pm` does NOT mangle longer keys like `pm.max_children`
  # (regex `^pm.*` previously matched ALL pm.* lines, replacing them with
  # `pm = dynamic` and causing 4 duplicate pm= lines in production).
  local conf="$1" key="$2" value="$3"
  if grep -qE "^${key}[[:space:]]*=" "$conf"; then
    sed -i -E "s|^${key}[[:space:]]*=.*|${key} = ${value}|" "$conf"
  else
    echo "${key} = ${value}" >> "$conf"
  fi
}

if [ ${#PHP_FPM_USER_DIRS[@]} -eq 0 ]; then
  echo "⊘ No FPM pool dirs detected — skipping"
else
  for DIR in "${PHP_FPM_USER_DIRS[@]}"; do
    for CONF in "$DIR"/*.conf; do
      [ -f "$CONF" ] || continue
      USER=$(basename "$CONF" .conf)
      if echo " $SKIP_USERS " | grep -q " $USER "; then SKIPPED=$((SKIPPED+1)); continue; fi

      [ -f "${CONF}.bak-pre-tune" ] || cp "$CONF" "${CONF}.bak-pre-tune"

      if echo " $HEAVY_USERS " | grep -q " $USER "; then
        # HEAVY (Laravel/CodeIgniter/Symfony) — dynamic warm pool, full HEAVY_CHILDREN
        START_SVR=$(( HEAVY_CHILDREN / 5 )); [ $START_SVR -lt 2 ] && START_SVR=2
        MIN_SPARE=$(( HEAVY_CHILDREN / 10 )); [ $MIN_SPARE -lt 1 ] && MIN_SPARE=1
        MAX_SPARE=$(( HEAVY_CHILDREN / 2 )); [ $MAX_SPARE -lt 4 ] && MAX_SPARE=4
        # process_idle_timeout is ondemand-only — strip any stale leftover
        sed -i '/^pm\.process_idle_timeout[[:space:]]*=/d' "$CONF"
        ensure_kv "$CONF" "pm" "dynamic"
        ensure_kv "$CONF" "pm.max_children" "$HEAVY_CHILDREN"
        ensure_kv "$CONF" "pm.max_requests" "500"
        ensure_kv "$CONF" "pm.start_servers" "$START_SVR"
        ensure_kv "$CONF" "pm.min_spare_servers" "$MIN_SPARE"
        ensure_kv "$CONF" "pm.max_spare_servers" "$MAX_SPARE"
        ensure_kv "$CONF" "request_terminate_timeout" "30s"
        HEAVY_TOUCHED=$((HEAVY_TOUCHED+1))
      elif echo " $MEDIUM_USERS " | grep -q " $USER "; then
        # MEDIUM (WordPress/WooCommerce/OpenCart/Magento) — ondemand, 50% of heavy.
        # Strip heavy-only spare-server keys in case this user was heavy before.
        sed -i -E '/^pm\.(start_servers|min_spare_servers|max_spare_servers)[[:space:]]*=/d' "$CONF"
        ensure_kv "$CONF" "pm" "ondemand"
        ensure_kv "$CONF" "pm.max_children" "$MEDIUM_CHILDREN"
        ensure_kv "$CONF" "pm.max_requests" "500"
        ensure_kv "$CONF" "pm.process_idle_timeout" "30s"
        ensure_kv "$CONF" "request_terminate_timeout" "30s"
        MEDIUM_TOUCHED=$((MEDIUM_TOUCHED+1))
      else
        # LIGHT (static HTML / basic PHP) — ondemand, 25% of heavy.
        sed -i -E '/^pm\.(start_servers|min_spare_servers|max_spare_servers)[[:space:]]*=/d' "$CONF"
        ensure_kv "$CONF" "pm" "ondemand"
        ensure_kv "$CONF" "pm.max_children" "$LIGHT_CHILDREN"
        ensure_kv "$CONF" "pm.max_requests" "500"
        ensure_kv "$CONF" "pm.process_idle_timeout" "30s"
        ensure_kv "$CONF" "request_terminate_timeout" "30s"
        TOUCHED=$((TOUCHED+1))
      fi
    done
  done
  echo "✓ Light: $TOUCHED  Medium: $MEDIUM_TOUCHED  Heavy: $HEAVY_TOUCHED  Skipped: $SKIPPED"

  # ─ Persist tier values + user lists for the heal cron ─
  #   Why the heal cron exists: in production we hit a case where users
  #   correctly auto-detected as heavy still ended up with LIGHT_CHILDREN
  #   in their pool config — either a subtle script logic bug, or CWP
  #   regenerating pool configs from its template at some later trigger.
  #   The heal cron re-classifies every tenant every 5 min using the SAME
  #   fingerprints (bh_classify_user) and re-asserts the correct pool per
  #   tier (heavy/medium/light) if it drifts. Self-correcting both ways.
  mkdir -p /var/lib/bh-server-ops
  cat > /var/lib/bh-server-ops/fpm-config <<EOF
# Generated by perf-bootstrap.sh — values used by bh-fpm-pool-heal cron
HEAVY_CHILDREN=$HEAVY_CHILDREN
MEDIUM_CHILDREN=$MEDIUM_CHILDREN
LIGHT_CHILDREN=$LIGHT_CHILDREN
SKIP_USERS="$SKIP_USERS"
EOF
  echo "$HEAVY_USERS"  | tr ' ' '\n' | grep -v '^$' | sort -u > /var/lib/bh-server-ops/heavy-users.list
  echo "$MEDIUM_USERS" | tr ' ' '\n' | grep -v '^$' | sort -u > /var/lib/bh-server-ops/medium-users.list

  # ─ Install heal cron (every 5 min) ─
  cat > /usr/local/sbin/bh-fpm-pool-heal.sh <<'HEALSCRIPT'
#!/bin/bash
# BH-FPM-POOL-HEAL — every 5 min, re-classify every tenant by app type and
# reconcile its php-fpm pool to the correct TIER. Defends against CWP pool
# regen AND any script logic bug that misclassified users. Fully bidirectional:
# promotes AND demotes between heavy/medium/light as apps are installed/removed.
#
# Tiers (must mirror bh_classify_user in perf-bootstrap.sh):
#   HEAVY  (Laravel/CodeIgniter/Symfony) → pm=dynamic, HEAVY_CHILDREN + spares
#   MEDIUM (WordPress/Woo/OpenCart/Magento) → pm=ondemand, MEDIUM_CHILDREN
#   LIGHT  (static/basic, the default) → pm=ondemand, LIGHT_CHILDREN

CONF=/var/lib/bh-server-ops/fpm-config
[ -f "$CONF" ] || exit 0
. "$CONF"
[ -n "$HEAVY_CHILDREN" ] || exit 0
# Back-compat: derive medium if an old fpm-config (pre-3-tier) lacks it.
# Ratio must mirror perf-bootstrap.sh: MEDIUM=75% (was 50%), LIGHT=25%.
[ -n "$MEDIUM_CHILDREN" ] || { MEDIUM_CHILDREN=$(( HEAVY_CHILDREN * 3 / 4 )); [ "$MEDIUM_CHILDREN" -lt 3 ] && MEDIUM_CHILDREN=3; }
[ -n "$LIGHT_CHILDREN" ]  || { LIGHT_CHILDREN=$(( HEAVY_CHILDREN / 4 ));      [ "$LIGHT_CHILDREN"  -lt 2 ] && LIGHT_CHILDREN=2; }
SKIP_USERS="${SKIP_USERS:-nobody}"

START_SVR=$(( HEAVY_CHILDREN / 5 )); [ $START_SVR -lt 2 ] && START_SVR=2
MIN_SPARE=$(( HEAVY_CHILDREN / 10 )); [ $MIN_SPARE -lt 1 ] && MIN_SPARE=1
MAX_SPARE=$(( HEAVY_CHILDREN / 2 )); [ $MAX_SPARE -lt 4 ] && MAX_SPARE=4

# Idempotent key=value setter, anchored on '=' so short keys like 'pm'
# don't accidentally clobber 'pm.max_children' etc.
ensure_kv() {
  local conf="$1" key="$2" value="$3"
  if grep -qE "^${key}[[:space:]]*=" "$conf"; then
    sed -i -E "s|^${key}[[:space:]]*=.*|${key} = ${value}|" "$conf"
  else
    echo "${key} = ${value}" >> "$conf"
  fi
}

# bh_classify_user <homedir> → echoes: heavy | medium | light
# IDENTICAL to the function in perf-bootstrap.sh — keep in sync.
bh_classify_user() {
  local H="$1"
  find "$H" -maxdepth 4 -name artisan -type f 2>/dev/null | head -1 | grep -q . && { echo heavy; return; }
  find "$H" -maxdepth 4 -name spark   -type f 2>/dev/null | head -1 | grep -q . && { echo heavy; return; }
  find "$H" -maxdepth 5 -type f -path "*/system/core/CodeIgniter.php" 2>/dev/null | head -1 | grep -q . && { echo heavy; return; }
  find "$H" -maxdepth 5 -type f -path "*/config/bundles.php"          2>/dev/null | head -1 | grep -q . && { echo heavy; return; }
  find "$H" -maxdepth 5 -type f \( -name wp-load.php -o -name wp-config.php \) 2>/dev/null | head -1 | grep -q . && { echo medium; return; }
  find "$H" -maxdepth 5 -type f -path "*/system/library/cart/cart.php"         2>/dev/null | head -1 | grep -q . && { echo medium; return; }
  find "$H" -maxdepth 5 -type f \( -path "*/app/etc/env.php" -o -path "*/app/Mage.php" \) 2>/dev/null | head -1 | grep -q . && { echo medium; return; }
  echo light
}

# Build the desired tier per user from a fresh filesystem scan.
DETECTED_HEAVY=" "; DETECTED_MEDIUM=" "
for HOMEDIR in /home/*; do
  [ -d "$HOMEDIR" ] || continue
  USER=$(basename "$HOMEDIR")
  case " $SKIP_USERS " in *" $USER "*) continue ;; esac
  case "$(bh_classify_user "$HOMEDIR")" in
    heavy)  DETECTED_HEAVY="$DETECTED_HEAVY$USER " ;;
    medium) DETECTED_MEDIUM="$DETECTED_MEDIUM$USER " ;;
  esac
done

# Refresh cached lists
echo "$DETECTED_HEAVY"  | tr ' ' '\n' | grep -v '^$' | sort -u > /var/lib/bh-server-ops/heavy-users.list
echo "$DETECTED_MEDIUM" | tr ' ' '\n' | grep -v '^$' | sort -u > /var/lib/bh-server-ops/medium-users.list

# Apply the HEAVY (dynamic) profile to a pool conf.
apply_heavy() {
  local POOL="$1"
  sed -i -E '/^pm[[:space:]]*=[[:space:]]*(dynamic|ondemand)[[:space:]]*$/d' "$POOL"
  sed -i '/^pm\.process_idle_timeout[[:space:]]*=/d' "$POOL"
  ensure_kv "$POOL" "pm" "dynamic"
  ensure_kv "$POOL" "pm.max_children" "$HEAVY_CHILDREN"
  ensure_kv "$POOL" "pm.max_requests" "500"
  ensure_kv "$POOL" "pm.start_servers" "$START_SVR"
  ensure_kv "$POOL" "pm.min_spare_servers" "$MIN_SPARE"
  ensure_kv "$POOL" "pm.max_spare_servers" "$MAX_SPARE"
  ensure_kv "$POOL" "request_terminate_timeout" "30s"
}

# Apply an ondemand profile (medium or light) to a pool conf.
apply_ondemand() {
  local POOL="$1" CHILDREN="$2"
  sed -i -E '/^pm[[:space:]]*=[[:space:]]*(dynamic|ondemand)[[:space:]]*$/d' "$POOL"
  sed -i -E '/^pm\.(start_servers|min_spare_servers|max_spare_servers)[[:space:]]*=/d' "$POOL"
  ensure_kv "$POOL" "pm" "ondemand"
  ensure_kv "$POOL" "pm.max_children" "$CHILDREN"
  ensure_kv "$POOL" "pm.max_requests" "500"
  ensure_kv "$POOL" "pm.process_idle_timeout" "30s"
  ensure_kv "$POOL" "request_terminate_timeout" "30s"
}

# Single reconcile loop over every pool conf: figure the user's desired tier
# (default LIGHT), skip if already in the correct clean state, else re-apply.
HEAVY_N=0; MEDIUM_N=0; LIGHT_N=0; CHANGED=0
for DIR in /opt/alt/php-fpm*/usr/etc/php-fpm.d/users; do
  for POOL in "$DIR"/*.conf; do
    [ -f "$POOL" ] || continue
    USER=$(basename "$POOL" .conf)
    case " $SKIP_USERS " in *" $USER "*) continue ;; esac

    # Desired tier
    if   echo "$DETECTED_HEAVY"  | grep -q " $USER "; then TIER=heavy
    elif echo "$DETECTED_MEDIUM" | grep -q " $USER "; then TIER=medium
    else TIER=light; fi

    CUR_PM=$(grep -oE '^pm[[:space:]]*=[[:space:]]*[a-z]+' "$POOL" | head -1 | awk '{print $3}')
    CUR_CHILDREN=$(grep -oE '^pm\.max_children[[:space:]]*=[[:space:]]*[0-9]+' "$POOL" | head -1 | awk '{print $3}')
    CUR_START=$(grep -oE '^pm\.start_servers[[:space:]]*=[[:space:]]*[0-9]+' "$POOL" | head -1 | awk '{print $3}')
    PM_LINE_COUNT=$(grep -cE '^pm[[:space:]]*=' "$POOL")
    HAS_SPARES=$(grep -cE '^pm\.(start_servers|min_spare_servers|max_spare_servers)' "$POOL")
    HAS_IDLE=$(grep -cE '^pm\.process_idle_timeout[[:space:]]*=' "$POOL")

    case "$TIER" in
      heavy)
        HEAVY_N=$((HEAVY_N+1))
        # Healthy: dynamic + right children + right start + EXACTLY one pm= line
        # (PM_LINE_COUNT=1 catches the legacy duplicate-pm bug) + no idle line.
        if [ "$CUR_PM" = "dynamic" ] && [ "$CUR_CHILDREN" = "$HEAVY_CHILDREN" ] \
           && [ "$CUR_START" = "$START_SVR" ] && [ "$PM_LINE_COUNT" = "1" ] && [ "$HAS_IDLE" = "0" ]; then
          continue
        fi
        apply_heavy "$POOL"; CHANGED=$((CHANGED+1)) ;;
      medium)
        MEDIUM_N=$((MEDIUM_N+1))
        if [ "$CUR_PM" = "ondemand" ] && [ "$CUR_CHILDREN" = "$MEDIUM_CHILDREN" ] \
           && [ "$PM_LINE_COUNT" = "1" ] && [ "$HAS_SPARES" = "0" ] && [ "$HAS_IDLE" -ge 1 ]; then
          continue
        fi
        apply_ondemand "$POOL" "$MEDIUM_CHILDREN"; CHANGED=$((CHANGED+1)) ;;
      light)
        LIGHT_N=$((LIGHT_N+1))
        if [ "$CUR_PM" = "ondemand" ] && [ "$CUR_CHILDREN" = "$LIGHT_CHILDREN" ] \
           && [ "$PM_LINE_COUNT" = "1" ] && [ "$HAS_SPARES" = "0" ] && [ "$HAS_IDLE" -ge 1 ]; then
          continue
        fi
        apply_ondemand "$POOL" "$LIGHT_CHILDREN"; CHANGED=$((CHANGED+1)) ;;
    esac
  done
done

if [ $CHANGED -gt 0 ]; then
  for SVC in $(systemctl list-units --type=service --state=active --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^php-fpm[0-9]+\.service$'); do
    systemctl reload "$SVC" >/dev/null 2>&1
  done
  echo "$(date '+%Y-%m-%d %H:%M:%S') changed=$CHANGED (heavy=$HEAVY_N medium=$MEDIUM_N light=$LIGHT_N)" >> /var/log/bh-fpm-heal.log
fi
HEALSCRIPT
  chmod +x /usr/local/sbin/bh-fpm-pool-heal.sh

  cat > /etc/cron.d/bh-fpm-pool-heal <<'HEALCRON'
# BH-FPM-POOL-HEAL — re-assert per-tier pm pools (heavy/medium/light) every 5 min
*/5 * * * * root /usr/local/sbin/bh-fpm-pool-heal.sh >/dev/null 2>&1
HEALCRON
  touch /var/log/bh-fpm-heal.log
  echo "✓ heal cron installed: /usr/local/sbin/bh-fpm-pool-heal.sh (every 5 min)"
fi

# ────────────────────────────────────────────────
# 4. CWP template patch (only if CWP detected)
# ────────────────────────────────────────────────
echo ""
echo "─── [5/11] CWP template patch ───"
if [ -n "$CWP_TPL_DIR" ] && [ -d "$CWP_TPL_DIR" ]; then
  for T in "$CWP_TPL_DIR"/default.tpl "$CWP_TPL_DIR"/processes-40.tpl "$CWP_TPL_DIR"/processes-45.tpl; do
    [ -f "$T" ] || continue
    chattr -i "$T" 2>/dev/null || true
    [ -f "${T}.bak-pre-tune" ] || cp "$T" "${T}.bak-pre-tune"
    sed -i "s/^pm.max_children = .*/pm.max_children = ${LIGHT_CHILDREN}/" "$T"
    sed -i 's/^pm.max_requests = .*/pm.max_requests = 500/' "$T"
    sed -i 's/^pm.process_idle_timeout = .*/pm.process_idle_timeout = 30s/' "$T"
    grep -q "^request_terminate_timeout" "$T" || \
      echo "request_terminate_timeout = 30s" >> "$T"
    chattr +i "$T" 2>/dev/null || true
    echo "✓ $(basename $T) patched & frozen"
  done
else
  echo "⊘ Not CWP — skipping template patch"
fi

# ────────────────────────────────────────────────
# 5b. HTTP/3 enablement — MUST run before any nginx-touching section
#     (otherwise the nginx package swap reinstalls and our anti-bot /
#     perf configs end up applied against the wrong binary)
# ────────────────────────────────────────────────
echo ""
echo "─── [5b/11] HTTP/3 (codeit nginx + QUIC templates) ───"

if [ "$ENABLE_HTTP3" != "1" ]; then
  echo "⊘ HTTP/3 enablement skipped (set ENABLE_HTTP3=1 to enable)"
elif [ "$IS_SLAVE_SERVER" = "1" ]; then
  echo "⊘ slave/API mode — skipping HTTP/3 (browsers don't talk to slave APIs)"
elif ! grep -qiE 'release 8' /etc/redhat-release 2>/dev/null /etc/almalinux-release 2>/dev/null /etc/system-release 2>/dev/null; then
  echo "⊘ HTTP/3 swap targets EL8 only (codeit build is EL8-specific) — skipping"
elif ! command -v nginx >/dev/null 2>&1; then
  echo "⊘ nginx not installed — skipping HTTP/3"
else
  CWP_NGINX_TPL_DIR=/usr/local/cwpsrv/htdocs/resources/conf/web_servers/vhosts/nginx
  H3_BACKUP_DIR="/var/backups/bh-http3/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$H3_BACKUP_DIR"

  # ─ A. Detect if already on codeit build ─
  CURRENT_RELEASE=$(rpm -qi nginx 2>/dev/null | awk -F': ' '/^Release/ {print $2; exit}')
  if echo "$CURRENT_RELEASE" | grep -q 'codeit'; then
    echo "✓ nginx already on codeit build ($CURRENT_RELEASE) — skipping package swap"
  else
    echo "  Current nginx release: ${CURRENT_RELEASE:-unknown} — swap needed"

    # ─ B. Disable F5 nginx-mainline repo if present ─
    if [ -f /etc/yum.repos.d/nginx.repo ]; then
      cp /etc/yum.repos.d/nginx.repo "$H3_BACKUP_DIR/nginx.repo"
      yum-config-manager --disable nginx-mainline >/dev/null 2>&1 || \
        sed -i '/\[nginx-mainline\]/,/^\[/{s/^enabled=1/enabled=0/}' /etc/yum.repos.d/nginx.repo
      echo "  ✓ disabled F5 nginx-mainline repo"
    fi

    # ─ C. Add codeit stable repo (mainline URL is 404 as of 2026-05; stable has H3 builds) ─
    if [ ! -f /etc/yum.repos.d/codeit.el8.repo ]; then
      cat > /etc/yum.repos.d/codeit.el8.repo <<'CODEITREPO'
[CodeIT]
name=CodeIT repo
baseurl=https://repo.codeit.guru/packages/centos/8/$basearch
enabled=1
gpgkey=https://repo.codeit.guru/RPM-GPG-KEY-MasterOfDevon
gpgcheck=1
CODEITREPO
      yum clean all >/dev/null 2>&1
      yum makecache >/dev/null 2>&1
      echo "  ✓ added codeit stable repo"
    fi

    # ─ D. Discover latest codeit package URLs ─
    CODEIT_BASE="https://repo.codeit.guru/packages/centos/8/x86_64"
    LATEST_NGINX=$(curl -s "$CODEIT_BASE/" 2>/dev/null | grep -oE 'nginx-[0-9.]+-[0-9]+\.module_codeit_mainline\.codeit\.el8\.x86_64\.rpm' | sort -V | tail -1)
    LATEST_BROTLI=$(curl -s "$CODEIT_BASE/" 2>/dev/null | grep -oE 'libbrotli-[0-9.]+-[0-9]+\.codeit\.el8\.x86_64\.rpm' | sort -V | tail -1)
    LATEST_OSSL=$(curl -s "$CODEIT_BASE/" 2>/dev/null | grep -oE 'openssl-quic-libs-[0-9.]+-[0-9]+\.codeit\.el8\.x86_64\.rpm' | sort -V | tail -1)
    if [ -z "$LATEST_NGINX" ] || [ -z "$LATEST_BROTLI" ] || [ -z "$LATEST_OSSL" ]; then
      echo "  ✗ couldn't discover codeit package URLs (network/repo issue) — skipping HTTP/3"
      ENABLE_HTTP3=0
    fi

    # ─ E. Atomic brotli swap — CRITICAL ORDER ─
    #     yum/dnf has a runtime dlopen on libbrotlidec.so.1 (NOT a declared
    #     RPM dep, so --whatrequires can't see it). If we remove brotli
    #     without immediately providing libbrotlidec.so.1, yum dies and we
    #     can't recover via yum. So: pre-download codeit's libbrotli, then
    #     rpm-erase brotli + rpm-install libbrotli back-to-back. Tight window.
    if [ "$ENABLE_HTTP3" = "1" ]; then
      if rpm -q libbrotli >/dev/null 2>&1 && ! rpm -q brotli >/dev/null 2>&1; then
        echo "✓ codeit libbrotli already installed — skipping brotli swap"
      elif rpm -q brotli >/dev/null 2>&1; then
        DEPS=$(rpm -q --whatrequires brotli libbrotlidec libbrotlienc libbrotlicommon 2>&1 | grep -v 'no package requires' | grep -v '^$' || true)
        if [ -n "$DEPS" ]; then
          echo "  ⚠ brotli has declared dependents — aborting HTTP/3 swap:"
          echo "$DEPS" | sed 's/^/    /'
          ENABLE_HTTP3=0
        else
          echo "  pre-downloading codeit libbrotli (yum has hidden runtime dep on libbrotlidec.so.1)..."
          if ! curl -fsSL -o /tmp/bh-codeit-libbrotli.rpm "$CODEIT_BASE/$LATEST_BROTLI"; then
            echo "  ✗ couldn't download codeit libbrotli — aborting (yum still works)"
            ENABLE_HTTP3=0
          elif [ ! -s /tmp/bh-codeit-libbrotli.rpm ]; then
            echo "  ✗ codeit libbrotli download was empty — aborting"
            ENABLE_HTTP3=0
          else
            # Tight swap — yum is unusable between these two rpm commands
            rpm -e --nodeps brotli 2>/dev/null
            if rpm -ivh /tmp/bh-codeit-libbrotli.rpm >/dev/null 2>&1; then
              echo "  ✓ swapped brotli → codeit libbrotli atomically"
            else
              echo "  ✗ FATAL: codeit libbrotli install failed — yum is now BROKEN"
              echo "    Recovery: rpm -ivh /tmp/bh-codeit-libbrotli.rpm"
              ENABLE_HTTP3=0
            fi
            rm -f /tmp/bh-codeit-libbrotli.rpm
          fi
        fi
      else
        # No brotli AND no libbrotli — install codeit's via rpm directly
        echo "  no brotli/libbrotli present — installing codeit libbrotli"
        if curl -fsSL -o /tmp/bh-codeit-libbrotli.rpm "$CODEIT_BASE/$LATEST_BROTLI" \
           && rpm -ivh /tmp/bh-codeit-libbrotli.rpm >/dev/null 2>&1; then
          echo "  ✓ codeit libbrotli installed"
        else
          echo "  ✗ codeit libbrotli install failed"
          ENABLE_HTTP3=0
        fi
        rm -f /tmp/bh-codeit-libbrotli.rpm
      fi
    fi

    # ─ F. Install codeit nginx + openssl-quic-libs via yum (yum works now) ─
    if [ "$ENABLE_HTTP3" = "1" ]; then
      echo "  installing nginx + openssl-quic-libs..."
      if yum install -y "$CODEIT_BASE/$LATEST_OSSL" "$CODEIT_BASE/$LATEST_NGINX" > /tmp/bh-http3-install.log 2>&1; then
        echo "  ✓ codeit nginx stack installed"
        [ -f /etc/nginx/nginx.conf.rpmnew ] && mv /etc/nginx/nginx.conf.rpmnew /etc/nginx/nginx.conf.rpmnew.ignored
        NEW_OSSL=$(nginx -V 2>&1 | grep -oE 'OpenSSL [0-9.]+' | head -1)
        echo "  ✓ now built with: $NEW_OSSL (was OpenSSL 1.1.1k)"
        rm -f /tmp/bh-http3-install.log
      else
        echo "  ✗ codeit nginx install failed — last 10 lines of /tmp/bh-http3-install.log:"
        tail -10 /tmp/bh-http3-install.log 2>/dev/null | sed 's/^/    /'
        ENABLE_HTTP3=0
      fi
    fi
  fi

  # ─ F. Self-signed default cert for QUIC binder (only if missing) ─
  if [ "$ENABLE_HTTP3" = "1" ]; then
    if [ ! -f /etc/pki/tls/certs/default.bundle ] || [ ! -f /etc/pki/tls/private/default.key ]; then
      mkdir -p /etc/pki/tls/certs /etc/pki/tls/private
      openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout /etc/pki/tls/private/default.key \
        -out /etc/pki/tls/certs/default.bundle \
        -days 1825 -subj "/CN=default" >/dev/null 2>&1
      chmod 600 /etc/pki/tls/private/default.key
      echo "  ✓ generated self-signed default cert (5-year, for QUIC binder)"
    else
      echo "✓ default cert already present"
    fi

    # ─ G. Global QUIC reuseport binder at /etc/nginx/bh.d/global_quic.conf ─
    #    (perf-bootstrap wires include /etc/nginx/bh.d/*.conf later in section 6c)
    NGX_BH_D=/etc/nginx/bh.d
    mkdir -p "$NGX_BH_D"
    if [ ! -f "$NGX_BH_D/global_quic.conf" ]; then
      cat > "$NGX_BH_D/global_quic.conf" <<'QUICCONF'
# BH-HTTP3-GLOBAL
# Reuseport binder for QUIC — only ONE server block per box can carry
# `reuseport` on UDP 443. This block owns the socket but does NOT serve
# content. Real H3 traffic is routed via SNI to per-vhost `listen 443 quic;`
# directives emitted by the CWP vhost template (BH-HTTP3-INJECT block).
server {
    listen 443 quic reuseport;
    listen [::]:443 quic reuseport;
    server_name _;
    ssl_certificate      /etc/pki/tls/certs/default.bundle;
    ssl_certificate_key  /etc/pki/tls/private/default.key;
    ssl_protocols TLSv1.3;
    ssl_conf_command Ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256;
    return 444;
}
# END BH-HTTP3-GLOBAL
QUICCONF
      echo "  ✓ wrote $NGX_BH_D/global_quic.conf"
    else
      echo "✓ $NGX_BH_D/global_quic.conf already present — leaving as-is"
    fi

    # ─ H. Patch CWP vhost templates (idempotent — skip if BH-HTTP3-INJECT tag present) ─
    if [ -d "$CWP_NGINX_TPL_DIR" ]; then
      # H.1 — Patch default.stpl + http3.stpl (whichever exist) with H3 listen lines.
      # Anchor: FIRST line containing "listen ... ssl" (matches any of:
      #   "listen :443 ssl http2;"   (legacy literal)
      #   "listen :443 ssl %http2%;" (CWP placeholder syntax)
      #   "listen :443 ssl;"         (nginx 1.30+ split syntax)
      # ). Skips webmail/mail/cpanel/ftp blocks (those come later, anchor=first).
      for TPL in default.stpl http3.stpl; do
        F="$CWP_NGINX_TPL_DIR/$TPL"
        [ -f "$F" ] || continue

        # State B — already script-managed → skip
        if grep -q 'BH-HTTP3-INJECT' "$F"; then
          echo "✓ $TPL already patched (BH-HTTP3-INJECT tag present) — skipping"
          continue
        fi

        # State C — manually H3'd without BH tags → skip with warning.
        # Detection: file contains `listen ... quic;`, `http3 on;`, or
        # `add_header Alt-Svc ... h3=`. Likely a prior manual edit;
        # injecting now would duplicate directives.
        if grep -qE '^[[:space:]]*(listen[[:space:]]+.*[[:space:]]quic[[:space:]]*;|http3[[:space:]]+on[[:space:]]*;|add_header[[:space:]]+Alt-Svc[[:space:]]+.*h3=)' "$F"; then
          echo "⚠ $TPL has manual H3 directives but no BH-HTTP3-INJECT tags — skipping."
          echo "   Detected lines:"
          grep -nE '^[[:space:]]*(listen[[:space:]]+.*[[:space:]]quic|http3[[:space:]]+on|add_header[[:space:]]+Alt-Svc[[:space:]]+.*h3=)' "$F" | sed 's/^/     /'
          echo "   Either remove those lines and re-run, or wrap them with BH-HTTP3-INJECT markers."
          continue
        fi

        # State A — clean CWP template → 3 modifications in MAIN server block only:
        #   1) Inject listen quic + http3 on after the FIRST listen-ssl line
        #   2) Append TLSv1.3 to `ssl_protocols TLSv1.2;` (QUIC needs TLSv1.3)
        #   3) Inject Alt-Svc add_header inside location / before proxy_pass
        #      (CRITICAL — nginx's add_header inheritance is all-or-nothing;
        #       server-level Alt-Svc gets clobbered by location-level
        #       add_headers in the CWP template's `location /` block)
        cp "$F" "$H3_BACKUP_DIR/$TPL"
        awk '
          BEGIN { block_count = 0; injected_listen = 0; injected_altsvc_loc = 0 }
          /^server[[:space:]]*\{/ { block_count++ }
          # (2) ssl_protocols TLSv1.2;  → ssl_protocols TLSv1.2 TLSv1.3;  (main block only)
          block_count == 1 && /^[[:space:]]*ssl_protocols[[:space:]]+TLSv1\.2[[:space:]]*;/ {
            sub(/TLSv1\.2[[:space:]]*;/, "TLSv1.2 TLSv1.3;")
          }
          # (1) listen ssl ... → also listen quic + http3 on
          /^[[:space:]]*listen[[:space:]].*[[:space:]]ssl([[:space:]]|;)/ && injected_listen == 0 {
            print
            print "    # BH-HTTP3-INJECT"
            print "    listen %ip%:%nginx_port% quic;"
            print "    http3 on;"
            print "    # END BH-HTTP3-INJECT"
            injected_listen = 1
            next
          }
          # (3) Alt-Svc inside MAIN block`s first proxy_pass-bearing location
          block_count == 1 && /^[[:space:]]*proxy_pass[[:space:]]/ && injected_altsvc_loc == 0 {
            print "        # BH-HTTP3-ALTSVC-LOC"
            print "        add_header Alt-Svc \047h3=\":443\"; ma=86400\047 always;"
            print "        # END BH-HTTP3-ALTSVC-LOC"
            injected_altsvc_loc = 1
          }
          { print }
        ' "$F" > "$F.tmp" && mv "$F.tmp" "$F"

        # Verify all 3 modifications landed
        MOD_LISTEN=$(grep -c 'BH-HTTP3-INJECT' "$F" 2>/dev/null || echo 0)
        MOD_TLS=$(grep -cE 'ssl_protocols.*TLSv1\.3' "$F" 2>/dev/null || echo 0)
        MOD_ALTSVC=$(grep -c 'BH-HTTP3-ALTSVC-LOC' "$F" 2>/dev/null || echo 0)
        if [ "$MOD_LISTEN" -ge 1 ] && [ "$MOD_TLS" -ge 1 ] && [ "$MOD_ALTSVC" -ge 1 ]; then
          echo "  ✓ patched $TPL (listen quic + TLSv1.3 + Alt-Svc, backup: $H3_BACKUP_DIR/$TPL)"
        else
          cp "$H3_BACKUP_DIR/$TPL" "$F"
          echo "  ✗ $TPL: incomplete patch (listen=$MOD_LISTEN tls=$MOD_TLS altsvc=$MOD_ALTSVC) — restored from backup"
          echo "     first 'listen' line:"
          grep -nE '^[[:space:]]*listen' "$F" | head -1 | sed 's/^/       /'
        fi
      done

      # H.2 — Auto-create http3.stpl by cloning the patched default.stpl, if missing.
      #       Fresh CWP installs don't ship http3.stpl. Having it gives a per-user
      #       fallback: admin assigns http3 template to a user → that user keeps H3
      #       even if default.stpl gets overwritten by a CWP update later.
      if [ ! -f "$CWP_NGINX_TPL_DIR/http3.stpl" ] && [ -f "$CWP_NGINX_TPL_DIR/default.stpl" ]; then
        cp "$CWP_NGINX_TPL_DIR/default.stpl" "$CWP_NGINX_TPL_DIR/http3.stpl"
        echo "  ✓ created http3.stpl (clone of patched default.stpl — per-user H3 fallback)"
      fi

      # H.3 — Auto-create http3.tpl by cloning default.tpl, if missing.
      #       Port-80 template — no H3 changes needed (H3 is HTTPS-only) but CWP
      #       expects both .tpl + .stpl when an admin assigns the "http3" template.
      if [ ! -f "$CWP_NGINX_TPL_DIR/http3.tpl" ] && [ -f "$CWP_NGINX_TPL_DIR/default.tpl" ]; then
        cp "$CWP_NGINX_TPL_DIR/default.tpl" "$CWP_NGINX_TPL_DIR/http3.tpl"
        echo "  ✓ created http3.tpl (clone of default.tpl — port 80 fallback)"
      fi
    else
      echo "⊘ $CWP_NGINX_TPL_DIR not found — skipping template patch"
    fi

    # ─ I. Open UDP 443 in whichever host firewall is active ─
    #     Most cloud/datacenter networks already allow UDP 443 at the edge —
    #     host firewall only matters if it's actively filtering. CSF and
    #     firewalld are the ones we know how to talk to. cpGuard doesn't
    #     manage L4 ports directly (it's a WAF/malware layer, port filtering
    #     is delegated to firewalld/iptables underneath). Anything else →
    #     silent skip; trust the network already permits UDP 443.
    if command -v csf >/dev/null 2>&1 && [ -f /etc/csf/csf.conf ] && systemctl is-active --quiet lfd 2>/dev/null; then
      if grep -E '^UDP_IN' /etc/csf/csf.conf | grep -qE '(^|,)443(,|"|$)'; then
        echo "✓ csf: UDP 443 already open"
      else
        sed -i 's/^\(UDP_IN = "[^"]*\)"/\1,443"/' /etc/csf/csf.conf
        sed -i 's/^\(UDP_OUT = "[^"]*\)"/\1,443"/' /etc/csf/csf.conf
        csf -r >/dev/null 2>&1
        echo "  ✓ csf: opened UDP 443"
      fi
    elif systemctl is-active --quiet firewalld 2>/dev/null; then
      if firewall-cmd --list-ports 2>/dev/null | grep -q '443/udp'; then
        echo "✓ firewalld: UDP 443 already open"
      else
        firewall-cmd --permanent --add-port=443/udp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        echo "  ✓ firewalld: opened UDP 443"
      fi
    else
      echo "ℹ csf/firewalld not actively managing ports — assuming UDP 443 open at network level"
    fi

    # ─ J. Install heal cron — re-injects template tag if CWP updates wipe it ─
    cat > /usr/local/sbin/bh-http3-template-heal.sh <<'HEALSCRIPT'
#!/bin/bash
# BH-HTTP3-TEMPLATE-HEAL — runs every 5 min via cron
# 1. Re-injects BH-HTTP3-INJECT block into CWP nginx vhost templates if
#    CWP package updates wiped it.
# 2. Recreates http3.stpl / http3.tpl from default.{stpl,tpl} if missing.
# Idempotent — no-op if everything is in place.
TPL_DIR=/usr/local/cwpsrv/htdocs/resources/conf/web_servers/vhosts/nginx
HEALED=0
for TPL in default.stpl http3.stpl; do
  F="$TPL_DIR/$TPL"
  [ -f "$F" ] || continue
  grep -q 'BH-HTTP3-INJECT' "$F" && continue
  if grep -qE '^[[:space:]]*(listen[[:space:]]+.*[[:space:]]quic[[:space:]]*;|http3[[:space:]]+on[[:space:]]*;|add_header[[:space:]]+Alt-Svc[[:space:]]+.*h3=)' "$F"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') SKIP $TPL: manual H3 directives present without BH-HTTP3-INJECT tags" >> /var/log/bh-http3-heal.log
    continue
  fi
  cp "$F" "$F.bh-pre-heal"
  awk '
    BEGIN { block_count = 0; injected_listen = 0; injected_altsvc_loc = 0 }
    /^server[[:space:]]*\{/ { block_count++ }
    block_count == 1 && /^[[:space:]]*ssl_protocols[[:space:]]+TLSv1\.2[[:space:]]*;/ {
      sub(/TLSv1\.2[[:space:]]*;/, "TLSv1.2 TLSv1.3;")
    }
    /^[[:space:]]*listen[[:space:]].*[[:space:]]ssl([[:space:]]|;)/ && injected_listen == 0 {
      print
      print "    # BH-HTTP3-INJECT"
      print "    listen %ip%:%nginx_port% quic;"
      print "    http3 on;"
      print "    # END BH-HTTP3-INJECT"
      injected_listen = 1
      next
    }
    block_count == 1 && /^[[:space:]]*proxy_pass[[:space:]]/ && injected_altsvc_loc == 0 {
      print "        # BH-HTTP3-ALTSVC-LOC"
      print "        add_header Alt-Svc \047h3=\":443\"; ma=86400\047 always;"
      print "        # END BH-HTTP3-ALTSVC-LOC"
      injected_altsvc_loc = 1
    }
    { print }
  ' "$F" > "$F.tmp" && mv "$F.tmp" "$F"
  if grep -q 'BH-HTTP3-INJECT' "$F" && grep -qE 'ssl_protocols.*TLSv1\.3' "$F" && grep -q 'BH-HTTP3-ALTSVC-LOC' "$F"; then
    HEALED=$((HEALED+1))
    rm -f "$F.bh-pre-heal"
  else
    cp "$F.bh-pre-heal" "$F"
    rm -f "$F.bh-pre-heal"
    echo "$(date '+%Y-%m-%d %H:%M:%S') WARN $TPL: incomplete patch — left untouched" >> /var/log/bh-http3-heal.log
  fi
done
# Recreate http3.{stpl,tpl} from default.{stpl,tpl} if missing
if [ ! -f "$TPL_DIR/http3.stpl" ] && [ -f "$TPL_DIR/default.stpl" ]; then
  cp "$TPL_DIR/default.stpl" "$TPL_DIR/http3.stpl"
  HEALED=$((HEALED+1))
fi
if [ ! -f "$TPL_DIR/http3.tpl" ] && [ -f "$TPL_DIR/default.tpl" ]; then
  cp "$TPL_DIR/default.tpl" "$TPL_DIR/http3.tpl"
  HEALED=$((HEALED+1))
fi
if [ $HEALED -gt 0 ]; then
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1
  echo "$(date '+%Y-%m-%d %H:%M:%S') healed $HEALED template(s)" >> /var/log/bh-http3-heal.log
fi
HEALSCRIPT
    chmod +x /usr/local/sbin/bh-http3-template-heal.sh
    cat > /etc/cron.d/bh-http3-heal <<'HEALCRON'
# BH-HTTP3-HEAL — re-inject H3 lines into CWP templates if wiped
*/5 * * * * root /usr/local/sbin/bh-http3-template-heal.sh >/dev/null 2>&1
HEALCRON
    touch /var/log/bh-http3-heal.log
    echo "  ✓ heal cron installed (every 5 min)"

    # ─ K. Quick nginx -t — if broken, restore template backups.
    #    Full nginx reload happens in section [9/11] after anti-bot/perf work.
    if ! nginx -t >/dev/null 2>&1; then
      echo "  ✗ nginx -t failed after H3 setup — restoring template backups"
      for TPL in default.stpl http3.stpl; do
        [ -f "$H3_BACKUP_DIR/$TPL" ] && cp "$H3_BACKUP_DIR/$TPL" "$CWP_NGINX_TPL_DIR/$TPL"
      done
      rm -f "$NGX_BH_D/global_quic.conf"
      echo "  ⚠ HTTP/3 rolled back — inspect: nginx -t"
    else
      echo "  ✓ nginx -t passes (final reload happens in section [9/11])"
    fi
  fi
fi

# ────────────────────────────────────────────────
# 5. Apache MPM bump (auto-detect MPM type)
# ────────────────────────────────────────────────
echo ""
echo "─── [6/11] Apache MPM tuning ───"
if [ "$APPLY_APACHE_MPM" = "1" ] && [ -n "$APACHE_BIN" ] && [ -f "$APACHE_MPM_CONF" ]; then
  CURRENT_MPM=$($APACHE_BIN -V 2>&1 | grep "Server MPM" | awk '{print $3}' | tr 'A-Z' 'a-z')
  echo "Current MPM: $CURRENT_MPM"
  echo "Config file: $APACHE_MPM_CONF"

  # Sanity: is the MPM conf file actually included by httpd.conf? CWP ships
  # it commented out by default → all our tuning becomes a no-op while
  # Apache silently runs on hardcoded built-in defaults (ServerLimit 16,
  # ThreadsPerChild 25 = 400 workers max). Auto-uncomment if found.
  HTTPD_CONF=$($APACHE_BIN -V 2>&1 | grep SERVER_CONFIG_FILE | sed 's/.*"\(.*\)".*/\1/')
  case "$HTTPD_CONF" in /*) : ;; *) HTTPD_CONF="$(dirname $($APACHE_BIN -V 2>&1 | grep HTTPD_ROOT | sed 's/.*"\(.*\)".*/\1/'))/$HTTPD_CONF" ;; esac
  HTTPD_ROOT=$($APACHE_BIN -V 2>&1 | grep HTTPD_ROOT | sed 's/.*"\(.*\)".*/\1/')
  [ -d "$HTTPD_ROOT" ] && HTTPD_CONF="$HTTPD_ROOT/conf/httpd.conf"
  if [ -f "$HTTPD_CONF" ]; then
    INCLUDE_REL=$(echo "$APACHE_MPM_CONF" | sed "s|$HTTPD_ROOT/||")
    if grep -qE "^\s*#\s*Include\s+(${INCLUDE_REL}|conf/extra/httpd-mpm.conf)" "$HTTPD_CONF"; then
      echo "⚠ httpd-mpm.conf include is COMMENTED OUT in $HTTPD_CONF — uncommenting"
      cp "$HTTPD_CONF" "${HTTPD_CONF}.bak-pre-mpm-include"
      sed -i 's|^\s*#\s*Include\s\+conf/extra/httpd-mpm.conf|Include conf/extra/httpd-mpm.conf|' "$HTTPD_CONF"
      echo "  ✓ uncommented — MPM conf will now actually load"
    elif ! grep -qE "^\s*Include\s+(${INCLUDE_REL}|conf/extra/httpd-mpm.conf)" "$HTTPD_CONF"; then
      echo "⚠ httpd-mpm.conf is not Include'd anywhere — adding line to $HTTPD_CONF"
      echo "Include conf/extra/httpd-mpm.conf" >> "$HTTPD_CONF"
    else
      echo "✓ httpd-mpm.conf is properly included"
    fi
  fi

  # MAX_WORKERS, THREADS_PER_CHILD, SERVER_LIMIT already computed in the
  # RAM TIER block at the top of the script — use those values.
  THREADS=$THREADS_PER_CHILD
  # Spare-thread band MUST cover several full children, otherwise Apache
  # constantly kills/spawns children to stay in band → graceful-shutdown
  # thrash (lots of "G" in scoreboard, multi-second DurationPerReq, server
  # appears slow with 0% CPU). Anchor to ThreadsPerChild × ServerLimit, not
  # MaxRequestWorkers / N.
  SS=4   # StartServers — Apache will scale up to MinSpareThreads anyway
  MIN_S=$(( THREADS_PER_CHILD * 2 ));                       [ $MIN_S -lt 50 ]  && MIN_S=50
  MAX_S=$(( THREADS_PER_CHILD * (SERVER_LIMIT / 2) ));      [ $MAX_S -lt 200 ] && MAX_S=200
  TL=$(( THREADS_PER_CHILD * 2 )); [ $TL -lt 64 ] && TL=64   # ThreadLimit
  echo "Sizing: TARGET_RAM=${TARGET_RAM_GB}G → MaxRequestWorkers=$MAX_WORKERS, ServerLimit=$SERVER_LIMIT, ThreadsPerChild=$THREADS"

  chattr -i "$APACHE_MPM_CONF" 2>/dev/null || true
  [ -f "${APACHE_MPM_CONF}.bak-pre-tune" ] || cp "$APACHE_MPM_CONF" "${APACHE_MPM_CONF}.bak-pre-tune"

  # ── Self-heal: strip stray immutable flags from RPM-OWNED apache paths ──
  # Older versions of this script (and manual hardening) left +i on files the
  # cwp-httpd RPM owns (conf/extra/*.conf, htdocs/*). rpm then can't replace
  # them → "Error unpacking rpm package" → `yum update cwp-httpd` fails and
  # Apache is stuck on the old version. Our own drop-ins (conf.d/99-global-
  # hardening.conf) are NOT rpm-owned and keep their +i.
  STUCK=$(lsattr -R /usr/local/apache/conf/extra /usr/local/apache/htdocs 2>/dev/null \
            | grep -E '^-{4}i' | awk '{print $NF}')
  if [ -n "$STUCK" ]; then
    printf '%s\n' "$STUCK" | while read -r f; do chattr -i "$f" 2>/dev/null || true; done
    echo "✓ cleared immutable flag on $(printf '%s\n' "$STUCK" | wc -l) rpm-owned file(s) (unblocks yum)"
  fi

  if [ "$CURRENT_MPM" = "event" ] || [ "$CURRENT_MPM" = "worker" ]; then
    MOD="mpm_${CURRENT_MPM}_module"
    python3 <<PYEOF
import re
path = '$APACHE_MPM_CONF'
with open(path) as f: content = f.read()
new_block = """<IfModule $MOD>
    StartServers             $SS
    MinSpareThreads        $MIN_S
    MaxSpareThreads        $MAX_S
    ThreadLimit            $TL
    ThreadsPerChild         $THREADS
    ServerLimit             $SERVER_LIMIT
    MaxRequestWorkers     $MAX_WORKERS
    MaxConnectionsPerChild 0
</IfModule>"""
if re.search(r'<IfModule\s+$MOD>.*?</IfModule>', content, re.DOTALL):
    content = re.sub(r'<IfModule\s+$MOD>.*?</IfModule>',
                     new_block, content, count=1, flags=re.DOTALL)
else:
    content += "\n\n" + new_block + "\n"
with open(path, 'w') as f: f.write(content)
print("✓ $MOD block updated")
PYEOF
  elif [ "$CURRENT_MPM" = "prefork" ]; then
    PRE_LIMIT=$(( MAX_WORKERS / 4 ))
    [ "$PRE_LIMIT" -lt 256 ] && PRE_LIMIT=256
    python3 <<PYEOF
import re
path = '$APACHE_MPM_CONF'
with open(path) as f: content = f.read()
new_block = """<IfModule mpm_prefork_module>
    StartServers           5
    MinSpareServers        5
    MaxSpareServers       20
    ServerLimit          $PRE_LIMIT
    MaxRequestWorkers    $PRE_LIMIT
    MaxConnectionsPerChild 0
</IfModule>"""
if re.search(r'<IfModule\s+mpm_prefork_module>.*?</IfModule>', content, re.DOTALL):
    content = re.sub(r'<IfModule\s+mpm_prefork_module>.*?</IfModule>',
                     new_block, content, count=1, flags=re.DOTALL)
else:
    content += "\n\n" + new_block + "\n"
with open(path, 'w') as f: f.write(content)
print("✓ prefork MPM block updated")
PYEOF
  else
    echo "⚠ Unknown MPM '$CURRENT_MPM' — skipping"
  fi

  if $APACHE_BIN -t 2>&1 | grep -q "Syntax OK"; then
    # ⚠ Do NOT chattr +i this file — it is OWNED BY THE cwp-httpd RPM.
    # An immutable rpm-owned file makes rpm fail to unpack
    # ("cpio: rename failed - Directory not empty") and the WHOLE
    # `yum update cwp-httpd` transaction aborts, leaving Apache on the old
    # version + a half-broken rpm state. Seen live 2026-07-28 fleet-wide.
    # The 5-min FPM/MPM heal cron re-asserts our values after a CWP rebuild,
    # so freezing the file buys nothing and breaks updates.
    chattr -i "$APACHE_MPM_CONF" 2>/dev/null || true
    echo "✓ MPM config valid"
    # MPM directives (ThreadsPerChild, ServerLimit) only re-read on a full
    # RESTART, never on a reload. Without this, the new MaxRequestWorkers
    # tier never takes effect and you stay capped at the old worker count.
    MPM_NEEDS_RESTART=1
  else
    echo "✗ Syntax error — restoring backup"
    cp "${APACHE_MPM_CONF}.bak-pre-tune" "$APACHE_MPM_CONF"
  fi
else
  echo "⊘ Apache MPM tuning skipped"
fi

# ────────────────────────────────────────────────
# 6g. httpd stale-PID self-heal (survives unclean / attack-forced reboots)
# ────────────────────────────────────────────────
# After a HARD reboot, Apache can leave a 0-byte / stale logs/httpd.pid. On
# next boot apachectl reads it, finds no valid PID, and refuses to start
# ("AH00058: Error retrieving pid file" → httpd.service fails). Observed on
# s3 after an attack-forced reboot (2026-06-08). A tiny systemd drop-in clears
# any stale pid before each start so httpd always comes back up. ExecStartPre
# runs ONLY on start (never on reload) so it can't disturb a live instance;
# lives in /etc so CWP package updates don't wipe it; leading '-' = ignore if
# the file is already gone.
echo ""
echo "─── [6g/11] httpd stale-PID self-heal ───"
if systemctl list-unit-files 2>/dev/null | grep -q '^httpd\.service' && [ -n "$APACHE_BIN" ]; then
  ROOT=$("$APACHE_BIN" -V 2>/dev/null | sed -n 's/.*HTTPD_ROOT="\([^"]*\)".*/\1/p')
  PIDREL=$("$APACHE_BIN" -V 2>/dev/null | sed -n 's/.*DEFAULT_PIDFILE="\([^"]*\)".*/\1/p')
  [ -z "$ROOT" ] && ROOT=/usr/local/apache
  [ -z "$PIDREL" ] && PIDREL=logs/httpd.pid
  case "$PIDREL" in /*) HTTPD_PID_PATH="$PIDREL" ;; *) HTTPD_PID_PATH="$ROOT/$PIDREL" ;; esac
  DROPIN_DIR=/etc/systemd/system/httpd.service.d
  DROPIN="$DROPIN_DIR/10-clear-stale-pid.conf"
  WANT="[Service]
ExecStartPre=-/bin/rm -f ${HTTPD_PID_PATH}"
  mkdir -p "$DROPIN_DIR"
  if [ "$(cat "$DROPIN" 2>/dev/null)" != "$WANT" ]; then
    printf '%s\n' "$WANT" > "$DROPIN"
    systemctl daemon-reload 2>/dev/null
    echo "✓ installed httpd stale-pid self-heal ($HTTPD_PID_PATH)"
  else
    echo "✓ httpd stale-pid self-heal already present ($HTTPD_PID_PATH)"
  fi
else
  echo "⊘ no httpd.service / Apache bin — skipping"
fi

# ────────────────────────────────────────────────
# 6h. ModSecurity request-body limit (large WP-admin / Elementor / Gutenberg saves)
# ────────────────────────────────────────────────
# Apache mod_security2 defaults SecRequestBodyNoFilesLimit to 128 KB. A
# WordPress/Elementor/Gutenberg "save" POSTs the entire page as one JSON body;
# once it crosses 128 KB, ModSecurity rejects the body → PHP receives a
# truncated request → mangled FastCGI response (the classic
# 'AH01071: Got error PHP message: ooo' + 'ModSecurity: Request body no files
# data length is larger than the configured limit') → the editor reports a
# save failure. Tell-tale symptom: "save works with 1-2 widgets, fails at 3"
# (the extra element tips the JSON over 128 KB). Raise the no-files limit to
# 64 MB and never hard-reject an over-size admin save — ProcessPartial scans
# the bulk and lets the remainder through. Server-wide (phase-1 directive),
# so it fixes every WP/admin site on the box at once.
echo ""
echo "─── [6h/11] ModSecurity request-body limit ───"
MODSEC_NOFILES_LIMIT="${MODSEC_NOFILES_LIMIT:-67108864}"    # 64 MB  — form/JSON POSTs (was 128 KB default)
MODSEC_BODY_LIMIT="${MODSEC_BODY_LIMIT:-134217728}"         # 128 MB — POSTs that include file uploads
if [ "$HAS_MODSEC" = 1 ] && [ -n "$APACHE_BIN" ]; then
  # Locate the Apache mod_security2 conf that turns the engine on.
  MSF=""
  for C in /usr/local/apache/conf.d/mod_security.conf \
           /etc/httpd/conf.d/mod_security.conf \
           /usr/local/apache/conf.d/*.conf /etc/httpd/conf.d/*.conf; do
    [ -f "$C" ] || continue
    if grep -qE '^[[:space:]]*(SecRequestBodyAccess|SecRuleEngine)' "$C" 2>/dev/null; then MSF="$C"; break; fi
  done
  if [ -z "$MSF" ]; then
    echo "⊘ mod_security active but no editable conf with SecRuleEngine/SecRequestBodyAccess found — skipping"
  else
    cp -a "$MSF" "${MSF}.bh-bak.$(date +%s)" 2>/dev/null
    # Anchor new directives just after SecRequestBodyAccess (inside <IfModule mod_security2.c>).
    ANCHOR=$(grep -nE '^[[:space:]]*SecRequestBodyAccess' "$MSF" | head -1 | cut -d: -f1)
    [ -z "$ANCHOR" ] && ANCHOR=$(grep -nE '^[[:space:]]*SecRuleEngine' "$MSF" | head -1 | cut -d: -f1)
    bh_set_modsec_directive() {   # $1=directive  $2=value
      if grep -qE "^[[:space:]]*$1([[:space:]]|\$)" "$MSF"; then
        sed -i -E "s|^[[:space:]]*$1[[:space:]].*|    $1 $2|" "$MSF"          # update in place (no line shift)
      elif [ -n "$ANCHOR" ]; then
        sed -i "${ANCHOR}a\\    $1 $2" "$MSF"                                  # insert below anchor
        ANCHOR=$((ANCHOR + 1))
      fi
    }
    bh_set_modsec_directive SecRequestBodyLimit        "$MODSEC_BODY_LIMIT"
    bh_set_modsec_directive SecRequestBodyNoFilesLimit "$MODSEC_NOFILES_LIMIT"
    bh_set_modsec_directive SecRequestBodyLimitAction  "ProcessPartial"
    if "$APACHE_BIN" -t >/dev/null 2>&1; then
      echo "✓ ModSecurity body limits set in $MSF"
      echo "    NoFiles=$MODSEC_NOFILES_LIMIT  Body=$MODSEC_BODY_LIMIT  Action=ProcessPartial (reload happens in [9/11])"
    else
      LAST_BAK=$(ls -t "${MSF}.bh-bak."* 2>/dev/null | head -1)
      [ -n "$LAST_BAK" ] && cp -a "$LAST_BAK" "$MSF"
      echo "⚠ httpd -t failed after edit — reverted $MSF, no change applied"
    fi
  fi
else
  echo "⊘ mod_security / Apache not detected — skipping"
fi

# ────────────────────────────────────────────────
# 6i. REST API write methods (PUT/DELETE/PATCH) — WooCommerce/WP REST,
#     courier & fulfilment integrations, mobile apps, headless, webhooks
# ────────────────────────────────────────────────
# Stock Apache/CWP ships conf/extra/httpd-userdir.conf with
#   <Directory "/home/*/public_html"> Require method GET POST OPTIONS </Directory>
# which DENIES PUT/DELETE/PATCH server-wide (authz_core "AH01630: client denied
# by server configuration"). WordPress/WooCommerce REST API uses PUT (update) and
# DELETE — so any integration that WRITES back (couriers like ecomdrive, Zapier,
# mobile apps, headless front-ends, payment/webhook callbacks) gets a 403 while
# reads (GET) work fine. Tell-tale: "connection test OK / GET works but order sync
# or status write-back fails with 403". Safe to allow because mod_dav is disabled
# (httpd-dav.conf stays #Include'd) — these methods simply reach PHP/WordPress;
# Apache never treats PUT as a filesystem write. Also mirror the methods into the
# COMODO CWAF method whitelist (rule id 210700) so the WAF policy agrees. Edits
# are validated with httpd -t (auto-revert on failure); reload happens in [9/11].
echo ""
echo "─── [6i/11] REST API write methods (PUT/DELETE/PATCH) ───"
if [ -n "$APACHE_BIN" ]; then
  UDF=""
  for C in /usr/local/apache/conf/extra/httpd-userdir.conf \
           /etc/httpd/conf/extra/httpd-userdir.conf \
           /etc/httpd/conf.d/userdir.conf \
           /etc/apache2/mods-available/userdir.conf; do
    [ -f "$C" ] && grep -qE '^[[:space:]]*Require method[[:space:]]' "$C" 2>/dev/null && { UDF="$C"; break; }
  done
  if [ -n "$UDF" ] && grep -qE '^[[:space:]]*Require method[[:space:]]+GET[[:space:]]+POST[[:space:]]+OPTIONS[[:space:]]*$' "$UDF"; then
    cp -a "$UDF" "${UDF}.bh-bak.$(date +%s)" 2>/dev/null
    sed -i -E 's|^([[:space:]]*Require method)[[:space:]]+GET[[:space:]]+POST[[:space:]]+OPTIONS[[:space:]]*$|\1 GET POST OPTIONS HEAD PUT DELETE PATCH|' "$UDF"
    if "$APACHE_BIN" -t >/dev/null 2>&1; then
      echo "✓ REST write methods enabled in $UDF (reload happens in [9/11])"
    else
      LAST_BAK=$(ls -t "${UDF}.bh-bak."* 2>/dev/null | head -1)
      [ -n "$LAST_BAK" ] && cp -a "$LAST_BAK" "$UDF"
      echo "⚠ httpd -t failed after edit — reverted $UDF, no change applied"
    fi
  elif [ -n "$UDF" ]; then
    echo "✓ httpd-userdir already allows REST methods (or customized) — $UDF"
  else
    echo "⊘ no httpd-userdir.conf with a 'Require method' allowlist found — skipping"
  fi
  # Mirror into COMODO CWAF method whitelist (id 210700 references this file) so
  # the WAF policy agrees. The file commonly ships WITHOUT a trailing newline —
  # guard it before appending or the first method joins the last line (PROPFINDPUT).
  WL=/usr/local/apache/modsecurity-cwaf/rules/userdata_wl_methods
  if [ "$HAS_MODSEC" = 1 ] && [ -f "$WL" ]; then
    [ -n "$(tail -c1 "$WL" 2>/dev/null)" ] && printf '\n' >> "$WL"   # ensure trailing newline
    for m in PUT DELETE PATCH; do grep -qxF "$m" "$WL" || printf '%s\n' "$m" >> "$WL"; done
    echo "✓ CWAF method whitelist includes PUT/DELETE/PATCH ($WL)"
  fi
else
  echo "⊘ Apache not detected — skipping"
fi

# ────────────────────────────────────────────────
# 6j. User-crontab SHELL heal (cPanel→CWP migration fix)
# ────────────────────────────────────────────────
# cPanel account migrations import user crontabs carrying
# SHELL="/usr/local/cpanel/bin/jailshell" — a path that does NOT exist on a
# CWP box. crond still LOGS the CMD every run, but the exec through the
# missing shell fails silently, so the job NEVER actually executes (WHMCS /
# Blesta / WordPress / Mautic crons look scheduled but do nothing — the #1
# "my cron isn't firing" cause on migrated resellers). Rewrite any SHELL=
# that points to a non-existent binary to /bin/bash, and install a 30-min
# heal cron so future migrations self-correct.
echo ""
echo "─── [6j/11] User-crontab SHELL heal (cPanel→CWP migration fix) ───"
cat > /usr/local/sbin/bh-cron-shell-heal.sh <<'HEALSCRIPT'
#!/bin/bash
# Auto-managed by bh-server-ops. Fix user crontabs whose SHELL= points to a
# non-existent binary (classic cPanel->CWP leftover: jailshell). crond logs
# the CMD but the exec via the missing shell fails silently -> job never runs.
BACKUP_DIR=/root/bh-cron-shell-backups
mkdir -p "$BACKUP_DIR"
fixed=0
for f in /var/spool/cron/*; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in *.bhbak.*|*.swp|*~) continue ;; esac
  sh=$(grep -oE '^[[:space:]]*SHELL=.*' "$f" 2>/dev/null | head -1 | sed 's/.*SHELL=//; s/"//g; s/[[:space:]]*$//')
  if [ -n "$sh" ] && [ ! -x "$sh" ]; then
    cp -a "$f" "$BACKUP_DIR/$(basename "$f").$(date +%s)" 2>/dev/null
    sed -i 's#^\([[:space:]]*\)SHELL=.*#\1SHELL="/bin/bash"#' "$f"
    touch "$f"
    logger -t bh-cron-shell-heal "fixed $(basename "$f"): SHELL was '$sh' -> /bin/bash" 2>/dev/null
    echo "  fixed $(basename "$f") (SHELL was '$sh')"
    fixed=$((fixed + 1))
  fi
done
echo "bh-cron-shell-heal: $fixed crontab(s) fixed"
exit 0
HEALSCRIPT
chmod 750 /usr/local/sbin/bh-cron-shell-heal.sh
/usr/local/sbin/bh-cron-shell-heal.sh | sed 's/^/  /'
cat > /etc/cron.d/bh-cron-shell-heal <<'HEALCRON'
# BH cron SHELL heal — auto-managed by bh-server-ops (fixes migrated jailshell crontabs)
*/30 * * * * root /usr/local/sbin/bh-cron-shell-heal.sh >/dev/null 2>&1
HEALCRON
chmod 644 /etc/cron.d/bh-cron-shell-heal
echo "✓ heal cron installed: /usr/local/sbin/bh-cron-shell-heal.sh (every 30 min)"

# ────────────────────────────────────────────────
# 6k. CWP panel hostname-cert heal (panel dead after a CWP update)
# ────────────────────────────────────────────────
# A CWP panel update can leave /etc/pki/tls/certs/hostname.crt missing while
# only hostname.cert exists. cwpsrv.conf references the .crt, so its
# ExecStartPre config test fails ("cannot load certificate ... hostname.crt")
# and the PANEL NEVER STARTS — ports 2082/2083/2086/2087 all refuse to
# connect while httpd/nginx keep serving sites fine. Hit the whole fleet
# 2026-07-28. Recreate the .crt from .cert and restart cwpsrv.
# ⚠ NEVER openssl-generate a fresh cert/key here — that overwrites the real
# hostname.key and yields "key values mismatch". Copy only.
echo ""
echo "─── [6k/11] CWP panel hostname-cert heal ───"
if [ -f /usr/local/cwpsrv/bin/cwpsrv ]; then
  if [ ! -f /etc/pki/tls/certs/hostname.crt ] && [ -f /etc/pki/tls/certs/hostname.cert ]; then
    cp -f /etc/pki/tls/certs/hostname.cert /etc/pki/tls/certs/hostname.crt
    chmod 644 /etc/pki/tls/certs/hostname.crt
    echo "✓ recreated missing /etc/pki/tls/certs/hostname.crt from hostname.cert"
  fi
  if /usr/local/cwpsrv/bin/cwpsrv -t >/dev/null 2>&1; then
    systemctl is-active --quiet cwpsrv || { systemctl restart cwpsrv 2>/dev/null; sleep 2; }
    echo "✓ cwpsrv config OK (service: $(systemctl is-active cwpsrv 2>/dev/null))"
  else
    echo "⚠ cwpsrv config test FAILS — panel will not start. Details:"
    /usr/local/cwpsrv/bin/cwpsrv -t 2>&1 | tail -3 | sed 's/^/    /'
  fi
else
  echo "⊘ cwpsrv not present — skipping"
fi

# ────────────────────────────────────────────────
# 5b. Apache mod_status visibility + bad-watchdog detector
# ────────────────────────────────────────────────
# Without /server-status reachable on the Apache backend port, future
# slowdown diagnosis is blind (you can't see scoreboard, BusyWorkers,
# DurationPerReq, Stopping count). Install a localhost-only Location.
# Also detect external "auto-restart on high load" cron scripts — these
# fight the tuning and cause the exact graceful-shutdown thrash we just
# fixed (lots of "G" in scoreboard, multi-second response times, 0% CPU).
echo ""
echo "─── [6b/11] Apache visibility + bad-watchdog check ───"
if [ -d /usr/local/apache/conf.d ] && [ -n "$APACHE_BIN" ]; then
  STATUS_CONF=/usr/local/apache/conf.d/server-status.conf
  PUB_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  cat > "$STATUS_CONF" <<EOF
ExtendedStatus On
<Location /server-status>
    SetHandler server-status
    Require ip 127.0.0.1
    Require ip ::1
${PUB_IP:+    Require ip $PUB_IP}
</Location>
EOF
  echo "✓ /server-status enabled (127.0.0.1${PUB_IP:+, $PUB_IP})"
fi
# Detect known-bad watchdog patterns in cron — anything that restarts httpd
# unconditionally based on load alone (no real TTFB check, no throttle).
BAD_WD=$(crontab -l 2>/dev/null | grep -E 'apache-watchdog|highload|systemctl restart httpd' | grep -v auto-recovery || true)
if [ -n "$BAD_WD" ]; then
  echo ""
  echo "⚠ WARNING: aggressive Apache restart cron detected:"
  echo "$BAD_WD" | sed 's/^/    /'
  echo "  These fight MPM tuning and cause graceful-shutdown thrash."
  echo "  Recommended: remove with → crontab -l | grep -v apache-watchdog | crontab -"
  echo "  This script's own /usr/local/sbin/auto-recovery is safer (real TTFB"
  echo "  check, 10-min throttle, reload before restart)."
fi

# ────────────────────────────────────────────────
# 6c. Nginx anti-bot + rate limiting (when nginx fronts Apache)
# ────────────────────────────────────────────────
# Why this exists: when Apache is the backend behind nginx (default CWP
# layout), bot traffic still consumes Apache workers — bots ignore robots.txt
# and hammer dynamic URLs. Cheaper to drop them at the nginx edge with
# `return 444` (closes connection, costs almost nothing) than to let them
# reach Apache+ModSecurity. Also rate-limits /robots.txt itself which is
# typically the most-hit URL on a hosting fleet (we saw 379 of 412 visible
# requests on one server).
#
# Strategy:
#   1. Drop /etc/nginx/conf.d/00-anti-bot.conf — http-level zones + UA map
#   2. Drop /etc/nginx/snippets/anti-bot-server.conf — server-level enforcement
#   3. Patch each existing CWP vhost in /etc/nginx/conf.d/vhosts/*.conf
#      to `include` the snippet (idempotent via marker)
#   4. Try to patch the CWP template so newly-created vhosts also get it
echo ""
echo "─── [6c/11] Nginx anti-bot + rate limit ───"

NGINX_BIN=$(command -v nginx 2>/dev/null || echo "")
if [ "$IS_SLAVE_SERVER" = "1" ]; then
  echo "⊘ slave/API mode — skipping anti-bot (would block server-to-server API auth)"
  echo "  to enable: rerun with IS_SLAVE_SERVER=0"
elif [ -z "$NGINX_BIN" ] || ! systemctl is-active --quiet nginx 2>/dev/null; then
  echo "⊘ nginx not running — skipping anti-bot setup"
else
  # Detect vhost dir (CWP variants)
  NGX_VHOST_DIR=""
  for D in /etc/nginx/conf.d/vhosts /usr/local/nginx/conf/conf.d/vhosts /etc/nginx/sites-enabled; do
    [ -d "$D" ] && NGX_VHOST_DIR="$D" && break
  done
  NGX_CONF_D=/etc/nginx/conf.d
  [ -d /usr/local/nginx/conf/conf.d ] && [ ! -d "$NGX_CONF_D" ] && NGX_CONF_D=/usr/local/nginx/conf/conf.d

  # ─ fd-limit auto-raise ─
  # nginx -t opens every per-vhost log file + cert + map. On large fleets
  # (observed on s1: 672 vhosts, default ulimit 1024) it hits "Too many open
  # files" mid-parse, bails before bh.d/*.conf loads, and the resulting
  # "unknown bh_bad_bot variable" error LOOKS like a config bug but is
  # actually fd starvation. Auto-raise BEFORE nginx -t to avoid the trap.
  CUR_NOFILE=$(ulimit -n 2>/dev/null || echo 1024)
  VHOST_COUNT=0
  [ -n "$NGX_VHOST_DIR" ] && VHOST_COUNT=$(find "$NGX_VHOST_DIR" -maxdepth 1 -name '*.conf' 2>/dev/null | wc -l)
  # Need ~10 fds per vhost (access log + error log + cert + key + chain +
  # snippet includes). Round up + headroom = 65536 on any box with 200+ vhosts.
  TARGET_NOFILE=65536
  if [ "$VHOST_COUNT" -gt 200 ] || [ "$CUR_NOFILE" -lt 4096 ]; then
    # 1) systemd override for nginx.service so daemon has high LimitNOFILE
    if [ -d /etc/systemd/system ]; then
      mkdir -p /etc/systemd/system/nginx.service.d
      if [ ! -f /etc/systemd/system/nginx.service.d/bh-nofile.conf ] || \
         ! grep -q "LimitNOFILE=$TARGET_NOFILE" /etc/systemd/system/nginx.service.d/bh-nofile.conf 2>/dev/null; then
        cat > /etc/systemd/system/nginx.service.d/bh-nofile.conf <<EOF
[Service]
LimitNOFILE=$TARGET_NOFILE
EOF
        systemctl daemon-reload 2>/dev/null
        echo "✓ systemd nginx LimitNOFILE=$TARGET_NOFILE (was default 1024)"
      fi
    fi
    # 2) tell nginx itself to actually use the higher limit (worker_rlimit_nofile)
    if [ -f "$NGX_MAIN_CONF_EARLY" ] || [ -f /etc/nginx/nginx.conf ]; then
      NGX_CONF_FOR_RLIMIT=/etc/nginx/nginx.conf
      [ -f /usr/local/nginx/conf/nginx.conf ] && [ ! -f "$NGX_CONF_FOR_RLIMIT" ] && NGX_CONF_FOR_RLIMIT=/usr/local/nginx/conf/nginx.conf
      if ! grep -qE '^\s*worker_rlimit_nofile' "$NGX_CONF_FOR_RLIMIT"; then
        sed -i "1i worker_rlimit_nofile $TARGET_NOFILE;" "$NGX_CONF_FOR_RLIMIT"
        echo "✓ added 'worker_rlimit_nofile $TARGET_NOFILE;' to $NGX_CONF_FOR_RLIMIT"
      fi
    fi
    # 3) limits.conf — for any future shell sessions / scripts
    if [ -d /etc/security/limits.d ]; then
      cat > /etc/security/limits.d/99-bh-nofile.conf <<EOF
* soft nofile $TARGET_NOFILE
* hard nofile $((TARGET_NOFILE * 2))
root soft nofile $TARGET_NOFILE
root hard nofile $((TARGET_NOFILE * 2))
EOF
      echo "✓ /etc/security/limits.d/99-bh-nofile.conf written"
    fi
    # 4) raise THIS shell's limit so the upcoming nginx -t can succeed
    ulimit -n "$TARGET_NOFILE" 2>/dev/null && echo "✓ raised current shell ulimit -n to $TARGET_NOFILE (was $CUR_NOFILE)"
    # 5) bounce nginx so the new daemon LimitNOFILE actually takes effect
    #    (reload doesn't change rlimit; only restart does)
    systemctl restart nginx 2>/dev/null && echo "✓ nginx restarted to pick up new fd limit"
  fi
  NGX_SNIPPETS=/etc/nginx/snippets
  mkdir -p "$NGX_SNIPPETS"

  # ─ http-level maps live OUTSIDE conf.d/ so CWP regen / yum reinstall nginx
  #   can't wipe them (which would leave the vhost-included snippet referencing
  #   undefined $bh_bad_bot / $bh_trusted_ip vars and refuse to start nginx).
  NGX_MAIN_CONF=/etc/nginx/nginx.conf
  [ -f /usr/local/nginx/conf/nginx.conf ] && [ ! -f "$NGX_MAIN_CONF" ] && NGX_MAIN_CONF=/usr/local/nginx/conf/nginx.conf
  NGX_BH_D=/etc/nginx/bh.d
  mkdir -p "$NGX_BH_D"
  if [ -f "$NGX_MAIN_CONF" ] && ! grep -qF "include $NGX_BH_D/" "$NGX_MAIN_CONF"; then
    # Insert before the first conf.d/*.conf include so maps load before vhosts.
    # Use awk (not sed) for whitespace-tolerant matching — different nginx
    # packagings format the include line differently (single vs multi space,
    # tabs, trailing space before semicolon).
    cp "$NGX_MAIN_CONF" "${NGX_MAIN_CONF}.bak-pre-bhd-include"
    awk -v incl="    include $NGX_BH_D/*.conf;" '
      !done && /include[[:space:]]+\/etc\/nginx\/conf\.d\/\*\.conf[[:space:]]*;/ {
        print incl
        done = 1
      }
      { print }
      END { exit (done ? 0 : 1) }
    ' "$NGX_MAIN_CONF" > "${NGX_MAIN_CONF}.tmp"
    if [ $? -eq 0 ] && grep -qF "include $NGX_BH_D/" "${NGX_MAIN_CONF}.tmp"; then
      mv "${NGX_MAIN_CONF}.tmp" "$NGX_MAIN_CONF"
      echo "✓ added 'include $NGX_BH_D/*.conf;' to $NGX_MAIN_CONF (before conf.d include)"
    else
      # Fallback: no conf.d/*.conf include found — append inside the http{} block
      # by inserting after the opening 'http {' line.
      rm -f "${NGX_MAIN_CONF}.tmp"
      awk -v incl="    include $NGX_BH_D/*.conf;" '
        !done && /^[[:space:]]*http[[:space:]]*\{/ {
          print
          print incl
          done = 1
          next
        }
        { print }
        END { exit (done ? 0 : 1) }
      ' "$NGX_MAIN_CONF" > "${NGX_MAIN_CONF}.tmp"
      if [ $? -eq 0 ] && grep -qF "include $NGX_BH_D/" "${NGX_MAIN_CONF}.tmp"; then
        mv "${NGX_MAIN_CONF}.tmp" "$NGX_MAIN_CONF"
        echo "✓ added 'include $NGX_BH_D/*.conf;' to $NGX_MAIN_CONF (after http{} open)"
      else
        rm -f "${NGX_MAIN_CONF}.tmp"
        echo "✗ could NOT insert 'include $NGX_BH_D/*.conf;' into $NGX_MAIN_CONF"
        echo "  add this line manually inside the http{} block, then re-run."
        echo "  skipping anti-bot setup to avoid leaving nginx in a broken state."
        # Skip the rest of the anti-bot block by faking the maps-not-loaded condition
        SKIP_ANTIBOT=1
      fi
    fi
  fi
  # Hard verify: the include must actually be in nginx.conf before we proceed,
  # otherwise the maps we're about to write will sit unused and nginx -t will
  # fail with 'unknown bh_bad_bot variable' the moment any vhost is reloaded.
  if [ "${SKIP_ANTIBOT:-0}" != "1" ] && ! grep -qF "include $NGX_BH_D/" "$NGX_MAIN_CONF"; then
    echo "✗ post-check: include line missing from $NGX_MAIN_CONF — aborting anti-bot setup"
    SKIP_ANTIBOT=1
  fi
  # If a previous bootstrap version dropped maps in conf.d/, remove them now
  # to avoid "duplicate map" errors once bh.d/ is loaded.
  rm -f "$NGX_CONF_D/00-anti-bot.conf" "$NGX_CONF_D/00-trusted-ips.conf"

  echo "  nginx vhost dir: ${NGX_VHOST_DIR:-(none found — http-only setup)}"
  echo "  nginx maps dir:  $NGX_BH_D"
  echo "  nginx conf.d:    $NGX_CONF_D"

if [ "${SKIP_ANTIBOT:-0}" = "1" ]; then
  echo "⊘ anti-bot setup skipped (couldn't wire up include in $NGX_MAIN_CONF)"
else
  # ─ http-level: trusted IPs (skip anti-bot for these) ─
  if [ -n "$TRUSTED_IPS" ]; then
    {
      echo "# bh-trusted v1 — IPs that bypass anti-bot (master/slave fleet sync)"
      echo "geo \$bh_trusted_ip {"
      echo "    default 0;"
      echo "    127.0.0.1/32 1;"
      for ip in $TRUSTED_IPS; do echo "    $ip/32 1;"; done
      echo "}"
    } > "$NGX_BH_D/00-trusted-ips.conf"
    echo "✓ wrote $NGX_BH_D/00-trusted-ips.conf ($(echo $TRUSTED_IPS | wc -w) IPs allowlisted)"
  else
    # always create a stub so the snippet's `if ($bh_trusted_ip)` is valid
    cat > "$NGX_BH_D/00-trusted-ips.conf" <<'EOTR'
# bh-trusted v1 — stub (no TRUSTED_IPS configured)
geo $bh_trusted_ip {
    default 0;
    127.0.0.1/32 1;
}
EOTR
  fi

  # ─ http-level: bad-bot UA map (zones removed — used by fail2ban now) ─
  cat > "$NGX_BH_D/00-anti-bot.conf" <<'NGXHTTP'
# bh-anti-bot v1 — http-level UA map (loaded before vhosts)

map $http_user_agent $bh_bad_bot {
    default                 0;
    # SEO-spy crawlers (not search engines — these scrape for paid SEO tools)
    "~*ahrefsbot"           1;
    "~*semrushbot"          1;
    "~*mj12bot"             1;
    "~*dotbot"              1;
    "~*petalbot"            1;
    "~*bytespider"          1;
    "~*amazonbot"           1;
    # AI training crawlers (NOT search engines — Googlebot is allowed)
    "~*claudebot"           1;
    "~*gptbot"              1;
    "~*chatgpt-user"        1;
    "~*ccbot"               1;
    "~*google-extended"     1;
    # Generic scraper toolkits
    "~*headlesschrome"      1;
    "~*scrapy"              1;
    "~*python-requests"     1;
    "~*go-http-client"      1;
    "~*libwww-perl"         1;
    # NOTE: Real search engines (Googlebot, Bingbot, DuckDuckBot, YandexBot,
    # BaiduSpider, Applebot) are NOT in this list and crawl normally.
    # facebookexternalhit is also NOT blocked — needed for social share previews.
    # Empty User-Agent is NOT blocked either — legitimate server-to-server API
    # clients (CWP DNS slave sync, Blesta hooks, internal monitoring scripts)
    # routinely send no UA. Blocking empty UA broke DNS slave sync on a
    # production CWP fleet — never again.
}

# bh-webmail v1 — strip leading "www." so domain.com/webmail -> webmail.domain.com
map $host $bh_wm_host {
    default               $host;
    "~^www\.(?<wmd>.+)$"  $wmd;
}
NGXHTTP

  # ─ http-level: wp-login.php per-IP rate-limit zone ─
  # Keyed on $binary_remote_addr (the REAL client — CWP already restores it from
  # Cloudflare via set_real_ip_from). The map yields an EMPTY key for every URI
  # except wp-login.php, and limit_req ignores empty keys — so ONLY wp-login is
  # rate-limited, server-wide, with no per-location/upstream knowledge needed.
  if [ "$APPLY_WP_EDGE_GUARD" = "1" ]; then
    cat >> "$NGX_BH_D/00-anti-bot.conf" <<NGXWP

# bh-wp-edge v1 — wp-login.php brute-force throttle (empty key elsewhere = not limited)
map \$request_uri \$bh_wplogin_key {
    default              "";
    "~*/wp-login\\.php"   \$binary_remote_addr;
}
limit_req_zone \$bh_wplogin_key zone=bh_wplogin:10m rate=$WPLOGIN_RATE;
limit_req_status 429;
NGXWP
    echo "✓ wp-login rate-limit zone added (rate=$WPLOGIN_RATE, real-IP keyed)"
  fi

  # ─ http-level: throttle aggressive but LEGITIMATE crawlers ─
  # facebookexternalhit must NOT be blocked (it powers link-share previews), but
  # left unlimited it can take a site down: izzaclothing.com (2026-08-26) was DDoSed
  # into 503 by facebookexternalhit from 434 distinct Facebook IPs — every FPM worker
  # stuck 20-29 min, 3,892 x 499 (crawler gave up, PHP kept running).
  # The zone key is a CONSTANT string, so ALL crawler IPs share ONE budget; a per-IP
  # limit would be useless against a 434-IP crawler. Empty key => not limited, so
  # real visitors are never affected.
  if [ "$APPLY_CRAWLER_THROTTLE" = "1" ]; then
    cat >> "$NGX_BH_D/00-anti-bot.conf" <<NGXCRAWL

# bh-crawler-throttle v1 — shared budget for aggressive-but-legitimate crawlers
map \$http_user_agent \$bh_slow_crawler {
    default                    "";
    "~*facebookexternalhit"    "fbcrawl";
    "~*meta-externalagent"     "fbcrawl";
}
limit_req_zone \$bh_slow_crawler zone=bh_crawler:10m rate=$CRAWLER_RATE;
NGXCRAWL
    # limit_req_status is emitted ONCE, by whichever guard runs. nginx treats a
    # SECOND limit_req_status at http level as a FATAL "directive is duplicate"
    # (verified on s3: nginx -t [emerg]) — so only set it if wp-edge did not.
    if [ "$APPLY_WP_EDGE_GUARD" != "1" ]; then
      echo "limit_req_status 429;" >> "$NGX_BH_D/00-anti-bot.conf"
    fi
    echo "✓ crawler throttle zone added (rate=$CRAWLER_RATE, shared across all crawler IPs)"
  fi

  # ─ server-level: the actual enforcement, included from each vhost ─
  # ONLY block-style rules — never try to "rate-limit then forward",
  # because we don't know the vhost's upstream from inside an include.
  # Brute-force protection on /wp-login.php is handled by fail2ban below.
  cat > "$NGX_SNIPPETS/anti-bot-server.conf" <<'NGXSERVER'
# bh-anti-bot v3 — included at the top of every server { }
# Trusted IPs bypass UA-based blocking (master/slave fleet sync, etc.)
# Path-based blocks below ALWAYS fire (xmlrpc/.env are never legit).

set $bh_block 0;
if ($bh_bad_bot)    { set $bh_block 1; }
if ($bh_trusted_ip) { set $bh_block 0; }
if ($bh_block = 1)  { return 444; }

# Block paths with no legitimate use + constant attack targets
location = /xmlrpc.php       { deny all; access_log off; log_not_found off; return 444; }
location ~* /wp-config\.php  { deny all; return 444; }
location ~* /\.(env|git|svn|htaccess|htpasswd|DS_Store)(/|$) { deny all; return 444; }
location ~* /(?:eval-stdin|wlwmanifest|adminer|phpunit|phpinfo)\.php$ { deny all; return 444; }

# bh-webmail v1 — /webmail (and /roundcube), www or non-www, -> https://webmail.<domain>/
# Fires at nginx BEFORE Apache/any CMS, so it works regardless of what's on the domain.
# Survives CWP vhost rebuilds because this snippet is injected into the CWP nginx template.
location ~* ^/(?:webmail|roundcube)(?:/|$) { return 301 https://webmail.$bh_wm_host/; }
NGXSERVER

  # ─ server-level: WordPress edge guard (wp-cron HTTP block + wp-login throttle) ─
  # wp-cron.php: hard 444 over HTTP. Real wp-cron runs via php-CLI cron (not HTTP)
  # so this only kills external bot abuse + per-visit loopback overhead — globally,
  # no per-site config. wp-login.php: apply the rate-limit zone (empty key elsewhere
  # → only wp-login is throttled; needs no upstream, so it's snippet-safe).
  if [ "$APPLY_WP_EDGE_GUARD" = "1" ]; then
    cat >> "$NGX_SNIPPETS/anti-bot-server.conf" <<NGXWPS

# bh-wp-edge v1 — block wp-cron over HTTP (CLI crons unaffected) + throttle wp-login
location = /wp-cron.php { deny all; access_log off; log_not_found off; return 444; }
limit_req zone=bh_wplogin burst=$WPLOGIN_BURST nodelay;
NGXWPS
    echo "✓ wp-cron HTTP block + wp-login throttle (burst=$WPLOGIN_BURST) added to snippet"
  fi

  # ─ server-level: apply the crawler cap ─
  # Over-limit crawlers get 429, which they honour and retry later — far better than
  # the 503s a saturated FPM pool returns to REAL visitors.
  if [ "$APPLY_CRAWLER_THROTTLE" = "1" ]; then
    cat >> "$NGX_SNIPPETS/anti-bot-server.conf" <<NGXCRAWLS

# bh-crawler-throttle v1 — stop one crawler exhausting a tenant's PHP-FPM pool
limit_req zone=bh_crawler burst=$CRAWLER_BURST nodelay;
NGXCRAWLS
    echo "✓ crawler throttle applied to snippet (burst=$CRAWLER_BURST)"
  fi

  echo "✓ wrote $NGX_BH_D/00-anti-bot.conf"
  echo "✓ wrote $NGX_SNIPPETS/anti-bot-server.conf"

  # Snapshot the generated maps so auto-recovery can self-heal if anything
  # ever wipes them at runtime (CWP regen, careless cleanup, etc.).
  mkdir -p /var/lib/bh-server-ops
  cp -f "$NGX_BH_D/00-anti-bot.conf"    /var/lib/bh-server-ops/00-anti-bot.conf
  cp -f "$NGX_BH_D/00-trusted-ips.conf" /var/lib/bh-server-ops/00-trusted-ips.conf

  # ─ patch existing vhosts (idempotent via marker) ─
  if [ -n "$NGX_VHOST_DIR" ]; then
    PATCHED=0; SKIPPED=0; FAILED=0
    for VH in "$NGX_VHOST_DIR"/*.conf; do
      [ -f "$VH" ] || continue
      # skip if already patched
      if grep -q "bh-anti-bot-injected" "$VH"; then
        SKIPPED=$((SKIPPED + 1))
        continue
      fi
      # sanity: must contain a server { block to patch
      grep -qE '^\s*server\s*\{' "$VH" || { SKIPPED=$((SKIPPED + 1)); continue; }
      # inject include directive after the FIRST `server {` line
      python3 - "$VH" <<'PYEOF' || FAILED=$((FAILED + 1))
import sys, re
p = sys.argv[1]
with open(p) as f: c = f.read()
inject = "    # bh-anti-bot-injected\n    include /etc/nginx/snippets/anti-bot-server.conf;\n"
new, n = re.subn(r'(server\s*\{\s*\n)', r'\1' + inject, c, count=1)
if n == 1:
    with open(p, 'w') as f: f.write(new)
PYEOF
      if grep -q "bh-anti-bot-injected" "$VH"; then
        PATCHED=$((PATCHED + 1))
      else
        FAILED=$((FAILED + 1))
      fi
    done
    echo "✓ vhosts: patched=$PATCHED, already-done=$SKIPPED, failed=$FAILED"
  fi

  # ─ patch CWP nginx template (so newly-created vhosts also get it) ─
  CWP_NGX_TPL=""
  for T in /usr/local/cwpsrv/htdocs/resources/conf/web_servers/vhosts/nginx/default.tpl \
           /usr/local/cwpsrv/htdocs/resources/conf/web_servers/vhosts/nginx/php-fpm/default.tpl \
           /usr/local/cwpsrv/htdocs/resources/admin/cwp_files/nginx_*.conf \
           /usr/local/cwpsrv/htdocs/resources/admin/templates/nginx_*.conf \
           /etc/cwpnginx/conf.d/*.tpl; do
    [ -f "$T" ] && CWP_NGX_TPL="$T" && break
  done
  if [ -n "$CWP_NGX_TPL" ]; then
    if ! grep -q "bh-anti-bot-injected" "$CWP_NGX_TPL"; then
      cp "$CWP_NGX_TPL" "${CWP_NGX_TPL}.bak-pre-antibot"
      python3 - "$CWP_NGX_TPL" <<'PYEOF' || true
import sys, re
p = sys.argv[1]
with open(p) as f: c = f.read()
inject = "    # bh-anti-bot-injected\n    include /etc/nginx/snippets/anti-bot-server.conf;\n"
new, n = re.subn(r'(server\s*\{\s*\n)', r'\1' + inject, c, count=1)
if n == 1:
    with open(p, 'w') as f: f.write(new)
PYEOF
      grep -q "bh-anti-bot-injected" "$CWP_NGX_TPL" \
        && echo "✓ CWP nginx template patched: $CWP_NGX_TPL" \
        || echo "⚠ couldn't auto-patch CWP template — patch manually if needed: $CWP_NGX_TPL"
    else
      echo "✓ CWP nginx template already patched"
    fi
  else
    echo "⊘ CWP nginx template not found — only existing vhosts patched"
  fi

  # ─ enable a slim access log (visibility for future debugging) ─
  # Many CWP setups disable nginx access logs entirely. Without them you
  # can't see WHO is hammering you when the next slow-hour hits.
  if ! grep -rq "access_log /var/log/nginx/access" "$NGX_CONF_D" 2>/dev/null; then
    cat > "$NGX_CONF_D/01-access-log.conf" <<'NGXLOG'
# bh-anti-bot v1 — slim access log for debugging bot floods
log_format bh_slim '$remote_addr "$request" $status $body_bytes_sent "$http_user_agent"';
access_log /var/log/nginx/access.log bh_slim buffer=32k flush=5s;
NGXLOG
    echo "✓ enabled slim nginx access log → /var/log/nginx/access.log"
  fi

  # ─ validate + reload ─
  if "$NGINX_BIN" -t 2>/dev/null; then
    systemctl reload nginx 2>/dev/null && echo "✓ nginx reloaded"
  else
    echo "✗ nginx config test failed — reverting anti-bot changes"
    rm -f "$NGX_BH_D/00-anti-bot.conf" "$NGX_BH_D/00-trusted-ips.conf" "$NGX_CONF_D/01-access-log.conf"
    rm -f "$NGX_SNIPPETS/anti-bot-server.conf"
    # Revert the include line we added to nginx.conf so we don't leave a dangling reference
    [ -f "${NGX_MAIN_CONF}.bak-pre-bhd-include" ] && cp "${NGX_MAIN_CONF}.bak-pre-bhd-include" "$NGX_MAIN_CONF"
    [ -n "$CWP_NGX_TPL" ] && [ -f "${CWP_NGX_TPL}.bak-pre-antibot" ] && cp "${CWP_NGX_TPL}.bak-pre-antibot" "$CWP_NGX_TPL"
    "$NGINX_BIN" -t
    echo "  reverted. nginx.conf restored from ${NGX_MAIN_CONF}.bak-pre-bhd-include"
  fi
fi  # close SKIP_ANTIBOT guard
fi

# ────────────────────────────────────────────────
# 6e. fail2ban for nginx 444s + WP brute-force
# ────────────────────────────────────────────────
# Drops repeat-offender IPs at the firewall level so they never reach
# nginx again. Two jails:
#   - nginx-badbot: any IP that gets 444'd more than 10 times in 10 min
#                   = persistent scraper, ban 24h
#   - wp-login:     any IP with 5+ POST /wp-login.php in 5 min
#                   = brute-force attempt, ban 1h
echo ""
echo "─── [6e/11] fail2ban (nginx + WP brute-force) ───"
if [ "$IS_SLAVE_SERVER" = "1" ]; then
  echo "⊘ slave/API mode — skipping fail2ban nginx jails (could ban legit API clients)"
  echo "  fail2ban can still be installed manually for SSH protection"
else
# Wrapped in `set +e` because package install can fail on locked-down
# systems (no EPEL repo, network issues) and we don't want to kill the
# whole bootstrap over an optional component.
set +e
# CRITICAL: every install call MUST have `</dev/null` to detach stdin.
# When the script is run via `curl | bash`, bash reads its commands from
# stdin. If dnf/yum/apt inherits that pipe, they silently consume the
# rest of the script as input → script appears to exit mid-section with
# no error. Wasted hours on this. Always redirect stdin for installers
# inside curl-piped scripts.
if ! command -v fail2ban-client >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then
    # On AlmaLinux/Rocky, EPEL is sometimes installed but not enabled
    # (CWP boxes especially). Three-step dance: install epel-release if
    # missing, force-enable the repo, refresh metadata, then install.
    rpm -q epel-release >/dev/null 2>&1 || dnf install -y -q epel-release </dev/null >/dev/null 2>&1
    dnf config-manager --set-enabled epel </dev/null >/dev/null 2>&1 || true
    # PowerTools (AlmaLinux 8) / CRB (RHEL 9+) holds some deps
    dnf config-manager --set-enabled powertools </dev/null >/dev/null 2>&1 || \
      dnf config-manager --set-enabled crb </dev/null >/dev/null 2>&1 || true
    dnf clean all </dev/null >/dev/null 2>&1
    dnf makecache </dev/null >/dev/null 2>&1
    dnf install -y -q fail2ban fail2ban-firewalld </dev/null >/dev/null 2>&1 || \
      dnf install -y -q fail2ban </dev/null >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    rpm -q epel-release >/dev/null 2>&1 || yum install -y -q epel-release </dev/null >/dev/null 2>&1
    yum-config-manager --enable epel </dev/null >/dev/null 2>&1 || true
    yum makecache </dev/null >/dev/null 2>&1
    yum install -y -q fail2ban </dev/null >/dev/null 2>&1
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update </dev/null >/dev/null 2>&1
    apt-get install -y -q fail2ban </dev/null >/dev/null 2>&1
  fi
fi
set -e

if command -v fail2ban-client >/dev/null 2>&1; then
  set +e   # don't kill the script if any single fail2ban op fails
  mkdir -p /etc/fail2ban/filter.d /etc/fail2ban/jail.d /etc/fail2ban/action.d

  # Filter: nginx 444 (bad bot)
  cat > /etc/fail2ban/filter.d/nginx-badbot.conf <<'F2BF'
[Definition]
failregex = ^<HOST>\s+"[A-Z]+\s+\S+.*"\s+444\s
ignoreregex =
F2BF

  # Filter: WP login POST
  cat > /etc/fail2ban/filter.d/wp-login.conf <<'F2BF'
[Definition]
failregex = ^<HOST>\s+"POST\s+(?:[^"]*/)?wp-login\.php[^"]*"
ignoreregex =
F2BF

  # Jail config — only active if nginx access log exists.
  # If CSF is detected & active, route bans through CSF so it doesn't
  # fight fail2ban's iptables rules.
  NGX_LOG=/var/log/nginx/access.log
  if systemctl is-active --quiet csf 2>/dev/null || command -v csf >/dev/null 2>&1; then
    F2B_BAN="csf-cmd"
    # filter.d action for CSF
    cat > /etc/fail2ban/action.d/csf-cmd.conf <<'CSFA'
[Definition]
actionban   = csf -d <ip> "fail2ban: <name>"
actionunban = csf -dr <ip>
CSFA
    echo "  CSF detected — fail2ban bans will route through CSF"
  else
    F2B_BAN="iptables-multiport"
  fi
  cat > /etc/fail2ban/jail.d/bh-nginx.conf <<F2BJ
[DEFAULT]
banaction = $F2B_BAN
backend   = auto

[nginx-badbot]
enabled  = true
port     = http,https
filter   = nginx-badbot
logpath  = $NGX_LOG
maxretry = 10
findtime = 600
bantime  = 86400

[wp-login]
enabled  = true
port     = http,https
filter   = wp-login
logpath  = $NGX_LOG
maxretry = 5
findtime = 300
bantime  = 3600
F2BJ

  systemctl enable --now fail2ban 2>/dev/null
  systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban 2>/dev/null
  sleep 1
  if systemctl is-active --quiet fail2ban; then
    echo "✓ fail2ban active — jails:"
    fail2ban-client status 2>/dev/null | grep -E "Jail list" | sed 's/^/    /'
  else
    echo "⚠ fail2ban installed but not running — check: journalctl -u fail2ban -n 50"
  fi
  set -e
else
  echo "⊘ fail2ban not installable on this system (no EPEL repo? offline?) — skipping"
  echo "  manual install: dnf install -y epel-release && dnf install -y fail2ban"
fi
fi   # close: if [ "$IS_SLAVE_SERVER" = "1" ]; then ... else ...

# ────────────────────────────────────────────────
# 6f. Nginx http-level perf tuning (open_file_cache + gzip + keepalive)
# ────────────────────────────────────────────────
# Note: we deliberately do NOT inject a static-file edge location into
# vhosts here. CWP's default vhost template already has a nested
# `location ~ .*\.(jpg|css|js|...)` block inside `location /` that does
# this correctly with the right `root` directive. Adding our own at
# server-level shadowed it (nginx prefers top-level regex over nested
# regex) and caused 404s/config errors on every CWP install.
#
# The actual speed wins are at the http {} level (loaded by all vhosts):
# open_file_cache, gzip, sendfile, keepalive — these don't touch
# location matching and are safe everywhere.
echo ""
echo "─── [6f/11] Nginx http-level perf tuning ───"
if [ -n "$NGINX_BIN" ] && systemctl is-active --quiet nginx 2>/dev/null; then
  # Roll back any prior buggy static-edge injection from older script versions
  rm -f "$NGX_SNIPPETS/static-edge.conf"
  if [ -n "$NGX_VHOST_DIR" ]; then
    for VH in "$NGX_VHOST_DIR"/*.conf; do
      [ -f "$VH" ] || continue
      if grep -q "bh-static-edge-injected" "$VH" 2>/dev/null; then
        sed -i '/bh-static-edge-injected/,+1d' "$VH"
      fi
    done
  fi

  # Check for each directive across the WHOLE nginx config tree (including
  # nginx.conf itself) — many distros pre-set some of these. We only emit
  # the lines that aren't already there, so we never get "duplicate".
  # NOTE: explicit `set +e` around this block — `[ -z ... ] && cat` returns
  # non-zero when the directive already exists, which would kill the
  # whole script under `set -e`.
  set +e
  ALL_NGX_CONF=$(find /etc/nginx /usr/local/nginx/conf -name "*.conf" -type f 2>/dev/null)
  has() { echo "$ALL_NGX_CONF" | xargs grep -lE "^\s*$1\b" 2>/dev/null | grep -v "02-perf.conf" | head -1; }
  PERF_CONF="$NGX_CONF_D/02-perf.conf"
  rm -f "$PERF_CONF"
  {
    echo "# bh-perf v1 — http-level perf knobs (only directives missing elsewhere)"
    if [ -z "$(has open_file_cache)" ]; then cat <<'EOP'
open_file_cache          max=10000 inactive=60s;
open_file_cache_valid    30s;
open_file_cache_min_uses 2;
open_file_cache_errors   on;
EOP
    fi
    if [ -z "$(has gzip_types)" ]; then cat <<'EOP'
gzip               on;
gzip_vary          on;
gzip_proxied       any;
gzip_comp_level    5;
gzip_min_length    1024;
gzip_types         text/plain text/css application/json application/javascript text/javascript application/xml application/xml+rss text/xml image/svg+xml application/vnd.ms-fontobject font/ttf font/otf font/eot;
EOP
    fi
    [ -z "$(has sendfile)" ]           && echo "sendfile           on;"
    [ -z "$(has tcp_nopush)" ]         && echo "tcp_nopush         on;"
    [ -z "$(has tcp_nodelay)" ]        && echo "tcp_nodelay        on;"
    [ -z "$(has keepalive_timeout)" ]  && echo "keepalive_timeout  30;"
    [ -z "$(has keepalive_requests)" ] && echo "keepalive_requests 1000;"
    [ -z "$(has server_tokens)" ]      && echo "server_tokens      off;"
    true   # ensure block returns 0
  } > "$PERF_CONF"
  if [ "$(wc -l < "$PERF_CONF" 2>/dev/null || echo 0)" -le 1 ]; then
    rm -f "$PERF_CONF"
    echo "✓ all perf directives already set elsewhere"
  else
    echo "✓ wrote $PERF_CONF (added missing perf directives only)"
  fi
  set -e

  if "$NGINX_BIN" -t 2>/dev/null; then
    systemctl reload nginx 2>/dev/null && echo "✓ nginx reloaded with perf tuning"
  else
    echo "⚠ nginx config error after perf tuning — review with: nginx -t"
    rm -f "$NGX_CONF_D/02-perf.conf"
  fi
else
  echo "⊘ nginx not running — skipping perf tuning"
fi

# ────────────────────────────────────────────────
# 6d. PHP handler audit (warn if users on slow CGI)
# ────────────────────────────────────────────────
# php-cgi (suPHP/mod_php) spawns a fresh PHP process per request — no
# OPcache reuse, ~100-250ms startup overhead. On a hosting fleet that's
# the difference between 5 sites/sec and 50 sites/sec. We don't auto-
# switch (CWP-specific operation, depends on user's PHP version), but
# warn so the admin can fix in CWP UI.
echo ""
echo "─── [6d/11] PHP handler audit ───"
CGI_USERS=$(ps -eo user,cmd 2>/dev/null | awk '/php-cgi/ && !/grep/ {print $1}' | sort -u | grep -vE '^(root|nobody|apache)$' || true)
if [ -n "$CGI_USERS" ]; then
  echo "⚠ Users running PHP via php-cgi (slow — should be PHP-FPM):"
  echo "$CGI_USERS" | sed 's/^/    /'
  echo "  Fix in CWP: User Account → List Accounts → Edit user → PHP Selector → PHP-FPM"
  echo "  Each user moved to FPM is roughly 10× less Apache worker time per request."
else
  echo "✓ no users on slow php-cgi handler"
fi

# ────────────────────────────────────────────────
# 6. Redis cap
# ────────────────────────────────────────────────
echo ""
echo "─── [7/11] Redis cap ───"
if [ "$APPLY_REDIS" = "1" ] && command -v redis-cli >/dev/null && systemctl is-active --quiet redis 2>/dev/null; then
  redis-cli CONFIG SET maxmemory "$REDIS_MAX" > /dev/null
  redis-cli CONFIG SET maxmemory-policy allkeys-lru > /dev/null
  redis-cli CONFIG REWRITE > /dev/null 2>&1 || true
  echo "✓ Redis: maxmemory $REDIS_MAX, allkeys-lru"
else
  echo "⊘ Redis not running or skipped"
fi

# ────────────────────────────────────────────────
# 7b. clamd resource cap (CPU/RAM/IO) — AV daemon is a known resource hog
# ────────────────────────────────────────────────
# clamd loads the full signature DB into RAM and spikes CPU + leaks RAM during
# mail scans, starving web/mysql. Cap it via a systemd drop-in so it always
# yields. Drop-in lives under /etc/systemd → survives CWP rebuilds (no re-assert
# cron needed). Idempotent: only rewrites + restarts clamd if the cap changed.
echo ""
echo "─── [7b/11] clamd resource cap ───"
if [ "$APPLY_CLAMD_LIMITS" = "1" ]; then
  CLAMD_UNIT=$(systemctl list-units --type=service --all 2>/dev/null | grep -oiE 'clamd@?[a-z]*\.service' | head -1)
  [ -z "$CLAMD_UNIT" ] && CLAMD_UNIT=$(systemctl list-unit-files 2>/dev/null | grep -oiE 'clamd@?[a-z]*\.service' | head -1)
  if [ -z "$CLAMD_UNIT" ]; then
    echo "⊘ no clamd unit on this box — skipping"
  else
    CLAMD_DROPDIR="/etc/systemd/system/${CLAMD_UNIT}.d"
    CLAMD_DROPIN="$CLAMD_DROPDIR/bh-limits.conf"
    mkdir -p "$CLAMD_DROPDIR"
    CLAMD_NEWCONF=$(cat <<CONF
# BH-CLAMD-LIMITS — cap clamd so it can't starve web/mysql/mail (resource hog, low value)
[Service]
CPUQuota=${CLAMD_CPUQUOTA}
MemoryMax=${CLAMD_MEMMAX}
MemoryHigh=${CLAMD_MEMHIGH}
Nice=15
IOSchedulingClass=idle
CPUWeight=20
# END BH-CLAMD-LIMITS
CONF
)
    if [ -f "$CLAMD_DROPIN" ] && [ "$(cat "$CLAMD_DROPIN")" = "$CLAMD_NEWCONF" ]; then
      echo "✓ clamd limits already applied ($CLAMD_UNIT: CPU $CLAMD_CPUQUOTA / RAM $CLAMD_MEMMAX) — unchanged"
    else
      echo "$CLAMD_NEWCONF" > "$CLAMD_DROPIN"
      systemctl daemon-reload
      systemctl restart "$CLAMD_UNIT" 2>/dev/null
      sleep 2
      if systemctl is-active --quiet "$CLAMD_UNIT"; then
        echo "✓ clamd capped ($CLAMD_UNIT): CPU $CLAMD_CPUQUOTA, MemoryMax $CLAMD_MEMMAX, idle IO, Nice 15"
      else
        echo "⚠ $CLAMD_UNIT didn't restart cleanly after cap — raise CLAMD_MEMMAX and re-run; check: systemctl status $CLAMD_UNIT"
      fi
    fi
  fi
else
  echo "⊘ clamd resource cap skipped (set APPLY_CLAMD_LIMITS=1 to enable)"
fi

# ────────────────────────────────────────────────
# 7c. tmp_bak janitor — clean CWP backup staging CWP fails to remove
# ────────────────────────────────────────────────
# Installs /usr/local/sbin/bh-tmpbak-janitor.sh + a cron. The janitor removes
# stale /home/tmp_bak/.backup_temp<user> dirs while PROTECTING any in-progress
# backup: active dir detected via the backup process tree's cmdline+cwd, PLUS
# the newest dir (always the active one), PLUS a min-age guard. Worst case if a
# race ever hit: one user's backup is incomplete that run — temp dirs are COPIES
# so live /home data is never touched. flock-guarded; logs only when it deletes.
echo ""
echo ""
echo "─── [7d/11] CWP domlogs rotation ───"
# CWP per-domain Apache logs (/usr/local/apache/domlogs) are rotated by NOTHING —
# no logrotate config ships for them. Measured 2026-08-27: s1 held 30 GB with a single
# domain log at 2,984 MB. Left alone they grow until the disk fills.
#
# ⚠️⚠️ Match *.log ONLY. That directory also holds <domain>.bytes files which are
#      BANDWIDTH COUNTERS, not logs — rotating/truncating them corrupts traffic
#      accounting. *.log covers <domain>.log AND <domain>.error.log; .bytes is excluded.
#      The install is gated on a logrotate dry-run proving 0 .bytes files in scope.
# ⚠️ copytruncate is required: Apache (as nobody) holds these open, so a plain rotate
#      leaves it writing to a deleted inode and the space is not freed until a restart.
#      Verified copytruncate preserves the inode, so no Apache reload is needed.
if [ "$APPLY_DOMLOGS_ROTATE" = "1" ] && [ -d /usr/local/apache/domlogs ]; then
  DL_CONF=/etc/logrotate.d/cwp-domlogs
  cat > "$DL_CONF" <<DLROT
# bh-domlogs-rotate v1 — CWP per-domain Apache logs, otherwise unrotated.
# *.log ONLY: <domain>.bytes are bandwidth counters, NOT logs — never rotate them.
/usr/local/apache/domlogs/*.log {
    daily
    rotate $DOMLOGS_ROTATE_KEEP
    maxsize $DOMLOGS_ROTATE_MAXSIZE
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su root root
}
DLROT
  chmod 644 "$DL_CONF"; chown root:root "$DL_CONF"

  DL_BYTES=$(logrotate -d "$DL_CONF" 2>&1 | grep -c '\.bytes')
  if [ "${DL_BYTES:-1}" -ne 0 ]; then
    rm -f "$DL_CONF"
    echo "⚠ config would touch $DL_BYTES .bytes counter file(s) — removed, no change"
  else
    DL_BIG=$(find /usr/local/apache/domlogs -maxdepth 1 -type f -name '*.log' -size +${DOMLOGS_ROTATE_MAXSIZE%M}M 2>/dev/null | wc -l)
    if [ "$DL_BIG" -gt 0 ]; then
      DL_G=$(find /usr/local/apache/domlogs -maxdepth 1 -type f -name '*.log' -size +${DOMLOGS_ROTATE_MAXSIZE%M}M -printf '%s
' 2>/dev/null | awk '{s+=$1} END {printf "%.1f", s/1073741824}')
      find /usr/local/apache/domlogs -maxdepth 1 -type f -name '*.log' -size +${DOMLOGS_ROTATE_MAXSIZE%M}M -exec truncate -s 0 {} \; 2>/dev/null
      echo "✓ domlogs rotation installed + truncated $DL_BIG oversized log(s), reclaimed ~${DL_G}G"
    else
      echo "✓ domlogs rotation installed (keep=$DOMLOGS_ROTATE_KEEP, maxsize=$DOMLOGS_ROTATE_MAXSIZE; nothing oversized)"
    fi
  fi
else
  echo "⊘ domlogs rotation skipped (set APPLY_DOMLOGS_ROTATE=1 / no domlogs dir)"
fi

echo "─── [7c/11] tmp_bak backup-staging janitor ───"
if [ "$APPLY_TMPBAK_JANITOR" = "1" ] && { [ -d /usr/local/cwp ] || [ -d "$TMPBAK_DIR" ]; }; then
  cat > /usr/local/sbin/bh-tmpbak-janitor.sh <<'JANITOR'
#!/bin/bash
# bh-tmpbak-janitor — remove stale CWP backup staging dirs that CWP fails to
# clean, while PROTECTING active backups. Installed by bh-server-ops.
set -u
TMPBAK="${TMPBAK_DIR:-/home/tmp_bak}"
MINAGE="${TMPBAK_JANITOR_MINAGE:-10}"
LOG=/var/log/bh-tmpbak-janitor.log
exec 9>/var/run/bh-tmpbak-janitor.lock 2>/dev/null || exit 0
flock -n 9 || exit 0
[ -d "$TMPBAK" ] || exit 0
# robustly detect the active backup's temp dir(s) to PROTECT
BKPIDS=$(pgrep -f 'cron_newbackup|cron_autobackup|async_backup' 2>/dev/null)
ALL="$BKPIDS"
for p in $BKPIDS; do ALL="$ALL $(pgrep -P "$p" 2>/dev/null)"; done
for p in $ALL; do ALL="$ALL $(pgrep -P "$p" 2>/dev/null)"; done
PROTECT=$( { for p in $ALL; do tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null; echo; readlink "/proc/$p/cwd" 2>/dev/null; done; } | grep -oE '\.backup_temp[a-z0-9_]+' | sort -u )
if [ -n "$BKPIDS" ]; then
  NEWEST=$(ls -dt "$TMPBAK"/.backup_temp* 2>/dev/null | head -1 | xargs -r basename)
  PROTECT=$(printf '%s\n%s\n' "$PROTECT" "$NEWEST" | grep -v '^$' | sort -u)
fi
deleted=0
for d in "$TMPBAK"/.backup_temp*; do
  [ -d "$d" ] || continue
  case "$d" in "$TMPBAK"/.backup_temp*) : ;; *) continue ;; esac   # hard path guard
  b=$(basename "$d")
  printf '%s\n' "$PROTECT" | grep -qx "$b" && continue              # active backup
  [ -n "$(find "$d" -maxdepth 0 -mmin -"$MINAGE" 2>/dev/null)" ] && continue  # too recent
  ionice -c2 -n7 rm -rf "$d" && deleted=$((deleted+1))
done
[ "$deleted" -gt 0 ] && echo "$(date '+%F %T') removed $deleted stale dir(s); protected=[$(printf '%s' "$PROTECT" | tr '\n' ',')]; free=$(df -h "$TMPBAK" 2>/dev/null | tail -1 | awk '{print $4}')" >> "$LOG"
exit 0
JANITOR
  chmod 700 /usr/local/sbin/bh-tmpbak-janitor.sh
  cat > /etc/cron.d/bh-tmpbak-janitor <<CRON
# BH tmp_bak janitor — clears stale CWP backup staging (protects in-progress backups)
*/${TMPBAK_JANITOR_INTERVAL} * * * * root TMPBAK_DIR=${TMPBAK_DIR} TMPBAK_JANITOR_MINAGE=${TMPBAK_JANITOR_MINAGE} /usr/local/sbin/bh-tmpbak-janitor.sh >/dev/null 2>&1
CRON
  echo "✓ tmp_bak janitor installed: /usr/local/sbin/bh-tmpbak-janitor.sh"
  echo "  cron: every ${TMPBAK_JANITOR_INTERVAL}min | dir $TMPBAK_DIR | min-age ${TMPBAK_JANITOR_MINAGE}min | log /var/log/bh-tmpbak-janitor.log"
  echo "  run once now (optional): TMPBAK_DIR=$TMPBAK_DIR /usr/local/sbin/bh-tmpbak-janitor.sh"
else
  echo "⊘ tmp_bak janitor skipped (no CWP / no $TMPBAK_DIR, or APPLY_TMPBAK_JANITOR=0)"
fi

# ────────────────────────────────────────────────
# 7b. MariaDB InnoDB buffer pool (sized to REAL data, online, no restart)
# ────────────────────────────────────────────────
echo ""
echo "─── [8/11] MariaDB buffer pool (sized to REAL data) ───"
if [ "${APPLY_MARIADB_TUNING:-1}" != "1" ]; then
  echo "⊘ skipped (APPLY_MARIADB_TUNING=0)"
elif ! MYCLI=$(command -v mariadb || command -v mysql) || [ -z "$MYCLI" ]; then
  echo "⊘ no mariadb/mysql client — skipping"
elif ! "$MYCLI" -N -e "SELECT 1" >/dev/null 2>&1; then
  echo "⊘ cannot connect to the DB as root (socket auth unavailable) — skipping"
else
  MY_CNF=/etc/my.cnf
  [ -f "$MY_CNF" ] || MY_CNF=/etc/my.cnf.d/server.cnf
  _q(){ "$MYCLI" -N -e "$1" 2>/dev/null; }

  _ram_mb=$(free -m | awk '/^Mem:/{print $2}')
  _cur_b=$(_q "SELECT @@innodb_buffer_pool_size;")
  # real on-disk footprint of every user schema
  _data_mb=$(_q "SELECT IFNULL(ROUND(SUM(data_length+index_length)/1048576),0) FROM information_schema.tables WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys');")
  # pages are 16KB; what the pool is ACTUALLY holding right now
  _hold_mb=$(_q "SELECT IFNULL(ROUND(VARIABLE_VALUE*16384/1048576),0) FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='Innodb_buffer_pool_pages_data';")
  : "${_cur_b:=0}"; : "${_data_mb:=0}"; : "${_hold_mb:=0}"

  if [ "${_data_mb:-0}" -le 0 ]; then
    echo "⊘ could not read data size (permissions?) — skipping, nothing changed"
  else
    _cur_mb=$(( _cur_b / 1048576 ))
    _want_mb=$(( _data_mb * MARIADB_POOL_FACTOR / 10 ))
    _floor_mb=$(( MARIADB_POOL_MIN_GB * 1024 ))
    _ceil_mb=$(( _ram_mb * MARIADB_POOL_RAM_PCT / 100 ))
    [ "$_want_mb" -lt "$_floor_mb" ] && _want_mb=$_floor_mb
    [ "$_want_mb" -gt "$_ceil_mb" ] && { _want_mb=$_ceil_mb; echo "  (capped at ${MARIADB_POOL_RAM_PCT}% of RAM)"; }
    # round up to a whole GB so the my.cnf value stays human-readable
    _want_gb=$(( (_want_mb + 1023) / 1024 )); _want_mb=$(( _want_gb * 1024 ))

    echo "  RAM=${_ram_mb}M  real data=${_data_mb}M  currently holding=${_hold_mb}M"
    echo "  pool now=${_cur_mb}M  ->  target=${_want_mb}M (${_want_gb}G)"

    # SAFETY: never shrink below what the pool is actively holding, or we force
    # a mass eviction and every evicted page has to be re-read from disk.
    if [ "$_want_mb" -lt "$_hold_mb" ]; then
      echo "  ⚠ target ${_want_mb}M is BELOW live data ${_hold_mb}M → would force eviction; raising to fit"
      _want_gb=$(( (_hold_mb + 1023) / 1024 + 1 )); _want_mb=$(( _want_gb * 1024 ))
      echo "    adjusted target=${_want_mb}M (${_want_gb}G)"
    fi

    _delta=$(( _cur_mb - _want_mb )); [ "$_delta" -lt 0 ] && _delta=$(( -_delta ))
    if [ "$_delta" -le 512 ]; then
      echo "✓ already within 512M of target — nothing to do"
    else
      _bak="/root/my.cnf.bak-$(date +%F-%H%M%S)"
      cp -a "$MY_CNF" "$_bak" 2>/dev/null && echo "  backup: $_bak"
      # 1) live resize — dynamic since MariaDB 10.2, no restart, seconds when the
      #    new size stays above live data (only free pages are released)
      if "$MYCLI" -e "SET GLOBAL innodb_buffer_pool_size = $(( _want_mb * 1048576 ));" >/dev/null 2>&1; then
        echo "  ✓ online resize applied (no restart)"
      else
        echo "  ⚠ online resize refused — writing config only (applies on next restart)"
      fi
      # 2) persist. A MISSING directive must be APPENDED — sed-replace silently
      #    does nothing, which is exactly how s3 sat on the 128M default.
      if grep -qE '^[[:space:]]*innodb_buffer_pool_size' "$MY_CNF" 2>/dev/null; then
        sed -i "s|^[[:space:]]*innodb_buffer_pool_size[[:space:]]*=.*|innodb_buffer_pool_size = ${_want_gb}G|" "$MY_CNF"
      elif grep -qE '^\[mysqld\]' "$MY_CNF" 2>/dev/null; then
        sed -i "/^\[mysqld\]/a innodb_buffer_pool_size = ${_want_gb}G" "$MY_CNF"
      else
        printf '\n[mysqld]\ninnodb_buffer_pool_size = %sG\n' "$_want_gb" >> "$MY_CNF"
      fi
      # 3) validate the config PARSES before we ever leave it in place
      if mariadbd --help --verbose >/dev/null 2>&1 || mysqld --help --verbose >/dev/null 2>&1; then
        echo "  ✓ config parses clean → $MY_CNF (innodb_buffer_pool_size = ${_want_gb}G)"
      else
        cp -a "$_bak" "$MY_CNF"
        echo "  ⚠ config FAILED to parse — restored $_bak (live value still applied)"
      fi
      _new_mb=$(( $(_q "SELECT @@innodb_buffer_pool_size;") / 1048576 ))
      echo "  now live: ${_new_mb}M   service: $(systemctl is-active mariadb 2>/dev/null || systemctl is-active mysqld 2>/dev/null)"
    fi

    # long_query_time=0 logs EVERY query the moment anyone enables the slow log,
    # which fills the disk. Found live on biswashost. Only fix the landmine —
    # deliberately do NOT enable the slow log here (it eats disk on a busy box).
    _lqt=$(_q "SELECT @@long_query_time;")
    if [ -n "$_lqt" ] && awk -v v="$_lqt" 'BEGIN{exit !(v < 1)}'; then
      "$MYCLI" -e "SET GLOBAL long_query_time=2;" >/dev/null 2>&1 && \
        echo "  ✓ long_query_time was $_lqt (would log EVERY query) → set to 2"
    fi
  fi
fi

# ────────────────────────────────────────────────
# 7. Reload services (graceful)
# ────────────────────────────────────────────────
echo ""
echo "─── [9/11] Reload services ───"
for S in "${PHP_FPM_SERVICES[@]}"; do
  systemctl is-active --quiet "$S" 2>/dev/null && systemctl reload "$S" && echo "✓ reloaded $S"
done

# Apache reload — verify still active after reload, restart if dead
if [ -n "$APACHE_SERVICE" ] && systemctl is-active --quiet "$APACHE_SERVICE" 2>/dev/null; then
  # MPM-level changes (ServerLimit, ThreadsPerChild) only take effect on
  # full restart. A reload keeps the old thread count, so the new
  # MaxRequestWorkers tier never activates.
  if [ "${MPM_NEEDS_RESTART:-0}" = "1" ]; then
    echo "  MPM changed → full restart (required for ServerLimit/ThreadsPerChild to apply)"
    systemctl restart "$APACHE_SERVICE" 2>/dev/null
  else
    systemctl reload "$APACHE_SERVICE" 2>/dev/null
  fi
  sleep 2
  if systemctl is-active --quiet "$APACHE_SERVICE"; then
    echo "✓ reloaded $APACHE_SERVICE (still active)"
  else
    echo "⚠ $APACHE_SERVICE died after reload — auto-restarting..."
    systemctl restart "$APACHE_SERVICE" 2>&1
    sleep 2
    if systemctl is-active --quiet "$APACHE_SERVICE"; then
      echo "✓ $APACHE_SERVICE restarted successfully"
    else
      echo "✗ $APACHE_SERVICE restart FAILED — manual intervention required:"
      echo "    systemctl status $APACHE_SERVICE"
      echo "    tail -20 /usr/local/apache/logs/error_log"
    fi
  fi
fi

# ────────────────────────────────────────────────
# 9. Apache global security hardening (drop-in conf)
# ────────────────────────────────────────────────
# Static-rule hardening: blocks sensitive file exposure, hidden directories,
# PHP-in-uploads (#1 malware persistence vector), aggressive bots/scrapers,
# dangerous HTTP methods. Complements (does not replace) cpGuard / mod_security
# / fail2ban which handle dynamic threats (login brute-force, WAF rules).
# ────────────────────────────────────────────────
echo ""
echo "─── [10/11] Apache global security hardening ───"
if [ "$APPLY_APACHE_HARDENING" = "1" ] && [ -n "$APACHE_BIN" ]; then
  # Pick the right drop-in path per distro
  HARDENING_CONF=""
  if   [ "$PANEL" = "cwp" ]    && [ -d /usr/local/apache/conf.d ]; then HARDENING_CONF=/usr/local/apache/conf.d/99-global-hardening.conf
  elif [ "$PANEL" = "rhel" ]   && [ -d /etc/httpd/conf.d ];        then HARDENING_CONF=/etc/httpd/conf.d/99-global-hardening.conf
  elif [ "$PANEL" = "debian" ] && [ -d /etc/apache2/conf-available ]; then HARDENING_CONF=/etc/apache2/conf-available/99-global-hardening.conf
  fi

  if [ -z "$HARDENING_CONF" ]; then
    echo "⊘ No suitable Apache conf.d directory — skipping"
  else
    chattr -i "$HARDENING_CONF" 2>/dev/null || true
    [ -f "$HARDENING_CONF" ] && [ ! -f "${HARDENING_CONF}.bak-pre-tune" ] && \
      cp "$HARDENING_CONF" "${HARDENING_CONF}.bak-pre-tune"

    cat > "$HARDENING_CONF" <<'HARDENEOF'
# ===================================================================
# Global Security Hardening — auto-managed by bh-server-ops bootstrap
# Complements cpGuard / mod_security / fail2ban (dynamic threats).
#
# Uses LocationMatch (URL-based) instead of FilesMatch (filename-based)
# because FilesMatch at server-config level doesn't always propagate to
# per-vhost contexts on CWP. Bot blocks live inside <Directory "/home">
# so they apply to all tenant DocumentRoots.
# ===================================================================

# 1. Sensitive file exposure (URL-based — propagates to all vhosts)
<LocationMatch "(?i)^/(\.env(\..*)?|\.git/|\.htaccess|\.htpasswd|\.user\.ini|composer\.(json|lock)|package(-lock)?\.json|yarn\.lock|wp-config(-sample)?\.php|configuration\.php|wp-cron\.php|xmlrpc\.php|readme\.html|license\.txt|install\.php|upgrade\.php|info\.php|phpinfo\.php|test\.php|adminer\.php|pma\.php)(/.*)?$">
  Require all denied
</LocationMatch>

# 2. Hidden directories (.git, .svn, .hg) — explicit list (avoid lookahead)
<LocationMatch "(?i)^/\.(git|svn|hg|bzr|DS_Store|idea|vscode|cache|aws|ssh|env|history)(/|$)">
  Require all denied
</LocationMatch>

# 3. Disable TRACE/TRACK (XSS attack vector)
TraceEnable Off

# 4. Block PHP execution in upload directories (malware persistence vector)
<LocationMatch "(?i)^/.*/(wp-content/uploads|uploads|public/storage|storage/app/public)/.*\.(php|phtml|php3|php4|php5|php7|phar|pl|py|jsp|asp|aspx|sh|cgi)(\?.*)?$">
  Require all denied
</LocationMatch>
<LocationMatch "(?i)^/(wp-content/uploads|uploads|public/storage|storage/app/public)/.*\.(php|phtml|php3|php4|php5|php7|phar|pl|py|jsp|asp|aspx|sh|cgi)(\?.*)?$">
  Require all denied
</LocationMatch>

# 5. Block direct access to WordPress internals
<LocationMatch "(?i)^/wp-includes/.*\.php$">
  Require all denied
</LocationMatch>

# 6. Block aggressive bots inside /home (all tenant DocumentRoots).
#    Server-config-level mod_rewrite isn't inherited by vhosts on CWP,
#    so we anchor the rules to /home which CWP uses for tenant homes.
<Directory "/home">
  <IfModule mod_rewrite.c>
    RewriteEngine On
    RewriteOptions InheritDown

    # SEO/scraper bots
    RewriteCond %{HTTP_USER_AGENT} (PetalBot|MJ12bot|DotBot|SemrushBot|AhrefsBot|Bytespider|YandexBot|seznambot|MegaIndex|BLEXBot|DataForSeoBot|GeedoShop|MauiBot|sogou|spbot|trendkite|garlik|webmeup|exabot|Lipperhey|psbot|360Spider) [NC,OR]
    # AI training bots
    RewriteCond %{HTTP_USER_AGENT} (GPTBot|ClaudeBot|CCBot|Amazonbot|anthropic-ai|cohere-ai|magpie-crawler|Diffbot|ImagesiftBot|Omgili|SiteAnalyzerBot|TurnitinBot|PerplexityBot) [NC]
    # NOTE: do NOT block empty/dash-only User-Agent — that assumption is wrong.
    # Legitimate server-to-server APIs send no UA: Telegram webhooks, payment/gateway
    # callbacks, uptime monitors, etc. (matches the nginx bh.d/00-anti-bot.conf stance.)
    RewriteRule .* - [F,L]
  </IfModule>
</Directory>

# 7. Hide server version info
ServerTokens Prod
ServerSignature Off
HARDENEOF

    # Validate config before reload
    if $APACHE_BIN -t 2>&1 | grep -q "Syntax OK"; then
      # Enable on Debian (needs symlink in conf-enabled)
      if [ "$PANEL" = "debian" ] && [ ! -L /etc/apache2/conf-enabled/99-global-hardening.conf ]; then
        ln -sf "$HARDENING_CONF" /etc/apache2/conf-enabled/99-global-hardening.conf
      fi
      chattr +i "$HARDENING_CONF" 2>/dev/null || true
      echo "✓ $HARDENING_CONF deployed + frozen"
    else
      echo "✗ Apache syntax error after hardening — restoring backup"
      [ -f "${HARDENING_CONF}.bak-pre-tune" ] && cp "${HARDENING_CONF}.bak-pre-tune" "$HARDENING_CONF" || rm -f "$HARDENING_CONF"
    fi
  fi

  # ── ALSO patch main httpd.conf with wp-cron/xmlrpc block (belt-and-suspenders)
  #    Some setups don't include conf.d/* reliably (legacy CWP, custom builds).
  #    Adding to main config guarantees the block fires regardless.
  HTTPD_CONF=""
  case "$PANEL" in
    cwp)    HTTPD_CONF=/usr/local/apache/conf/httpd.conf ;;
    rhel)   HTTPD_CONF=/etc/httpd/conf/httpd.conf ;;
    debian) HTTPD_CONF=/etc/apache2/apache2.conf ;;
  esac

  if [ -n "$HTTPD_CONF" ] && [ -f "$HTTPD_CONF" ]; then
    # Idempotency check — skip if our marker OR an existing xmlrpc block is present
    if grep -q "BH-OPS-HARDENING-MARKER\|<FilesMatch.*xmlrpc\\\\\.php" "$HTTPD_CONF"; then
      echo "✓ httpd.conf already has wp-cron/xmlrpc block — skipping"
    else
      # Backup once
      [ -f "${HTTPD_CONF}.bak-pre-tune" ] || cp "$HTTPD_CONF" "${HTTPD_CONF}.bak-pre-tune"

      cat >> "$HTTPD_CONF" <<'HTTPDEOF'

# ── BH-OPS-HARDENING-MARKER ── (managed by bh-server-ops bootstrap)
# Block wp-cron.php and xmlrpc.php at main config level (belt-and-suspenders
# alongside conf.d/99-global-hardening.conf). Tenants should use real cron
# instead of wp-cron.php; xmlrpc.php has no legitimate use case in 99% of sites.
<FilesMatch "^(wp-cron\.php|xmlrpc\.php)$">
    Require all denied
</FilesMatch>
# ── END BH-OPS-HARDENING-MARKER ──
HTTPDEOF

      # Validate syntax — restore on failure
      if $APACHE_BIN -t 2>&1 | grep -q "Syntax OK"; then
        echo "✓ $HTTPD_CONF appended wp-cron/xmlrpc block"
      else
        echo "✗ Apache syntax error after httpd.conf patch — restoring backup"
        cp "${HTTPD_CONF}.bak-pre-tune" "$HTTPD_CONF"
      fi
    fi
  fi

  # Reload Apache once at the end (covers both conf.d drop-in + httpd.conf patch)
  # Verify Apache STAYS active after reload — auto-restart if it dies.
  if $APACHE_BIN -t 2>&1 | grep -q "Syntax OK"; then
    systemctl reload "$APACHE_SERVICE" 2>/dev/null
    sleep 2
    if systemctl is-active --quiet "$APACHE_SERVICE"; then
      echo "✓ reloaded $APACHE_SERVICE (hardening live, still active)"
    else
      echo "⚠ $APACHE_SERVICE died after hardening reload — auto-restarting..."
      systemctl restart "$APACHE_SERVICE" 2>&1
      sleep 2
      if systemctl is-active --quiet "$APACHE_SERVICE"; then
        echo "✓ $APACHE_SERVICE restarted successfully"
      else
        echo "✗ $APACHE_SERVICE failed to start — REVERTING hardening:"
        chattr -i "$HARDENING_CONF" 2>/dev/null || true
        rm -f "$HARDENING_CONF"
        [ -f "${HTTPD_CONF}.bak-pre-tune" ] && cp "${HTTPD_CONF}.bak-pre-tune" "$HTTPD_CONF"
        systemctl restart "$APACHE_SERVICE" 2>&1
        echo "✗ Reverted. Check: systemctl status $APACHE_SERVICE"
      fi
    fi
  else
    echo "✗ Apache config has syntax errors — REVERTING hardening:"
    $APACHE_BIN -t 2>&1 | head -10
    chattr -i "$HARDENING_CONF" 2>/dev/null || true
    rm -f "$HARDENING_CONF"
    [ -f "${HTTPD_CONF}.bak-pre-tune" ] && cp "${HTTPD_CONF}.bak-pre-tune" "$HTTPD_CONF"
    systemctl reload "$APACHE_SERVICE" 2>/dev/null
  fi
else
  echo "⊘ Apache hardening skipped"
fi

# ────────────────────────────────────────────────
# 9b. Remove CWP's exposed legacy webftp (Monsta) + permanently deny it
# ────────────────────────────────────────────────
echo ""
echo "─── [10b/11] Remove exposed CWP webftp ───"
if [ "$APPLY_REMOVE_WEBFTP" = "1" ]; then
  WEBFTP_DIR=/usr/local/apache/htdocs/webftp_simple
  webftp_state="absent"
  if [ -d "$WEBFTP_DIR" ]; then rm -rf "$WEBFTP_DIR" && webftp_state="deleted"; fi
  # Permanent deny — fires on every vhost even if CWP recreates the files/alias.
  if [ -d /usr/local/apache/conf.d ]; then
    cat > /usr/local/apache/conf.d/00-bh-block-webftp.conf <<'CONF'
# BH-BLOCK-WEBFTP — legacy CWP Monsta webftp removed; keep its URLs denied so a
# CWP rebuild can't silently re-expose it. Returns 403 on every vhost.
<LocationMatch "(?i)^/webftp(_simple)?(/|$)">
    Require all denied
</LocationMatch>
# END BH-BLOCK-WEBFTP
CONF
  fi
  # Comment the CWP Alias lines (the deny covers it regardless, but keep tidy).
  DR=/usr/local/apache/conf.d/domain-redirects.conf
  if [ -f "$DR" ] && grep -qE '^[[:space:]]*Alias[[:space:]]+/(webftp|WebFTP|webftp_simple)\b' "$DR"; then
    cp -a "$DR" "$DR.bak-pre-webftp" 2>/dev/null
    sed -i -E 's#^([[:space:]]*Alias[[:space:]]+/(webftp|WebFTP|webftp_simple)\b.*)#\# bh-removed-webftp \1#' "$DR"
  fi
  if [ -n "$APACHE_BIN" ] && "$APACHE_BIN" -t >/dev/null 2>&1; then
    systemctl reload "${APACHE_SERVICE:-httpd}" 2>/dev/null
    echo "✓ webftp $webftp_state + /webftp* denied (403) + aliases commented"
  else
    echo "⚠ apache config test FAILED after webftp removal — review $DR / 00-bh-block-webftp.conf"
  fi
else
  echo "⊘ webftp removal skipped (set APPLY_REMOVE_WEBFTP=1 to enable)"
fi


echo ""
echo "─── [10c/11] CWP admin panel IP lock ───"
# WHY: /pma (phpMyAdmin) and /roundcube are served ONLY from the CWP ADMIN server
# blocks (2030/2086 and 2031/2087) — the user blocks on 2082/2083 do NOT include
# them, and the user panel 302-redirects to :2087 with the port HARDCODED in
# ionCube-encoded PHP. So 2087 MUST stay open to customers, which also exposes the
# admin login + API. Fix it by PATH instead of by port: cwpsrv is nginx, so lock
# /login, /admin and /api to trusted IPs and leave /pma + /roundcube open.
# Only cwp_panels.conf is touched — it is NOT regenerated on cwpsrv restart
# (unlike cwp_services.conf / cwpsrv.conf), so customer services can't be broken here.
if [ "$APPLY_CWP_ADMIN_IPLOCK" = "1" ]; then
  CWPP=/usr/local/cwpsrv/conf/cwp_panels.conf
  CWPBIN=/usr/local/cwpsrv/bin/cwpsrv
  if [ ! -f "$CWPP" ] || [ ! -x "$CWPBIN" ]; then
    echo "⊘ cwp_panels.conf or cwpsrv binary not found — skipped"
  else
    BLK="    # BH-ADMIN-IPLOCK
"
    for _ip in $CWP_ADMIN_TRUSTED_IPS; do BLK="${BLK}    allow ${_ip};
"; done
    BLK="${BLK}    deny all;
    # END BH-ADMIN-IPLOCK
"

    cp -a "$CWPP" "$CWPP.bak-pre-iplock" 2>/dev/null
    # Strip any previous block first, so re-running also refreshes the IP list.
    sed -i '/# BH-ADMIN-IPLOCK/,/# END BH-ADMIN-IPLOCK/d' "$CWPP"
    awk -v blk="$BLK" '
      /^location \/(login|admin|api) \{$/ { print; printf "%s", blk; next }
      { print }
    ' "$CWPP" > "$CWPP.bhnew" && mv -f "$CWPP.bhnew" "$CWPP"

    _n=$(grep -c '# BH-ADMIN-IPLOCK' "$CWPP" 2>/dev/null || echo 0)
    if [ "$_n" -ne 3 ]; then
      cp -a "$CWPP.bak-pre-iplock" "$CWPP"
      echo "⚠ expected 3 locked locations, got $_n — reverted, no change"
    elif "$CWPBIN" -t >/dev/null 2>&1; then
      systemctl reload cwpsrv 2>/dev/null
      echo "✓ CWP admin (/login,/admin,/api) locked to: $CWP_ADMIN_TRUSTED_IPS"
      echo "  /pma + /roundcube left OPEN for customers (verify: 403 from outside, 200 from a trusted IP)"
    else
      cp -a "$CWPP.bak-pre-iplock" "$CWPP"
      "$CWPBIN" -t 2>&1 | sed 's/^/    /'
      echo "⚠ cwpsrv config test FAILED — reverted from $CWPP.bak-pre-iplock"
    fi
  fi
else
  echo "⊘ CWP admin IP lock skipped (set APPLY_CWP_ADMIN_IPLOCK=1 to enable)"
fi


# ────────────────────────────────────────────────
# 10. Install helper scripts (tenant-cap, monitor, auto-recovery)
# ────────────────────────────────────────────────
echo ""
echo "─── [11/11] Install helper scripts ───"
if [ "$INSTALL_HELPERS" = "1" ]; then
  mkdir -p /usr/local/sbin

  # ── tenant-cap: instantly cap a noisy tenant's PHP workers ────
  cat > /usr/local/sbin/tenant-cap <<'TENANTCAP'
#!/bin/bash
# tenant-cap — cap (or check) a tenant's PHP-FPM max_children across all PHP versions
# Usage:
#   tenant-cap medicalp 4    # cap medicalp at 4 max workers
#   tenant-cap medicalp      # show current settings
#   tenant-cap medicalp 10   # restore to default 10
USER="$1"
LIMIT="$2"
[ -z "$USER" ] && { echo "Usage: tenant-cap <user> [max_children]"; exit 1; }

found_any=0
for D in /opt/alt/php-fpm*/usr/etc/php-fpm.d/users \
         /opt/cpanel/ea-php*/root/etc/php-fpm.d/users \
         /etc/php/*/fpm/pool.d \
         /etc/php-fpm.d; do
  [ -d "$D" ] || continue
  CONF="$D/$USER.conf"
  [ -f "$CONF" ] || continue
  found_any=1
  if [ -z "$LIMIT" ]; then
    CUR=$(grep -E "^pm.max_children" "$CONF" | awk -F= '{print $2}' | tr -d ' ')
    echo "  $D : pm.max_children = ${CUR:-?}"
  else
    sed -i "s/^pm.max_children = .*/pm.max_children = $LIMIT/" "$CONF"
    echo "  $D : pm.max_children = $LIMIT (set)"
  fi
done

[ "$found_any" = "0" ] && { echo "✗ No pool configs found for user '$USER'"; exit 1; }

# Reload all running php-fpm services
if [ -n "$LIMIT" ]; then
  for S in $(systemctl list-units --type=service --state=active --no-legend 2>/dev/null | awk '{print $1}' | grep -E "^(php-fpm|ea-php.*-php-fpm|php[0-9.]+-fpm)"); do
    systemctl reload "$S" 2>/dev/null && echo "✓ reloaded $S"
  done
fi
TENANTCAP
  chmod +x /usr/local/sbin/tenant-cap
  echo "✓ /usr/local/sbin/tenant-cap installed"

  # ── saturation-monitor: log if any site TTFB > threshold ──────
  cat > /usr/local/sbin/saturation-monitor <<MONITOR
#!/bin/bash
# saturation-monitor — log to /var/log/saturation.log if any monitored site is slow
THRESHOLD=$TTFB_WARN_THRESHOLD
SITES="$MONITOR_SITES"
LOG=/var/log/saturation.log

# Auto-discover CWP user domains if SITES is empty
if [ -z "\$SITES" ] && [ -d /etc/cwpsrv ]; then
    SITES=\$(find /etc/cwpsrv -maxdepth 3 -name '*.conf' 2>/dev/null | xargs -I{} grep -hE '^\s*server_name' {} 2>/dev/null | awk '{print \$2}' | tr -d ';' | grep -vE '^(www\\.|webmail\\.|mail\\.|cpanel\\.|ftp\\.)' | sort -u | head -10)
fi
[ -z "\$SITES" ] && exit 0

for SITE in \$SITES; do
    # Strip protocol + trailing slash so user can paste full URL or hostname
    HOST=\$(echo "\$SITE" | sed -E 's#^https?://##; s#/.*##')
    [ -z "\$HOST" ] && continue
    T=\$(curl -s -o /dev/null -w "%{time_starttransfer}" -m 30 "https://\$HOST/" 2>/dev/null)
    T_INT=\${T%.*}
    if [ "\${T_INT:-0}" -gt "\$THRESHOLD" ] 2>/dev/null; then
        CW=\$(ss -tan state close-wait 2>/dev/null | wc -l)
        TOP=\$(ps aux 2>/dev/null | grep "php-fpm: pool" | grep -v grep | awk '{print \$1}' | sort | uniq -c | sort -rn | head -3 | awk '{printf "%s:%s ",\$2,\$1}')
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] SLOW: \$HOST TTFB=\${T}s  CLOSE_WAIT=\$CW  top_pools=\$TOP" >> \$LOG
    fi
done
MONITOR
  chmod +x /usr/local/sbin/saturation-monitor
  echo "✓ /usr/local/sbin/saturation-monitor installed"

  # ── auto-recovery: graceful reload if catastrophic TTFB ───────
  cat > /usr/local/sbin/auto-recovery <<RECOVERY
#!/bin/bash
# auto-recovery — graceful reload Apache + FPM + Varnish if any site is past recovery threshold
THRESHOLD=$TTFB_RECOVER_THRESHOLD
SITES="$MONITOR_SITES"
LOG=/var/log/auto-recovery.log

# ── Self-heal: anti-bot maps OR the nginx.conf bh.d include wiped? ──
# CWP "Rebuild Web Server" (admin → WebServer Settings) regenerates nginx.conf
# from its template — silently DROPPING our 'include /etc/nginx/bh.d/*.conf;'
# line — and can also wipe conf.d/. Either way the vhost-included snippet still
# references \$bh_bad_bot / \$bh_trusted_ip but the defining map is no longer
# loaded → nginx refuses to start ("unknown bh_bad_bot variable") on the next
# reload. Restore BOTH the include line and the map files, then reload — or
# start nginx if the rebuild already left it down.
if [ -f /etc/nginx/snippets/anti-bot-server.conf ]; then
    HEALED=0
    mkdir -p /etc/nginx/bh.d
    # 1) map files — restore from snapshot if a CWP/yum action removed them
    if [ -d /var/lib/bh-server-ops ]; then
        for F in 00-anti-bot.conf 00-trusted-ips.conf; do
            if [ -f /var/lib/bh-server-ops/\$F ] && [ ! -f /etc/nginx/bh.d/\$F ]; then
                cp /var/lib/bh-server-ops/\$F /etc/nginx/bh.d/\$F
                echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Healed missing /etc/nginx/bh.d/\$F" >> \$LOG
                HEALED=1
            fi
        done
    fi
    # 2) the http-level include in nginx.conf (CWP rebuild strips this)
    NGXMAIN=/etc/nginx/nginx.conf
    [ -f /usr/local/nginx/conf/nginx.conf ] && [ ! -f \$NGXMAIN ] && NGXMAIN=/usr/local/nginx/conf/nginx.conf
    if [ -f \$NGXMAIN ] && ! grep -qF "include /etc/nginx/bh.d/" \$NGXMAIN; then
        cp -a \$NGXMAIN \$NGXMAIN.bak-bhguard 2>/dev/null
        if grep -qF "include /etc/nginx/conf.d/*.conf;" \$NGXMAIN; then
            # insert before the conf.d include so maps load before vhosts
            awk '/include \/etc\/nginx\/conf\.d\/\*\.conf;/ && !d {print "    include /etc/nginx/bh.d/*.conf;"; d=1} {print}' \$NGXMAIN > \$NGXMAIN.bhtmp
        else
            # fallback: drop it right after the http{ opening brace
            awk '/^[[:space:]]*http[[:space:]]*\{/ && !d {print; print "    include /etc/nginx/bh.d/*.conf;"; d=1; next} {print}' \$NGXMAIN > \$NGXMAIN.bhtmp
        fi
        if grep -qF "include /etc/nginx/bh.d/" \$NGXMAIN.bhtmp; then
            mv \$NGXMAIN.bhtmp \$NGXMAIN
            echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Healed missing bh.d include in \$NGXMAIN (CWP rebuild)" >> \$LOG
            HEALED=1
        else
            rm -f \$NGXMAIN.bhtmp
        fi
    fi
    if [ "\$HEALED" = "1" ] && command -v nginx >/dev/null 2>&1; then
        if nginx -t >/dev/null 2>&1; then
            # reload if running; start/restart if the rebuild left nginx down
            systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null
            echo "[\$(date '+%Y-%m-%d %H:%M:%S')] nginx reloaded/started after self-heal" >> \$LOG
        fi
    fi
fi

if [ -z "\$SITES" ] && [ -d /etc/cwpsrv ]; then
    SITES=\$(find /etc/cwpsrv -maxdepth 3 -name '*.conf' 2>/dev/null | xargs -I{} grep -hE '^\s*server_name' {} 2>/dev/null | awk '{print \$2}' | tr -d ';' | grep -vE '^(www\\.|webmail\\.|mail\\.|cpanel\\.|ftp\\.)' | sort -u | head -5)
fi
[ -z "\$SITES" ] && exit 0

NEEDS_RECOVERY=0
for SITE in \$SITES; do
    # Strip protocol + trailing slash
    HOST=\$(echo "\$SITE" | sed -E 's#^https?://##; s#/.*##')
    [ -z "\$HOST" ] && continue
    T=\$(curl -s -o /dev/null -w "%{time_starttransfer}" -m 25 "https://\$HOST/" 2>/dev/null)
    T_INT=\${T%.*}
    if [ "\${T_INT:-0}" -gt "\$THRESHOLD" ] 2>/dev/null; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Saturation: \$HOST TTFB=\${T}s — triggering recovery" >> \$LOG
        NEEDS_RECOVERY=1
        break
    fi
done

if [ "\$NEEDS_RECOVERY" = "1" ]; then
    # Throttle: don't recover more than once per 10 min
    LAST=\$(stat -c %Y \$LOG.lastfire 2>/dev/null || echo 0)
    NOW=\$(date +%s)
    if [ \$((NOW - LAST)) -lt 600 ]; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Skipped — last recovery <10 min ago" >> \$LOG
        exit 0
    fi
    touch \$LOG.lastfire

    # ── Apache: try graceful reload first (no downtime); if site STILL slow
    #    after 5s, full restart (1-2s blip but always clears stuck workers).
    if systemctl is-active --quiet httpd 2>/dev/null; then
        systemctl reload httpd 2>/dev/null && echo "  reloaded httpd" >> \$LOG
        sleep 5
        # Re-check the same site that was slow — if still bad, escalate to restart
        for SITE in \$SITES; do
            HOST=\$(echo "\$SITE" | sed -E 's#^https?://##; s#/.*##')
            [ -z "\$HOST" ] && continue
            T=\$(curl -s -o /dev/null -w "%{time_starttransfer}" -m 15 "https://\$HOST/" 2>/dev/null)
            T_INT=\${T%.*}
            if [ "\${T_INT:-0}" -gt "\$THRESHOLD" ] 2>/dev/null; then
                echo "  ⚠ reload didn't clear stuck workers — escalating to restart" >> \$LOG
                systemctl restart httpd 2>/dev/null && echo "  restarted httpd" >> \$LOG
                break
            fi
        done
    fi

    # ── PHP-FPM: reload re-execs master (zero downtime, fresh workers)
    #    — always sufficient unless master itself is hung.
    for S in \$(systemctl list-units --type=service --state=active --no-legend 2>/dev/null | awk '{print \$1}' | grep -E "^(php-fpm|ea-php.*-php-fpm|php[0-9.]+-fpm)"); do
        systemctl reload "\$S" 2>/dev/null && echo "  reloaded \$S" >> \$LOG
    done

    # ── Varnish cache flush
    command -v varnishadm >/dev/null && varnishadm "ban req.url ~ ." 2>/dev/null && echo "  flushed varnish" >> \$LOG

    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Recovery complete" >> \$LOG
fi
RECOVERY
  chmod +x /usr/local/sbin/auto-recovery
  echo "✓ /usr/local/sbin/auto-recovery installed"

  # ── Install crontab watchdog (REQUIRED, runs even if user disables monitors) ──
  # The watchdog hourly snapshots /var/spool/cron/root and auto-restores
  # if the crontab shrinks unexpectedly (the v3.4 wipe symptom). Lives in
  # /etc/cron.d/ so it can't be wiped along with user-spool. This is the
  # real fix for the wipe bug — it lets us keep monitor jobs in user-spool
  # (for CWP/cPanel UI visibility) without the fragility.
  cat > /usr/local/sbin/bh-crontab-watchdog.sh <<'WATCHDOG'
#!/bin/bash
# BH crontab watchdog — snapshot + auto-restore root's user-spool crontab.
BACKUP_DIR="/root/.crontab-backups"
SPOOL="/var/spool/cron/root"
LOG="/var/log/bh-crontab-watchdog.log"
KEEP=30
SHRINK_THRESHOLD_PCT=70   # restore if current < 70% of last snapshot size

mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

[ -f "$SPOOL" ] || { log "spool missing, skipping"; exit 0; }

CUR_SIZE=$(wc -c < "$SPOOL")
LATEST=$(ls -1t "$BACKUP_DIR"/root.* 2>/dev/null | head -1)

if [ -z "$LATEST" ]; then
    cp -a "$SPOOL" "$BACKUP_DIR/root.$(date +%Y%m%d-%H%M%S)"
    log "first snapshot taken (size=$CUR_SIZE)"
    exit 0
fi

LAST_SIZE=$(wc -c < "$LATEST")

if [ "$LAST_SIZE" -gt 100 ] && [ "$CUR_SIZE" -lt $((LAST_SIZE * SHRINK_THRESHOLD_PCT / 100)) ]; then
    log "WIPE DETECTED: current=$CUR_SIZE bytes, last good=$LAST_SIZE bytes ($LATEST)"
    cp -a "$SPOOL" "$BACKUP_DIR/WIPED.$(date +%Y%m%d-%H%M%S)"
    cp -a "$LATEST" "$SPOOL"
    chown root:root "$SPOOL"; chmod 600 "$SPOOL"
    log "RESTORED from $LATEST"
    command -v mail >/dev/null && echo "Root crontab on $(hostname) was wiped and auto-restored. See $LOG and $BACKUP_DIR." | mail -s "ALERT: crontab wipe on $(hostname)" root 2>/dev/null
    exit 0
fi

if ! diff -q "$SPOOL" "$LATEST" >/dev/null 2>&1; then
    cp -a "$SPOOL" "$BACKUP_DIR/root.$(date +%Y%m%d-%H%M%S)"
    log "snapshot taken (size=$CUR_SIZE)"
    ls -1t "$BACKUP_DIR"/root.* 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
fi
WATCHDOG
  chmod +x /usr/local/sbin/bh-crontab-watchdog.sh
  /usr/local/sbin/bh-crontab-watchdog.sh   # take first snapshot before we modify spool

  cat > /etc/cron.d/bh-crontab-watchdog <<'EOF'
# BH-CRONTAB-WATCHDOG — snapshots + auto-restores root crontab. Do not delete.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
0 * * * * root /usr/local/sbin/bh-crontab-watchdog.sh
# END BH-CRONTAB-WATCHDOG
EOF
  chmod 644 /etc/cron.d/bh-crontab-watchdog
  chown root:root /etc/cron.d/bh-crontab-watchdog
  echo "✓ /usr/local/sbin/bh-crontab-watchdog.sh installed (hourly, /etc/cron.d/bh-crontab-watchdog)"
  echo "✓ first snapshot saved to /root/.crontab-backups/ — auto-restore enabled"

  # ── Setup monitor cron jobs in user-spool ──────────────────────
  # Written to root's user-spool crontab so CWP/cPanel UI shows them
  # alongside other root jobs. The watchdog above protects against the
  # v3.4 wipe bug — if anything (panel misclick, bad script) wipes the
  # spool, the watchdog auto-restores within an hour.
  #
  # Safety guard: only rewrite the spool if `crontab -l` succeeded AND
  # produced non-empty output. Belt-and-suspenders with the watchdog.
  # Also removes any LEGACY /etc/cron.d/bh-perf-monitors from v3.5.
  rm -f /etc/cron.d/bh-perf-monitors

  if EXISTING_CRON=$(crontab -l 2>/dev/null); then
    # Filter out any prior BH monitor lines so we don't duplicate on re-run
    FILTERED_CRON=$(printf '%s\n' "$EXISTING_CRON" | grep -v 'saturation-monitor' | grep -v 'auto-recovery' | grep -v '# BH-PERF-MONITORS' || true)

    NEW_LINES=""
    NEW_LINES+="# BH-PERF-MONITORS (managed by perf-bootstrap.sh — safe to keep)"$'\n'
    if [ "$ENABLE_MONITOR_CRON" = "1" ]; then
      NEW_LINES+="*/5 * * * * /usr/local/sbin/saturation-monitor >/dev/null 2>&1"$'\n'
    fi
    if [ "$ENABLE_AUTO_RECOVERY_CRON" = "1" ]; then
      NEW_LINES+="*/3 * * * * /usr/local/sbin/auto-recovery >/dev/null 2>&1"$'\n'
    fi

    # Only commit if we actually got something back from `crontab -l`
    # (empty $EXISTING_CRON when no crontab exists yet is fine — we'll create one).
    NEW_CRON=$(printf '%s\n%s' "$FILTERED_CRON" "$NEW_LINES" | sed '/^$/N;/^\n$/D')
    printf '%s\n' "$NEW_CRON" | crontab -

    [ "$ENABLE_MONITOR_CRON" = "1" ]      && echo "✓ cron added: saturation-monitor every 5 min (user-spool, visible in panel UI)"
    [ "$ENABLE_AUTO_RECOVERY_CRON" = "1" ] && echo "✓ cron added: auto-recovery every 3 min (user-spool, visible in panel UI)"
    [ "$ENABLE_AUTO_RECOVERY_CRON" != "1" ] && echo "⊘ auto-recovery cron disabled (set ENABLE_AUTO_RECOVERY_CRON=1 to enable)"
  else
    echo "⚠ Could not read root crontab (crontab -l failed). Skipping cron install."
    echo "  Watchdog is still active. Run script again once crontab access is restored."
  fi

  # Touch log files so they exist with right perms
  touch /var/log/saturation.log /var/log/auto-recovery.log
  chmod 644 /var/log/saturation.log /var/log/auto-recovery.log
else
  echo "⊘ Helper installation skipped"
fi

echo ""
echo "=============================================="
echo "  Bootstrap complete on $(hostname)"
echo "=============================================="
echo "  Panel: $PANEL"
echo "  Light tenants tuned: $TOUCHED"
echo "  Heavy tenants tuned: $HEAVY_TOUCHED"
[ "$INSTALL_HELPERS" = "1" ] && {
  echo "  Helpers: /usr/local/sbin/{tenant-cap, saturation-monitor, auto-recovery}"
  echo "  Monitor cron: $([ "$ENABLE_MONITOR_CRON" = "1" ] && echo enabled || echo disabled)"
  echo "  Auto-recovery cron: $([ "$ENABLE_AUTO_RECOVERY_CRON" = "1" ] && echo enabled || echo disabled)"
}
[ "$ENABLE_HTTP3" = "1" ] && {
  echo "  HTTP/3: codeit nginx + QUIC templates + heal cron (every 5 min)"
}
echo ""
echo "  Verify (run on this server):"
echo "    [ -n \"$APACHE_BIN\" ] && $APACHE_BIN -V | grep MPM"
echo "    [ -f \"$APACHE_MPM_CONF\" ] && grep -A 9 'mpm_.*_module' '$APACHE_MPM_CONF'"
echo ""
echo "  Monitor:"
echo "    watch -n 5 'uptime; echo CLOSE_WAIT: \$(ss -tan state close-wait | wc -l); free -h | head -2'"
echo ""
echo "  Rollback:"
echo "    chattr -i $APACHE_MPM_CONF $CWP_TPL_DIR/*.tpl 2>/dev/null"
echo "    for F in \$(find /opt /etc /usr/local -name '*.bak-pre-tune' 2>/dev/null); do mv \"\$F\" \"\${F%.bak-pre-tune}\"; done"
echo "    for S in ${PHP_FPM_SERVICES[*]} $APACHE_SERVICE; do systemctl is-active --quiet \"\$S\" && systemctl reload \"\$S\"; done"
echo "=============================================="
