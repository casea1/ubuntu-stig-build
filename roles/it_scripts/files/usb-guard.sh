#!/usr/bin/env bash
# it-usb -- manage USBGuard device authorisation.
#
# USBGuard is an ALLOW-LIST: devices in the policy work, everything else is
# blocked. This wraps the usbguard CLI so day-to-day use is one short command.
#
# Usage:
#   it-usb status                 daemon state + policy summary
#   it-usb list                   all devices, with allow/block state and IDs
#   it-usb blocked                only the devices currently being blocked
#   it-usb enroll                 GUIDED: plug a device in, it gets whitelisted
#   it-usb allow <id>             authorise NOW (until it is unplugged)
#   it-usb allow <id> --permanent authorise now AND add it to the policy
#   it-usb block <id>             de-authorise NOW
#   it-usb policy                 show the saved allow-list
#   it-usb regenerate             re-baseline the policy from ATTACHED devices
#   it-usb help
#
# <id> is EITHER the leading number in `it-usb list` (usbguard's own device rule
# id) OR the vendor:product pair, e.g. 0e90:0065. usbguard's output writes
# "19: block id 0e90:0065 ...", so both numbers are on the same line and either
# is a reasonable thing to reach for -- a vendor:product is resolved to the
# device number for you. If it matches several attached devices, they are
# listed and you pick one, or pass --all to authorise every match (which is
# usually what you want for a hub that presents USB2 and USB3 separately).
#
# EASIEST WAY TO WHITELIST A DEVICE:
#   sudo it-usb enroll          <- prompts you to plug it in, finds it, allows it
# Manual equivalent: plug in, `it-usb blocked` for the id, then
#   sudo it-usb allow <id> --permanent
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

RULES=/etc/usbguard/rules.conf
have() { command -v "$1" >/dev/null 2>&1; }
have usbguard || { echo "usbguard not installed (usbguard_enabled is false?)" >&2; exit 1; }

die() { echo "$*" >&2; exit 2; }

# usbguard prints "19: block id 0e90:0065 ..." -- the RULE id is the leading
# number, but the words "id 0e90:0065" sit right there in the same line, so
# reaching for the vendor:product pair is the obvious mistake to make. Accept
# both: a VID:PID is resolved to the rule number(s) that carry it.
# Flags are positional-agnostic: `allow 19 --permanent` and
# `allow 0e90:0065 --all --permanent` both work, and an unknown flag is an
# error rather than being silently ignored.
PERMANENT=0; ALL_MATCHES=0; ALL_FLAG=""; ARGS=()
for a in "$@"; do
  case "$a" in
    --permanent) PERMANENT=1 ;;
    --all)       ALL_MATCHES=1; ALL_FLAG="--all " ;;
    --*)         echo "unknown option: $a  (try: it-usb help)" >&2; exit 2 ;;
    *)           ARGS+=("$a") ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

RESOLVED=""
resolve_id() {
  local want="${1:-}"
  [ -n "$want" ] || die "need a device id -- see: it-usb list"
  if printf '%s' "$want" | grep -qE '^[0-9]+$'; then RESOLVED="$want"; return 0; fi
  printf '%s' "$want" | grep -qiE '^[0-9a-f]{4}:[0-9a-f]{4}$' \
    || die "expected a device number (e.g. 19) or a vendor:product id (e.g. 0e90:0065), got '$want'"

  local matches
  matches=$(usbguard list-devices 2>/dev/null | grep -iF " id $want " | sed -n 's/^\([0-9]\+\):.*/\1/p')
  [ -n "$matches" ] || die "no attached device has id $want -- see: it-usb list"

  if [ "$(printf '%s\n' "$matches" | wc -l)" -gt 1 ]; then
    if [ "$ALL_MATCHES" = 1 ]; then RESOLVED="$matches"; return 0; fi
    echo "$want matches more than one device:" >&2
    usbguard list-devices 2>/dev/null | grep -iF " id $want " | sed 's/^/    /' >&2
    echo >&2
    echo "Give the leading NUMBER of the one you want, or --all for every match:" >&2
    echo "    sudo it-usb allow <number> --permanent" >&2
    echo "    sudo it-usb allow $want --all --permanent" >&2
    exit 2
  fi
  RESOLVED="$matches"
  echo "  $want -> device $matches"
}

case "${1:-help}" in
  status)
    systemctl --no-pager --full status usbguard 2>/dev/null | head -6
    echo
    printf 'implicit policy : %s\n' "$(awk -F= '/^ImplicitPolicyTarget/{print $2}' /etc/usbguard/usbguard-daemon.conf 2>/dev/null)"
    printf 'policy rules    : %s\n' "$(grep -cvE '^\s*(#|$)' "$RULES" 2>/dev/null || echo 0)"
    printf 'devices present : %s\n' "$(usbguard list-devices 2>/dev/null | wc -l)"
    printf 'currently blocked: %s\n' "$(usbguard list-devices -b 2>/dev/null | wc -l)"
    ;;
  list)      usbguard list-devices ;;
  blocked)
    out="$(usbguard list-devices -b 2>/dev/null)"
    if [ -z "$out" ]; then echo "No blocked devices."; else
      echo "$out"; echo; echo "Authorise one with:  sudo it-usb allow <id> --permanent"
    fi
    ;;
  allow)
    resolve_id "${2:-}"
    if [ "$PERMANENT" = 1 ]; then
      cp -a "$RULES" "$RULES.bak-$(date +%Y%m%d-%H%M%S)"
      for d in $RESOLVED; do
        usbguard allow-device -p "$d" || die "allow failed for device $d"
        echo "Allowed device $d and appended it to the policy."
      done
      echo "Policy backup: $RULES.bak-*"
    else
      for d in $RESOLVED; do
        usbguard allow-device "$d" || die "allow failed for device $d"
        echo "Allowed device $d for this session only (re-blocked when unplugged)."
      done
      echo "Make it stick with:  sudo it-usb allow ${2} ${ALL_FLAG}--permanent"
    fi
    ;;
  block)
    resolve_id "${2:-}"
    for d in $RESOLVED; do
      usbguard block-device "$d" && echo "Blocked device $d."
    done
    ;;
  enroll)
    # Guided whitelisting: snapshot device ids, wait for an insertion, diff,
    # confirm, then authorise permanently. Safer than reading ids by eye --
    # you cannot accidentally authorise the wrong (already-present) device.
    before="$(usbguard list-devices 2>/dev/null | cut -d: -f1 | sort)"
    echo "Plug in the device to authorise now."
    printf 'Press Enter once it is connected (Ctrl-C to abort)... '
    read -r _
    sleep 1
    after="$(usbguard list-devices 2>/dev/null | cut -d: -f1 | sort)"
    new_ids="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
    if [ -z "$new_ids" ]; then
      echo
      echo "No new device detected."
      echo "Some devices re-use an id, or the device may present several interfaces."
      echo "Check 'sudo it-usb blocked' and allow by id instead."
      exit 1
    fi
    echo
    echo "New device(s) detected:"
    for id in $new_ids; do usbguard list-devices 2>/dev/null | grep -E "^$id:" | sed 's/^/  /'; done
    echo
    printf 'Authorise the above PERMANENTLY (added to the policy)? [y/N] '
    read -r a; [ "$a" = y ] || { echo "aborted -- nothing changed"; exit 0; }
    cp -a "$RULES" "$RULES.bak-$(date +%Y%m%d-%H%M%S)"
    fail=0
    for id in $new_ids; do
      if usbguard allow-device -p "$id"; then echo "  authorised $id"; else echo "  FAILED $id" >&2; fail=1; fi
    done
    echo "Policy backup: $RULES.bak-*"
    [ "$fail" = 0 ] || exit 1
    ;;
  policy)
    echo "== $RULES =="
    grep -nvE '^\s*(#|$)' "$RULES" 2>/dev/null || echo "(empty)"
    ;;
  regenerate)
    echo "This RE-BASELINES the allow-list against the devices attached RIGHT NOW."
    echo "Anything currently plugged in becomes authorised. Unplug what should not be."
    printf 'Continue? [y/N] '; read -r a; [ "$a" = y ] || { echo "aborted"; exit 0; }
    cp -a "$RULES" "$RULES.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null
    umask 077
    usbguard generate-policy > "$RULES.new" || die "generate-policy failed"
    mv "$RULES.new" "$RULES"; chmod 0600 "$RULES"
    systemctl restart usbguard
    echo "Policy regenerated from attached devices; daemon restarted."
    echo "Backup: $RULES.bak-*"
    ;;
  # Print the comment header, stopping at the first non-comment line. The old
  # fixed range '2,30p' ran past the end of the header and printed shell source
  # (set -uo pipefail, the sudo re-exec) as if it were documentation.
  help|-h|--help)
    awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0" ;;
  *) die "unknown command '$1' -- try: it-usb help" ;;
esac
