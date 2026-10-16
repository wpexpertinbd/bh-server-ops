#!/bin/bash
# bh-cwp-nodejs-menu-heal.sh — put "Node.JS Apps" back into the CWP user-panel sidebar.
#
#   bash bh-cwp-nodejs-menu-heal.sh            # heal now + install itself to /usr/local/sbin and a 15-min cron
#   bash /usr/local/sbin/bh-cwp-nodejs-menu-heal.sh --check   # report only, change nothing
#
# Why (2026-10-17): the CWP update of 2026-10-14 shipped a new user theme "original" whose
# menu_left.html (CWP file dated 2026-09-23) no longer contains the Node.JS Apps entry. The module
# itself (?module=nodejs_manager) still works; only the link is gone, so users cannot find it.
# Every CWP update can overwrite the theme again, hence the cron.
#
# What it does, per cwp_theme/*/menu_left.html that has NO "module=nodejs_manager" link:
#   - adds the entry right after the "sslwizard" item of the Domains menu, tagged BH-NODEJS-MENU
#   - lets the Domains menu itself open for users who only have Node.js
# Shown when ("nodejs" in extra_rmenu) or ("nodejs_manager" in rmenu) or (swmenu==1) — the stock
# condition plus the package feature list. Themes that already have the link are left untouched.
# Safety: parts of cwp_theme are writable by the panel user cwpsvc, so root never writes a temp or
# backup file there and never follows a symlink: the new file is built in a root-only dir and put in
# place with one rename() on the same filesystem; a symlinked menu_left.html is refused.
# Keeps owner/mode, one backup per theme in $WORK/<theme>.menu_left.html.prev, logs to
# /var/log/bh-cwp-nodejs-menu-heal.log. Undo: copy the .prev back, remove the cron + script.
set -u

THEMES=/usr/local/cwpsrv/var/services/users/cwp_theme
LOG=/var/log/bh-cwp-nodejs-menu-heal.log
SELF=/usr/local/sbin/bh-cwp-nodejs-menu-heal.sh
CRON=/etc/cron.d/bh-cwp-nodejs-menu-heal
WORK=/root/.bh-cwp-nodejs-menu-heal
MARK='BH-NODEJS-MENU'
COND='("nodejs" in extra_rmenu )or("nodejs_manager" in rmenu )or(swmenu==1)'
MODE=heal
[ "${1:-}" = --check ] && MODE=check
[ -z "${1:-}" ] || [ "$MODE" = check ] || { echo "usage: $0 [--check]" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "✗ run as root" >&2; exit 1; }
[ -d "$THEMES" ] || { echo "- no CWP user themes here ($THEMES) — nothing to do"; exit 0; }

log(){ echo "$(date '+%F %T') $*" >> "$LOG"; echo "$*"; }

rc=0
if [ "$MODE" = heal ]; then
  if [ -f "$0" ] && [ "$(readlink -f "$0")" != "$SELF" ]; then
    if ! { install -m 0755 "$0" "$SELF.new" && mv -f "$SELF.new" "$SELF"; }; then
      echo "✗ could not install $SELF" >&2; rc=1
    fi
  fi
  if [ -x "$SELF" ]; then
    if ! { printf '%s\n' '# bh-server-ops: re-add "Node.JS Apps" to the CWP user sidebar after CWP updates' \
         'SHELL=/bin/bash' "*/15 * * * * root $SELF >/dev/null 2>&1" > "$CRON" && chmod 644 "$CRON"; }; then
      echo "✗ could not write $CRON" >&2; rc=1
    fi
  else
    echo "✗ $SELF missing — no cron installed" >&2; rc=1
  fi
  install -d -m 700 "$WORK" || { echo "✗ cannot create $WORK" >&2; exit 1; }
  [ -L "$WORK" ] && { echo "✗ $WORK is a symlink — refusing" >&2; exit 1; }
fi

for F in "$THEMES"/*/menu_left.html; do
  th=$(basename "$(dirname "$F")")
  if [ -L "$F" ] || [ -L "$(dirname "$F")" ]; then log "WARN $th: $F or its dir is a symlink — refused"; rc=1; continue; fi
  [ -f "$F" ] || continue
  if grep -q 'module=nodejs_manager' "$F"; then
    echo "✓ $th: Node.JS Apps link present$(grep -q "$MARK" "$F" && echo ' (BH patch)')"
    continue
  fi
  # Anchor: the sslwizard item, then the next {% endif %}. No anchor = unknown layout, do not guess.
  if ! grep -q 'href="?module=sslwizard"' "$F"; then
    log "WARN $th: link missing but no sslwizard anchor in $F — left untouched"; rc=1; continue
  fi
  if [ "$MODE" = check ]; then echo "✗ $th: Node.JS Apps link MISSING (heal would add it)"; rc=1; continue; fi

  # Work on a snapshot in the root-only dir: copied without following links, then checked, so a
  # file swapped for a symlink after the check above can never feed another file into the theme.
  C="$WORK/$th.menu_left.html.prev"
  rm -f "$C" && cp -p --no-dereference "$F" "$C" || { log "ERR $th: snapshot failed"; rc=1; continue; }
  if [ -L "$C" ] || [ ! -f "$C" ]; then rm -f "$C"; log "WARN $th: $F is not a regular file — refused"; rc=1; continue; fi
  T=$(mktemp "$WORK/$th.XXXXXX") || { log "ERR $th: mktemp failed"; rc=1; continue; }
  awk -v cond="$COND" -v mark="$MARK" '
    # widen the Domains menu condition once (the "if" line that tests sslwizard and domains)
    !widened && /\{% if / && /"sslwizard" in rmenu/ && /"domains" in rmenu/ && !/nodejs/ {
      sub(/\{% if /, "{% if (\"nodejs\" in extra_rmenu )or(\"nodejs_manager\" in rmenu )or"); widened=1 }
    { print }
    /href="\?module=sslwizard"/ { seen=1; next }
    seen && !done && /\{% endif %\}/ {
      match($0, /^[ \t]*/); ind=substr($0, 1, RLENGTH)
      print ind "{# " mark " #}{% if " cond " %}"
      print ind "<li class=\"search\"><a href=\"?module=nodejs_manager\">Node.JS Apps</a></li>"
      print ind "{% endif %}{# END " mark " #}"
      done=1 }
  ' "$C" > "$T"
  old=$(wc -l < "$C"); new=$(wc -l < "$T")
  # Must have: 2 markers, exactly 3 new lines, the link, AND the Domains menu condition widened
  # (otherwise users with only Node.js would get a link inside a menu that never opens).
  if [ "$(grep -c "$MARK" "$T")" != 2 ] || [ $((new - old)) -ne 3 ] || ! grep -q 'module=nodejs_manager' "$T" \
     || ! grep -E '\{% if .*"domains" in rmenu' "$T" | grep -q '"nodejs_manager" in rmenu'; then
    rm -f "$T"; log "WARN $th: patch did not apply cleanly (layout changed?) — left untouched"; rc=1; continue
  fi
  # rename() is only atomic on the same filesystem; never fall back to a copy into the theme dir.
  if [ "$(stat -c %d "$WORK")" != "$(stat -c %d "$(dirname "$F")")" ]; then
    rm -f "$T"; log "WARN $th: $WORK is on another filesystem than $F — left untouched"; rc=1; continue
  fi
  chown "$(stat -c %u:%g "$C")" "$T" && chmod "$(stat -c %a "$C")" "$T" \
    && mv -fT "$T" "$F" || { rm -f "$T"; log "ERR $th: could not replace $F"; rc=1; continue; }
  log "healed $th: Node.JS Apps re-added to $F (backup $C)"
done
exit $rc
