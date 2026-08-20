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
# <id> is the leading number in `it-usb list` (usbguard's device rule id).
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
need_id() { [ -n "${1:-}" ] || die "need a device id -- see: it-usb list"; \
            printf '%s' "$1" | grep -qE '^[0-9]+$' || die "device id must be a number, got '$1'"; }

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
    need_id "${2:-}"
    if [ "${3:-}" = "--permanent" ]; then
      cp -a "$RULES" "$RULES.bak-$(date +%Y%m%d-%H%M%S)"
      usbguard allow-device -p "$2" || die "allow failed"
      echo "Allowed device $2 and appended it to the policy."
      echo "Policy backup: $RULES.bak-*"
    else
      usbguard allow-device "$2" || die "allow failed"
      echo "Allowed device $2 for this session only (re-blocked when unplugged)."
      echo "Make it stick with:  sudo it-usb allow $2 --permanent"
    fi
    ;;
  block)
    need_id "${2:-}"
    usbguard block-device "$2" && echo "Blocked device $2."
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
  help|-h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1' -- try: it-usb help" ;;
esac
