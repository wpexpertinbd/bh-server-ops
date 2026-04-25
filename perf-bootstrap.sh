#!/bin/bash
# ================================================================
#  Universal Web Server Performance Bootstrap (v3.1)
#  Works on: CWP, cPanel/EA4, RHEL/AlmaLinux/Rocky, Debian/Ubuntu
#  Idempotent. Safe to re-run.
#
#  Installs:
#    1. Server-wide perf tuning (kernel, OPcache, FPM, MPM, Redis)
#    2. /usr/local/sbin/tenant-cap        — quick noisy-neighbor cap
#    3. /usr/local/sbin/saturation-monitor — TTFB watcher (cron 5min)
#    4. /usr/local/sbin/auto-recovery     — auto-reload on saturation (cron 3min)
# ================================================================

set -e

#################### EDIT THESE IF APPLICABLE ####################
HEAVY_USERS=""              # Laravel/Symfony users get 20 workers dynamic
                            # Example: HEAVY_USERS="artechbd kotipoti"
SKIP_USERS="nobody"         # System users to skip
APPLY_APACHE_MPM=1          # 0 to skip MPM bump
APPLY_REDIS=1               # 0 to skip Redis cap
TARGET_RAM_GB=64            # Used to size MPM workers — adjust if smaller box

# Helper scripts + cron
INSTALL_HELPERS=1           # 0 to skip /usr/local/sbin/ helpers
ENABLE_MONITOR_CRON=1       # 0 to skip TTFB monitor cron (5min)
ENABLE_AUTO_RECOVERY_CRON=0 # 1 to enable self-healing reload cron (3min)
                            # Off by default — enable after observing patterns

# Sites to monitor for saturation. Space-separated.
# If empty, monitor will auto-discover from CWP user_data or skip.
MONITOR_SITES=""            # Example: MONITOR_SITES="www.artechbd.com api.artechbd.com kotipoti.com"
TTFB_WARN_THRESHOLD=10      # seconds; log to /var/log/saturation.log if exceeded
TTFB_RECOVER_THRESHOLD=20   # seconds; auto-recovery triggers if exceeded
#################################################################

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
    PHP_FPM_SERVICES+=("php-fpm-${V}")
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
echo "  Universal Perf Bootstrap v3"
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
echo ""

if [ -z "$APACHE_BIN" ] && [ ${#PHP_FPM_USER_DIRS[@]} -eq 0 ]; then
  echo "✗ No Apache or PHP-FPM detected. Nothing to do."
  exit 1
fi

# ────────────────────────────────────────────────
# 1. Kernel tunables
# ────────────────────────────────────────────────
echo "─── [1/7] Kernel tunables ───"
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
# 2. OPcache bump for every PHP-FPM ini.d found
# ────────────────────────────────────────────────
echo ""
echo "─── [2/7] OPcache tuning ───"
if [ ${#PHP_INI_DIRS[@]} -eq 0 ]; then
  echo "⊘ No PHP ini directories detected — skipping"
else
  for INI_DIR in "${PHP_INI_DIRS[@]}"; do
    cat > "$INI_DIR/99-opcache-tuned.ini" <<'EOF'
; Bootstrap OPcache tune — Laravel/WordPress safe
opcache.memory_consumption=256
opcache.max_accelerated_files=20000
opcache.interned_strings_buffer=16
opcache.revalidate_freq=60
EOF
    echo "✓ $INI_DIR/99-opcache-tuned.ini"
  done
fi

# ────────────────────────────────────────────────
# 3. Per-user FPM pool tuning + request_terminate_timeout
# ────────────────────────────────────────────────
echo ""
echo "─── [3/7] Per-user FPM pool tuning ───"
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
        ensure_kv "$CONF" "pm" "dynamic"
        ensure_kv "$CONF" "pm.max_children" "20"
        ensure_kv "$CONF" "pm.max_requests" "500"
        ensure_kv "$CONF" "pm.start_servers" "4"
        ensure_kv "$CONF" "pm.min_spare_servers" "2"
        ensure_kv "$CONF" "pm.max_spare_servers" "8"
        ensure_kv "$CONF" "request_terminate_timeout" "30s"
        HEAVY_TOUCHED=$((HEAVY_TOUCHED+1))
      else
        ensure_kv "$CONF" "pm" "ondemand"
        ensure_kv "$CONF" "pm.max_children" "10"
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
echo "─── [4/7] CWP template patch ───"
if [ -n "$CWP_TPL_DIR" ] && [ -d "$CWP_TPL_DIR" ]; then
  for T in "$CWP_TPL_DIR"/default.tpl "$CWP_TPL_DIR"/processes-40.tpl "$CWP_TPL_DIR"/processes-45.tpl; do
    [ -f "$T" ] || continue
    chattr -i "$T" 2>/dev/null || true
    [ -f "${T}.bak-pre-tune" ] || cp "$T" "${T}.bak-pre-tune"
    sed -i 's/^pm.max_children = 4$/pm.max_children = 10/' "$T"
    sed -i 's/^pm.max_requests = 4000$/pm.max_requests = 500/' "$T"
    sed -i 's/^pm.process_idle_timeout = 15s$/pm.process_idle_timeout = 30s/' "$T"
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
echo "─── [5/7] Apache MPM tuning ───"
if [ "$APPLY_APACHE_MPM" = "1" ] && [ -n "$APACHE_BIN" ] && [ -f "$APACHE_MPM_CONF" ]; then
  CURRENT_MPM=$($APACHE_BIN -V 2>&1 | grep "Server MPM" | awk '{print $3}' | tr 'A-Z' 'a-z')
  echo "Current MPM: $CURRENT_MPM"
  echo "Config file: $APACHE_MPM_CONF"

  case "$TARGET_RAM_GB" in
    "" | *[!0-9]*) MAX_WORKERS=1600 ;;
    *)
      if [ "$TARGET_RAM_GB" -ge 64 ];   then MAX_WORKERS=1600
      elif [ "$TARGET_RAM_GB" -ge 32 ]; then MAX_WORKERS=800
      elif [ "$TARGET_RAM_GB" -ge 16 ]; then MAX_WORKERS=400
      else                                   MAX_WORKERS=200; fi ;;
  esac
  THREADS=50
  SERVER_LIMIT=$(( MAX_WORKERS / THREADS ))
  echo "Sizing: TARGET_RAM=${TARGET_RAM_GB}G → MaxRequestWorkers=$MAX_WORKERS, ServerLimit=$SERVER_LIMIT"

  chattr -i "$APACHE_MPM_CONF" 2>/dev/null || true
  [ -f "${APACHE_MPM_CONF}.bak-pre-tune" ] || cp "$APACHE_MPM_CONF" "${APACHE_MPM_CONF}.bak-pre-tune"

  if [ "$CURRENT_MPM" = "event" ] || [ "$CURRENT_MPM" = "worker" ]; then
    MOD="mpm_${CURRENT_MPM}_module"
    python3 <<PYEOF
import re
path = '$APACHE_MPM_CONF'
with open(path) as f: content = f.read()
new_block = """<IfModule $MOD>
    StartServers             8
    MinSpareThreads        100
    MaxSpareThreads        400
    ThreadLimit            128
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
echo "─── [6/7] Redis cap ───"
if [ "$APPLY_REDIS" = "1" ] && command -v redis-cli >/dev/null && systemctl is-active --quiet redis 2>/dev/null; then
  redis-cli CONFIG SET maxmemory 2gb > /dev/null
  redis-cli CONFIG SET maxmemory-policy allkeys-lru > /dev/null
  redis-cli CONFIG REWRITE > /dev/null 2>&1 || true
  echo "✓ Redis: maxmemory 2GB, allkeys-lru"
else
  echo "⊘ Redis not running or skipped"
fi

# ────────────────────────────────────────────────
# 7. Reload services (graceful)
# ────────────────────────────────────────────────
echo ""
echo "─── [7/8] Reload services ───"
for S in "${PHP_FPM_SERVICES[@]}"; do
  systemctl is-active --quiet "$S" 2>/dev/null && systemctl reload "$S" && echo "✓ reloaded $S"
done
[ -n "$APACHE_SERVICE" ] && systemctl is-active --quiet "$APACHE_SERVICE" 2>/dev/null && \
  systemctl reload "$APACHE_SERVICE" && echo "✓ reloaded $APACHE_SERVICE"

# ────────────────────────────────────────────────
# 8. Install helper scripts (tenant-cap, monitor, auto-recovery)
# ────────────────────────────────────────────────
echo ""
echo "─── [8/8] Install helper scripts ───"
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
    T=\$(curl -s -o /dev/null -w "%{time_starttransfer}" -m 30 "https://\$SITE/" 2>/dev/null)
    T_INT=\${T%.*}
    if [ "\${T_INT:-0}" -gt "\$THRESHOLD" ] 2>/dev/null; then
        CW=\$(ss -tan state close-wait 2>/dev/null | wc -l)
        TOP=\$(ps aux 2>/dev/null | grep "php-fpm: pool" | grep -v grep | awk '{print \$1}' | sort | uniq -c | sort -rn | head -3 | awk '{printf "%s:%s ",\$2,\$1}')
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] SLOW: \$SITE TTFB=\${T}s  CLOSE_WAIT=\$CW  top_pools=\$TOP" >> \$LOG
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
    T=\$(curl -s -o /dev/null -w "%{time_starttransfer}" -m 25 "https://\$SITE/" 2>/dev/null)
    T_INT=\${T%.*}
    if [ "\${T_INT:-0}" -gt "\$THRESHOLD" ] 2>/dev/null; then
        echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Saturation: \$SITE TTFB=\${T}s — triggering recovery" >> \$LOG
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

    systemctl reload httpd 2>/dev/null && echo "  reloaded httpd" >> \$LOG
    for S in \$(systemctl list-units --type=service --state=active --no-legend 2>/dev/null | awk '{print \$1}' | grep -E "^(php-fpm|ea-php.*-php-fpm|php[0-9.]+-fpm)"); do
        systemctl reload "\$S" 2>/dev/null && echo "  reloaded \$S" >> \$LOG
    done
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
