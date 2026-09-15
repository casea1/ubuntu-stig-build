#!/usr/bin/env bash
# LUKS / TPM auto-unlock status.
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"
KREL=$(uname -r)
# --- shared: which encrypted disk does this box actually boot from? ---------
#
# `blkid -t TYPE=crypto_LUKS -o device | head -1` is the idiom and it is WRONG
# on this fleet. These workstations have two NVMe drives, the OS is not always
# the first one blkid lists (on dev-15 it is nvme1n1p3, with a spare at
# nvme0n1p3), and a passphrase or a keyslot edit aimed at the wrong disk looks
# like it worked while changing nothing that boots. Prefer, in order: the disk
# the root filesystem is stacked on, then whatever /etc/crypttab names, then --
# only if there is exactly one -- the single LUKS device on the box.
luks_all_devices() { blkid -t TYPE=crypto_LUKS -o device 2>/dev/null; }

luks_root_device() {
  local rootsrc d
  rootsrc="$(findmnt -no SOURCE / 2>/dev/null)"
  [ -n "$rootsrc" ] || return 1
  rootsrc="$(basename "$(readlink -f "$rootsrc" 2>/dev/null)")"
  [ -n "$rootsrc" ] || return 1
  for d in $(luks_all_devices); do
    lsblk -no KNAME "$d" 2>/dev/null | grep -qx "$rootsrc" && { printf '%s' "$d"; return 0; }
  done
  return 1
}

luks_crypttab_device() {
  local name src rest d
  [ -r /etc/crypttab ] || return 1
  while read -r name src rest; do
    case "$name" in ''|\#*) continue ;; esac
    case "$src" in
      UUID=*) d="$(blkid -U "${src#UUID=}" 2>/dev/null)" ;;
      /dev/*) d="$src" ;;
      *)      d="" ;;
    esac
    [ -n "$d" ] && { printf '%s' "$d"; return 0; }
  done < /etc/crypttab
  return 1
}

# $1 = a device the caller was given, or empty.
luks_pick_device() {
  local given="${1:-}" d n
  if [ -n "$given" ]; then printf '%s' "$given"; return 0; fi
  d="$(luks_root_device)"     && { printf '%s' "$d"; return 0; }
  d="$(luks_crypttab_device)" && { printf '%s' "$d"; return 0; }
  n="$(luks_all_devices | wc -l)"
  [ "$n" -eq 1 ] && { luks_all_devices | tr -d '\n'; return 0; }
  return 1
}

LUKS=$(luks_pick_device "") || LUKS=""
sb=$(mokutil --sb-state 2>/dev/null | tr -d '\n')
init=NO; lsinitramfs "/boot/initrd.img-$KREL" 2>/dev/null | grep -qi clevis && init=YES
bind=""; [ -n "$LUKS" ] && bind=$(clevis luks list -d "$LUKS" 2>/dev/null | grep tpm2)

echo "== LUKS / TPM AUTO-UNLOCK =="
printf '  LUKS device      : %s\n' "${LUKS:-NONE FOUND}"
printf '  secure boot      : %s\n' "${sb:-unknown}"
printf '  TPM present      : '; [ -e /sys/class/tpm/tpm0 ] && echo yes || echo "NO"
printf '  clevis initramfs : %s\n' "$init"
printf '  TPM binding      : %s\n' "${bind:-none}"
printf '  passphrase file  : '; [ -e /etc/luks/initial-passphrase ] && echo "PRESENT (bind may not have run / purge disabled)" || echo "absent (purged after bind, as expected)"

echo -n "  VERDICT          : "
if [ -n "$bind" ] && [ "$init" = YES ] && echo "$sb" | grep -qi enabled; then
  echo "configured. Reboot to confirm it boots WITHOUT a passphrase prompt."
  echo "                     (If it STILL prompts, the binding is stale for the current PCR 7 -> run it-luks-rebind.)"
elif [ -n "$bind" ] && ! echo "$sb" | grep -qi enabled; then
  echo "bound, but SECURE BOOT IS OFF -> PCR7 seal invalid. Enable Secure Boot, then run it-luks-rebind."
elif [ -n "$bind" ] && [ "$init" != YES ]; then
  echo "bound, but clevis missing from THIS kernel's initramfs -> run: update-initramfs -u -k all ; reboot"
else
  echo "NOT set up (no TPM binding). Stage /etc/luks/initial-passphrase + run the build, or run it-luks-rebind."
fi
