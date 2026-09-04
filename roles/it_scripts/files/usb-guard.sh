#!/usr/bin/env bash
# it-usb -- manage USBGuard device authorisation.
#
# USBGuard is an ALLOW-LIST: devices in the policy work, everything else is
# blocked. This wraps the usbguard CLI so day-to-day use is one short command.
#
# Usage:
#   it-usb status                 daemon state + policy summary
#   it-usb list                   all devices as a tree: state, class, port
#   it-usb list --raw             usbguard's own output, unformatted
#   it-usb blocked                only the devices currently being blocked
#
# `list` decodes the USB class byte (hub / HID / MASS STORAGE / network / ...)
# and nests each device under what it is plugged into, so a flash drive behind
# a dock is visibly behind that dock. A "!" marks the classes that can act on
# their own -- keyboards (keystroke injection), storage (data movement) and
# radios. Those are the ones to look twice at before authorising.
#   it-usb enroll                 GUIDED: plug a device in, it gets whitelisted
#   it-usb allow <id>             authorise NOW (until it is unplugged)
#   it-usb allow <id> --permanent authorise now AND add it to the policy
#   it-usb trust <vid:pid> [serial]
#                                 pre-authorise by vendor:product, WITHOUT the
#                                 device being plugged in. For hardware that
#                                 disconnects itself when the host does not
#                                 authorise it fast enough (write blockers do
#                                 this), a policy rule beats racing the device.
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
RENDER="$(dirname "$(readlink -f "$0")")/usb-render.py"
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
PERMANENT=0; ALL_MATCHES=0; ALL_FLAG=""; RAW=0; ARGS=()
for a in "$@"; do
  case "$a" in
    --permanent) PERMANENT=1 ;;
    --all)       ALL_MATCHES=1; ALL_FLAG="--all " ;;
    --raw)       RAW=1 ;;
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

    # Which classes still need a human. Read from the policy rather than
    # restated here, so this cannot drift from what the daemon enforces.
    cls=$(sed -nE 's/^allow with-interface none-of \{ (.*) \}.*/\1/p' "$RULES" 2>/dev/null | tail -1)
    if [ -n "$cls" ]; then
      printf 'needs enrolling : %s\n' "$cls"
      echo   '                  Everything else -- serial adapters, hubs and docks, printers,'
      echo   '                  audio, video, JTAG programmers -- is authorised on connect.'
    else
      printf 'needs enrolling : EVERY device (no class policy in %s)\n' "$RULES"
    fi
    printf 'currently blocked: %s\n' "$(usbguard list-devices -b 2>/dev/null | wc -l)"

    # The question `it-usb blocked` cannot answer. A device USBGuard AUTHORISED
    # still does nothing if no driver can claim it: a USB stick or DVD reader
    # needs usb-storage (and uas on USB3), and where usb_storage_enabled is
    # false both are blacklisted. The device then enumerates, is authorised,
    # and never appears anywhere -- absent from `blocked` precisely BECAUSE
    # USBGuard allowed it. That cost an afternoon once; it is one line now.
    echo
    bl=$(grep -rlE '^[[:space:]]*(blacklist|install)[[:space:]]+(usb[-_]storage|uas)([[:space:]]|$)' \
         /etc/modprobe.d/ 2>/dev/null | tr '\n' ' ')
    mods=$(lsmod 2>/dev/null)
    loaded() { case "$mods" in *"$1"*) echo loaded ;; *) echo "not loaded" ;; esac; }
    if [ -n "$bl" ]; then
      printf 'usb mass storage: BLACKLISTED by %s\n' "$bl"
      echo   '                  No USB drive, and no USB DVD/CD reader, can appear on'
      echo   '                  this box however it is authorised. That is intended where'
      echo   '                  usb_storage_enabled is false. To use optical or removable'
      echo   '                  media here, set usb_storage_enabled: true in the box'"'"'s'
      echo   '                  /opt/it/site.yml and pull -- USBGuard still gates every device.'
    else
      printf 'usb mass storage: allowed (usb-storage %s, uas %s)\n' "$(loaded usb_storage)" "$(loaded uas)"
    fi
    printf 'optical devices : %s\n' "$(ls -d /dev/sr* 2>/dev/null | tr '\n' ' ' || true)"
    ;;
  list)
    # --raw gives usbguard's own output, for scripting or when the renderer is
    # unavailable. Everything else gets the readable tree.
    if [ "$RAW" = 1 ] || [ ! -x "$RENDER" ]; then usbguard list-devices
    else usbguard list-devices 2>/dev/null | "$RENDER"; fi
    ;;
  blocked)
    out="$(usbguard list-devices -b 2>/dev/null)"
    if [ -z "$out" ]; then echo "No blocked devices."
    elif [ "$RAW" = 1 ] || [ ! -x "$RENDER" ]; then
      echo "$out"; echo; echo "Authorise one with:  sudo it-usb allow <id> --permanent"
    else
      printf '%s\n' "$out" | "$RENDER"
    fi
    ;;
  allow)
    resolve_id "${2:-}"
    if [ "$PERMANENT" = 1 ]; then
      cp -a "$RULES" "$RULES.bak-$(date +%Y%m%d-%H%M%S)"
      for d in $RESOLVED; do
        if usbguard allow-device -p "$d" 2>/dev/null; then
          echo "Allowed device $d and appended it to the policy."
          continue
        fi
        # usbguard's -p does an UPSERT and refuses when more than one existing
        # rule already matches the device -- which is what happens with two
        # identical hubs (same vendor:product, different port). Fall back to
        # appending this device's own full descriptor, hash and all, so the new
        # rule is unambiguous.
        line=$(usbguard list-devices 2>/dev/null | awk -v n="$d:" '$1==n')
        if [ -z "$line" ]; then
          die "allow failed for device $d, and it is no longer present"
        fi
        rule=$(printf '%s' "$line" | sed 's/^[0-9]\{1,\}: *//; s/^[a-z]\{1,\} /allow /')
        usbguard append-rule "$rule" \
          || die "allow failed for device $d and the fallback rule was rejected: $rule"
        usbguard allow-device "$d" >/dev/null 2>&1
        echo "Allowed device $d and appended an exact rule for it."
        echo "  ${rule}"
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
  trust)
    # Pre-authorise a device by vendor:product BEFORE it is plugged in.
    #
    # `allow` needs the device present, which does not work for hardware that
    # gives up when the host does not authorise it: the CRU WriteBlocker
    # disconnects about six seconds after enumerating unauthorised, so there is
    # a race to catch it. A policy rule authorises it the instant it appears,
    # with no window to lose.
    id="${2:-}"
    printf '%s' "$id" | grep -qiE '^[0-9a-f]{4}:[0-9a-f]{4}$' \
      || die "usage: it-usb trust <vendor:product> [serial]  e.g. it-usb trust 0e90:0064"
    serial="${3:-}"
    rule="allow id $id"
    [ -n "$serial" ] && rule="$rule serial \"$serial\""
    # Match the EXACT rule, not just the id. A serial-scoped rule for one unit
    # must not make a second unit of the same model look already-trusted: on
    # ASP-2 that left the replacement WriteBlocker unauthorised, and because it
    # gives up and disconnects after six seconds, `it-usb blocked` showed
    # nothing by the time anyone looked.
    if grep -qF "$rule" "$RULES" 2>/dev/null; then
      echo "Already trusted: $rule"; exit 0
    fi
    existing=$(grep -F "allow id $id" "$RULES" 2>/dev/null)
    if [ -n "$existing" ]; then
      echo "Note: $id is already covered by a NARROWER rule:"
      printf '%s\n' "$existing" | sed 's/^/  /'
      echo "Adding this one as well."
      echo
    fi
    cp -a "$RULES" "$RULES.bak-$(date +%Y%m%d-%H%M%S)"
    usbguard append-rule "$rule" || die "append-rule failed"
    echo "Trusted $id -- it is now authorised the moment it is connected."
    [ -n "$serial" ] && echo "  (restricted to serial $serial)"
    echo "Policy backup: $RULES.bak-*"
    echo
    echo "This is BROADER than allowing one enumerated device: any device"
    echo "presenting this vendor:product${serial:+ and serial} is accepted. Use it for"
    echo "standing equipment, not for one-off media."
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
