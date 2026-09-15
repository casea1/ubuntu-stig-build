#!/usr/bin/env bash
# LUKS / TPM auto-unlock status.
#
#   it-luks           the usual summary
#   it-luks check     a short report built to be transcribed off an air-gapped
#                     screen: which disk boots, its keyslots and tokens, whether
#                     a token points at a deleted slot, whether EVERY installed
#                     kernel's initramfs carries clevis, and whether the TPM can
#                     release a key right now.
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

# ---------------------------------------------------------------------------
# it-luks check -- a short report meant to be READ ALOUD or transcribed.
#
# The deployed boxes are air-gapped: nothing can be copied off them, so a
# diagnostic that needs a 40-line paste is a diagnostic nobody can act on. Every
# line here is one fact, short enough to read down a phone.
#
# It exists because the checks above only ever looked at the RUNNING kernel's
# initramfs. A box sitting on generic says "clevis initramfs: YES" while the
# FIPS kernel's initramfs -- the one that has to unlock the disk at the next
# boot -- may have no clevis in it at all, and nothing reported that.
# ---------------------------------------------------------------------------
if [ "${1:-}" = check ]; then
  echo "== LUKS PRE-FLIGHT =="
  [ -n "$LUKS" ] || { echo "  no LUKS device found"; exit 1; }
  root="$(luks_root_device 2>/dev/null)"
  printf '  device      : %s%s\n' "$LUKS" \
    "$([ "$LUKS" = "$root" ] && printf '  (holds /)' || printf '  (NOT the root disk)')"
  printf '  other disks : %s\n' "$(luks_all_devices | grep -vx "$LUKS" | paste -sd' ' - || true)"

  printf '  slots       : %s\n' \
    "$(cryptsetup luksDump "$LUKS" 2>/dev/null |
       awk '/^[[:space:]]*[0-9]+: luks2/{s=$1} /PBKDF:/{printf "%s%s ", s, $2}')"

  toks="$(cryptsetup luksDump "$LUKS" 2>/dev/null | awk '
      /^Tokens:/  { intok = 1; next }
      /^Digests:/ { intok = 0 }
      intok && /^[[:space:]]+[0-9]+:[[:space:]]*[^[:space:]]/ { t = $2; next }
      intok && /^[[:space:]]+Keyslot:/ { gsub(/[^0-9]/, "", $2); print $2 ":" t }')"
  printf '  tokens      : %s\n' "${toks:-none}"

  # A token pointing at a keyslot that was deleted is the failure that looks
  # like a wrong passphrase: the TPM has nothing to open, and the prompt that
  # follows is the only way in.
  for tk in $toks; do
    sl="${tk%%:*}"
    if cryptsetup luksDump "$LUKS" 2>/dev/null | grep -qE "^[[:space:]]*$sl: luks2"; then
      printf '  token slot %s: EXISTS\n' "$sl"
    else
      printf '  token slot %s: MISSING -- the token points at a deleted keyslot\n' "$sl"
    fi
  done

  # THE HEADER'S OWN HASHES, WHICH DECIDE WHETHER FIPS CAN READ IT AT ALL.
  #
  # A LUKS2 header names a hash for each keyslot (AF) and for each digest. If any
  # of them is blake2b, a FIPS kernel refuses the algorithm -- the kernel prints
  # "blake2b-256-generic is disabled due to fips" -- cryptsetup cannot verify the
  # header, and the device is reported as NOT A VALID LUKS DEVICE with no used
  # slots. Every passphrase is then rejected because nothing got as far as
  # checking one. This is invisible from a generic kernel, where blake2b works.
  hashes="$(cryptsetup luksDump "$LUKS" 2>/dev/null |
            awk -F: '/[Hh]ash:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | sort -u)"
  badh="$(printf '%s\n' "$hashes" | grep -v '^$' |
          grep -viE '^sha(1|224|256|384|512)$|^sha3-' | paste -sd' ' -)"
  printf '  header hashes : %s\n' "$(printf '%s\n' "$hashes" | grep -v '^$' | paste -sd' ' -)"
  if [ -n "$badh" ]; then
    printf '  HEADER HASH   : %s IS NOT FIPS-APPROVED -- a FIPS kernel cannot read\n' "$badh"
    printf '                  this header at all. It reports "not a valid LUKS\n'
    printf '                  device" and rejects every passphrase.\n'
  else
    printf '  header hashes : all FIPS-approved\n'
  fi

  printf '  TPM present : %s\n' "$([ -e /sys/class/tpm/tpm0 ] && echo yes || echo NO)"
  printf '  secure boot : %s\n' "$(mokutil --sb-state 2>/dev/null | tr -d '\n')"

  # EVERY installed kernel, not just the running one.
  for img in /boot/initrd.img-*; do
    [ -e "$img" ] || continue
    kv="${img#/boot/initrd.img-}"
    c=NO; lsinitramfs "$img" 2>/dev/null | grep -qi clevis && c=YES
    y=NO; lsinitramfs "$img" 2>/dev/null | grep -q 'cryptsetup' && y=YES
    printf '  initrd %-22s clevis=%s cryptsetup=%s\n' "$kv" "$c" "$y"
  done

  # Can the TPM actually release a key RIGHT NOW? Output is discarded: this
  # prints yes or no, never the passphrase it recovers.
  if command -v clevis >/dev/null 2>&1 && clevis luks pass --help >/dev/null 2>&1; then
    for tk in $toks; do
      sl="${tk%%:*}"
      if clevis luks pass -d "$LUKS" -s "$sl" >/dev/null 2>&1; then
        printf '  TPM unlock slot %s: WORKS NOW\n' "$sl"
      else
        printf '  TPM unlock slot %s: FAILS NOW\n' "$sl"
      fi
    done
  else
    echo "  TPM unlock  : cannot test (this clevis has no 'luks pass')"
  fi

  # Slots with no token behind them: the ones a person can type at a prompt.
  pbk="$(cryptsetup luksDump "$LUKS" 2>/dev/null |
    awk '/^[[:space:]]*[0-9]+: luks2/{s=$1; sub(":","",s)} /PBKDF:/{if ($2 ~ /pbkdf2/) print s}')"
  tokslots="$(printf '%s\n' $toks | cut -d: -f1 | grep -v '^$' || true)"
  if [ -n "$tokslots" ]; then
    typeable="$(printf '%s\n' "$pbk" | grep -vxF "$tokslots" | grep -v '^$' | paste -sd, -)"
  else
    typeable="$(printf '%s\n' "$pbk" | grep -v '^$' | paste -sd, -)"
  fi
  printf '  typeable pbkdf2 slots : %s\n' "${typeable:-NONE -- nothing can be typed at the prompt}"
  exit 0
fi

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
