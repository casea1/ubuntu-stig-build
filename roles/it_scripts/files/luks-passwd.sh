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

DEV="${1:-$(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null | head -1)}"
[ -n "$DEV" ] || die "No LUKS device found. Pass it explicitly: it-luks-passwd /dev/nvmeXn1pY"
cryptsetup isLuks "$DEV" 2>/dev/null || die "$DEV is not a LUKS device."

printf '\n%sChange the disk passphrase%s\n' "$B" "$R"
printf '  device    : %s\n' "$DEV"

# Show the slots, so someone who is about to change the only one can see that.
slots="$(cryptsetup luksDump "$DEV" 2>/dev/null | awk '/^[[:space:]]*[0-9]+: luks2/{n++} END{print n+0}')"
tpm="$(clevis luks list -d "$DEV" 2>/dev/null | grep -c tpm2 || true)"
printf '  keyslots  : %s\n' "${slots:-?}"
printf '  TPM slots : %s\n' "${tpm:-0}"

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

# luksChangeKey replaces the passphrase IN PLACE in its own slot. It refuses
# without the current passphrase, which is the behaviour we want: this is a
# rotation, not a recovery, and there is no recovery without a key.
if cryptsetup luksChangeKey "$DEV"; then
  printf '\n  %sOK%s   passphrase changed on %s\n' "$G" "$R" "$DEV"
  [ "${tpm:-0}" -gt 0 ] \
    && printf '  %sTPM auto-unlock is unaffected. Reboot to confirm it still unlocks itself.%s\n\n' "$DIM" "$R" \
    || printf '  %sReboot and confirm the new passphrase unlocks the disk BEFORE you release the machine.%s\n\n' "$Y" "$R"
else
  die "
passphrase NOT changed. The old one is still in place and nothing was removed.
Wrong current passphrase is the usual cause."
fi
