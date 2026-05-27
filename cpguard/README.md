# cPGuard Unattended Installer (CWP Pro + AlmaLinux)

End-to-end automation of the BiswasHost manual cPGuard install workflow.
Replaces ~30 minutes of clicking + answering installer prompts per server
with a single command. Scales from 1 server (run on the box itself) to
N servers (run dispatcher from your laptop).

## What it does

Per server (`cpguard-install.sh`):

1. **Preflight** — verify AlmaLinux/Rocky/CentOS, CWP, Apache, disk + RAM; detect existing cPGuard + CSF.
2. **Whitelist cPGuard call-home IPs** (`137.184.200.210`, `159.89.87.35`, `167.99.149.179`) via `csf` or `firewalld` so the installer can reach licensing.
3. **Install cPGuard** (Standard or Lite) — drives the interactive installer via `expect` with the canonical BiswasHost answers:
   - web server / WAF server = `apache`
   - vhost path = `/usr/local/apache/conf.d/vhosts/*.conf`
   - WAF conf = `/usr/local/apache/cpguard.conf`
   - restart cmd = `systemctl restart httpd`
   - audit log = `/usr/local/apache/logs/modsec_audit.log`
   - domain_list / user_list / error_log = blank
4. **Patch `mod_security.conf`** — comments the OWASP-old Include, adds the cPGuard Include. Snapshots the original to `.bh-preinstall` first so we can roll back if Apache config-tests fail.
5. **Apply BiswasHost SecRuleRemoveById exclusions** → `/etc/cpguard/custom-exclusions.conf` (38 rules covering CWP, WordPress, Joomla, Drupal, phpMyAdmin, webftp_simple + rule `1006000` for BD consumer-ISP false positives on ecommerce sites).
6. **Migrate CSF rules** (if CSF detected) via `/opt/cpguard/app/scripts/csf_migration.php`.
7. **Apply license** + `cpgcli waf --enable` + `cpgcli cleanup --enable`.
8. **`httpd -t` + restart** — rolls back on config failure.
9. **Verify**:
   - `cpgcli license --status` shows Active
   - `cpgcli waf --status` shows enabled
   - `httpd` active, HTTP smoke test returns 200/301/302/403
   - 30-second tail of `error_log` shows no fatal ModSec errors

Exit code: `0` clean, `2` partial (one+ verify check failed), `1` fatal.

Idempotent — safe to re-run. Logs to `/var/log/bh-cpguard-install.log`. A parsed summary lands in `/tmp/bh-cpg-summary.txt` for the dispatcher to slurp.

## Single-server use

SSH to the target, then:

```bash
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/bh-server-ops/main/cpguard/cpguard-install.sh \
  -o /root/cpguard-install.sh
chmod +x /root/cpguard-install.sh
bash /root/cpguard-install.sh CPG-YOUR-LICENSE-KEY
```

Or one-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/wpexpertinbd/bh-server-ops/main/cpguard/cpguard-install.sh \
  | bash -s -- CPG-YOUR-LICENSE-KEY
```

Env overrides (optional):

| Var | Default | Effect |
|---|---|---|
| `CPGUARD_EDITION` | `standard` | Set to `lite` for cPGuard Lite |
| `APPLY_EXCLUSIONS` | `1` | `0` skips the SecRuleRemoveById block |
| `MIGRATE_CSF` | `1` | `0` skips CSF migration even if detected |

## Fleet use (dispatcher from your laptop)

```bash
git clone https://github.com/wpexpertinbd/bh-server-ops.git
cd bh-server-ops/cpguard
cp servers.csv.example servers.csv
$EDITOR servers.csv     # fill in hostname, ip, port, user, key path, license key
bash dispatch.sh --dry-run             # preflight every server, no install
bash dispatch.sh                       # install all in parallel (4 at a time)
bash dispatch.sh --only srv03,srv07    # retry specific hosts
bash dispatch.sh --parallel 2          # slower, gentler on cPGuard mirror
```

Output:

```
logs/srv01.log        # full transcript
logs/srv01.summary    # parsed key=value pairs
...
logs/SUMMARY.md       # markdown table — paste into Fiverr delivery
```

`SUMMARY.md` columns: Host, Result, cPGuard version, License, WAF, CSF migrated, HTTP smoke, Duration, ModSec errors.

## Rollback

If the installer fails mid-run and Apache won't start:

```bash
cp /usr/local/apache/conf.d/mod_security.conf.bh-preinstall \
   /usr/local/apache/conf.d/mod_security.conf
systemctl restart httpd
```

Then run the cPGuard uninstaller if you want a fully clean slate:

```bash
cd /usr/local/src
curl -fsSL https://downloads.opsshield.com/cpguard/cpguard_uninstall.sh -o cpguard_uninstall.sh
bash cpguard_uninstall.sh
```

## Notes / known quirks

- **`expect`** is auto-installed via `dnf`/`yum` if missing. The installer's prompts are matched with permissive regex so minor wording changes in future cPGuard releases shouldn't break the flow — but if cPGuard adds a *new* prompt, expect will time out (1800s) and you'll see `EXPECT TIMEOUT` in the log. Add a new `-re` clause to the heredoc and retry.
- **Pre-existing cPGuard** is detected and the installer step is skipped; license refresh + config patches + verify still run. Useful for re-licensing renewals.
- **CWP firewall whitelist** uses `csf -a` if CSF is present, else `firewall-cmd --permanent --add-source`. If neither is present (rare on CWP), whitelisting silently no-ops — usually fine because outbound traffic isn't typically blocked.
- **No client data is touched.** Customer vhosts, databases, mail are untouched. Only `mod_security.conf`, `/etc/cpguard/`, and the cPGuard install paths change.
