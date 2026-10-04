#!/bin/bash
# bh-apache-upgrade.sh — upgrade CWP's Apache (/usr/local/apache) to a newer 2.4.x
# from apache.org source, WITHOUT touching any configuration.
#
#   bash bh-apache-upgrade.sh 2.4.69               # build, verify, install, restart, health-check
#   bash bh-apache-upgrade.sh 2.4.69 --build-only  # build + verify only, install nothing
#
# Why not CWP's apache-rebuild.sh (also the alphagnu "latest Apache" guide):
#   - it DELETES conf/httpd.conf and installs a stock one (our BH hardening block,
#     MPM include, DirectoryIndex, upload limits all lost) and overwrites
#     sharedip.conf + system-redirects.conf;
#   - it fetches suexec.patch over plain http and never verifies the source;
#   - it restarts with no config test and has no rollback.
# This script uses the SAME ./configure options, keeps every config file
# (Apache's `make install` preserves the live conf/, htdocs/), verifies the
# tarball's SHA-256 and that it is PGP-signed by a PINNED release-manager key,
# backs up first and rolls back automatically on ANY failure after install.
#
# suexec.patch is deliberately NOT applied: no server in the fleet runs it (the
# cwp-httpd RPM is built without it — checked 2026-10-05), and its
# is_group_member() never advances its loop (setuid-root infinite loop).
#
# ⚠ Afterwards `rpm -V cwp-httpd` flags bin/ + modules/ (expected). Use the
# sha256 manifest this writes to /root/bh-apache-manifests/ for tamper checks.
# A later `yum update cwp-httpd` would overwrite this build.
set -euo pipefail

VER="${1:-}"; MODE="${2:-}"
A=/usr/local/apache
LOG=/var/log/bh-apache-upgrade.log
TS=$(date +%Y%m%d-%H%M%S)
BACKUP=/root/bh-apache-backup-$TS.tgz
MANIFEST_DIR=/root/bh-apache-manifests
# Primary-key fingerprints allowed to sign httpd releases (signed 2.4.66, .68, .69).
# Add a new release manager here only after checking https://downloads.apache.org/httpd/KEYS.
SIGNERS="${BH_APACHE_SIGNERS:-65B2D44FE74BD5E3DE3AC3F082781DE46D5954FA}"

die(){ echo "✗ $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
[[ "$VER" =~ ^2\.4\.[0-9]{1,3}$ ]] || die "usage: $0 <2.4.x> [--build-only]"
[ -z "$MODE" ] || [ "$MODE" = --build-only ] || die "unknown option: $MODE"
[ -x "$A/bin/httpd" ] || die "$A/bin/httpd not found — not a CWP Apache"

exec > >(tee -a "$LOG") 2>&1
exec 9>/run/bh-apache-upgrade.lock
flock -n 9 || die "another bh-apache-upgrade is running"
echo "=== bh-apache-upgrade $VER ${MODE} on $(hostname -s) at $TS ==="

CUR=$("$A/bin/httpd" -v | grep -oE 'Apache/[0-9.]+' | cut -d/ -f2)
echo "current: $CUR"
if [ "$CUR" = "$VER" ] && [ -z "$MODE" ]; then echo "✓ already $VER — nothing to do"; exit 0; fi
[ "$(printf '%s\n%s\n' "$CUR" "$VER" | sort -V | tail -1)" = "$VER" ] || die "$VER is OLDER than the running $CUR — refusing to downgrade"
"$A/bin/httpd" -t >/dev/null 2>&1 || die "current config does NOT pass httpd -t — fix that first"

# Same options as the cwp-httpd RPM and CWP's rebuild script (build/config.nice).
CONFIGURE_ARGS=(--enable-so --prefix=/usr/local/apache --enable-unique-id --enable-ssl=shared
  --enable-rewrite --enable-deflate --enable-suexec --with-suexec-docroot=/home
  --with-suexec-caller=nobody --with-suexec-logfile=/usr/local/apache/logs/suexec_log
  --enable-asis --enable-filter --with-pcre --with-apr=/usr/bin/apr-1-config
  --with-apr-util=/usr/bin/apu-1-config --enable-headers --enable-expires
  --enable-proxy --enable-userdir)
[ -f "$A/build/config.nice" ] || die "$A/build/config.nice missing — cannot confirm the installed build options"
_have=$(grep -oE '"--[^"]+"' "$A/build/config.nice" | tr -d '"' | sort | tr '\n' ' ')
_want=$(printf '%s\n' "${CONFIGURE_ARGS[@]}" | sort | tr '\n' ' ')
[ "$_have" = "$_want" ] || die "installed build options differ from this script's — review first:
  installed: $_have
  script:    $_want"
_env=$(grep -E '^[A-Z_]+=' "$A/build/config.nice" || true)
[ -z "$_env" ] || die "installed build used extra environment ($_env) — review first"

# Free space: build (~300M), backup, install.
for d in /usr/local/src /root "$A"; do
  free=$(df -Pm "$d" | awk 'NR==2{print $4}')
  [ "$free" -ge 2048 ] || die "less than 2 GB free on $d (${free}M)"
done

echo "─── dependencies"
yum -y -q install gcc make gnupg2 openssl-devel apr-devel apr-util-devel pcre2-devel \
  expat-devel libuuid-devel >/dev/null || die "yum install of build deps failed"

W=$(mktemp -d /usr/local/src/bh-apache-XXXXXX)
INSTALLING=0; DONE=0
rollback(){
  set +e
  trap - EXIT ERR
  echo "!!! ROLLING BACK to $CUR from $BACKUP"
  systemctl kill --signal=SIGTERM httpd 2>/dev/null   # hard stop: TERM = immediate
  for _i in $(seq 1 30); do pgrep -x httpd >/dev/null || break; sleep 1; done
  # Restore program files only — config was proven unchanged, and restoring it
  # could revert a vhost CWP wrote in the meantime.
  if ! tar xzf "$BACKUP" -C / --exclude=usr/local/apache/conf --exclude=usr/local/apache/conf.d; then
    echo "✗✗ RESTORE FAILED — Apache files may be mixed; backup is $BACKUP"
  fi
  systemctl reset-failed httpd 2>/dev/null; systemctl start httpd
  sleep 2
  echo "after rollback: $("$A/bin/httpd" -v 2>&1 | head -1) | httpd is $(systemctl is-active httpd)"
  [ "$(systemctl is-active httpd)" = active ] || echo "✗✗ APACHE IS DOWN — start it by hand: systemctl start httpd"
  rm -rf "$W"
  exit 1
}
on_exit(){
  rc=$?
  if [ "$INSTALLING" = 1 ] && [ "$DONE" = 0 ]; then echo "✗ unexpected failure (rc=$rc) after install began"; rollback; fi
  rm -rf "$W"
}
trap on_exit EXIT
cd "$W"

echo "─── download + verify httpd-$VER"
got=0
for base in https://downloads.apache.org/httpd https://archive.apache.org/dist/httpd; do
  if curl -fsSL --max-time 300 -o "httpd-$VER.tar.gz" "$base/httpd-$VER.tar.gz" \
     && curl -fsSL --max-time 60 -o "httpd-$VER.tar.gz.sha256" "$base/httpd-$VER.tar.gz.sha256" \
     && curl -fsSL --max-time 60 -o "httpd-$VER.tar.gz.asc" "$base/httpd-$VER.tar.gz.asc"; then got=1; break; fi
done
[ "$got" = 1 ] || die "could not download httpd-$VER (+ .sha256/.asc) from apache.org"
want=$(grep -oE '^[0-9a-f]{64}' "httpd-$VER.tar.gz.sha256" | head -1 || true)
have=$(sha256sum "httpd-$VER.tar.gz" | cut -d' ' -f1)
[ -n "$want" ] && [ "$want" = "$have" ] || die "SHA-256 mismatch (want $want, have $have)"
echo "✓ sha256 $have"
curl -fsSL --max-time 60 -o KEYS https://downloads.apache.org/httpd/KEYS || die "could not fetch Apache KEYS"
export GNUPGHOME="$W/gnupg"; mkdir -m 700 "$GNUPGHOME"
gpg -q --batch --import KEYS >/dev/null 2>&1 || true
gpg --batch --status-fd 1 --verify "httpd-$VER.tar.gz.asc" "httpd-$VER.tar.gz" > gpg.status 2>/dev/null || true
signer=$(awk '$2=="VALIDSIG"{print $NF}' gpg.status | head -1)
[ -n "$signer" ] || die "PGP signature of httpd-$VER.tar.gz did NOT verify"
case " $SIGNERS " in *" $signer "*) ;; *) die "signed by $signer, which is not a pinned Apache release manager" ;; esac
echo "✓ PGP signature valid, signer $signer (pinned)"

echo "─── build"
tar -xzf "httpd-$VER.tar.gz"
cd "httpd-$VER"
./configure "${CONFIGURE_ARGS[@]}" > "$W/configure.log" 2>&1 || { tail -20 "$W/configure.log"; die "configure failed"; }
make -j"$(nproc)" > "$W/make.log" 2>&1 || { tail -30 "$W/make.log"; die "make failed"; }
NEWV=$(./httpd -v | grep -oE 'Apache/[0-9.]+' | cut -d/ -f2)
[ "$NEWV" = "$VER" ] || die "built binary reports $NEWV, expected $VER"
echo "✓ built Apache/$NEWV"
if [ "$MODE" = --build-only ]; then echo "✓ --build-only: nothing installed"; exit 0; fi

# ── everything below changes the live server ──
VHOSTS=$(grep -lE 'SuexecUserGroup|proxy:unix' "$A"/conf.d/vhosts/*.conf 2>/dev/null | grep -v '\.ssl\.conf$' | head -15 || true)
probe(){ # "domain code", using each vhost's own <VirtualHost IP:port>
  local f d hp
  for f in $VHOSTS; do
    d=$(grep -m1 -oE 'ServerName [^ ]+' "$f" | awk '{print $2}' || true)
    hp=$(grep -m1 -oE '<VirtualHost [0-9.]+:[0-9]+' "$f" | awk '{print $2}' || true)
    [ -n "$d" ] && [ -n "$hp" ] || continue
    echo "$d $(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H "Host: $d" "http://$hp/" || true)"
  done
  return 0
}
BEFORE=$(probe | sort -u -k1,1)
nok=$(echo "$BEFORE" | awk '$2 ~ /^[23]/' | grep -c . || true)
[ "$nok" -ge 3 ] || die "health check would be meaningless: only $nok vhosts answer 2xx/3xx before the upgrade"
echo "health baseline: $nok vhosts answering 2xx/3xx"
# Live config only; conf/original/ is Apache's template copy and is rewritten by every install.
conf_sum(){ (cd "$A" && find conf conf.d -path conf/original -prune -o -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum) || true; }
mod_sum(){ (cd "$A" && sha256sum modules/*.so 2>/dev/null) || true; }
CONF_BEFORE=$(conf_sum); MOD_BEFORE=$(mod_sum)

echo "─── backup → $BACKUP"
tar czf "$BACKUP" -C / --exclude=usr/local/apache/logs --exclude=usr/local/apache/domlogs \
  --exclude=usr/local/apache/htdocs usr/local/apache
tar tzf "$BACKUP" usr/local/apache/bin/httpd >/dev/null || die "backup is unreadable — aborting before any change"
echo "✓ backup $(du -h "$BACKUP" | cut -f1)"

INSTALLING=1   # from here on, ANY failure rolls back (EXIT trap)
echo "─── install"
make install > "$W/install.log" 2>&1 || { tail -20 "$W/install.log"; rollback; }
CONF_AFTER=$(conf_sum)
# Every "hash  path" line from before must still exist byte-identical; new paths are only a warning.
changed=$(comm -23 <(echo "$CONF_BEFORE" | sort) <(echo "$CONF_AFTER" | sort) | awk '{print $2}' || true)
if [ -n "$changed" ]; then
  echo "✗ make install changed or removed live configuration files:"; echo "$changed" | head; rollback
fi
added=$(comm -13 <(echo "$CONF_BEFORE" | awk '{print $2}' | sort) <(echo "$CONF_AFTER" | awk '{print $2}' | sort) || true)
[ -z "$added" ] || { echo "⚠ install added new config files (unused unless included):"; echo "$added" | sed 's/^/   /'; }
echo "✓ live configuration untouched"
modchg=$(diff <(echo "$MOD_BEFORE") <(mod_sum) | awk '/^[<>]/{print $3}' | sort -u | tr '\n' ' ' || true)
echo "  modules replaced by the build: $(echo "$modchg" | wc -w)  (third-party mod_security2/cloudflare/rpaf: $(echo "$modchg" | grep -oE 'mod_(security2|cloudflare|rpaf)\.so' | tr '\n' ' ' || true)none expected)"
"$A/bin/httpd" -t || { echo "✗ httpd -t fails with the new binary"; rollback; }

echo "─── restart (hard stop: in-flight requests are cut, outage is seconds not minutes)"
systemctl kill --signal=SIGTERM httpd || true
for _i in $(seq 1 30); do pgrep -x httpd >/dev/null || break; sleep 1; done
pgrep -x httpd >/dev/null && { echo "✗ old httpd did not exit"; rollback; }
systemctl reset-failed httpd 2>/dev/null || true
systemctl start httpd || { echo "✗ start failed"; rollback; }
for _i in $(seq 1 20); do [ "$(systemctl is-active httpd)" = active ] && break; sleep 1; done
[ "$(systemctl is-active httpd)" = active ] || { echo "✗ httpd not active"; rollback; }
RUNV=$("$A/bin/httpd" -v | grep -oE 'Apache/[0-9.]+' | cut -d/ -f2)
[ "$RUNV" = "$VER" ] || { echo "✗ installed binary reports $RUNV"; rollback; }
sleep 3
AFTER=$(probe | sort -u -k1,1)
echo "health (domain before after):"; join <(echo "$BEFORE") <(echo "$AFTER") | sed 's/^/  /'
bad=$(join -a1 -e 000 -o 0,1.2,2.2 <(echo "$BEFORE") <(echo "$AFTER") | awk '$2 ~ /^[23]/ && $3 !~ /^[23]/' || true)
[ -z "$bad" ] || { echo "✗ sites broke after upgrade:"; echo "$bad"; rollback; }

DONE=1   # upgrade verified — nothing after this may roll it back
# (2026-10-05: listing a non-existent "lib" here failed under pipefail and rolled back a healthy upgrade on s2)
mkdir -p "$MANIFEST_DIR"
if ! (cd "$A" && find bin modules -type f -print0 | sort -z | xargs -0 sha256sum) > "$MANIFEST_DIR/apache-$VER-$TS.sha256"; then
  echo "⚠ could not write the sha256 manifest — upgrade itself is fine"
fi
echo "✓ Apache $CUR → $VER on $(hostname -s); backup $BACKUP"
echo "  tamper check from now on: cd $A && sha256sum -c --quiet $MANIFEST_DIR/apache-$VER-$TS.sha256"
