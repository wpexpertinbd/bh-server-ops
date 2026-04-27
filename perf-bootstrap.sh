#!/bin/bash
# ================================================================
#  Universal Web Server Performance Bootstrap (v3.4)
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
HEAVY_USERS="${HEAVY_USERS:-}"               # Laravel/Symfony users — 20 workers dynamic
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
if   [ "$TARGET_RAM_GB" -ge 60 ]; then  # 64 GB-class
  MAX_WORKERS=1600;  THREADS_PER_CHILD=50;  SERVER_LIMIT=32
  LIGHT_CHILDREN=10; HEAVY_CHILDREN=20
  OPCACHE_MB=256;    OPCACHE_FILES=20000;   INTERNED_MB=16
  REDIS_MAX=2gb
elif [ "$TARGET_RAM_GB" -ge 30 ]; then  # 32 GB-class (reports ~30-31)
  MAX_WORKERS=800;   THREADS_PER_CHILD=50;  SERVER_LIMIT=16
  LIGHT_CHILDREN=10; HEAVY_CHILDREN=20
  OPCACHE_MB=256;    OPCACHE_FILES=20000;   INTERNED_MB=16
  REDIS_MAX=1gb
elif [ "$TARGET_RAM_GB" -ge 14 ]; then  # 16 GB-class (reports ~15)
  MAX_WORKERS=400;   THREADS_PER_CHILD=50;  SERVER_LIMIT=8
  LIGHT_CHILDREN=8;  HEAVY_CHILDREN=15
  OPCACHE_MB=192;    OPCACHE_FILES=15000;   INTERNED_MB=12
  REDIS_MAX=512mb
elif [ "$TARGET_RAM_GB" -ge 7 ];  then  # 8 GB-class (reports ~7)
  MAX_WORKERS=200;   THREADS_PER_CHILD=40;  SERVER_LIMIT=5
  LIGHT_CHILDREN=6;  HEAVY_CHILDREN=12
  OPCACHE_MB=128;    OPCACHE_FILES=10000;   INTERNED_MB=8
  REDIS_MAX=384mb
elif [ "$TARGET_RAM_GB" -ge 3 ];  then  # 4 GB-class (reports ~3.5)
  MAX_WORKERS=100;   THREADS_PER_CHILD=25;  SERVER_LIMIT=4
  LIGHT_CHILDREN=4;  HEAVY_CHILDREN=8
  OPCACHE_MB=96;     OPCACHE_FILES=8000;    INTERNED_MB=8
  REDIS_MAX=256mb
else                                       # tiny VPS (1-3 GB)
  MAX_WORKERS=50;    THREADS_PER_CHILD=25;  SERVER_LIMIT=2
  LIGHT_CHILDREN=3;  HEAVY_CHILDREN=5
  OPCACHE_MB=64;     OPCACHE_FILES=5000;    INTERNED_MB=4
  REDIS_MAX=128mb
fi

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
    rm -f "$INI_DIR/99-opcache-tuned.ini"
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

  # Remove cron
  CRON_TMP=$(mktemp)
  crontab -l 2>/dev/null | grep -v 'saturation-monitor' | grep -v 'auto-recovery' > "$CRON_TMP" || true
  crontab "$CRON_TMP"
  rm -f "$CRON_TMP"
  echo "✓ Removed monitor + auto-recovery cron entries"

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

  ask_yn "Apply Apache MPM tuning?" "y"
  APPLY_APACHE_MPM="$REPLY"

  ask_yn "Apply Redis cap (2GB + LRU)?" "y"
  APPLY_REDIS="$REPLY"

  ask_yn "Apply Apache global hardening (block bad bots, sensitive files, PHP-in-uploads)?" "y"
  APPLY_APACHE_HARDENING="$REPLY"

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
  echo "  Install helpers:           $([ "$INSTALL_HELPERS" = "1" ] && echo yes || echo no)"
  echo "  Saturation-monitor cron:   $([ "$ENABLE_MONITOR_CRON" = "1" ] && echo yes || echo no)"
  echo "  Auto-recovery cron:        $([ "$ENABLE_AUTO_RECOVERY_CRON" = "1" ] && echo yes || echo no)"
  echo "  Sites to monitor:          ${MONITOR_SITES:-(auto-discover)}"
  echo ""
  ask_yn "Proceed with these settings?" "y"
  [ "$REPLY" = "0" ] && { echo "Aborted."; exit 0; }
  echo ""
fi

# ────────────────────────────────────────────────
# 1. Kernel tunables
# ────────────────────────────────────────────────
echo "─── [1/10] Kernel tunables ───"
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
echo "─── [2/10] Swap setup ───"
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
echo "─── [3/10] OPcache tuning ───"
if [ ${#PHP_INI_DIRS[@]} -eq 0 ]; then
  echo "⊘ No PHP ini directories detected — skipping"
else
  for INI_DIR in "${PHP_INI_DIRS[@]}"; do
    cat > "$INI_DIR/99-opcache-tuned.ini" <<EOF
; Bootstrap OPcache tune (auto-scaled to ${TARGET_RAM_GB}GB RAM)
opcache.memory_consumption=${OPCACHE_MB}
opcache.max_accelerated_files=${OPCACHE_FILES}
opcache.interned_strings_buffer=${INTERNED_MB}
opcache.revalidate_freq=60
EOF
    echo "✓ $INI_DIR/99-opcache-tuned.ini  (${OPCACHE_MB}MB / ${OPCACHE_FILES} files)"
  done
fi

# ────────────────────────────────────────────────
# 3. Per-user FPM pool tuning + request_terminate_timeout
# ────────────────────────────────────────────────
echo ""
echo "─── [4/10] Per-user FPM pool tuning ───"
TOUCHED=0; SKIPPED=0; HEAVY_TOUCHED=0

# Auto-detect Laravel/Symfony users by presence of `artisan` file in any
# of their docroots. Saves having to maintain HEAVY_USERS by hand. Only
# adds users that aren't already in HEAVY_USERS or SKIP_USERS.
DETECTED_HEAVY=""
for HOMEDIR in /home/*; do
  [ -d "$HOMEDIR" ] || continue
  USER=$(basename "$HOMEDIR")
  case " $HEAVY_USERS $SKIP_USERS " in *" $USER "*) continue ;; esac
  # any artisan file anywhere in user's home (depth 4 covers most layouts)
  if find "$HOMEDIR" -maxdepth 4 -name "artisan" -type f 2>/dev/null | head -1 | grep -q .; then
    DETECTED_HEAVY="$DETECTED_HEAVY $USER"
  fi
done
if [ -n "$DETECTED_HEAVY" ]; then
  echo "  Auto-detected Laravel/Symfony users:$DETECTED_HEAVY"
  HEAVY_USERS="$HEAVY_USERS$DETECTED_HEAVY"
fi

ensure_kv() {
  local conf="$1" key="$2" value="$3"
  if grep -q "^${key}\b" "$conf"; then
    sed -i "s|^${key}.*|${key} = ${value}|" "$conf"
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
        # Heavy app users — dynamic pool, scaled HEAVY_CHILDREN per RAM tier
        START_SVR=$(( HEAVY_CHILDREN / 5 )); [ $START_SVR -lt 2 ] && START_SVR=2
        MIN_SPARE=$(( HEAVY_CHILDREN / 10 )); [ $MIN_SPARE -lt 1 ] && MIN_SPARE=1
        MAX_SPARE=$(( HEAVY_CHILDREN / 2 )); [ $MAX_SPARE -lt 4 ] && MAX_SPARE=4
        ensure_kv "$CONF" "pm" "dynamic"
        ensure_kv "$CONF" "pm.max_children" "$HEAVY_CHILDREN"
        ensure_kv "$CONF" "pm.max_requests" "500"
        ensure_kv "$CONF" "pm.start_servers" "$START_SVR"
        ensure_kv "$CONF" "pm.min_spare_servers" "$MIN_SPARE"
        ensure_kv "$CONF" "pm.max_spare_servers" "$MAX_SPARE"
        ensure_kv "$CONF" "request_terminate_timeout" "30s"
        HEAVY_TOUCHED=$((HEAVY_TOUCHED+1))
      else
        # Light tenants (WordPress etc.) — ondemand pool, LIGHT_CHILDREN per RAM tier
        ensure_kv "$CONF" "pm" "ondemand"
        ensure_kv "$CONF" "pm.max_children" "$LIGHT_CHILDREN"
        ensure_kv "$CONF" "pm.max_requests" "500"
        ensure_kv "$CONF" "pm.process_idle_timeout" "30s"
        ensure_kv "$CONF" "request_terminate_timeout" "30s"
        TOUCHED=$((TOUCHED+1))
      fi
    done
  done
  echo "✓ Light: $TOUCHED  Heavy: $HEAVY_TOUCHED  Skipped: $SKIPPED"
fi

# ────────────────────────────────────────────────
# 4. CWP template patch (only if CWP detected)
# ────────────────────────────────────────────────
echo ""
echo "─── [5/10] CWP template patch ───"
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
# 5. Apache MPM bump (auto-detect MPM type)
# ────────────────────────────────────────────────
echo ""
echo "─── [6/10] Apache MPM tuning ───"
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
    chattr +i "$APACHE_MPM_CONF" 2>/dev/null || true
    echo "✓ MPM config valid + frozen"
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
# 5b. Apache mod_status visibility + bad-watchdog detector
# ────────────────────────────────────────────────
# Without /server-status reachable on the Apache backend port, future
# slowdown diagnosis is blind (you can't see scoreboard, BusyWorkers,
# DurationPerReq, Stopping count). Install a localhost-only Location.
# Also detect external "auto-restart on high load" cron scripts — these
# fight the tuning and cause the exact graceful-shutdown thrash we just
# fixed (lots of "G" in scoreboard, multi-second response times, 0% CPU).
echo ""
echo "─── [6b/10] Apache visibility + bad-watchdog check ───"
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
echo "─── [6c/10] Nginx anti-bot + rate limit ───"

NGINX_BIN=$(command -v nginx 2>/dev/null || echo "")
if [ -z "$NGINX_BIN" ] || ! systemctl is-active --quiet nginx 2>/dev/null; then
  echo "⊘ nginx not running — skipping anti-bot setup"
else
  # Detect vhost dir (CWP variants)
  NGX_VHOST_DIR=""
  for D in /etc/nginx/conf.d/vhosts /usr/local/nginx/conf/conf.d/vhosts /etc/nginx/sites-enabled; do
    [ -d "$D" ] && NGX_VHOST_DIR="$D" && break
  done
  NGX_CONF_D=/etc/nginx/conf.d
  [ -d /usr/local/nginx/conf/conf.d ] && [ ! -d "$NGX_CONF_D" ] && NGX_CONF_D=/usr/local/nginx/conf/conf.d
  NGX_SNIPPETS=/etc/nginx/snippets
  mkdir -p "$NGX_SNIPPETS"

  echo "  nginx vhost dir: ${NGX_VHOST_DIR:-(none found — http-only setup)}"
  echo "  nginx conf.d:    $NGX_CONF_D"

  # ─ http-level: bad-bot UA map (zones removed — used by fail2ban now) ─
  cat > "$NGX_CONF_D/00-anti-bot.conf" <<'NGXHTTP'
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
NGXHTTP

  # ─ server-level: the actual enforcement, included from each vhost ─
  # ONLY block-style rules — never try to "rate-limit then forward",
  # because we don't know the vhost's upstream from inside an include.
  # Brute-force protection on /wp-login.php is handled by fail2ban below.
  cat > "$NGX_SNIPPETS/anti-bot-server.conf" <<'NGXSERVER'
# bh-anti-bot v1 — included at the top of every server { }

# 1. Drop bad-UA scrapers (444 = close connection, zero bytes sent back)
if ($bh_bad_bot) { return 444; }

# 2. Block paths with no legitimate use + constant attack targets
location = /xmlrpc.php       { deny all; access_log off; log_not_found off; return 444; }
location ~* /wp-config\.php  { deny all; return 444; }
location ~* /\.(env|git|svn|htaccess|htpasswd|DS_Store)(/|$) { deny all; return 444; }
location ~* /(?:eval-stdin|wlwmanifest|adminer|phpunit|phpinfo)\.php$ { deny all; return 444; }
NGXSERVER

  echo "✓ wrote $NGX_CONF_D/00-anti-bot.conf"
  echo "✓ wrote $NGX_SNIPPETS/anti-bot-server.conf"

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
    rm -f "$NGX_CONF_D/00-anti-bot.conf" "$NGX_CONF_D/01-access-log.conf"
    [ -n "$CWP_NGX_TPL" ] && [ -f "${CWP_NGX_TPL}.bak-pre-antibot" ] && cp "${CWP_NGX_TPL}.bak-pre-antibot" "$CWP_NGX_TPL"
    "$NGINX_BIN" -t
  fi
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
echo "─── [6e/10] fail2ban (nginx + WP brute-force) ───"
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
echo "─── [6f/10] Nginx http-level perf tuning ───"
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
echo "─── [6d/10] PHP handler audit ───"
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
echo "─── [7/10] Redis cap ───"
if [ "$APPLY_REDIS" = "1" ] && command -v redis-cli >/dev/null && systemctl is-active --quiet redis 2>/dev/null; then
  redis-cli CONFIG SET maxmemory "$REDIS_MAX" > /dev/null
  redis-cli CONFIG SET maxmemory-policy allkeys-lru > /dev/null
  redis-cli CONFIG REWRITE > /dev/null 2>&1 || true
  echo "✓ Redis: maxmemory $REDIS_MAX, allkeys-lru"
else
  echo "⊘ Redis not running or skipped"
fi

# ────────────────────────────────────────────────
# 7. Reload services (graceful)
# ────────────────────────────────────────────────
echo ""
echo "─── [8/10] Reload services ───"
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
echo "─── [9/10] Apache global security hardening ───"
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
    RewriteCond %{HTTP_USER_AGENT} (GPTBot|ClaudeBot|CCBot|Amazonbot|anthropic-ai|cohere-ai|magpie-crawler|Diffbot|ImagesiftBot|Omgili|SiteAnalyzerBot|TurnitinBot|PerplexityBot) [NC,OR]
    # Empty / dash-only User-Agent (no legitimate client sends these)
    RewriteCond %{HTTP_USER_AGENT} ^-?$
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
# 10. Install helper scripts (tenant-cap, monitor, auto-recovery)
# ────────────────────────────────────────────────
echo ""
echo "─── [10/10] Install helper scripts ───"
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

  # ── Setup cron jobs ─────────────────────────────────────────
  CRON_TMP=$(mktemp)
  crontab -l 2>/dev/null | grep -v 'saturation-monitor' | grep -v 'auto-recovery' > "$CRON_TMP" || true

  if [ "$ENABLE_MONITOR_CRON" = "1" ]; then
    echo "*/5 * * * * /usr/local/sbin/saturation-monitor >/dev/null 2>&1" >> "$CRON_TMP"
    echo "✓ cron added: saturation-monitor every 5 min"
  fi

  if [ "$ENABLE_AUTO_RECOVERY_CRON" = "1" ]; then
    echo "*/3 * * * * /usr/local/sbin/auto-recovery >/dev/null 2>&1" >> "$CRON_TMP"
    echo "✓ cron added: auto-recovery every 3 min"
  else
    echo "⊘ auto-recovery cron disabled (set ENABLE_AUTO_RECOVERY_CRON=1 to enable)"
  fi

  crontab "$CRON_TMP"
  rm -f "$CRON_TMP"

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
