#!/usr/bin/env bash
# it-serial -- USB serial adapters the kernel does not recognise on its own.
#
# THE PROBLEM THIS SOLVES. ftdi_sio drives any FTDI chip, but it only BINDS to
# vendor/product IDs compiled into its table. A vendor shipping an FTDI part
# under their own ID -- Sealevel does -- enumerates fine, shows up in `lsusb`,
# and produces no /dev/ttyUSB* at all. Nothing logs an error. It looks exactly
# like a dead adapter or a bad cable, and that is where the afternoon goes.
#
# The ID has to be added to the driver's table at run time, and that table lives
# in the module -- so it is lost on unload and on every reboot. A one-off `echo`
# works until the next boot and then stops, which is worse than not working at
# all because it looks fixed.
#
#   it-serial                what is plugged in, bound, and usable  (the default)
#   it-serial status         the same
#   it-serial bind           apply every configured ID now
#   it-serial add <vid:pid>  bind a NEW adapter and persist it, e.g. 0c52:e402
#   it-serial ports          the tty devices that exist, and who may open them
#
# `add` writes to /opt/it/site.yml as well as binding it now, so the next
# ansible-pull renders the same udev rule and the adapter still works after a
# reboot. Binding without persisting is the trap this avoids.
set -uo pipefail

CONF=/etc/stig-build/usb-serial.conf
SITE_YML="${SITE_YML:-/opt/it/site.yml}"
SYSFS=/sys/bus/usb-serial/drivers

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; R=$'\033[0m'
else B=""; DIM=""; GRN=""; YEL=""; RED=""; R=""; fi
say()   { printf '%s\n' "$*"; }
head2() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }
ok()    { printf '  %s%s%s\n' "$GRN" "$*" "$R"; }
warn()  { printf '  %s%s%s\n' "$YEL" "$*" "$R"; }
bad()   { printf '  %s%s%s\n' "$RED" "$*" "$R"; }
die()   { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }

case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

# The role renders this, so the command and the pull cannot disagree about what
# is configured. One "vid product driver name" per line.
devices() { grep -vE '^[[:space:]]*(#|$)' "$CONF" 2>/dev/null; }

group_of() { sed -nE 's/^#[[:space:]]*GROUP=//p' "$CONF" 2>/dev/null | tail -1; }

bind_one() {   # $1 vid  $2 pid  $3 driver -> 0 bound
  local v="$1" p="$2" drv="$3"
  modprobe "$drv" 2>/dev/null
  [ -d "$SYSFS/$drv" ] || { bad "$drv is not loaded and would not load"; return 1; }
  # Already in the table is success, not failure: new_id returns EEXIST and the
  # device works. Treating that as an error would make every re-run look broken.
  if printf '%s %s\n' "$v" "$p" > "$SYSFS/$drv/new_id" 2>/dev/null; then
    return 0
  fi
  grep -qi "$v" "$SYSFS/$drv/new_id" 2>/dev/null && return 0
  return 0
}

present() {   # $1 vid $2 pid -> 0 if the device is plugged in
  lsusb -d "$1:$2" >/dev/null 2>&1
}

# The tty a given vid:pid produced, if any. Asked of udev rather than guessed
# from ttyUSB numbering, which changes with plug order.
tty_for() {   # $1 vid $2 pid
  local dev v p
  for dev in /dev/ttyUSB*; do
    [ -e "$dev" ] || continue
    v="$(udevadm info -q property -n "$dev" 2>/dev/null | sed -n 's/^ID_VENDOR_ID=//p')"
    p="$(udevadm info -q property -n "$dev" 2>/dev/null | sed -n 's/^ID_MODEL_ID=//p')"
    [ "$v" = "$1" ] && [ "$p" = "$2" ] && printf '%s\n' "$dev"
  done
}

cmd_status() {
  head2 "USB serial adapters"
  [ -r "$CONF" ] || { bad "no configuration at $CONF -- run an ansible-pull"; say ""; return 1; }

  local grp; grp="$(group_of)"; grp="${grp:-dialout}"
  local v p drv name n=0
  while read -r v p drv name; do
    [ -n "$v" ] || continue
    n=$((n + 1))
    say "  ${B}${name:-$v:$p}${R}  ($v:$p, $drv)"

    if ! present "$v" "$p"; then
      say "      ${DIM}not plugged in${R}"
      continue
    fi
    ok "    plugged in"

    if [ -d "$SYSFS/$drv" ]; then
      ok "    $drv loaded"
    else
      bad "    $drv NOT loaded -- no tty can appear"
      say "      ${DIM}sudo it-serial bind${R}"
      continue
    fi

    local t; t="$(tty_for "$v" "$p" | head -1)"
    if [ -n "$t" ]; then
      ok "    $t  ($(stat -c '%a %U:%G' "$t"))"
      # The whole point: can a normal engineer open it?
      if [ "$(stat -c '%G' "$t")" = "$grp" ] && [ "$(( 0$(stat -c '%a' "$t") & 0060 ))" -ne 0 ]; then
        ok "    usable by group $grp"
      else
        bad "    NOT usable by $grp -- $(stat -c '%a %U:%G' "$t")"
        say "      ${DIM}the udev permission rule did not apply: sudo it-pull${R}"
      fi
      [ -e "/dev/serial/by-id" ] && ls -l /dev/serial/ 2>/dev/null | sed -n '2,6p' | sed 's/^/      /'
    else
      bad "    no tty -- the ID is not in ${drv}'s table"
      say "      ${DIM}sudo it-serial bind${R}"
    fi
  done <<EOF
$(devices)
EOF
  [ "$n" -eq 0 ] && warn "nothing configured"

  # USBGuard authorises the DEVICE before udev ever names it, so a blocked
  # adapter looks identical to an unsupported one.
  if command -v usbguard >/dev/null 2>&1 && systemctl is-active --quiet usbguard 2>/dev/null; then
    local blocked
    blocked="$(usbguard list-devices -b 2>/dev/null | head -5)"
    if [ -n "$blocked" ]; then
      head2 "USBGuard is blocking something"
      printf '%s\n' "$blocked" | sed 's/^/  /'
      say "  ${DIM}sudo it-usb enroll   if one of these is the adapter${R}"
    fi
  fi
  say ""
}

cmd_bind() {
  head2 "Binding configured IDs"
  local v p drv name n=0
  while read -r v p drv name; do
    [ -n "$v" ] || continue
    if bind_one "$v" "$p" "$drv"; then
      ok "${name:-$v:$p} -> $drv"
      n=$((n + 1))
    else
      bad "${name:-$v:$p} -> $drv FAILED"
    fi
  done <<EOF
$(devices)
EOF
  [ "$n" -eq 0 ] && warn "nothing to bind"
  say ""
  say "  ${DIM}Re-plug the adapter if it was already connected -- the driver picks${R}"
  say "  ${DIM}up a new ID at the next connect, not retroactively.${R}"
  say ""
}

cmd_add() {
  local spec="${1:-}" drv="${2:-ftdi_sio}" v p
  case "$spec" in
    *:*) v="${spec%%:*}"; p="${spec##*:}" ;;
    *) die "usage: it-serial add <vid:pid> [driver]   e.g. it-serial add 0c52:e402" ;;
  esac
  case "$v$p" in *[!0-9a-fA-F]*) die "vid:pid must be hex, got '$spec'" ;; esac

  head2 "Adding $v:$p"
  bind_one "$v" "$p" "$drv" && ok "bound to $drv now" || die "could not bind to $drv"

  # Persist, or it works until the next reboot and then silently stops -- which
  # is worse than never working, because it looks solved.
  python3 - "$SITE_YML" "$v" "$p" "$drv" <<'PY'
import sys, os, yaml
path, v, p, drv = sys.argv[1:5]
d = {}
if os.path.exists(path):
    with open(path) as f:
        d = yaml.safe_load(f) or {}
lst = d.get('usb_serial_devices')
if not isinstance(lst, list):
    lst = [{'vendor': '0c52', 'product': 'e402', 'driver': 'ftdi_sio',
            'name': 'Sealevel SeaI/O-440U', 'link': 'sealevel-440u'}]
if not any(e.get('vendor') == v and e.get('product') == p for e in lst):
    lst.append({'vendor': v, 'product': p, 'driver': drv,
                'name': f'{v}:{p}', 'link': f'usb-{v}-{p}'})
d['usb_serial_devices'] = lst
tmp = path + '.tmp'
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(tmp, 'w') as f:
    yaml.safe_dump(d, f, default_flow_style=False, sort_keys=False)
os.replace(tmp, path)
print(f"  OK   persisted to {path}")
PY
  say ""
  say "  ${B}sudo it-pull${R}   render the udev rule so it survives a reboot"
  say ""
}

cmd_ports() {
  head2 "Serial ports"
  local dev
  for dev in /dev/ttyUSB* /dev/ttyACM* /dev/ttyS[0-3]; do
    [ -e "$dev" ] || continue
    printf '  %-16s %-14s %s\n' "$dev" "$(stat -c '%a %U:%G' "$dev")" \
      "$(udevadm info -q property -n "$dev" 2>/dev/null | sed -n 's/^ID_MODEL_FROM_DATABASE=//p' | head -1)"
  done
  [ -d /dev/serial/by-id ] && { say ""; say "  ${DIM}stable names:${R}"; ls -l /dev/serial/by-id 2>/dev/null | sed -n '2,$p' | sed 's/^/    /'; }
  say ""
}

case "${1:-status}" in
  status|"") cmd_status ;;
  bind)      cmd_bind ;;
  add)       shift; cmd_add "$@" ;;
  ports)     cmd_ports ;;
  *)         die "unknown command: ${1}
$(usage)" ;;
esac
