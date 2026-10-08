#!/bin/bash
# bh-boot-order.sh — make Apache and amavis come up correctly after a reboot (CWP / AlmaLinux 8).
#
#   bash bh-boot-order.sh            # install/refresh both drop-ins (idempotent, no restarts);
#                                    # also copies itself to /usr/local/sbin/bh-boot-order.sh
#   bash /usr/local/sbin/bh-boot-order.sh --check   # show whether they are in place and loaded
#
# Found during the 2026-10-08 fleet reboots:
#  1. Apache: ModSecurity (cpGuard MEWAF) downloads its rules from https://rules.malware.expert at
#     start. httpd.service only waited for network.target, so on s3 Apache started before the
#     network was reachable, hung, was killed at 90 s, and sites were down ~2.5 min.
#     → wait for network-online.target, allow 180 s.
#  2. amavisd: came up "active" but listening on nothing (s3) or only [::1]:10024 (biswashost),
#     while Postfix's content_filter sends to 127.0.0.1:10024 → all mail deferred.
#     → wait for network-online.target and FAIL the start unless 127.0.0.1:10024 accepts a
#       connection within 120 s, so the unit's own Restart=on-failure retries it.
# Undo: delete the two files below and run `systemctl daemon-reload`.
set -euo pipefail

HTTPD_DROPIN=/etc/systemd/system/httpd.service.d/bh-network-online.conf
AMAVIS_DROPIN=/etc/systemd/system/amavisd.service.d/bh-listen-check.conf

check(){
  local ok=1
  if systemctl cat httpd >/dev/null 2>&1; then
    if systemctl show -p After --value httpd | grep -q network-online.target \
       && [ "$(systemctl show -p TimeoutStartUSec --value httpd)" = 3min ]; then echo "✓ httpd waits for network-online, 3 min start timeout"
    else echo "✗ httpd drop-in missing or not loaded"; ok=0; fi
  else echo "- httpd.service not present"; fi
  if systemctl cat amavisd >/dev/null 2>&1; then
    if systemctl show -p ExecStartPost --value amavisd | grep -q 127.0.0.1/10024; then echo "✓ amavisd start is verified against 127.0.0.1:10024"
    else echo "✗ amavisd drop-in missing or not loaded"; ok=0; fi
  else echo "- amavisd.service not present"; fi
  local w=""
  for u in NetworkManager-wait-online systemd-networkd-wait-online; do
    [ "$(systemctl is-enabled $u 2>/dev/null)" = enabled ] && { w=$u; break; }
  done
  if [ -n "$w" ]; then echo "✓ $w enabled (network-online is meaningful)"
  else echo "⚠ no *-wait-online service enabled — network-online.target is reached immediately, the wait does nothing"; fi
  [ "$(systemctl is-failed amavisd 2>/dev/null)" = failed ] && echo "✗ amavisd is FAILED — fix the cause, then: systemctl reset-failed amavisd && systemctl start amavisd" && ok=0
  [ "$ok" = 1 ]
}

if [ "${1:-}" = --check ]; then check; exit $?; fi
[ -z "${1:-}" ] || { echo "usage: $0 [--check]" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "✗ run as root" >&2; exit 1; }

# Keep a copy so `bh-boot-order.sh --check` works later on this server.
if [ -f "$0" ] && [ "$(readlink -f "$0")" != /usr/local/sbin/bh-boot-order.sh ]; then
  install -m 0755 "$0" /usr/local/sbin/bh-boot-order.sh || echo "⚠ could not copy to /usr/local/sbin" >&2
fi

if systemctl cat httpd >/dev/null 2>&1; then
  install -d -m 755 "$(dirname "$HTTPD_DROPIN")"
  printf '%s\n' \
    '# bh-server-ops bh-boot-order.sh: start Apache only once the network is really up (ModSecurity' \
    '# fetches cpGuard MEWAF rules over HTTPS at start), and allow it 3 minutes.' \
    '[Unit]' 'Wants=network-online.target' 'After=network-online.target' '' \
    '[Service]' 'TimeoutStartSec=180' > "$HTTPD_DROPIN"
  chmod 644 "$HTTPD_DROPIN"
fi

if systemctl cat amavisd >/dev/null 2>&1; then
  install -d -m 755 "$(dirname "$AMAVIS_DROPIN")"
  printf '%s\n' \
    '# bh-server-ops bh-boot-order.sh: amavis must really LISTEN on 127.0.0.1:10024 (Postfix content_filter)' \
    '# before it counts as started; otherwise the start fails and Restart=on-failure retries it.' \
    '# No StartLimit override on purpose: with RestartSec=15 the default limit (5 starts / 10 s) never' \
    '# trips, so it keeps retrying instead of giving up for good after a few failed attempts.' \
    '[Unit]' 'Wants=network-online.target' 'After=network-online.target' '' \
    '[Service]' 'TimeoutStartSec=180' 'RestartSec=15' \
    "ExecStartPost=/bin/bash -c 'for i in \$(seq 1 120); do (exec 3<>/dev/tcp/127.0.0.1/10024) 2>/dev/null && exit 0; sleep 1; done; echo \"amavisd not listening on 127.0.0.1:10024 after 120 s\" >&2; exit 1'" \
    > "$AMAVIS_DROPIN"
  chmod 644 "$AMAVIS_DROPIN"
fi

systemctl daemon-reload
echo "installed (takes effect at the next start of each service; nothing was restarted):"
check
