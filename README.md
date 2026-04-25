# bh-server-ops

BiswasHost server ops scripts — performance bootstrap, FPM/MPM tuning, monitoring for CWP/Linux web stacks.

## Scripts

### `perf-bootstrap.sh` — Universal web server tuning

Auto-detecting one-shot performance bootstrap. Works on:
- CWP/CloudLinux (alt-php paths)
- cPanel/EA4
- RHEL / AlmaLinux / Rocky (native httpd + php-fpm)
- Debian / Ubuntu (apache2 + php-fpm)

**What it does:**
1. Kernel tunables (TCP TIME_WAIT, somaxconn, swappiness)
2. OPcache 256 MB across all installed PHP versions
3. Per-user FPM pool tuning (light = 10 workers ondemand, heavy = 20 dynamic) + `request_terminate_timeout = 30s`
4. CWP template patch (only on CWP boxes — frozen with `chattr +i`)
5. Apache MPM bump (event/worker/prefork) — RAM-scaled MaxRequestWorkers
6. Redis maxmemory cap + LRU policy
7. Graceful service reloads

Idempotent — safe to re-run.

## Usage

```bash
# 1. SSH to target server as root
# 2. Get the script (curl is best — line endings are guaranteed correct)
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/bh-server-ops/main/perf-bootstrap.sh -o /root/perf-bootstrap.sh

# 3. Edit the EDIT block at the top
nano /root/perf-bootstrap.sh
#    HEAVY_USERS="laravel-user1 laravel-user2"
#    TARGET_RAM_GB=64

# 4. Run
chmod +x /root/perf-bootstrap.sh
bash /root/perf-bootstrap.sh
```

The script prints what it auto-detected (panel, Apache MPM, PHP versions, services) before applying changes — sanity check before deploying.

### ⚠️ If you uploaded the script from Windows (SCP / FileZilla / WinSCP)

Windows uses CRLF line endings — bash will fail with `$'\r': command not found` errors. Fix:

```bash
# RHEL / AlmaLinux / Rocky / CentOS / CWP
yum install -y dos2unix

# Debian / Ubuntu
apt-get install -y dos2unix

# Convert + run
dos2unix /root/perf-bootstrap.sh
chmod +x /root/perf-bootstrap.sh
bash /root/perf-bootstrap.sh
```

If `dos2unix` isn't available, this one-liner does the same thing:
```bash
sed -i 's/\r$//' /root/perf-bootstrap.sh
```

**Tip:** Always use `curl` (Method 1 above) instead of SCP — fetched files always have correct LF line endings.

## RAM-based MPM scaling

| `TARGET_RAM_GB` | MaxRequestWorkers | ServerLimit | Peak Apache RAM |
|---|---|---|---|
| ≥ 64 | 1600 | 32 | ~8 GB |
| ≥ 32 | 800 | 16 | ~4 GB |
| ≥ 16 | 400 | 8 | ~2 GB |
| < 16 | 200 | 4 | ~1 GB |

## Rollback

Every modified file gets a `.bak-pre-tune` copy. To revert:

```bash
chattr -i /usr/local/apache/conf/extra/httpd-mpm.conf 2>/dev/null
chattr -i /usr/local/cwpsrv/htdocs/resources/conf/web_servers/vhosts/php-fpm/*.tpl 2>/dev/null
for F in $(find /opt /etc /usr/local -name '*.bak-pre-tune' 2>/dev/null); do
  mv "$F" "${F%.bak-pre-tune}"
done
systemctl reload httpd
for V in 74 80 81 82 83 84 85; do
  systemctl is-active --quiet php-fpm-$V && systemctl reload php-fpm-$V
done
```

## Verification commands

```bash
# Apache MPM live config
/usr/local/apache/bin/httpd -V | grep MPM
grep -A 9 "mpm_event_module" /usr/local/apache/conf/extra/httpd-mpm.conf

# FPM pool tuning of any user
grep -E "^pm|^request_terminate" /opt/alt/php-fpm83/usr/etc/php-fpm.d/users/USER.conf

# Live saturation check
echo "Load: $(uptime | awk -F'load average:' '{print $2}')"
echo "CLOSE_WAIT: $(ss -tan state close-wait | wc -l)"
echo "Apache threads: $(ps -eLF | grep httpd | wc -l)"
```

## Track record

- **bitsboxhost s4** (CWP, 64 GB, 45 tenants) — fixed "site slow every 4 hours" pattern; TTFB 800 ms → 165 ms; survived multi-tenant scraper attacks after MPM bump
- **bitsboxhost s3** (CWP, 64 GB, ~45 tenants) — applied as fresh deploy, 315 light tenants tuned in one run
