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
#  3. named (2026-10-09, s3): after the reboot it listened on the public IP for UDP but TCP only on
#     127.0.0.1, so PowerDNS could not pull zones (AXFR = TCP) — "Connection refused", a new domain
#     stayed SERVFAIL. `rndc scan` did not fix it, a restart did.
#     → wait for network-online.target and FAIL the start unless every public IPv4 that has UDP :53
#       also has TCP :53 (only when listen-on is "any"); Restart=on-failure retries it.
# Undo: delete the three files below and run `systemctl daemon-reload`.
set -euo pipefail

HTTPD_DROPIN=/etc/systemd/system/httpd.service.d/bh-network-online.conf
AMAVIS_DROPIN=/etc/systemd/system/amavisd.service.d/bh-listen-check.conf
NAMED_DROPIN=/etc/systemd/system/named.service.d/bh-listen-check.conf
SELF=/usr/local/sbin/bh-boot-order.sh

# Called by named's ExecStartPost. Succeeds once every global IPv4 with UDP :53 also has TCP :53.
# Skipped (success) when listen-on is not "any" — then the admin chose the addresses on purpose.
# (Outputs are captured into variables first: under pipefail, `cmd | grep -q` can fail on SIGPIPE.)
public_ips(){ ip -4 -o addr show scope global | awk '{split($4,a,"/"); print a[1]}'; }
listening(){ ss -ln"$1" "sport = :53" | awk 'NR>1{print $4}'; }   # $1 = t or u

named_post(){
  local conf
  conf=$(/usr/sbin/named-checkconf -p 2>/dev/null || true)
  if ! awk '/^[[:space:]]*listen-on port 53 \{/{getline; if ($0 ~ /^[[:space:]]*"?any"?;/) f=1} END{exit !f}' <<<"$conf"; then
    exit 0
  fi
  # Only IPs named actually bound for UDP count: an address on a down interface or one another daemon
  # holds would otherwise fail every start forever. But at least one public IP must be bound, so a
  # pass before named has bound anything does not succeed by accident.
  local i ip ips tcp udp bound missing
  ips=$(public_ips)
  [ -n "$ips" ] || exit 0
  for i in $(seq 1 60); do
    bound=0; missing=""
    tcp=$(listening t); udp=$(listening u)
    for ip in $ips; do
      grep -qxF "$ip:53" <<<"$udp" || continue
      bound=1
      grep -qxF "$ip:53" <<<"$tcp" || missing="$missing $ip"
    done
    [ "$bound" = 1 ] && [ -z "$missing" ] && exit 0
    sleep 1
  done
  if [ "$bound" = 1 ]; then
    echo "named has UDP but not TCP :53 on:$missing after 60 s (zone transfers to PowerDNS would fail)" >&2
  else
    echo "named not listening on any public IPv4 :53 after 60 s" >&2
  fi
  exit 1
}

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
  if systemctl cat named >/dev/null 2>&1; then
    if systemctl show -p ExecStartPost --value named | grep -q -- --named-post \
       && systemctl show -p After --value named | grep -q network-online.target; then echo "✓ named waits for network-online, start verified against TCP :53 on public IPs"
    else echo "✗ named drop-in missing or not loaded"; ok=0; fi
    local ip tcp udp
    tcp=$(listening t); udp=$(listening u)
    for ip in $(public_ips); do
      grep -qxF "$ip:53" <<<"$udp" || continue
      grep -qxF "$ip:53" <<<"$tcp" \
        || { echo "✗ named has UDP but NOT TCP on $ip:53 right now — PowerDNS cannot transfer zones; systemctl restart named"; ok=0; }
    done
  else echo "- named.service not present"; fi
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
if [ "${1:-}" = --named-post ]; then named_post; fi
[ -z "${1:-}" ] || { echo "usage: $0 [--check]   (--named-post is for named.service only)" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "✗ run as root" >&2; exit 1; }

# Keep a copy so `bh-boot-order.sh --check` works later — and named's drop-in calls it.
if [ -f "$0" ] && [ "$(readlink -f "$0")" != "$SELF" ]; then
  install -m 0755 "$0" "$SELF.new" && mv -f "$SELF.new" "$SELF" || echo "⚠ could not copy to /usr/local/sbin" >&2
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

if systemctl cat named >/dev/null 2>&1; then
  # The drop-in runs $SELF, so only install it when that copy exists and has the --named-post mode;
  # otherwise every named start would fail.
  if [ -x "$SELF" ] && grep -q -- '--named-post' "$SELF"; then
    install -d -m 755 "$(dirname "$NAMED_DROPIN")"
    printf '%s\n' \
      '# bh-server-ops bh-boot-order.sh: named must LISTEN on TCP :53 on the public IP (PowerDNS pulls zones' \
      '# by AXFR over TCP) before it counts as started; otherwise the start fails and Restart retries it.' \
      '[Unit]' 'Wants=network-online.target' 'After=network-online.target' '' \
      '[Service]' 'TimeoutStartSec=180' 'Restart=on-failure' 'RestartSec=10' \
      "ExecStartPost=$SELF --named-post" \
      > "$NAMED_DROPIN"
    chmod 644 "$NAMED_DROPIN"
  else
    echo "⚠ $SELF missing or too old (no --named-post) — named drop-in NOT installed" >&2
  fi
fi

systemctl daemon-reload
echo "installed (takes effect at the next start of each service; nothing was restarted):"
check
