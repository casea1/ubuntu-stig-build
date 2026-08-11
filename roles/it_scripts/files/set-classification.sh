#!/usr/bin/env bash
# it-set-classification -- change the on-screen classification banner level
# (the top/bottom CAPCO-colored bars). Applies the change durably AND restarts
# the banner live in every active GUI session, so it takes effect immediately.
#
# What it changes:
#   /etc/xdg/autostart/classification-banner.desktop  -- level for future logins
#   /opt/it/site.yml (classification_banner_level)    -- so a later ansible-pull
#                                                        keeps your choice
#   running banner processes                          -- restarted in place
#
# Levels are the section names defined in /etc/classification-banner.conf
# (UNCLASSIFIED, CUI, FOUO, CONFIDENTIAL, SECRET, TOP SECRET, SCI, ...).
#
# Usage:
#   sudo it-set-classification                 # interactive menu
#   sudo it-set-classification SECRET          # non-interactive
#   sudo it-set-classification "TOP SECRET"    # quote levels with spaces
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

CONF=/etc/classification-banner.conf
AUTOSTART=/etc/xdg/autostart/classification-banner.desktop
BIN=/usr/local/bin/classification-banner
SITE=/opt/it/site.yml
TS=$(date +%Y%m%d-%H%M%S)

[ -f "$CONF" ]      || { echo "ERROR: $CONF not found -- is the classification_banner role installed?"; exit 1; }
[ -f "$AUTOSTART" ] || { echo "ERROR: $AUTOSTART not found."; exit 1; }

# Available levels = section names in the conf, minus [DEFAULT].
mapfile -t LEVELS < <(grep -oP '^\[\K[^]]+' "$CONF" | grep -vx DEFAULT)
[ "${#LEVELS[@]}" -gt 0 ] || { echo "ERROR: no levels defined in $CONF"; exit 1; }

# Current level, parsed from the autostart Exec line.
current=$(grep -oP '^Exec=.*classification-banner\s+"?\K[^"]+' "$AUTOSTART" 2>/dev/null || echo "?")

# Choose the level: from an argument, or an interactive menu.
LEVEL="${1:-}"
if [ -n "$LEVEL" ]; then
    printf '%s\n' "${LEVELS[@]}" | grep -qxF "$LEVEL" || {
        echo "ERROR: '$LEVEL' is not a defined level."
        echo "Available: ${LEVELS[*]}"; exit 1; }
else
    echo "Current classification: $current"
    echo
    echo "Select the new classification level:"
    PS3="Level # (Ctrl-C to cancel): "
    select choice in "${LEVELS[@]}"; do
        [ -n "${choice:-}" ] && { LEVEL="$choice"; break; }
        echo "  invalid choice -- try again"
    done
fi

echo
echo "Setting classification banner -> $LEVEL"

# 1) Autostart entry (applied at every future login/RDP connect).
cp -a "$AUTOSTART" "$AUTOSTART.bak-$TS"
sed -i "s|^Exec=.*|Exec=env GDK_BACKEND=x11 $BIN \"$LEVEL\"|" "$AUTOSTART"
echo "  updated $AUTOSTART"

# 2) Durable per-box override so a later ansible-pull keeps this level
#    (local.yml loads /opt/it/site.yml over group_vars).
mkdir -p "$(dirname "$SITE")"
if [ -f "$SITE" ] && grep -qE '^[[:space:]]*#?[[:space:]]*classification_banner_level:' "$SITE"; then
    cp -a "$SITE" "$SITE.bak-$TS"
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*classification_banner_level:.*|classification_banner_level: \"$LEVEL\"|" "$SITE"
else
    printf 'classification_banner_level: "%s"\n' "$LEVEL" >> "$SITE"
fi
echo "  updated $SITE (classification_banner_level)"

# 3) Restart the banner live in every session where it's running, reusing that
#    session's own environment (DISPLAY/XAUTHORITY/etc.) read from the process --
#    so a change applies immediately without a re-login.
restarted=0
for pid in $(pgrep -f "$BIN" 2>/dev/null); do
    owner=$(stat -c %U "/proc/$pid" 2>/dev/null) || continue
    _envf="/proc/$pid/environ"
    disp=$(tr '\0' '\n' < "$_envf" 2>/dev/null | sed -n 's/^DISPLAY=//p'                 | head -1)
    xath=$(tr '\0' '\n' < "$_envf" 2>/dev/null | sed -n 's/^XAUTHORITY=//p'              | head -1)
    dbus=$(tr '\0' '\n' < "$_envf" 2>/dev/null | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' | head -1)
    xrd=$( tr '\0' '\n' < "$_envf" 2>/dev/null | sed -n 's/^XDG_RUNTIME_DIR=//p'          | head -1)
    kill "$pid" 2>/dev/null || true
    [ -n "$disp" ] || continue
    sudo -u "$owner" env GDK_BACKEND=x11 DISPLAY="$disp" \
        ${xath:+XAUTHORITY="$xath"} \
        ${dbus:+DBUS_SESSION_BUS_ADDRESS="$dbus"} \
        ${xrd:+XDG_RUNTIME_DIR="$xrd"} \
        setsid "$BIN" "$LEVEL" >/dev/null 2>&1 &
    restarted=$((restarted + 1))
done

if [ "$restarted" -gt 0 ]; then
    echo "  restarted the banner in $restarted active session(s)"
else
    echo "  no running banner found -- it will show at the next login / RDP connect"
fi
echo
echo "Done. Classification is now: $LEVEL"
