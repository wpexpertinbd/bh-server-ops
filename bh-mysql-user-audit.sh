#!/bin/bash
# bh-mysql-user-audit.sh — ALERT-ONLY watcher for dangerous MariaDB accounts/grants on CWP.
#
#   bash bh-mysql-user-audit.sh            # check now, print findings, alert on NEW ones
#   bash bh-mysql-user-audit.sh --install  # install to /usr/local/sbin + /etc/cron.d (every 5 min)
#   bash bh-mysql-user-audit.sh --quiet    # what the cron runs
#
# Why: CWP's user panel sometimes loses the account username (same bug as the `_main`/`_test`
# databases). On s1 (2026-10-08) it created the account "main user" with an EMPTY name:
#   ''@'localhost'  +  GRANT ALL PRIVILEGES ON `_%`.*
# A blank User in mysql.db applies to EVERY user, and `_%` matches every database — so every
# database user on the server had full rights on every database (seen live in phpMyAdmin).
# The old watcher (/root/mysql-user-audit.sh) was lost in the 2026-09-21 /root cleanup.
#
# This script NEVER changes the database. It reports; a human removes, e.g.:
#   mariadb -e "DROP USER ''@'localhost';"
#
# Exit: 0 = ran (findings or not), 2 = MariaDB unreachable, 3 = a check query failed (watcher
# broken — alerted, state NOT updated, so nothing is mistaken for "clean").
set -uo pipefail
umask 077

MYSQL="${BH_MYSQL:-mariadb}"                                   # overridable for tests only
LOG="${BH_AUDIT_LOG:-/var/log/bh-mysql-user-audit.log}"
STATE="${BH_AUDIT_STATE:-/var/lib/bh-server-ops/mysql-user-audit.state}"
CRIT_STAMP="$STATE.critical-alerted"
REALERT_CRITICAL_SECS=21600                                    # re-alert CRITICAL every 6 h
QUIET=0
HOST_S=$(hostname -s 2>/dev/null || hostname)

install_self(){
  [ -f "$0" ] || { echo "✗ run --install from a downloaded FILE (not curl | bash)" >&2; exit 1; }
  if ! install -m 0700 "$0" /usr/local/sbin/bh-mysql-user-audit.sh; then echo "✗ install failed" >&2; exit 1; fi
  if ! printf '%s\n' '# BH MariaDB account/grant watcher — alert-only (log + CWP notification). Delete to disable.' \
       '*/5 * * * * root /bin/bash /usr/local/sbin/bh-mysql-user-audit.sh --quiet' > /etc/cron.d/bh-mysql-user-audit; then
    echo "✗ could not write /etc/cron.d/bh-mysql-user-audit" >&2; exit 1; fi
  chmod 644 /etc/cron.d/bh-mysql-user-audit
  echo "✓ installed /usr/local/sbin/bh-mysql-user-audit.sh + /etc/cron.d/bh-mysql-user-audit (every 5 min)"
  exec /bin/bash /usr/local/sbin/bh-mysql-user-audit.sh
}
case "${1:-}" in
  --install) install_self ;;
  --quiet) QUIET=1 ;;
  "") ;;
  *) echo "usage: $0 [--install|--quiet]" >&2; exit 1 ;;
esac

exec 9>/run/bh-mysql-user-audit.lock
flock -n 9 || exit 0                                            # a previous run is still going

chmod 600 "$LOG" "$STATE" "$STATE.critical-alerted" 2>/dev/null || true   # files from older versions were 644
log(){ echo "$(date '+%F %T') $HOST_S $*" >> "$LOG"; }
# Only plain characters reach the CWP panel / syslog (customer-chosen names could carry markup).
clean(){ tr -cd "A-Za-z0-9_.%@:;'()=/+ \n[]-" ; }
notify(){ # $1 level, $2 subject, $3 message — returns 0 only if the CWP notification was posted
  local cli=/usr/local/cwpsrv/htdocs/resources/admin/include/libs/notifications/cli.php php=/usr/local/cwp/php71/bin/php
  logger -t bh-mysql-user-audit -p auth.crit -- "$(printf '%s' "$2: $3" | clean | head -c 900)" 2>/dev/null || true
  [ -x "$php" ] && [ -f "$cli" ] || return 1
  timeout 30 "$php" "$cli" --level="$1" --subject="$(printf '%s' "$2" | clean)" \
    --message="$(printf '%s' "$3" | clean | head -c 900)" >/dev/null 2>&1
}

timeout 30 "$MYSQL" -Nse "SELECT 1" 2>/dev/null | grep -qx 1 || {
  log "✗ cannot query MariaDB as root"; [ "$QUIET" = 1 ] || echo "✗ cannot query MariaDB as root" >&2; exit 2; }

# System accounts allowed to hold privileges — exact user@host pairs, never by name alone
# (a backdoor 'root'@'%' must NOT be excused). mariadb.sys is allowed only while LOCKED.
ALLOW="'root@localhost','root@127.0.0.1','root@::1','root@$(hostname | tr -cd 'A-Za-z0-9.-')','root@$HOST_S'"
P='JSON_VALUE(Priv,"$.access")'
# JSON booleans come back from JSON_VALUE as '1'/'0' (checked on MariaDB 12.3), not 'true'.
ISROLE='IFNULL(JSON_VALUE(Priv,"$.is_role"),"0") IN ("1","true")'
LOCKED='IFNULL(JSON_VALUE(Priv,"$.account_locked"),"0") IN ("1","true")'
# Stock MariaDB 10.4+ system account: 'mysql'@'localhost', password literally 'invalid' + unix_socket
# (only the OS user mysql can log in). Allowed ONLY while that holds.
STOCK_MYSQL='(User="mysql" AND Host="localhost" AND IFNULL(JSON_VALUE(Priv,"$.authentication_string"),"")="invalid")'

fail=0; failed=""; findings=""
run(){ # run one check in THIS shell; any error marks the whole run as broken
  local r
  if ! r=$(timeout 60 "$MYSQL" -Nse "$1" 2>&1); then fail=1; failed="$failed [$(printf '%s' "$r" | head -1 | cut -c1-120)]"; return; fi
  [ -n "$r" ] && findings="$findings$r"$'\n'
}

# CRITICAL — anything that applies to every user, or extra root-like accounts
run "SELECT CONCAT('CRITICAL anonymous account ''''@',Host) FROM mysql.global_priv WHERE User='' AND NOT ($ISROLE)"
for t in db tables_priv columns_priv procs_priv; do
  run "SELECT CONCAT('CRITICAL $t grant for ',IF(User='','<blank user = EVERY user>','PUBLIC = EVERY user'),' on [',Db,'] host ',Host) FROM mysql.$t WHERE User IN ('','PUBLIC')"
done
run "SELECT CONCAT('CRITICAL role granted to ',IF(User='','<blank user>','PUBLIC'),': ',Role) FROM mysql.roles_mapping WHERE User IN ('','PUBLIC')"
run "SELECT CONCAT('CRITICAL global privileges (access=',$P,') for ',User,'@',Host) FROM mysql.global_priv WHERE $P<>0 AND CONCAT(User,'@',Host) NOT IN ($ALLOW) AND NOT $STOCK_MYSQL"
# Stock install rows: root/mysql may proxy ''@'' (one per install-time hostname).
run "SELECT CONCAT('CRITICAL proxy grant ',User,'@',Host,' -> ',Proxied_user,'@',Proxied_host) FROM mysql.proxies_priv WHERE NOT (User IN ('root','mysql') AND Proxied_user='' AND Proxied_host='')"
# HIGH — grants reaching other accounts' databases, password-less logins
run "SELECT CONCAT('HIGH db grant [',Db,'] for ',User,'@',Host,IF(LEFT(Db,1) IN ('_','%'),' (wildcard-first: matches other accounts)',' (outside own account prefix)')) FROM mysql.db WHERE User NOT IN ('','PUBLIC','root','mariadb.sys') AND (LEFT(Db,1) IN ('_','%') OR LEFT(REPLACE(Db,'\\\\',''),LENGTH(SUBSTRING_INDEX(User,'_',1)))<>SUBSTRING_INDEX(User,'_',1))"
run "SELECT CONCAT('HIGH account without password ',User,'@',Host) FROM mysql.global_priv WHERE NOT ($ISROLE) AND User NOT IN ('','PUBLIC') AND IFNULL(JSON_VALUE(Priv,'\$.authentication_string'),'')='' AND IFNULL(JSON_VALUE(Priv,'\$.plugin'),'mysql_native_password') IN ('mysql_native_password','mysql_old_password') AND NOT (User='mariadb.sys' AND Host='localhost' AND $LOCKED)"
# MEDIUM — reachable from any host
run "SELECT CONCAT('MEDIUM any-host account ',User,'@',IF(Host='','<blank host>',Host)) FROM mysql.global_priv WHERE NOT ($ISROLE) AND User NOT IN ('','PUBLIC') AND (Host LIKE '%\\%%' OR Host='' OR Host LIKE '0.0.0.0/%')"

if [ "$fail" = 1 ]; then
  log "✗ WATCHER BROKEN: a check query failed:$failed (state NOT updated)"
  notify danger "MariaDB watcher broken on $HOST_S" "A check query failed:$failed — findings unknown until fixed." || true
  [ "$QUIET" = 1 ] || echo "✗ a check query failed:$failed" >&2
  exit 3
fi

findings=$(printf '%s' "$findings" | grep . | sort -u || true)
[ "$QUIET" = 1 ] || { if [ -n "$findings" ]; then echo "$findings"; else echo "✓ clean: no anonymous/PUBLIC/blank-user grants, extra privileged or proxy accounts, cross-account grants, password-less or any-host accounts"; fi; }

mkdir -p "$(dirname "$STATE")"
old=$(cat "$STATE" 2>/dev/null || true)
new=$(comm -13 <(printf '%s\n' "$old" | grep . | sort -u) <(printf '%s\n' "$findings" | grep . | sort -u) || true)
crit=$(printf '%s\n' "$findings" | grep '^CRITICAL' || true)
last=$(cat "$CRIT_STAMP" 2>/dev/null || echo 0); now=$(date +%s)
realert=""; [ -n "$crit" ] && [ $((now - last)) -ge "$REALERT_CRITICAL_SECS" ] && realert="$crit"
alert=$(printf '%s\n%s\n' "$new" "$realert" | grep . | sort -u || true)

if [ -n "$alert" ]; then
  while IFS= read -r line; do log "ALERT $line"; done <<< "$alert"
  if notify danger "MariaDB: dangerous account/grant on $HOST_S" "$(printf '%s\n' "$alert" | head -6 | paste -sd ';' -) — check: bash /usr/local/sbin/bh-mysql-user-audit.sh"; then
    printf '%s\n' "$findings" > "$STATE"
    [ -n "$crit" ] && echo "$now" > "$CRIT_STAMP"
  else
    log "⚠ CWP notification not delivered (syslog auth.crit sent) — will retry next run"
  fi
else
  printf '%s\n' "$findings" > "$STATE"                          # also forgets resolved findings
  [ -z "$crit" ] && rm -f "$CRIT_STAMP"
fi
exit 0
