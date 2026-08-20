#!/usr/bin/env bash
# it-grub -- check, set, or remove the GRUB2 bootloader password.
#
# WHAT IT PROTECTS: editing a GRUB menu entry (`e`) or the GRUB shell (`c`).
# Without it, anyone at the console appends init=/bin/bash to the kernel command
# line and gets a root shell -- no password anywhere.
#
# WHY IT IS NOT REDUNDANT WITH LUKS ON THIS FLEET: the LUKS key is TPM-sealed to
# PCR 7 (Secure Boot state) with no PIN. PCR 7 does NOT measure the kernel
# command line, so editing it does not change the PCR -- the TPM releases the key
# and the disk auto-decrypts. This password is the only control between physical
# access and a root shell on decrypted data.
#
# Usage:
#   it-grub status      what is configured now, and whether it will pass the scan
#   it-grub set         generate a password + apply it to THIS box (interactive)
#   it-grub hash        just print a PBKDF2 hash to vault for fleet-wide rollout
#   it-grub remove      remove the password from this box (recovery)
#
# FLEET vs ONE BOX:
#   `it-grub hash` -> vault the token into group_vars (grub_password_pbkdf2) so
#   the grub_password role applies it to every box on the next pull. That is the
#   supported path. `it-grub set` is for activating one box immediately; the
#   role SKIPS while group_vars still holds the CHANGEME sentinel, so a locally
#   set password is not clobbered -- but once you vault a hash, the role wins.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

DROPIN=/etc/grub.d/01_superusers
CFG=/boot/grub/grub.cfg
LINUX_TPL=/etc/grub.d/10_linux
SUPERUSER="${GRUB_SUPERUSER:-bootadmin}"
ok(){ printf '  \033[32mOK\033[0m   %s\n' "$1"; }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
wa(){ printf '  \033[33mWARN\033[0m %s\n' "$1"; }

status() {
  echo "GRUB bootloader password status"
  echo
  local rc=0
  if [ -f "$DROPIN" ]; then ok "drop-in present: $DROPIN"; else no "no drop-in at $DROPIN -- no password configured"; rc=1; fi

  if grep -q '^\s*set superusers=' "$CFG" 2>/dev/null; then
    local su; su=$(sed -n 's/^\s*set superusers="\?\([^"]*\)"\?.*/\1/p' "$CFG" | head -1)
    ok "superusers set in grub.cfg: $su"
    # SSG's OVAL accepts letters/underscore ONLY -- a digit or hyphen gives a
    # working password that still fails the scan.
    if printf '%s' "$su" | grep -qE '^[a-zA-Z_]+$'; then ok "superuser name passes the SSG regex ([a-zA-Z_]+)"
    else no "superuser '$su' has characters SSG rejects -- the scan will fail even though the password works"; rc=1; fi
  else no "no 'set superusers=' in $CFG"; rc=1; fi

  if grep -q '^\s*password_pbkdf2' "$CFG" 2>/dev/null; then ok "password_pbkdf2 present in grub.cfg"
  else no "no password_pbkdf2 in $CFG"; rc=1; fi

  # The one that breaks unattended reboot if wrong.
  local total restricted
  # grep -c already prints 0 and exits 1 when there are no matches, so `|| echo 0`
  # would emit "0\n0" and break the arithmetic below. `|| true` is what is wanted.
  total=$(grep -cE '^\s*menuentry ' "$CFG" 2>/dev/null || true); total=${total:-0}
  restricted=$(grep -E '^\s*menuentry ' "$CFG" 2>/dev/null | grep -cv -- '--unrestricted' || true); restricted=${restricted:-0}
  if [ "$total" -eq 0 ]; then no "no menu entries found in $CFG (?)"; rc=1
  elif [ "${restricted:-0}" -gt 0 ]; then
    no "$restricted of $total menu entries lack --unrestricted -- EVERY BOOT WILL PROMPT for the password"
    wa "fix: sudo it-grub set   (re-applies --unrestricted and regenerates safely)"; rc=1
  else ok "all $total menu entries are --unrestricted (normal boot needs no password)"; fi

  local perm; perm=$(stat -c '%a' "$CFG" 2>/dev/null)
  if [ "$perm" = "600" ]; then ok "grub.cfg permissions $perm"; else wa "grub.cfg permissions $perm (STIG wants 0600)"; fi

  [ -f "$CFG.pre-grubpw" ] && ok "recovery copy present: $CFG.pre-grubpw"
  echo
  [ "$rc" = 0 ] && echo "RESULT: bootloader password is configured correctly." \
                || echo "RESULT: NOT fully configured -- see FAIL lines above."
  return "$rc"
}

make_hash() {
  command -v grub-mkpasswd-pbkdf2 >/dev/null || { echo "grub-mkpasswd-pbkdf2 not found (apt install grub-common)" >&2; exit 1; }
  echo "You will be asked for the GRUB password twice. It is NOT a Linux account;"
  echo "it only gates editing boot entries. Store it in your password vault."
  echo
  local out hash
  out=$(grub-mkpasswd-pbkdf2) || exit 1
  hash=$(printf '%s' "$out" | grep -o 'grub\.pbkdf2\.sha512\.[0-9]*\.[0-9A-Fa-f]*\.[0-9A-Fa-f]*' | head -1)
  [ -n "$hash" ] || { echo "could not parse a hash out of grub-mkpasswd-pbkdf2" >&2; exit 1; }
  printf '%s' "$hash"
}

apply() { # $1 = hash
  local hash="$1"
  umask 077
  cat > "$DROPIN" <<EOF
#!/bin/sh
# Written by it-grub. The grub_password ansible role writes the same file.
cat <<'INNER'
set superusers="$SUPERUSER"
password_pbkdf2 $SUPERUSER $hash
INNER
EOF
  chmod 0700 "$DROPIN"

  # Without --unrestricted, setting superusers makes EVERY entry require the
  # password -- unattended reboot would be impossible.
  grep -q -- '--unrestricted' "$LINUX_TPL" || sed -i 's/^CLASS="/CLASS="--unrestricted /' "$LINUX_TPL"

  echo "Generating a candidate grub.cfg (not installing it yet)..."
  grub-mkconfig -o /tmp/grub.cfg.candidate >/dev/null 2>&1 || { echo "grub-mkconfig failed" >&2; rm -f "$DROPIN"; exit 1; }

  # Refuse to install anything that would hang the next boot.
  local total restricted
  total=$(grep -cE '^\s*menuentry ' /tmp/grub.cfg.candidate 2>/dev/null || true); total=${total:-0}
  restricted=$(grep -E '^\s*menuentry ' /tmp/grub.cfg.candidate 2>/dev/null | grep -cv -- '--unrestricted' || true); restricted=${restricted:-0}
  if ! grep -q password_pbkdf2 /tmp/grub.cfg.candidate || [ "$total" -eq 0 ] || [ "${restricted:-0}" -gt 0 ]; then
    echo "REFUSING to install: credential=$(grep -qc password_pbkdf2 /tmp/grub.cfg.candidate && echo yes || echo no) entries=$total restricted=$restricted" >&2
    echo "Candidate left at /tmp/grub.cfg.candidate; $CFG untouched; drop-in removed." >&2
    rm -f "$DROPIN"; exit 1
  fi

  [ -f "$CFG.pre-grubpw" ] || cp -a "$CFG" "$CFG.pre-grubpw"
  install -o root -g root -m 0600 /tmp/grub.cfg.candidate "$CFG"
  rm -f /tmp/grub.cfg.candidate
  echo "Applied. Normal boot needs no password; editing an entry now does."
  echo "Recovery copy: $CFG.pre-grubpw"
}

case "${1:-status}" in
  status) status ;;
  hash)
    h=$(make_hash) || exit 1
    echo; echo "PBKDF2 token (vault this, do NOT commit it in the clear):"; echo "  $h"; echo
    echo "Fleet rollout:"
    echo "  ansible-vault encrypt_string '$h' --name 'grub_password_pbkdf2'"
    echo "  ...then paste the !vault block over grub_password_pbkdf2 in group_vars/all.yml"
    ;;
  set)
    h=$(make_hash) || exit 1
    apply "$h"
    echo; echo "This box only. For the fleet, vault the hash -- see: it-grub hash"
    ;;
  remove)
    echo "This removes the GRUB password from THIS box (recovery use)."
    printf 'Continue? [y/N] '; read -r a; [ "$a" = y ] || { echo aborted; exit 0; }
    rm -f "$DROPIN"
    grub-mkconfig -o "$CFG" >/dev/null 2>&1 && chmod 0600 "$CFG"
    echo "Removed. NOTE: the grub_password role re-applies it on the next"
    echo "ansible-pull if a real hash is vaulted in group_vars."
    ;;
  help|-h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown command '$1' -- try: it-grub help" >&2; exit 2 ;;
esac
