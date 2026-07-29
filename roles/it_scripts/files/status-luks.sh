#!/usr/bin/env bash
# LUKS / TPM auto-unlock status.
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"
KREL=$(uname -r)
LUKS=$(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null | head -1)
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
