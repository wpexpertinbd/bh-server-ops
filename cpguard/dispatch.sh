#!/usr/bin/env bash
# ================================================================
#  BH cPGuard Fleet Dispatcher (v1.0)
#
#  Pushes cpguard-install.sh to N servers in parallel from your laptop,
#  collects per-server logs + a final markdown summary you can paste
#  into the Fiverr delivery message.
#
#  Reads servers.csv:
#    hostname,ip,ssh_port,ssh_user,ssh_auth,license_key
#
#    ssh_auth = path to private key file  OR  literal "askpass"
#    (askpass = sshpass will prompt once per host; use only if no keys)
#
#  Usage:
#    bash dispatch.sh                       # install on all servers in CSV
#    bash dispatch.sh --only host1,host2    # subset (retry failures)
#    bash dispatch.sh --dry-run             # preflight + verify only, no install
#    bash dispatch.sh --parallel 4          # override concurrency (default 4)
#
#  Output:
#    logs/<hostname>.log         per-server full transcript
#    logs/<hostname>.summary     parsed key=value pairs from the installer
#    logs/SUMMARY.md             aggregate markdown table (delivery doc)
# ================================================================

set -o pipefail

CSV=${CSV:-servers.csv}
PARALLEL=4
ONLY=""
DRY_RUN=0
SCRIPT_URL="https://raw.githubusercontent.com/wpexpertinbd/bh-server-ops/main/cpguard/cpguard-install.sh"
SCRIPT_LOCAL="$(dirname "$0")/cpguard-install.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --only)     ONLY="$2"; shift 2 ;;
    --parallel) PARALLEL="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --csv)      CSV="$2"; shift 2 ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

[ -f "$CSV" ] || { echo "ERROR: $CSV not found. Copy servers.csv.example to $CSV and fill in."; exit 1; }
command -v ssh   >/dev/null || { echo "ssh required";   exit 1; }
command -v xargs >/dev/null || { echo "xargs required"; exit 1; }

mkdir -p logs
: > logs/_dispatch.log

ts() { date '+%F %T'; }
say() { printf '[%s] %s\n' "$(ts)" "$*" | tee -a logs/_dispatch.log; }

# ---------- per-server runner ----------
run_one() {
  local row="$1"
  IFS=',' read -r host ip port user auth key <<<"$row"
  host=$(echo "$host" | tr -d '[:space:]')
  ip=$(echo "$ip"     | tr -d '[:space:]')
  port=${port:-22}
  user=${user:-root}

  local log="logs/${host}.log"
  local sum="logs/${host}.summary"
  : > "$log"; : > "$sum"

  echo "=== $(ts) START $host ($ip) ===" | tee -a "$log"

  # Build ssh command
  local ssh_opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=30 -p $port"
  local ssh_cmd
  if [ "$auth" = "askpass" ]; then
    command -v sshpass >/dev/null || { echo "sshpass required for askpass mode" | tee -a "$log"; return 1; }
    ssh_cmd="sshpass -p \"$SSHPASS_$host\" ssh $ssh_opts $user@$ip"
  else
    ssh_cmd="ssh $ssh_opts -i $auth $user@$ip"
  fi

  # Probe connectivity
  if ! eval "$ssh_cmd 'echo BH_PROBE_OK'" 2>&1 | tee -a "$log" | grep -q BH_PROBE_OK; then
    echo "FATAL: ssh probe failed for $host" | tee -a "$log"
    echo "result=ssh_failed" > "$sum"
    return 1
  fi
  echo "ssh OK" | tee -a "$log"

  if [ "$DRY_RUN" = "1" ]; then
    # Preflight-only: check OS, CWP, Apache, cPGuard already?
    eval "$ssh_cmd 'bash -s'" <<'PROBE' 2>&1 | tee -a "$log"
. /etc/os-release
echo "OS: $PRETTY_NAME"
[ -d /usr/local/cwpsrv ] && echo "CWP: yes" || echo "CWP: NO"
command -v httpd >/dev/null && echo "httpd: yes" || echo "httpd: NO"
[ -d /opt/cpguard ] && echo "cPGuard already: yes ($(cpgcli --version 2>/dev/null | head -1))" || echo "cPGuard already: no"
[ -x /usr/sbin/csf ] && echo "CSF: yes" || echo "CSF: no"
awk '/MemTotal/{printf "RAM: %.1f GB\n",$2/1024/1024}' /proc/meminfo
df -Pm /usr/local | awk 'NR==2{printf "disk_free: %s MB\n",$4}'
PROBE
    echo "result=dry_run_ok" > "$sum"
    echo "=== $(ts) DONE  $host (dry-run) ===" | tee -a "$log"
    return 0
  fi

  # Upload installer + run with license key
  scp -P "$port" $( [ "$auth" != "askpass" ] && echo "-i $auth" ) \
      -o StrictHostKeyChecking=accept-new \
      "$SCRIPT_LOCAL" "$user@$ip:/root/cpguard-install.sh" 2>&1 | tee -a "$log"

  local START=$(date +%s)
  eval "$ssh_cmd 'bash /root/cpguard-install.sh \"$key\"'" 2>&1 | tee -a "$log"
  local RC=${PIPESTATUS[0]}
  local DUR=$(( $(date +%s) - START ))

  # Pull the parsed summary from /tmp/bh-cpg-summary.txt on remote
  eval "$ssh_cmd 'cat /tmp/bh-cpg-summary.txt 2>/dev/null'" > "$sum" 2>/dev/null || true
  echo "duration_sec=$DUR"  >> "$sum"
  echo "exit_code=$RC"      >> "$sum"

  echo "=== $(ts) DONE  $host (rc=$RC, ${DUR}s) ===" | tee -a "$log"
  return $RC
}
export -f run_one ts
export DRY_RUN SCRIPT_LOCAL

# ---------- read CSV, filter, dispatch ----------
ROWS=$(grep -vE '^[[:space:]]*(#|$)' "$CSV" | tail -n +2 || true)
# Skip header line if first non-comment row contains "hostname"
if head -1 "$CSV" | grep -qi '^hostname'; then
  ROWS=$(tail -n +2 "$CSV" | grep -vE '^[[:space:]]*(#|$)')
else
  ROWS=$(grep -vE '^[[:space:]]*(#|$)' "$CSV")
fi

if [ -n "$ONLY" ]; then
  FILTER=$(echo "$ONLY" | tr ',' '|')
  ROWS=$(echo "$ROWS" | grep -E "^($FILTER),")
fi

TOTAL=$(echo "$ROWS" | grep -c .)
[ "$TOTAL" -gt 0 ] || { echo "No matching servers"; exit 1; }

say "Dispatching to $TOTAL server(s), parallelism=$PARALLEL, dry_run=$DRY_RUN"

# Use xargs for portable parallelism (no GNU parallel dep)
echo "$ROWS" | xargs -I{} -P "$PARALLEL" -n 1 bash -c 'run_one "$@"' _ {} || true

# ---------- aggregate summary ----------
SUMMARY=logs/SUMMARY.md
{
  echo "# cPGuard Fleet Install — $(date '+%F %T')"
  echo ""
  echo "| # | Host | Result | cPGuard | License | WAF | CSF migrated | HTTP | Duration | ModSec errors |"
  echo "|---|------|--------|---------|---------|-----|--------------|------|----------|---------------|"
  N=0
  echo "$ROWS" | while IFS=',' read -r host ip port user auth key; do
    N=$((N+1))
    host=$(echo "$host" | tr -d '[:space:]')
    sum="logs/${host}.summary"
    get() { grep "^$1=" "$sum" 2>/dev/null | tail -1 | cut -d= -f2- ; }
    printf '| %s | %s | %s | %s | %s | %s | %s | %s | %ss | %s |\n' \
      "$N" "$host" \
      "$(get result || echo unknown)" \
      "$(get cpguard_version || echo -)" \
      "$(get license_status || echo -)" \
      "$(get waf_status || echo -)" \
      "$(get csf_migrated || echo -)" \
      "$(get http_smoke || echo -)" \
      "$(get duration_sec || echo -)" \
      "$(get modsec_errors || echo -)"
  done
  echo ""
  echo "Logs: \`logs/<hostname>.log\` per server."
} > "$SUMMARY"

say "Summary written: $SUMMARY"
echo ""
cat "$SUMMARY"
