#!/bin/bash
# ================================================================
#  cPGuard Unattended Installer for CWP Pro + AlmaLinux (v1.0)
#
#  Runs ON the target server. Handles the full BiswasHost install
#  workflow non-interactively:
#    1. Preflight (OS, CWP, Apache, disk, RAM, cPGuard already?)
#    2. Whitelist cPGuard call-home IPs in CWP firewall (csf/firewalld)
#    3. Drive the interactive installer via `expect` with the canonical
#       BiswasHost answers (apache / apache / vhosts / cpguard.conf / ...)
#    4. Patch /usr/local/apache/conf.d/mod_security.conf
#       (comment owasp-old, include cpguard.conf) — idempotent
#    5. Write the standard BiswasHost SecRuleRemoveById exclusions
#       to /etc/cpguard/custom-exclusions.conf (incl. rule 1006000)
#    6. Auto-migrate CSF rules if CSF detected
#    7. Apply license, enable WAF, enable auto-cleanup
#    8. Restart httpd
#    9. Verify (license active, WAF on, services up, no fatal modsec)
#
#  Usage:
#    bash cpguard-install.sh LICENSE-KEY
#
#  Or one-liner (from dispatcher or by hand):
#    curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/bh-server-ops/main/cpguard/cpguard-install.sh \
#      | bash -s -- LICENSE-KEY
#
#  Idempotent. Safe to re-run. Logs to /var/log/bh-cpguard-install.log
# ================================================================

set -o pipefail

LICENSE="${1:-}"
EDITION="${CPGUARD_EDITION:-standard}"   # standard|lite
APPLY_EXCLUSIONS="${APPLY_EXCLUSIONS:-1}"
MIGRATE_CSF="${MIGRATE_CSF:-1}"
LOG=/var/log/bh-cpguard-install.log

# ---------- helpers ----------
log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&2; }
die()  { log "FATAL: $*"; exit 1; }
ok()   { log "OK:    $*"; }
warn() { log "WARN:  $*"; }

[ "$(id -u)" -eq 0 ] || die "Must run as root."
[ -n "$LICENSE" ] || die "Missing license key. Usage: bash $0 LICENSE-KEY"

mkdir -p "$(dirname "$LOG")"
: > /tmp/bh-cpg-summary.txt
SUMMARY_KV() { printf '%s=%s\n' "$1" "$2" >> /tmp/bh-cpg-summary.txt; }

log "================================================================"
log "BH cPGuard installer v1.0 starting on $(hostname)"
log "Edition: $EDITION | License: ${LICENSE:0:6}…${LICENSE: -4} | PID $$"
log "================================================================"

# ---------- 1. Preflight ----------
log "[1/9] Preflight..."

OS_REL=/etc/os-release
[ -f "$OS_REL" ] || die "Cannot read $OS_REL"
. "$OS_REL"
case "$ID" in
  almalinux|rocky|centos|rhel) ok "OS: $PRETTY_NAME" ;;
  *) die "Unsupported OS: $ID (expected almalinux/rocky/centos/rhel)" ;;
esac
SUMMARY_KV os "$PRETTY_NAME"

[ -d /usr/local/cwpsrv ] || die "CWP not detected (/usr/local/cwpsrv missing)"
ok "CWP detected"

command -v httpd  >/dev/null || die "httpd not found (Apache required)"
[ -d /usr/local/apache/conf.d ] || die "Apache conf.d missing — non-standard CWP build?"
ok "Apache present"

FREE_DISK_MB=$(df -Pm /usr/local | awk 'NR==2{print $4}')
[ "${FREE_DISK_MB:-0}" -ge 500 ] || die "Need ≥500MB free in /usr/local (have ${FREE_DISK_MB}MB)"
RAM_MB=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)
ok "Disk free: ${FREE_DISK_MB}MB | RAM: ${RAM_MB}MB"
SUMMARY_KV ram_mb "$RAM_MB"
SUMMARY_KV disk_free_mb "$FREE_DISK_MB"

# Already installed?
ALREADY_INSTALLED=0
if [ -d /opt/cpguard ] && command -v cpgcli >/dev/null 2>&1; then
  ALREADY_INSTALLED=1
  CUR_VER=$(cpgcli --version 2>/dev/null | head -1 || echo unknown)
  warn "cPGuard already installed ($CUR_VER) — will skip installer, refresh config + license only"
  SUMMARY_KV preexisting "yes"
else
  SUMMARY_KV preexisting "no"
fi

# cPGuard requires the OWASP-old ModSec ruleset to be the active baseline
# before install (its installer writes paths assuming it exists). If the
# server is still on Comodo WAF, abort here with clear instructions —
# rather than letting `expect` time out mysteriously mid-install.
OWASP_DIR=/usr/local/apache/modsecurity-owasp-old
if [ "$ALREADY_INSTALLED" -eq 0 ] && [ ! -d "$OWASP_DIR" ]; then
  CURRENT_WAF=""
  [ -d /usr/local/apache/modsecurity-comodo ] && CURRENT_WAF="comodo"
  [ -d /usr/local/apache/modsecurity-crs    ] && CURRENT_WAF="${CURRENT_WAF:+$CURRENT_WAF + }crs"
  [ -z "$CURRENT_WAF" ] && CURRENT_WAF="unknown/none"
  cat <<EOF | tee -a "$LOG"

================================================================
  ABORT: OWASP-old ModSec ruleset not installed on this server.

  cPGuard's installer requires $OWASP_DIR
  to exist before it will run. Current active WAF: $CURRENT_WAF

  FIX (per server, takes 30 seconds in CWP admin):
    1. Log into CWP admin
    2. Security  ->  ModSecurity
    3. Switch active ruleset to "OWASP" (or OWASP rules)
    4. Save / Install
    5. Re-run this script

  Note: OWASP is only required DURING install. Once cPGuard is up,
  the active ruleset becomes cPGuard's own — OWASP becomes inert.
================================================================
EOF
  die "Switch to OWASP in CWP first, then re-run."
fi
[ -d "$OWASP_DIR" ] && ok "OWASP-old baseline present (required by cPGuard installer)"

# CSF present?
CSF_PRESENT=0
if [ -x /usr/sbin/csf ] || [ -d /etc/csf ]; then
  CSF_PRESENT=1
  ok "CSF detected — will migrate after install"
fi
SUMMARY_KV csf_present "$CSF_PRESENT"

# Snapshot mod_security.conf before any edits
MSEC_CONF=/usr/local/apache/conf.d/mod_security.conf
if [ -f "$MSEC_CONF" ] && [ ! -f "$MSEC_CONF.bh-preinstall" ]; then
  cp -a "$MSEC_CONF" "$MSEC_CONF.bh-preinstall"
  ok "Snapshot saved: $MSEC_CONF.bh-preinstall"
fi

# ---------- 2. Whitelist cPGuard IPs ----------
log "[2/9] Whitelisting cPGuard call-home IPs..."
CPG_IPS=(137.184.200.210 159.89.87.35 167.99.149.179)
for ip in "${CPG_IPS[@]}"; do
  if command -v csf >/dev/null 2>&1; then
    grep -q "^$ip" /etc/csf/csf.allow 2>/dev/null || csf -a "$ip" "cpguard" >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-source="$ip" >/dev/null 2>&1 || true
  fi
done
command -v firewall-cmd >/dev/null && firewall-cmd --reload >/dev/null 2>&1 || true
ok "Whitelisted: ${CPG_IPS[*]}"

# ---------- 3. Install cPGuard (via expect) ----------
log "[3/9] Installing cPGuard ($EDITION)..."

if [ "$ALREADY_INSTALLED" -eq 0 ]; then
  command -v expect >/dev/null 2>&1 || {
    log "Installing expect..."
    dnf install -y expect >/dev/null 2>&1 || yum install -y expect >/dev/null 2>&1 || die "Failed to install expect"
  }

  if [ "$EDITION" = "lite" ]; then
    INSTALLER_URL="https://downloads.opsshield.com/cpguard/cpguard_lite_install.sh"
    INSTALLER_FILE="cpguard_lite_install.sh"
  else
    INSTALLER_URL="https://downloads.opsshield.com/cpguard/cpguard_install.sh"
    INSTALLER_FILE="cpguard_install.sh"
  fi

  cd /usr/local/src
  rm -f "$INSTALLER_FILE"
  curl -fsSL "$INSTALLER_URL" -o "$INSTALLER_FILE" || die "Failed to download installer"
  chmod +x "$INSTALLER_FILE"
  ok "Downloaded $INSTALLER_FILE ($(wc -c < "$INSTALLER_FILE") bytes)"

  # Drive the interactive installer. Patterns are intentionally permissive —
  # cPGuard installer wording changes between releases.
  cat > /tmp/bh-cpg-expect.exp <<EXPECT
#!/usr/bin/expect -f
set timeout 1800
log_user 1
spawn bash /usr/local/src/$INSTALLER_FILE $LICENSE

expect {
  -re "(?i)(web server|webserver)\[^\n\]*:"               { send "apache\r"; exp_continue }
  -re "(?i)web_?server_?conf\[^\n\]*:"                    { send "/usr/local/apache/conf.d/vhosts/*.conf\r"; exp_continue }
  -re "(?i)domain_?list\[^\n\]*:"                         { send "\r"; exp_continue }
  -re "(?i)user_?list\[^\n\]*:"                           { send "\r"; exp_continue }
  -re "(?i)waf_?server\[^\n\]*:"                          { send "apache\r"; exp_continue }
  -re "(?i)waf_?server_?conf\[^\n\]*:"                    { send "/usr/local/apache/cpguard.conf\r"; exp_continue }
  -re "(?i)(restart|reload)\[^\n\]*command\[^\n\]*:"      { send "systemctl restart httpd\r"; exp_continue }
  -re "(?i)(audit|modsec).*log\[^\n\]*:"                  { send "/usr/local/apache/logs/modsec_audit.log\r"; exp_continue }
  -re "(?i)error_?log\[^\n\]*:"                           { send "\r"; exp_continue }
  -re "(?i)\\\[y/n\\\]"                                   { send "y\r"; exp_continue }
  eof
  timeout { puts "EXPECT TIMEOUT"; exit 124 }
}

catch wait result
exit [lindex \$result 3]
EXPECT

  chmod +x /tmp/bh-cpg-expect.exp
  /tmp/bh-cpg-expect.exp 2>&1 | tee -a "$LOG"
  EXP_RC=${PIPESTATUS[0]}
  rm -f /tmp/bh-cpg-expect.exp

  [ "$EXP_RC" -eq 0 ] || warn "Installer exited rc=$EXP_RC — continuing to verify"

  [ -d /opt/cpguard ] || die "Installer ran but /opt/cpguard missing — check $LOG"
  command -v cpgcli >/dev/null 2>&1 || die "cpgcli not in PATH after install"
  ok "cPGuard binary installed"
else
  ok "Skipped installer (already present)"
fi

CPG_VER=$(cpgcli --version 2>/dev/null | head -1 || echo unknown)
SUMMARY_KV cpguard_version "$CPG_VER"

# ---------- 4. Patch mod_security.conf ----------
log "[4/9] Patching $MSEC_CONF..."

if [ -f "$MSEC_CONF" ]; then
  # Comment any active owasp-old/owasp.conf Include
  sed -i -E 's|^[[:space:]]*Include[[:space:]]+"?/usr/local/apache/modsecurity-owasp-old/owasp\.conf"?|#&|' "$MSEC_CONF"

  # Ensure cpguard.conf Include is present
  if ! grep -qE '^[[:space:]]*Include[[:space:]]+"?/usr/local/apache/cpguard\.conf"?' "$MSEC_CONF"; then
    echo 'Include "/usr/local/apache/cpguard.conf"' >> "$MSEC_CONF"
    ok "Added cpguard.conf Include"
  else
    ok "cpguard.conf Include already present"
  fi
else
  warn "$MSEC_CONF missing — installer may not have created it. Skipping patch."
fi

# ---------- 5. Standard BiswasHost exclusions ----------
if [ "$APPLY_EXCLUSIONS" = "1" ]; then
  log "[5/9] Writing BiswasHost SecRuleRemoveById exclusions..."
  mkdir -p /etc/cpguard
  cat > /etc/cpguard/custom-exclusions.conf <<'EXCL'
# BH-CPGUARD-EXCLUSIONS — managed by cpguard-install.sh, safe to edit
# BiswasHost standard set: CWP + popular CMS false positives + BD ISP fix

# CWP
SecRuleRemoveById 218500
SecRuleRemoveById 210492
SecRuleRemoveById 225170
SecRuleRemoveById 210730
SecRuleRemoveById 210380
SecRuleRemoveById 960017
SecRuleRemoveById 960015
SecRuleRemoveById 960009

# Joomla
SecRuleRemoveById 960024
SecRuleRemoveById 950120
SecRuleRemoveById 981173
SecRuleRemoveById 950901
SecRuleRemoveById 981257
SecRuleRemoveById 981245
SecRuleRemoveById 973338
SecRuleRemoveById 973300
SecRuleRemoveById 973304
SecRuleRemoveById 973333

# WordPress
SecRuleRemoveById 981242
SecRuleRemoveById 981246
SecRuleRemoveById 981243
SecRuleRemoveById 959073
SecRuleRemoveById 958030

# Drupal
SecRuleRemoveById 981231

# webftp_simple
SecRuleRemoveById 950922
SecRuleRemoveById 981000
SecRuleRemoveById 950109

# phpMyAdmin
SecRuleRemoveById 981205
SecRuleRemoveById 970901
SecRuleRemoveById 960904
SecRuleRemoveById 960915
SecRuleRemoveById 981318
SecRuleRemoveById 981320
SecRuleRemoveById 981240

# BD consumer ISP false-positive on ecommerce sites
SecRuleRemoveById 1006000
# END BH-CPGUARD-EXCLUSIONS
EXCL

  # Also append rule 1006000 marker to wafurls.txt (matches manual procedure)
  if [ -f /etc/cpguard/wafurls.txt ] && ! grep -q "SecRuleRemoveById 1006000" /etc/cpguard/wafurls.txt; then
    cat >> /etc/cpguard/wafurls.txt <<'EOF'

# Disable Proxy IPDB block (rule 1006000) — false-positives BD consumer ISPs
SecRuleRemoveById 1006000
EOF
  fi
  ok "Exclusions written (38 rules)"
else
  log "[5/9] Skipped exclusions (APPLY_EXCLUSIONS=0)"
fi

# ---------- 6. CSF migration ----------
if [ "$MIGRATE_CSF" = "1" ] && [ "$CSF_PRESENT" -eq 1 ]; then
  log "[6/9] Migrating CSF rules to cPGuard..."
  if [ -f /opt/cpguard/app/scripts/csf_migration.php ]; then
    php /opt/cpguard/app/scripts/csf_migration.php 2>&1 | tee -a "$LOG" || warn "CSF migration script reported errors — review log"
    SUMMARY_KV csf_migrated "yes"
    ok "CSF rules imported"
  else
    warn "csf_migration.php missing (cPGuard version too old?)"
    SUMMARY_KV csf_migrated "no_script"
  fi
else
  log "[6/9] CSF migration skipped (CSF_PRESENT=$CSF_PRESENT, MIGRATE_CSF=$MIGRATE_CSF)"
  SUMMARY_KV csf_migrated "skipped"
fi

# ---------- 7. License + WAF enable ----------
log "[7/9] Applying license + enabling WAF..."
cpgcli license --key "$LICENSE" 2>&1 | tee -a "$LOG" || warn "license --key returned non-zero"
sleep 2
cpgcli waf --enable 2>&1 | tee -a "$LOG" || warn "waf --enable returned non-zero"
cpgcli cleanup --enable >/dev/null 2>&1 || true
ok "License + WAF + cleanup applied"

# ---------- 8. Restart Apache ----------
log "[8/9] Restarting httpd..."
if httpd -t 2>&1 | tee -a "$LOG"; then
  systemctl restart httpd 2>&1 | tee -a "$LOG"
  sleep 2
  systemctl is-active --quiet httpd || die "httpd failed to start after restart — restore $MSEC_CONF.bh-preinstall and investigate"
  ok "httpd restarted cleanly"
else
  warn "httpd -t reported config errors — rolling back mod_security.conf"
  [ -f "$MSEC_CONF.bh-preinstall" ] && cp -a "$MSEC_CONF.bh-preinstall" "$MSEC_CONF"
  systemctl restart httpd
  die "Apache config invalid after cPGuard patches — rolled back, please investigate manually"
fi

# ---------- 9. Verify ----------
log "[9/9] Verifying installation..."

VERIFY_FAILS=0

LIC_STATUS=$(cpgcli license --status 2>/dev/null | tr -d '\r')
echo "$LIC_STATUS" | tee -a "$LOG"
if echo "$LIC_STATUS" | grep -iqE 'active|valid'; then
  ok "License: ACTIVE"
  SUMMARY_KV license_status "active"
else
  warn "License status not clearly Active — review above"
  SUMMARY_KV license_status "unclear"
  VERIFY_FAILS=$((VERIFY_FAILS+1))
fi

WAF_STATUS=$(cpgcli waf --status 2>/dev/null | tr -d '\r')
echo "$WAF_STATUS" | tee -a "$LOG"
if echo "$WAF_STATUS" | grep -iqE 'enabled|running|active'; then
  ok "WAF: ENABLED"
  SUMMARY_KV waf_status "enabled"
else
  warn "WAF status not clearly enabled — running cpgcli waf --enable again"
  cpgcli waf --enable >/dev/null 2>&1 || true
  SUMMARY_KV waf_status "retry_needed"
  VERIFY_FAILS=$((VERIFY_FAILS+1))
fi

systemctl is-active --quiet httpd    && ok "httpd: active"    || { warn "httpd inactive";    VERIFY_FAILS=$((VERIFY_FAILS+1)); }
systemctl is-active --quiet cpguard 2>/dev/null && ok "cpguard service: active" || warn "cpguard service: not present as systemd unit (some versions don't ship one)"

# 30s error_log sniff for fatal ModSec errors
log "Tailing error_log for 30s to detect fatal ModSec errors..."
FATAL=$(timeout 30 tail -F /usr/local/apache/logs/error_log 2>/dev/null | grep -m1 -iE 'modsecurity.*(fatal|error parsing)' || true)
if [ -n "$FATAL" ]; then
  warn "ModSec error detected: $FATAL"
  SUMMARY_KV modsec_errors "yes"
  VERIFY_FAILS=$((VERIFY_FAILS+1))
else
  ok "No fatal ModSec errors in last 30s"
  SUMMARY_KV modsec_errors "none"
fi

# Local HTTP smoke test
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1/ || echo 000)
if [[ "$HTTP_CODE" =~ ^(200|301|302|403)$ ]]; then
  ok "HTTP smoke test: $HTTP_CODE"
  SUMMARY_KV http_smoke "$HTTP_CODE"
else
  warn "HTTP smoke test returned $HTTP_CODE"
  SUMMARY_KV http_smoke "$HTTP_CODE"
  VERIFY_FAILS=$((VERIFY_FAILS+1))
fi

log "================================================================"
if [ "$VERIFY_FAILS" -eq 0 ]; then
  log "RESULT: SUCCESS — cPGuard $CPG_VER installed cleanly on $(hostname)"
  SUMMARY_KV result "success"
  exit 0
else
  log "RESULT: PARTIAL — $VERIFY_FAILS verification check(s) failed on $(hostname). Review $LOG"
  SUMMARY_KV result "partial"
  exit 2
fi
