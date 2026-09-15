#!/usr/bin/env bash
# it-luks-passwd -- change the LUKS disk passphrase on this machine.
#
# The passphrase set during imaging is TEMPORARY, like every other credential
# set at that stage. This is how it is replaced at deployment.
#
# Usage:  sudo it-luks-passwd [/dev/LUKSdev]     (device auto-detected if omitted)
#
# WHAT THIS DOES NOT AFFECT: the TPM auto-unlock. LUKS keyslots are independent
# of one another, so replacing the passphrase in its slot leaves the clevis/TPM2
# slot alone and the machine still unlocks itself at boot. `it-luks-rebind` is
# for a different fault, a STALE TPM binding after Secure Boot or firmware moved
# PCR 7, and is not needed after a passphrase change.
#
# WHAT IS UNRECOVERABLE: losing every passphrase AND the TPM binding. Either one
# alone is survivable, which is why the old passphrase is required below rather
# than assumed lost.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; Y=$'\033[33m'; RD=$'\033[31m'; G=$'\033[32m'; R=$'\033[0m'
else B=""; DIM=""; Y=""; RD=""; G=""; R=""; fi
die() { printf '%s%s%s\n' "$RD" "$*" "$R" >&2; exit 1; }

case "${1:-}" in
  -h|--help|help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
esac

command -v cryptsetup >/dev/null 2>&1 || die "cryptsetup is not installed."

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

DEV="$(luks_pick_device "${1:-}")" || die "This box has more than one encrypted disk and none of them
holds the root filesystem, so there is nothing safe to guess. Name it:
  sudo it-luks-passwd /dev/nvmeXn1pY
$(for d in $(luks_all_devices); do printf '  %s\n' "$d"; done)"
[ -n "$DEV" ] || die "No LUKS device found. Pass it explicitly: it-luks-passwd /dev/nvmeXn1pY"
cryptsetup isLuks "$DEV" 2>/dev/null || die "$DEV is not a LUKS device."

printf '\n%sChange the disk passphrase%s\n' "$B" "$R"
printf '  device    : %s%s\n' "$DEV" \
  "$([ "$DEV" = "$(luks_root_device 2>/dev/null)" ] && printf '   <- holds /, the disk this box boots')"

# Show the slots, so someone who is about to change the only one can see that.
slots="$(cryptsetup luksDump "$DEV" 2>/dev/null | awk '/^[[:space:]]*[0-9]+: luks2/{n++} END{print n+0}')"
tpm="$(clevis luks list -d "$DEV" 2>/dev/null | grep -c tpm2 || true)"
printf '  keyslots  : %s\n' "${slots:-?}"
printf '  TPM slots : %s\n' "${tpm:-0}"

# Report the KDF per slot, and say so loudly if one is argon2 on a box that has
# a FIPS kernel to boot into. See the note above luksChangeKey.
kdfs="$(cryptsetup luksDump "$DEV" 2>/dev/null |
        awk '/^[[:space:]]*[0-9]+: luks2/{s=$1} /PBKDF:/{printf "%s%s ", s, $2}')"
[ -n "$kdfs" ] && printf '  KDF/slot  : %s\n' "$kdfs"
if printf '%s' "$kdfs" | grep -qi argon && ls /boot/vmlinuz-*-fips >/dev/null 2>&1; then
  printf '\n  %sWARNING: a keyslot uses argon2, and this box has a FIPS kernel.%s\n' "$Y" "$R"
  printf '  %sArgon2 is not FIPS-approved. Such a slot may not unlock under the%s\n' "$DIM" "$R"
  printf '  %sFIPS kernel -- which you would discover at a boot prompt. The slot%s\n' "$DIM" "$R"
  printf '  %sthis changes is rewritten with pbkdf2; the others are NOT touched.%s\n' "$DIM" "$R"
fi

if [ "${tpm:-0}" -gt 0 ]; then
  printf '\n  %sThe TPM auto-unlock slot is separate and is NOT touched.%s\n' "$DIM" "$R"
  printf '  %sThis machine will keep unlocking itself at boot.%s\n' "$DIM" "$R"
else
  printf '\n  %sNo TPM slot on this device: the passphrase is the only way in.%s\n' "$Y" "$R"
fi

printf '\n  You will be asked for the CURRENT passphrase, then the new one twice.\n'
read -r -p "  Change it now? [y/N] " a
case "$a" in y|Y) ;; *) echo "  aborted -- nothing was changed"; exit 1 ;; esac
echo

# --pbkdf pbkdf2 IS NOT OPTIONAL ON THIS FLEET.
#
# LUKS2 defaults a new keyslot to argon2id. Argon2 is not a FIPS-approved KDF,
# so cryptsetup running under a FIPS kernel restricts itself to PBKDF2 -- which
# means a passphrase rotated while the box happened to be on a GENERIC kernel
# can produce a keyslot the FIPS kernel cannot process. You find out at the next
# boot, at the passphrase prompt, with no shell. Forcing pbkdf2 makes the slot
# work under both.
#
# luksChangeKey replaces the passphrase IN PLACE in its own slot. It refuses
# without the current passphrase, which is the behaviour we want: this is a
# rotation, not a recovery, and there is no recovery without a key.
if cryptsetup luksChangeKey --pbkdf pbkdf2 "$DEV"; then
  # RECORD IT. A LUKS2 header has no per-keyslot timestamp -- the format has no
  # field for one -- so "was this rotated after deployment?" is unanswerable
  # unless something writes it down at the time. This is that something.
  install -d -m 0755 /etc/stig-build 2>/dev/null || true
  printf '%s %s %s\n' "$(date -Is)" "${SUDO_USER:-$(id -un)}" "$DEV" \
    >> /etc/stig-build/credential-changes.log 2>/dev/null || true
  chmod 0644 /etc/stig-build/credential-changes.log 2>/dev/null || true
  printf '\n  %sOK%s   passphrase changed on %s\n' "$G" "$R" "$DEV"
  [ "${tpm:-0}" -gt 0 ] \
    && printf '  %sTPM auto-unlock is unaffected. Reboot to confirm it still unlocks itself.%s\n\n' "$DIM" "$R" \
    || printf '  %sReboot and confirm the new passphrase unlocks the disk BEFORE you release the machine.%s\n\n' "$Y" "$R"
else
  die "
passphrase NOT changed. The old one is still in place and nothing was removed.
Wrong current passphrase is the usual cause."
fi
