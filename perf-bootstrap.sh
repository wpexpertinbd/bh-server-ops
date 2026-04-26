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
ENABLE_AUTO_RECOVERY_CRON="${ENABLE_AUTO_RECOVERY_CRON:-0}"
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
if   [ "$TARGET_RAM_GB" -ge 64 ]; then  # baseline ~10 GB
  MAX_WORKERS=1600;  THREADS_PER_CHILD=50;  SERVER_LIMIT=32
  LIGHT_CHILDREN=10; HEAVY_CHILDREN=20
  OPCACHE_MB=256;    OPCACHE_FILES=20000;   INTERNED_MB=16
  REDIS_MAX=2gb
elif [ "$TARGET_RAM_GB" -ge 32 ]; then  # baseline ~6 GB
  MAX_WORKERS=800;   THREADS_PER_CHILD=50;  SERVER_LIMIT=16
  LIGHT_CHILDREN=10; HEAVY_CHILDREN=20
  OPCACHE_MB=256;    OPCACHE_FILES=20000;   INTERNED_MB=16
  REDIS_MAX=1gb
elif [ "$TARGET_RAM_GB" -ge 16 ]; then  # baseline ~3 GB
  MAX_WORKERS=400;   THREADS_PER_CHILD=50;  SERVER_LIMIT=8
  LIGHT_CHILDREN=8;  HEAVY_CHILDREN=15
  OPCACHE_MB=192;    OPCACHE_FILES=15000;   INTERNED_MB=12
  REDIS_MAX=512mb
elif [ "$TARGET_RAM_GB" -ge 8 ];  then  # baseline ~1.5 GB
  MAX_WORKERS=200;   THREADS_PER_CHILD=40;  SERVER_LIMIT=5
  LIGHT_CHILDREN=6;  HEAVY_CHILDREN=12
  OPCACHE_MB=128;    OPCACHE_FILES=10000;   INTERNED_MB=8
  REDIS_MAX=384mb
elif [ "$TARGET_RAM_GB" -ge 4 ];  then  # baseline ~700 MB (small VPS)
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

    ask_yn "Enable auto-recovery cron (every 3 min, auto-reloads on saturation)?" "n"
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

  # MAX_WORKERS, THREADS_PER_CHILD, SERVER_LIMIT already computed in the
  # RAM TIER block at the top of the script — use those values.
  THREADS=$THREADS_PER_CHILD
  # Scale spare-thread bands proportionally to the worker pool.
  SS=$(( MAX_WORKERS / 8 )); [ $SS -lt 4 ] && SS=4   # StartServers
  MIN_S=$(( MAX_WORKERS / 16 )); [ $MIN_S -lt 25 ] && MIN_S=25
  MAX_S=$(( MAX_WORKERS / 4 )); [ $MAX_S -lt 100 ] && MAX_S=100
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
    MaxConnectionsPerChild 10000
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
    MaxConnectionsPerChild 10000
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
  else
    echo "✗ Syntax error — restoring backup"
    cp "${APACHE_MPM_CONF}.bak-pre-tune" "$APACHE_MPM_CONF"
  fi
else
  echo "⊘ Apache MPM tuning skipped"
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
[ -n "$APACHE_SERVICE" ] && systemctl is-active --quiet "$APACHE_SERVICE" 2>/dev/null && \
  systemctl reload "$APACHE_SERVICE" && echo "✓ reloaded $APACHE_SERVICE"

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
# Blocks: file exposure, hidden dirs, PHP-in-uploads, bad bots, TRACE.
# ===================================================================

# 1. Sensitive file exposure
<FilesMatch "^(\.env(\..*)?|\.git.*|\.htaccess|\.htpasswd|\.user\.ini|composer\.(json|lock)|package(-lock)?\.json|yarn\.lock|wp-config(-sample)?\.php|configuration\.php|wp-cron\.php|xmlrpc\.php|readme\.html|license\.txt|install\.php|upgrade\.php|info\.php|phpinfo\.php|test\.php|adminer\.php|pma\.php)$">
  Require all denied
</FilesMatch>

# 2. Hidden directories (.git, .svn, .hg, .DS_Store) — except /.well-known/
<DirectoryMatch "/\.(?!well-known)">
  Require all denied
</DirectoryMatch>

# 3. Disable TRACE/TRACK (XSS attack vector)
TraceEnable Off

# 4. Block PHP execution in upload directories (malware persistence vector)
<LocationMatch "/(wp-content/uploads|uploads|public/storage|public_html/uploads|storage/app/public).*\.(php|phtml|php3|php4|php5|php7|phar|pl|py|jsp|asp|aspx|sh|cgi)$">
  Require all denied
</LocationMatch>

# 5. Block direct access to WordPress internals
<LocationMatch "/wp-includes/.*\.php$">
  Require all denied
</LocationMatch>

# 6. Block aggressive bots / scrapers / AI crawlers
SetEnvIfNoCase User-Agent "PetalBot|MJ12bot|DotBot|SemrushBot|AhrefsBot|Bytespider|YandexBot|seznambot|MegaIndex|BLEXBot|DataForSeoBot|GeedoShop|MauiBot|sogou|spbot|trendkite|garlik|webmeup|exabot|Lipperhey|psbot|360Spider" bad_bot
SetEnvIfNoCase User-Agent "GPTBot|ClaudeBot|CCBot|Amazonbot|anthropic-ai|cohere-ai|magpie-crawler|Diffbot|FacebookBot|ImagesiftBot|Omgili|SiteAnalyzerBot|TurnitinBot|PerplexityBot" bad_bot
SetEnvIfNoCase User-Agent "^$" bad_bot
SetEnvIfNoCase User-Agent "^-?$" bad_bot

<RequireAll>
  Require all granted
  Require not env bad_bot
</RequireAll>

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
  systemctl reload "$APACHE_SERVICE" 2>/dev/null && echo "✓ reloaded $APACHE_SERVICE (hardening live)"
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
