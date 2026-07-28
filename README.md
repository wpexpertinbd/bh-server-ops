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
   - **Raises ModSecurity `SecRequestBodyNoFilesLimit` to 64 MB** (Apache `mod_security2` default is only 128 KB). A WordPress/Elementor/Gutenberg "save" POSTs the whole page as one JSON body — once it crosses 128 KB ModSecurity rejects the body and the editor save fails with the cryptic `AH01071: Got error 'PHP message: ooo'` (real cause logged as `ModSecurity: Request body no files data length is larger than the configured limit`). Tell-tale: "save works with 1–2 widgets, fails at 3". `ProcessPartial` ensures an over-size admin save is never hard-blocked. Idempotent, validated with `httpd -t` (auto-reverts on failure).
   - **Allows REST API write methods (`PUT`/`DELETE`/`PATCH`)** — stock Apache/CWP `httpd-userdir.conf` ships `<Directory "/home/*/public_html"> Require method GET POST OPTIONS`, which denies PUT/DELETE server-wide (`authz_core: AH01630 client denied by server configuration`). WooCommerce/WP REST API uses PUT (update) + DELETE, so any integration that **writes back** — couriers (ecomdrive etc.), Zapier, mobile apps, headless front-ends, payment/webhook callbacks — gets a 403 while reads (GET) work. Tell-tale: "connection test OK / GET works but order sync or status write-back fails with 403". Safe because `mod_dav` is disabled (PUT just reaches PHP, never writes files); also mirrored into the COMODO CWAF method whitelist. Idempotent, validated with `httpd -t` (auto-reverts on failure).
   - **Heals the CWP panel after an update kills it (`hostname.crt`)** — a CWP update can leave `/etc/pki/tls/certs/hostname.crt` missing while only `hostname.cert` exists; `cwpsrv.conf` points at the `.crt`, so its config test fails and **the panel never starts** (ports 2082/2083/2086/2087 refuse to connect) even though sites keep serving. Recreates the `.crt` from `.cert` and restarts `cwpsrv`. ⚠️ Never openssl-generates a new cert/key (that overwrites the real `hostname.key` → `key values mismatch`).
   - **Clears stray `immutable` flags from RPM-owned Apache files** — older hardening left `chattr +i` on files the **cwp-httpd RPM owns** (`conf/extra/httpd-mpm.conf`, `htdocs/index.html`, …). rpm then can't replace them → `Error unpacking rpm package` / `cpio: rename failed - Directory not empty` → the whole `yum update cwp-httpd` transaction aborts and Apache stays on the old version. The MPM config is no longer frozen (the 5-min heal cron re-asserts our values instead); our own `conf.d/99-global-hardening.conf` keeps its `+i` since rpm doesn't own it.
   - **Heals migrated user-crontab `SHELL` (cPanel→CWP fix)** — cPanel account migrations import crontabs carrying `SHELL="/usr/local/cpanel/bin/jailshell"`, a path that **doesn't exist on CWP**. crond still logs the `CMD` line every run, but the exec through the missing shell fails silently, so the job **never actually runs** — WHMCS/Blesta/WordPress/Mautic crons look scheduled but do nothing (the #1 "my cron isn't firing" cause on migrated resellers). Rewrites any `SHELL=` pointing to a non-existent binary → `/bin/bash`, and installs `/usr/local/sbin/bh-cron-shell-heal.sh` + a 30-min `/etc/cron.d/bh-cron-shell-heal` so future migrations self-correct. Each crontab is backed up to `/root/bh-cron-shell-backups/` first. CLI crons and `curl`/`wget` HTTP crons are unaffected — only the dead `SHELL=` line is the culprit.
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

**Shortcut for slaves where `TRUSTED_IPS` is already exported in `/root/.bash_profile`** — no need to retype the IP list, just add the slave flag inline:
```bash
IS_SLAVE_SERVER=1 bash <(curl -sL https://raw.githubusercontent.com/wpexpertinbd/bh-server-ops/main/perf-bootstrap.sh) -y
```

**Standalone single-server** (no fleet):
```bash
bash <(curl -sL https://raw.githubusercontent.com/wpexpertinbd/bh-server-ops/main/perf-bootstrap.sh) -y
```

### Trigger the FPM pool heal cron immediately (don't wait 5 min)

The bootstrap installs `/usr/local/sbin/bh-fpm-pool-heal.sh` (runs every 5 min via cron). It re-classifies every tenant by app type and reconciles each php-fpm pool to the correct **tier** (heavy / medium / light) — fully bidirectional, so it both promotes a newly-installed framework up and demotes a removed app back down. To trigger it manually right after a bootstrap run — or any time you want to force a re-sync:

```bash
/usr/local/sbin/bh-fpm-pool-heal.sh
tail -5 /var/log/bh-fpm-heal.log
```

Output format in the log: `changed=N (heavy=H medium=M light=L)` — `changed` = pools rewritten this run; `heavy/medium/light` = how many pools are currently classified into each tier.

### Verify which tier each tenant landed in (and *why*)

The classifier writes its results to `/var/lib/bh-server-ops/{heavy,medium}-users.list`. To audit a box — confirm every HEAVY user is a genuine framework (not a WordPress/cart site that slipped through), print exactly which fingerprint matched each heavy user (with the file path for `spark`/Symfony so false positives are obvious):

```bash
for u in $(cat /var/lib/bh-server-ops/heavy-users.list); do
  h=/home/$u; m=""
  find "$h" -maxdepth 4 -name artisan -type f 2>/dev/null | head -1 | grep -q . && m="$m artisan"
  sp=$(find "$h" -maxdepth 4 -name spark -type f 2>/dev/null | head -1); [ -n "$sp" ] && m="$m SPARK[$sp]"
  find "$h" -maxdepth 5 -type f -path "*/system/core/CodeIgniter.php" 2>/dev/null | head -1 | grep -q . && m="$m CI3"
  sf=$(find "$h" -maxdepth 5 -type f -path "*/config/bundles.php" 2>/dev/null | head -1); [ -n "$sf" ] && m="$m SYMFONY[$sf]"
  echo "$u =>$m"
done
```

Healthy output shows only `artisan` (Laravel), `CI3` (CodeIgniter), or a real Symfony path. If any `SPARK[...]` points into `wp-content/` (a theme/plugin file literally named `spark`), that's a false positive — add the user to `SKIP_USERS` or force the right tier with `MEDIUM_USERS`.

Full per-tier breakdown (heavy / medium / light) in one shot — heavy & medium come from the list files, light = every other tuned pool:

```bash
echo "== HEAVY ==";  cat /var/lib/bh-server-ops/heavy-users.list
echo "== MEDIUM =="; cat /var/lib/bh-server-ops/medium-users.list
echo "== LIGHT (everything else tuned) =="
comm -23 \
  <(ls /opt/alt/php-fpm*/usr/etc/php-fpm.d/users/*.conf 2>/dev/null | xargs -n1 basename | sed 's/\.conf$//' | sort -u) \
  <( { cat /var/lib/bh-server-ops/heavy-users.list /var/lib/bh-server-ops/medium-users.list 2>/dev/null; echo nobody; } | sort -u )

# live pool-size distribution (sanity check against the tier numbers)
grep -h pm.max_children /opt/alt/php-fpm*/usr/etc/php-fpm.d/users/*.conf | sort | uniq -c
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
- **Heavy app users** (Laravel/CodeIgniter/Symfony tenants — get the full dynamic pool)
- **Apache MPM tuning?** (yes/no)
- **Redis cap?** (yes/no)
- **Install helpers?** (`tenant-cap`, `saturation-monitor`, `auto-recovery`)
- **Saturation-monitor cron** (every 5 min — recommended yes)
- **Auto-recovery cron** (every 3 min — default yes, self-healing safety net)
- **Sites to monitor** (auto-discover or provide explicit list)

A summary is shown before any change. Press Enter on each prompt to accept the default in `[brackets]`.

### Non-interactive run (curl pipe, automation, etc.)

When stdin isn't a TTY (e.g. `curl ... | bash`) or you pass `-y`, the script uses built-in defaults silently. Every tenant is **auto-classified into a tier** by scanning `/home/*` for app fingerprints (DB size is no longer a signal — tier is decided purely by app type):

| Tier | Detected apps | pm mode | `pm.max_children` |
|------|---------------|---------|-------------------|
| **HEAVY** | Laravel (`artisan`), CodeIgniter (`spark` / `system/core/CodeIgniter.php`), Symfony (`config/bundles.php`) | `dynamic` (warm pool + spares) | `HEAVY_CHILDREN` (100%) |
| **MEDIUM** | WordPress (`wp-load.php`/`wp-config.php`), WooCommerce, OpenCart, Magento | `ondemand` | 75% of heavy (floor 3) |
| **LIGHT** | everything else (static HTML / basic PHP) | `ondemand` | 25% of heavy (floor 2) |

This replaces the old 2-tier model where WooCommerce/OpenCart/big-DB swept almost every tenant into the heavy pool and exhausted RAM. Sizes derive from `HEAVY_CHILDREN` per RAM tier — never CWP's low built-in pool defaults. Override detection per tenant with `HEAVY_USERS="u1 u2"` / `MEDIUM_USERS="u3"` / `SKIP_USERS="u4"` env vars (no env needed for normal auto-detect):

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

# Protect a fragile tenant from any tuning (hard escape hatch — wins over auto-detect)
SKIP_USERS="fragileuser" bash perf-bootstrap.sh -y
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
If `/etc/nginx/snippets/anti-bot-server.conf` exists, the cron repairs two things that a **CWP "Rebuild Web Server"** (admin → WebServer Settings) is known to break, then reloads nginx — or **starts** it if the rebuild already left it down:

1. **The map files** in `/etc/nginx/bh.d/` — if either is missing, it's restored from the snapshot at `/var/lib/bh-server-ops/`.
2. **The `include /etc/nginx/bh.d/*.conf;` line in `nginx.conf`** — a CWP rebuild regenerates `nginx.conf` from its template and silently drops this line. The map files survive (they're in `bh.d/`, outside `conf.d/`), but with the include gone they're never loaded, so the per-vhost snippet's reference to `$bh_bad_bot` / `$bh_trusted_ip` becomes an `unknown "bh_bad_bot" variable` `[emerg]` and **nginx refuses to start on the next reload**. The cron re-inserts the line (before the `conf.d` include) and brings nginx back up.

Bounds the worst-case "nginx down after a CWP rebuild" outage to one cron interval. (CWP regen and `yum reinstall nginx` have both been observed wiping `/etc/nginx/conf.d/`, which is why the maps live in `bh.d/` — and the include line is now self-healed too, since the rebuild strips it from `nginx.conf` itself.)

**TTFB recovery (fires on threshold breach):**
If TTFB exceeds recovery threshold (default 20s):
1. Graceful reload Apache (zero downtime)
2. If site still slow after 5 sec → escalates to `restart httpd` (1-2 sec blip, guaranteed clear of stuck workers)
3. Reload all running PHP-FPM services
4. Flush Varnish cache
5. Throttle: skips if last recovery fired less than 10 min ago (prevents loops)
6. Logs to `/var/log/auto-recovery.log`

To disable, choose `n` at the prompt OR set `ENABLE_AUTO_RECOVERY_CRON=0`. Disable temporarily for diagnostic windows where you want saturation events to persist for inspection.

## HTTP/3 (real, not advertise-only)

EL8's stock nginx links against OpenSSL 1.1.1k which has zero QUIC API — so `--with-http_v3_module` loads but TLS handshakes silently fail. The script swaps to codeit.guru's nginx build (linked against `openssl-quic-libs-4.0.0`) which actually serves H3. System OpenSSL stays untouched; only nginx changes.

What the `ENABLE_HTTP3=1` path (default with `-y`) does, all idempotent:

1. Detects current nginx — if already on a `.codeit.el8` build, skips the swap
2. Disables F5's `nginx-mainline` repo, adds codeit's stable repo
3. Removes stock `brotli` only if nothing depends on it (auto-aborts H3 otherwise)
4. Installs `libbrotli` + `openssl-quic-libs` + `nginx` from codeit (via direct RPM URLs to bypass DNF modular filtering)
5. Generates `/etc/pki/tls/{certs/default.bundle,private/default.key}` (5-year self-signed) for the QUIC binder, only if missing
6. Drops `/etc/nginx/bh.d/global_quic.conf` (reuseport binder, returns 444 for unmatched SNI — real H3 routes via SNI to per-vhost listeners), only if absent
7. Patches CWP vhost templates at `/usr/local/cwpsrv/htdocs/resources/conf/web_servers/vhosts/nginx/{default,http3}.stpl` — injects `listen %ip%:%nginx_port% quic;` + `http3 on;` into the MAIN server block (skips webmail/mail/cpanel/ftp), tagged `# BH-HTTP3-INJECT`
8. Opens UDP 443 in csf or firewalld (auto-detect)
9. Installs `/usr/local/sbin/bh-http3-template-heal.sh` + 5-min cron — re-injects the template tag if CWP package updates wipe it
10. `nginx -t` + reload; if test fails, restores template backups and rolls back

To skip on a specific box (e.g. slave/API node where browsers never connect):
```bash
ENABLE_HTTP3=0 bash perf-bootstrap.sh -y
```
`IS_SLAVE_SERVER=1` also auto-skips H3 (no point serving QUIC to machine clients).

## RAM-tier scaling

Every memory-hungry setting (Apache MPM, FPM children, OPcache, Redis) auto-scales together based on detected RAM. Same script works from a tiny 1 vCPU/2 GB VPS to a 256 GB dedicated beast.

Thresholds are intentionally a few GB below the nominal class — `/proc/meminfo` always reports less than installed (kernel + firmware reserve ~2 GB on big boxes, ~1 GB on small VPS). 64 GB box reports ~62 GB, 128 GB reports ~125, etc.

FPM children scale off `HEAVY_CHILDREN` per tier: **light = 25%** (floor 2), **medium = 75%** (floor 3), **heavy = 100%**.

| Detected RAM | Apache MaxWorkers | FPM children (light/medium/heavy) | OPcache | Redis cap |
|---|---|---|---|---|
| **≥ 240 GB** (256 GB-class) | **5000 (100×50)** | **7 / 22 / 30** | **512 MB** | **8 GB** |
| **≥ 120 GB** (128 GB-class) | **3200 (64×50)** | **6 / 18 / 25** | **384 MB** | **4 GB** |
| ≥ 60 GB (64 GB-class) | 1600 (32×50) | 5 / 15 / 20 | 256 MB | 2 GB |
| ≥ 30 GB (32 GB-class) | 800 (16×50) | 5 / 15 / 20 | 256 MB | 1 GB |
| ≥ 14 GB (16 GB-class) | 400 (8×50) | 3 / 11 / 15 | 192 MB | 512 MB |
| ≥ 7 GB (8 GB-class) | 200 (5×40) | 3 / 9 / 12 | 128 MB | 384 MB |
| ≥ 3 GB (4 GB-class) | 100 (4×25) | 2 / 6 / 8 | 96 MB | 256 MB |
| < 3 GB (1-2 GB VPS) | 50 (2×25) | 2 / 3 / 5 | 64 MB | 128 MB |

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
| `/etc/nginx/nginx.conf` | gets one `include /etc/nginx/bh.d/*.conf;` line added (idempotent) | ⚠️ **CWP "Rebuild Web Server" regenerates this file and drops the line** → self-healed by the `auto-recovery` cron |
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
