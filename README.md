# bh-server-ops

Server ops scripts — performance bootstrap, FPM/MPM tuning, monitoring, and recovery for CWP/Linux web stacks.

## What's in `perf-bootstrap.sh`

A single auto-detecting script that:

1. Tunes the kernel for high-concurrency web workloads
2. Bumps OPcache to 256 MB across every installed PHP version
3. Tunes per-user PHP-FPM pools (with `request_terminate_timeout = 30s`)
4. Patches CWP templates so future tenants inherit the tuning
5. Bumps Apache MPM workers (RAM-scaled, frozen with `chattr +i`)
6. Caps Redis memory + sets LRU eviction policy
7. Reloads services gracefully (no downtime)
8. Installs three helper commands:
   - `tenant-cap` — instantly cap a noisy tenant's PHP workers
   - `saturation-monitor` — cron logs slow sites to `/var/log/saturation.log`
   - `auto-recovery` — cron auto-reloads services if a site is catastrophically slow (off by default)

Works on:
- CWP / CloudLinux (alt-php paths)
- cPanel / EA4
- RHEL / AlmaLinux / Rocky (native httpd + php-fpm)
- Debian / Ubuntu (apache2 + php-fpm)

Idempotent — safe to re-run.

## Quick install

```bash
# SSH to target server as root, then:
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/bh-server-ops/main/perf-bootstrap.sh -o /root/perf-bootstrap.sh

# Edit the EDIT block at the top
nano /root/perf-bootstrap.sh
#    HEAVY_USERS="laravel-user1 laravel-user2"
#    TARGET_RAM_GB=64
#    MONITOR_SITES="example.com api.example.com"   # optional, auto-discovers if empty

# Run
chmod +x /root/perf-bootstrap.sh
bash /root/perf-bootstrap.sh
```

The script prints what it auto-detected (panel, Apache MPM, PHP versions, services) before applying changes — sanity check before deploying.

### ⚠️ If you uploaded the script from Windows (SCP / FileZilla / WinSCP)

Windows uses CRLF line endings — bash will fail with `$'\r': command not found`. Fix:

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

Or this one-liner if `dos2unix` isn't available:
```bash
sed -i 's/\r$//' /root/perf-bootstrap.sh
```

**Tip:** Always use `curl` instead of SCP — fetched files always have correct LF line endings.

## Helper commands

After bootstrap, three commands are available system-wide.

### `tenant-cap` — emergency throttle for noisy tenants

```bash
# Cap a tenant under attack to 4 workers across all PHP versions
tenant-cap medicalp 4

# Show current cap (no second argument)
tenant-cap medicalp

# Restore default
tenant-cap medicalp 10
```

Reloads PHP-FPM automatically when applying changes.

### `saturation-monitor` — TTFB watchdog (cron, 5 min)

Runs every 5 minutes via cron. Hits each monitored site and appends to `/var/log/saturation.log` if TTFB exceeds threshold (default 10s):

```
[2026-04-25 14:32] SLOW: example.com TTFB=12.4s  CLOSE_WAIT=287  top_pools=user1:18 user2:6
```

Configure via:
- `MONITOR_SITES` — explicit list (auto-discovers from CWP if empty)
- `TTFB_WARN_THRESHOLD` — seconds (default 10)

Also runnable manually:
```bash
saturation-monitor
tail -20 /var/log/saturation.log
```

### `auto-recovery` — self-healing reload (cron, 3 min, off by default)

Optional cron that runs every 3 minutes. If TTFB exceeds recovery threshold (default 20s):
1. Graceful reload Apache
2. Reload all running PHP-FPM services
3. Flush Varnish cache
4. Throttle: skips if last recovery was less than 10 minutes ago
5. Logs to `/var/log/auto-recovery.log`

To enable, set `ENABLE_AUTO_RECOVERY_CRON=1` in the bootstrap script before running. **Recommendation:** observe `saturation-monitor` logs for a week first to see actual patterns, then enable auto-recovery only if needed.

## RAM-based MPM scaling

The script auto-sizes Apache MaxRequestWorkers based on `TARGET_RAM_GB`:

| `TARGET_RAM_GB` | MaxRequestWorkers | ServerLimit | Peak Apache RAM |
|---|---|---|---|
| ≥ 64 | 1600 | 32 | ~8 GB |
| ≥ 32 | 800 | 16 | ~4 GB |
| ≥ 16 | 400 | 8 | ~2 GB |
| < 16 | 200 | 4 | ~1 GB |

Adjust `THREADS=50` (top of MPM section) if you need finer control.

## Verification

```bash
# Apache MPM live config
/usr/local/apache/bin/httpd -V | grep MPM
grep -A 9 "mpm_event_module" /usr/local/apache/conf/extra/httpd-mpm.conf

# FPM pool of a specific user
grep -E "^pm|^request_terminate" /opt/alt/php-fpm83/usr/etc/php-fpm.d/users/USER.conf

# Helpers installed
ls -la /usr/local/sbin/tenant-cap /usr/local/sbin/saturation-monitor /usr/local/sbin/auto-recovery

# Cron jobs
crontab -l | grep -E "saturation-monitor|auto-recovery"

# Live saturation check
echo "Load: $(uptime | awk -F'load average:' '{print $2}')"
echo "CLOSE_WAIT: $(ss -tan state close-wait | wc -l)"
echo "Apache threads: $(ps -eLF | grep httpd | wc -l)"
```

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

# Remove helpers + cron
rm -f /usr/local/sbin/{tenant-cap,saturation-monitor,auto-recovery}
crontab -l | grep -v 'saturation-monitor\|auto-recovery' | crontab -
```

## Why this exists

Multi-tenant CWP / shared hosting boxes ship with very conservative defaults (4 PHP workers per tenant, 400 Apache MPM threads). Under modern attack patterns — WooCommerce filter URL bombing, scraper farms, AI bot crawlers — these defaults saturate quickly. One noisy tenant pins all Apache MPM threads while their PHP-FPM workers wait on slow MySQL queries, then every other tenant on the box queues 60-120 seconds for a free Apache thread.

The fix is layered:
1. **Cap each tenant's PHP workers** so noisy neighbors can't monopolize FPM slots
2. **`request_terminate_timeout = 30s`** so individual stuck requests can't hold workers indefinitely
3. **Bump Apache MPM** so 4× more concurrent connections fit before the queue forms
4. **Monitor + auto-recover** so you have forensic logs and self-healing as backstops

This script applies all four in one pass, idempotently, on any standard Linux web stack.

## License

MIT — use freely.
