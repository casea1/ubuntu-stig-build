#!/usr/bin/env bash
# luks-rebind -- re-seal the LUKS TPM2 auto-unlock keyslot to the CURRENT PCR 7
# (Secure Boot state). Use when the box prompts for the LUKS passphrase at boot
# despite having a TPM binding -- i.e. a STALE binding after a Secure Boot or
# firmware/bootloader change moved PCR 7.
#
# SAFE: your passphrase keyslot is never touched. It binds a FRESH TPM2 slot
# first, and only then removes the old stale one -- so a wrong passphrase or a
# failed bind can never lock you out (you can always boot with the passphrase).
#
# Usage:   sudo it-luks-rebind [/dev/LUKSdev]     (device auto-detected if omitted)
#          LUKS_PCRS=7 LUKS_PCR_BANK=sha256 override the PCR set.
set -u
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

PCRS="${LUKS_PCRS:-7}"
BANK="${LUKS_PCR_BANK:-sha256}"
CFG="{\"pcr_bank\":\"$BANK\",\"pcr_ids\":\"$PCRS\"}"

DEV="${1:-$(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null | head -1)}"
[ -n "$DEV" ] || { echo "No LUKS device found. Pass it explicitly: $0 /dev/nvmeXn1pY"; exit 1; }

command -v clevis >/dev/null 2>&1 || { echo "clevis not installed."; exit 1; }

echo "LUKS device : $DEV"
echo "Seal to     : PCR $PCRS ($BANK)"
sb=$(mokutil --sb-state 2>/dev/null | tr -d '\n'); echo "Secure Boot : ${sb:-unknown}"
if ! echo "$sb" | grep -qi enabled; then
  echo "WARNING: Secure Boot is OFF -- a PCR 7 seal is not meaningful or stable without it."
  read -r -p "Continue anyway? [y/N] " a; case "$a" in y|Y) ;; *) echo "aborted"; exit 1;; esac
fi

echo
echo "Current clevis bindings:"
clevis luks list -d "$DEV" 2>/dev/null | sed 's/^/  /' || echo "  (none)"
before=$(clevis luks list -d "$DEV" 2>/dev/null | awk -F: '/tpm2/{gsub(/ /,"",$1);print $1}')

echo
read -r -p "Re-bind the TPM2 keyslot now (you will enter your LUKS passphrase once)? [y/N] " a
case "$a" in y|Y) ;; *) echo "aborted"; exit 1;; esac

echo ">> binding a fresh TPM2 keyslot to PCR $PCRS ..."
if ! clevis luks bind -d "$DEV" tpm2 "$CFG"; then
  echo "!! bind failed (wrong passphrase?). Nothing was removed; existing slots are intact."
  exit 1
fi

after=$(clevis luks list -d "$DEV" 2>/dev/null | awk -F: '/tpm2/{gsub(/ /,"",$1);print $1}')
for s in $before; do
  echo ">> removing old (stale) TPM2 keyslot $s"
  clevis luks unbind -d "$DEV" -s "$s" -f 2>/dev/null || echo "   (could not unbind slot $s; remove manually if needed)"
done

echo ">> rebuilding initramfs for all kernels ..."
if update-initramfs -u -k all >/dev/null 2>&1; then echo "   done"; else echo "   update-initramfs reported an issue"; fi

if [ -e /etc/luks/initial-passphrase ]; then
  rm -f /etc/luks/initial-passphrase && echo ">> removed leftover /etc/luks/initial-passphrase"
fi

echo
echo "Result:"
clevis luks list -d "$DEV" 2>/dev/null | sed 's/^/  /'
echo
echo "Done. REBOOT to confirm it unlocks without a passphrase prompt:  sudo reboot"
