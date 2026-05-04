# bh-server-ops

Server ops scripts — performance bootstrap, FPM/MPM tuning, monitoring, and recovery for CWP/Linux web stacks.

## What's in `perf-bootstrap.sh`

A single auto-detecting script that:

1. Tunes the kernel for high-concurrency web workloads
2. Auto-creates swap if none exists (small VPS often ship without)
3. Bumps OPcache (RAM-scaled) across every installed PHP version
4. Tunes per-user PHP-FPM pools (with `request_terminate_timeout = 30s`)
5. Patches CWP templates so future tenants inherit the tuning
6. Bumps Apache MPM workers (RAM-scaled, frozen with `chattr +i`)
7. Caps Redis memory + sets LRU eviction policy
8. Reloads services gracefully (no downtime)
9. **Drops in nginx anti-bot WAF** — http-level UA map + trusted-IP allowlist + per-vhost server snippet that blocks SEO/AI scrapers and constant attack paths (xmlrpc, /.env, /.git, etc.). Files live in `/etc/nginx/bh.d/` (outside `conf.d/` so CWP regen / `yum reinstall nginx` can't wipe them) and are auto-included via a one-line `include /etc/nginx/bh.d/*.conf;` added to `nginx.conf`. Snapshotted to `/var/lib/bh-server-ops/` so the `auto-recovery` cron can restore them within 3 minutes if anything ever does delete them.
10. Installs three helper commands:
    - `tenant-cap` — instantly cap a noisy tenant's PHP workers
    - `saturation-monitor` — cron logs slow sites to `/var/log/saturation.log`
    - `auto-recovery` — cron auto-reloads services if a site is catastrophically slow + self-heals missing nginx anti-bot maps

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
chmod +x /root/perf-bootstrap.sh
bash /root/perf-bootstrap.sh
```

**Or one-liner (fully unattended, uses auto-detected defaults):**

```bash
curl -sL https://raw.githubusercontent.com/wpexpertinbd/bh-server-ops/main/perf-bootstrap.sh | bash -s -- -y
```

### Pick the command that matches the server type

Replace `<ip-list>` with **all your fleet's server IPs**, space-separated, e.g. `"1.2.3.4 5.6.7.8 9.10.11.12"`.

**Master / shared hosting / reseller server** (full WAF + tuning):
```bash
TRUSTED_IPS="<ip-list>" \
  bash <(curl -sL https://raw.githubusercontent.com/wpexpertinbd/bh-server-ops/main/perf-bootstrap.sh) -y
```

**Slave / DNS portal / Blesta API / monitoring backend** (skip WAF, keep tuning):
```bash
IS_SLAVE_SERVER=1 \
TRUSTED_IPS="<ip-list>" \
  bash <(curl -sL https://raw.githubusercontent.com/wpexpertinbd/bh-server-ops/main/perf-bootstrap.sh) -y
```

**Standalone single-server** (no fleet):
```bash
bash <(curl -sL https://raw.githubusercontent.com/wpexpertinbd/bh-server-ops/main/perf-bootstrap.sh) -y
```

### What slave mode skips

`IS_SLAVE_SERVER=1` skips three things that block legitimate server-to-server API auth:
- nginx anti-bot WAF (returns 444 to programmatic clients with empty/unusual UAs)
- Apache global hardening (mod_rewrite bot blocks)
- fail2ban nginx jails (would auto-ban repeating master IPs)

It still applies: kernel/sysctl, OPcache, MPM tuning, FPM pool tuning, Redis cap, helper scripts.

### Make settings persistent across re-runs

The script reads env vars at runtime. Put your fleet's IPs (and slave flag, if applicable) in `/root/.bash_profile` so you don't have to retype them:

```bash
# On every server, run ONCE:
cat >> /root/.bash_profile <<'EOF'
export TRUSTED_IPS="<ip-list>"
# uncomment the next line ONLY on slave/API-only servers
# export IS_SLAVE_SERVER=1
EOF
source /root/.bash_profile
```

After that, future runs are just:
```bash
bash <(curl -sL https://raw.githubusercontent.com/wpexpertinbd/bh-server-ops/main/perf-bootstrap.sh) -y
```
…and the env vars are picked up automatically.

## Daily health check (when a client complains "site is slow")

Four commands, 30 seconds, tells you if it's a real server problem or not:

```bash
# 1. Apache worker saturation + avg response time
curl -s http://127.0.0.1:8181/server-status?auto | grep -E "BusyWorkers|IdleWorkers|DurationPerReq|ReqPerSec"

# 2. fail2ban — has anyone been banned recently?
fail2ban-client status nginx-badbot 2>/dev/null | grep -E "Currently|Total"
fail2ban-client status wp-login    2>/dev/null | grep -E "Currently|Total"

# 3. What URLs are Apache workers serving right now? (find the noisy site/path)
curl -s "http://127.0.0.1:8181/server-status" | grep -oE '(GET|POST) [^ <]+' | awk '{print $2}' | sort | uniq -c | sort -rn | head -10

# 4. Trend over the last hour (slow-watch cron logs)
tail -50 /root/slow-watch.log
```

Healthy looks like:
- `IdleWorkers` > 50% of total
- `DurationPerReq` < 1000 ms
- No new fail2ban bans every minute
- No single URL dominating scoreboard

If any of those are bad, the URL list (#3) usually points at the noisy site to investigate.

## Apache MPM and tier verification

```bash
# What tier did the script pick?
grep -A 9 "mpm_event_module" /usr/local/apache/conf/extra/httpd-mpm.conf

# Confirm Apache loaded it (scoreboard size = ServerLimit × ThreadsPerChild)
curl -s http://127.0.0.1:8181/server-status?auto | grep Scoreboard | sed 's/Scoreboard: //' | wc -c
# 401 chars = old default (problem) | 1601/3201/5001 = tier applied correctly

# Was the Include line uncommented?
grep "httpd-mpm" /usr/local/apache/conf/httpd.conf
# should NOT have a leading #
```

The script runs **interactive by default** — it auto-detects the environment (panel, Apache MPM, PHP versions, RAM), then prompts for:

- **Action:** Install / Rollback / Quit
- **TARGET_RAM_GB** (auto-filled from `free -g`)
- **Heavy app users** (Laravel/Symfony tenants — get 20 dynamic workers)
- **Apache MPM tuning?** (yes/no)
- **Redis cap?** (yes/no)
- **Install helpers?** (`tenant-cap`, `saturation-monitor`, `auto-recovery`)
- **Saturation-monitor cron** (every 5 min — recommended yes)
- **Auto-recovery cron** (every 3 min — default yes, self-healing safety net)
- **Sites to monitor** (auto-discover or provide explicit list)

A summary is shown before any change. Press Enter on each prompt to accept the default in `[brackets]`.

### Non-interactive run (curl pipe, automation, etc.)

When stdin isn't a TTY (e.g. `curl ... | bash`) or you pass `-y`, the script uses built-in defaults silently:

```bash
# Pass defaults via flag
bash perf-bootstrap.sh -y

# Or set them as env vars
HEAVY_USERS="user1 user2" \
TARGET_RAM_GB=32 \
ENABLE_AUTO_RECOVERY_CRON=1 \
bash perf-bootstrap.sh -y

# Pipe-from-curl (treated as non-interactive)
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/bh-server-ops/main/perf-bootstrap.sh | bash
```

### Rollback

```bash
# Interactive — choose 'R' at the action prompt
bash /root/perf-bootstrap.sh

# Non-interactive — pass --rollback
bash /root/perf-bootstrap.sh --rollback
```

Restores all `.bak-pre-tune` backups, removes drop-in OPcache/sysctl, removes helpers + cron, reloads services.

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

### `auto-recovery` — self-healing reload (cron, 3 min, **on by default**)

Cron runs every 3 minutes. Two responsibilities:

**Self-heal (always runs first, no threshold):**
If `/etc/nginx/snippets/anti-bot-server.conf` exists but either of the http-level maps in `/etc/nginx/bh.d/` is missing, the maps are restored from the snapshot at `/var/lib/bh-server-ops/` and nginx is reloaded. Bounds the worst-case "nginx down because something wiped a conf file" outage to 3 minutes. (The snippet references `$bh_bad_bot` / `$bh_trusted_ip` — if those maps disappear, nginx refuses to start. CWP regen and `yum reinstall nginx` have both been observed wiping `/etc/nginx/conf.d/`, which is why the maps live in `bh.d/` now and are also snapshotted.)

**TTFB recovery (fires on threshold breach):**
If TTFB exceeds recovery threshold (default 20s):
1. Graceful reload Apache (zero downtime)
2. If site still slow after 5 sec → escalates to `restart httpd` (1-2 sec blip, guaranteed clear of stuck workers)
3. Reload all running PHP-FPM services
4. Flush Varnish cache
5. Throttle: skips if last recovery fired less than 10 min ago (prevents loops)
6. Logs to `/var/log/auto-recovery.log`

To disable, choose `n` at the prompt OR set `ENABLE_AUTO_RECOVERY_CRON=0`. Disable temporarily for diagnostic windows where you want saturation events to persist for inspection.

## RAM-tier scaling

Every memory-hungry setting (Apache MPM, FPM children, OPcache, Redis) auto-scales together based on detected RAM. Same script works from a tiny 1 vCPU/2 GB VPS to a 256 GB dedicated beast.

Thresholds are intentionally a few GB below the nominal class — `/proc/meminfo` always reports less than installed (kernel + firmware reserve ~2 GB on big boxes, ~1 GB on small VPS). 64 GB box reports ~62 GB, 128 GB reports ~125, etc.

| Detected RAM | Apache MaxWorkers | FPM children (light/heavy) | OPcache | Redis cap |
|---|---|---|---|---|
| **≥ 240 GB** (256 GB-class) | **5000 (100×50)** | **15 / 30** | **512 MB** | **8 GB** |
| **≥ 120 GB** (128 GB-class) | **3200 (64×50)** | **12 / 25** | **384 MB** | **4 GB** |
| ≥ 60 GB (64 GB-class) | 1600 (32×50) | 10 / 20 | 256 MB | 2 GB |
| ≥ 30 GB (32 GB-class) | 800 (16×50) | 10 / 20 | 256 MB | 1 GB |
| ≥ 14 GB (16 GB-class) | 400 (8×50) | 8 / 15 | 192 MB | 512 MB |
| ≥ 7 GB (8 GB-class) | 200 (5×40) | 6 / 12 | 128 MB | 384 MB |
| ≥ 3 GB (4 GB-class) | 100 (4×25) | 4 / 8 | 96 MB | 256 MB |
| < 3 GB (1-2 GB VPS) | 50 (2×25) | 3 / 5 | 64 MB | 128 MB |

Total baseline (Apache workers + OPcache + Redis):
- 256 GB box: ~160 GB used (62% of RAM) — leaves ~96 GB for DB, FPM, OS cache
- 128 GB box: ~100 GB used (78%)
- 64 GB box: ~50 GB used (78%)
- 16 GB box: ~12 GB used (75%)
- 8 GB box: ~6 GB used (75%)
- 4 GB box: ~2.5 GB used (62%)
- 2 GB box: ~1 GB used (50%)

Tenant FPM children + MariaDB share the rest.

Force a specific tier if auto-detect is wrong (e.g. lying hypervisor):
```bash
TARGET_RAM_GB=128 bash <(curl -sL https://raw.githubusercontent.com/wpexpertinbd/bh-server-ops/main/perf-bootstrap.sh) -y
```

## Swap setup

Many small VPS providers ship without swap. Step [2/9] auto-creates `/swapfile` if no swap exists:

| RAM | Swap created |
|---|---|
| ≤ 2 GB | 2× RAM |
| 3-8 GB | 1× RAM |
| 9-32 GB | 8 GB |
| > 32 GB | 4 GB |

Skipped if any swap already exists OR if disk free < `swap + 5 GB`. Persisted via `/etc/fstab`.

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

## Files this script creates / modifies

| Path | Purpose | Survives `yum reinstall nginx`? |
|---|---|---|
| `/etc/nginx/bh.d/00-anti-bot.conf` | http-level UA map (`$bh_bad_bot`) | ✅ custom dir, untouched by package mgr |
| `/etc/nginx/bh.d/00-trusted-ips.conf` | http-level allowlist (`$bh_trusted_ip`) | ✅ custom dir, untouched by package mgr |
| `/etc/nginx/snippets/anti-bot-server.conf` | server-level enforcement, `include`d by every vhost | ✅ |
| `/etc/nginx/conf.d/01-access-log.conf` | slim access log so bot floods are visible | ⚠️ in conf.d/, may be wiped by package update |
| `/etc/nginx/nginx.conf` | gets one `include /etc/nginx/bh.d/*.conf;` line added (idempotent) | ✅ usually preserved as `.rpmsave` on reinstall |
| `/var/lib/bh-server-ops/` | snapshot copy of the bh.d maps for `auto-recovery` self-heal | ✅ |
| `/usr/local/apache/conf/extra/httpd-mpm.conf` | RAM-tier MPM config | ✅ frozen with `chattr +i` after edit |
| `/etc/sysctl.d/99-bh-tune.conf` | kernel tuning | ✅ |
| FPM pool files at `/opt/alt/php-fpm*/usr/etc/php-fpm.d/users/*.conf` | per-user FPM tuning | ✅ |
| `/usr/local/sbin/{tenant-cap,saturation-monitor,auto-recovery}` | helpers | ✅ |

The "untouched" guarantees are based on observed CWP / yum behaviour as of late 2026 — `/etc/nginx/conf.d/` is the directory most likely to get swept (CWP nginx vhost regen + `yum reinstall nginx` have both been observed clearing it). If you find files vanishing from `bh.d/` on your fleet, please open an issue with the trigger.

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
