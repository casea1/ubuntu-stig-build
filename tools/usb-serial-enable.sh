#!/usr/bin/env bash
# usb-serial-enable -- make an FTDI-based adapter the kernel does not recognise
# work on a plain Ubuntu box, persistently, for ordinary users.
#
# STANDALONE. Nothing from the ubuntu-stig-build baseline is needed; copy this
# one file to the machine and run it. Written for Ubuntu 22.04 VMs but the
# mechanism is the same on 20.04 and 24.04.
#
# THE PROBLEM. ftdi_sio drives any FTDI chip, but it only BINDS to vendor and
# product IDs compiled into its table. A vendor shipping an FTDI part under
# their own ID -- Sealevel does, 0c52:e402 for the SeaI/O U-series -- enumerates
# fine, appears in `lsusb`, and produces no /dev/ttyUSB* at all. Nothing logs an
# error. It looks exactly like a dead adapter or a bad cable.
#
# The ID has to be added to the driver's table at run time. That table lives in
# the MODULE, so it is lost on unload and on every reboot: a one-off
# `echo 0c52 e402 > /sys/bus/usb-serial/drivers/ftdi_sio/new_id` works until the
# next boot and then silently stops, which is worse than never working because
# it looks solved. Hence a service, not a command someone remembers to run.
#
#   sudo ./usb-serial-enable.sh                 install for the Sealevel default
#   sudo ./usb-serial-enable.sh 0c52:e402 ...   one or more <vid>:<pid>
#   sudo ./usb-serial-enable.sh --check         report only, change nothing
#   sudo ./usb-serial-enable.sh --uninstall     remove everything it installed
#
#   --group NAME   who may open the port (default: dialout)
#   --user  NAME   also add this user to that group (default: the sudo caller)
set -uo pipefail

DEFAULT_IDS="0c52:e402"          # Sealevel SeaI/O U-series (SeaI/O-440U)
DRIVER=ftdi_sio
GROUP=dialout
ADD_USER="${SUDO_USER:-}"
RULES=/etc/udev/rules.d/71-usb-serial-extra.rules
UNIT=/etc/systemd/system/usb-serial-bind.service
BINDER=/usr/local/sbin/usb-serial-bind
MODE=install
IDS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check)     MODE=check; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    --group)     GROUP="${2:?--group needs a name}"; shift 2 ;;
    --user)      ADD_USER="${2:?--user needs a name}"; shift 2 ;;
    -h|--help)   awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit 0 ;;
    -*)          echo "unknown option: $1" >&2; exit 1 ;;
    *)           IDS="$IDS $1"; shift ;;
  esac
done
IDS="$(printf '%s' "${IDS:-$DEFAULT_IDS}" | tr -s ' ')"
IDS="${IDS# }"

say()  { printf '%s\n' "$*"; }
ok()   { printf '  OK    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*" >&2; }
die()  { printf 'FAIL  %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

for spec in $IDS; do
  case "$spec" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
    *) die "expected <vid>:<pid> as 4 hex digits each, got '$spec'" ;;
  esac
done

# ---------------------------------------------------------------------------
if [ "$MODE" = uninstall ]; then
  say "Removing"
  systemctl disable --now usb-serial-bind.service 2>/dev/null
  rm -f "$UNIT" "$BINDER" "$RULES"
  systemctl daemon-reload 2>/dev/null
  udevadm control --reload-rules 2>/dev/null
  ok "removed the rule, the service and the binder"
  say "  ${ADD_USER:+(left $ADD_USER in $GROUP -- remove by hand if unwanted)}"
  exit 0
fi

say ""
say "USB serial adapter setup   ($IDS -> $DRIVER, group $GROUP)"
say ""

# ---- 1. is the device even visible? On a VM this is the usual answer --------
# A VM only sees a USB device that the hypervisor has been told to pass
# through. No amount of driver work helps until `lsusb` shows it, and this is
# by far the most common reason "the driver did not work" on a virtual machine.
missing_dev=0
for spec in $IDS; do
  if lsusb -d "$spec" >/dev/null 2>&1; then
    ok "$spec is attached"
  else
    warn "$spec is NOT attached"
    missing_dev=1
  fi
done
if [ "$missing_dev" -eq 1 ]; then
  say ""
  say "  If this is a VM, the hypervisor has to pass the device through first:"
  say "    VMware      VM Settings -> USB Controller -> connect the device,"
  say "                and USB 3.1 compatibility if it is a USB3 port"
  say "    VirtualBox  Devices -> USB -> tick the adapter (needs the Ext Pack)"
  say "    KVM/libvirt virsh attach-device, or a <hostdev> USB entry in the XML"
  say "  Everything below still installs -- it will take effect when it appears."
  say ""
fi

# ---- 2. is the driver present at all? --------------------------------------
# On Ubuntu the usb-serial drivers live in linux-modules-extra, which cloud and
# minimal VM images frequently do NOT have. `modprobe ftdi_sio` then fails with
# "module not found" and the obvious reading -- the driver is broken -- is wrong.
if modprobe "$DRIVER" 2>/dev/null; then
  ok "$DRIVER loaded"
elif modinfo "$DRIVER" >/dev/null 2>&1; then
  die "$DRIVER exists but will not load -- see: dmesg | tail"
else
  bad "$DRIVER is not available on this kernel"
  say ""
  say "  Ubuntu ships the usb-serial drivers in linux-modules-extra, which a"
  say "  cloud or minimal VM image often does not install:"
  say "    sudo apt install linux-modules-extra-\$(uname -r)"
  say "  then run this again."
  exit 2
fi

[ "$MODE" = check ] && {
  say ""
  for spec in $IDS; do
    v="${spec%%:*}"; p="${spec##*:}"
    if grep -qis "$v.*$p" "/sys/bus/usb-serial/drivers/$DRIVER/new_id" 2>/dev/null; then :; fi
  done
  ls -l /dev/ttyUSB* 2>/dev/null | sed 's/^/  /' || say "  no /dev/ttyUSB* present"
  [ -f "$UNIT" ]  && ok "bind service installed" || warn "bind service NOT installed"
  [ -f "$RULES" ] && ok "udev rule installed"    || warn "udev rule NOT installed"
  say ""
  exit 0
}

# ---- 3. the binder -----------------------------------------------------------
getent group "$GROUP" >/dev/null 2>&1 || { groupadd "$GROUP" && ok "created group $GROUP"; }

cat > "$BINDER" <<EOF
#!/bin/sh
# Installed by usb-serial-enable.sh -- do not edit by hand.
# Adds vendor/product IDs to $DRIVER's table. The table is in the MODULE, so
# this has to run after every boot, not once at install time.
modprobe $DRIVER 2>/dev/null || exit 0
for id in $IDS; do
  printf '%s %s\n' "\${id%%:*}" "\${id##*:}" > /sys/bus/usb-serial/drivers/$DRIVER/new_id 2>/dev/null
done
exit 0
EOF
chmod 0755 "$BINDER"; chown root:root "$BINDER"
ok "binder at $BINDER"

# ---- 4. the service ----------------------------------------------------------
cat > "$UNIT" <<EOF
# Installed by usb-serial-enable.sh -- do not edit by hand.
[Unit]
Description=Add unrecognised USB serial IDs to $DRIVER's table
After=systemd-udevd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BINDER

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now usb-serial-bind.service >/dev/null 2>&1 \
  && ok "usb-serial-bind.service enabled and run" \
  || warn "could not enable usb-serial-bind.service"

# ---- 5. udev: re-bind on hotplug, and let a normal user open the port --------
{
  echo "# Installed by usb-serial-enable.sh -- do not edit by hand."
  echo "#"
  echo "# SYSTEMD_WANTS rather than RUN+=: writing new_id makes the kernel re-probe"
  echo "# and emit fresh uevents while udev is still processing this one, and udev"
  echo "# kills a RUN that runs long. The service does the work off the event path."
  echo "#"
  echo "# MODE 0660 + group, never 0666: a world-writable device node is a finding"
  echo "# on a hardened box and buys nothing over a group."
  for spec in $IDS; do
    v="${spec%%:*}"; p="${spec##*:}"
    echo ""
    echo "ACTION==\"add\", SUBSYSTEM==\"usb\", ATTR{idVendor}==\"$v\", ATTR{idProduct}==\"$p\", TAG+=\"systemd\", ENV{SYSTEMD_WANTS}+=\"usb-serial-bind.service\""
    echo "SUBSYSTEM==\"tty\", ATTRS{idVendor}==\"$v\", ATTRS{idProduct}==\"$p\", MODE=\"0660\", GROUP=\"$GROUP\", SYMLINK+=\"serial/usb-$v-$p\""
  done
} > "$RULES"
chmod 0644 "$RULES"
udevadm control --reload-rules 2>/dev/null
udevadm trigger --subsystem-match=usb --action=add 2>/dev/null
ok "udev rule at $RULES"

# ---- 6. the user --------------------------------------------------------------
if [ -n "$ADD_USER" ] && id "$ADD_USER" >/dev/null 2>&1; then
  if id -nG "$ADD_USER" | tr ' ' '\n' | grep -qx "$GROUP"; then
    ok "$ADD_USER is already in $GROUP"
  else
    usermod -aG "$GROUP" "$ADD_USER" && ok "added $ADD_USER to $GROUP"
    warn "$ADD_USER must log out and back in for that to take effect"
  fi
fi

# ---- 7. did it work ----------------------------------------------------------
say ""
sleep 1
found=0
for dev in /dev/ttyUSB*; do
  [ -e "$dev" ] || continue
  found=1
  printf '  OK    %s  %s\n' "$dev" "$(stat -c '%a %U:%G' "$dev")"
done
if [ "$found" -eq 0 ]; then
  if [ "$missing_dev" -eq 1 ]; then
    warn "no /dev/ttyUSB* yet -- expected, the device is not attached"
  else
    warn "no /dev/ttyUSB* yet -- unplug and re-plug the adapter"
    say  "        the driver picks up a new ID at the next CONNECT, not retroactively"
  fi
fi
say ""
say "  Survives reboots. Check any time:  sudo $0 --check"
say "  Undo:                              sudo $0 --uninstall"
say ""
