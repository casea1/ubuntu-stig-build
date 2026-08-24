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

# grub-mkpasswd-pbkdf2 writes its "Enter password:" prompts to STDOUT, not
# stderr. Running it as `out=$(grub-mkpasswd-pbkdf2)` therefore captures the
# prompts along with the hash and the terminal shows NOTHING -- the command
# looks hung when it is actually waiting for a password nobody can see. That is
# what it did, and it cost someone a hard reset mid-run.
#
# So: prompt here, on stderr where it is always visible, and feed the answer in
# on stdin. Piped (not a tty) grub-mkpasswd-pbkdf2 reads both lines from stdin
# and only the hash comes back on stdout. The password never appears in the
# process table -- it goes through the pipe, not the argument list.
make_hash() {
  command -v grub-mkpasswd-pbkdf2 >/dev/null || { echo "grub-mkpasswd-pbkdf2 not found (apt install grub-common)" >&2; exit 1; }
  {
    echo "Set the GRUB password. It is NOT a Linux account and it is NOT your"
    echo "LUKS passphrase -- it only gates editing a boot entry. Vault it."
    echo
  } >&2

  # Read from the controlling terminal when there is one, so this still works
  # if stdin was redirected; fall back to stdin when there is not (a box with
  # no tty would otherwise fail here with "No such device or address").
  local pw pw2 out hash
  { exec 3</dev/tty; } 2>/dev/null || exec 3<&0
  printf 'GRUB password: ' >&2;  read -rs pw  <&3; echo >&2
  printf 'Confirm      : ' >&2;  read -rs pw2 <&3; echo >&2
  exec 3<&-
  [ -n "$pw" ]        || { echo "empty password -- aborted" >&2; exit 1; }
  [ "$pw" = "$pw2" ]  || { echo "passwords do not match -- aborted" >&2; exit 1; }

  echo "Deriving the PBKDF2 hash (a few seconds)..." >&2
  out=$(printf '%s\n%s\n' "$pw" "$pw2" | grub-mkpasswd-pbkdf2 2>/dev/null) || exit 1
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
  #
  # 10_linux builds its entries from $CLASS, so patching that covers the kernel
  # entries and the "Advanced options" submenu. It does NOT cover entries from
  # the other generators -- UEFI Firmware Settings, memtest, os-prober -- which
  # emit `menuentry` literally. Those are why a first run reports
  # "entries=8 restricted=3" and refuses: three entries no CLASS edit can reach.
  grep -q -- '--unrestricted' "$LINUX_TPL" || sed -i 's/^CLASS="/CLASS="--unrestricted /' "$LINUX_TPL"

  # Patch the literal `menuentry` lines the other generators emit. 40_custom and
  # 41_custom are the operator's own and are left alone -- a site may want an
  # entry that IS password-gated, and silently unrestricting it would remove a
  # control someone chose on purpose.
  for gen in /etc/grub.d/*; do
    case "$(basename "$gen")" in
      # Our own backups must be skipped or a second run patches THEM, and the
      # revert then restores an already-patched generator.
      *.pre-grubpw|*.bak|*.dpkg-*|*.ucf-*|*~) continue ;;
      00_header|01_users|*_custom|README) continue ;;
    esac
    [ -f "$gen" ] || continue
    # Detection must cover BOTH emission styles or the file is skipped before
    # the patch runs -- which is what left 30_uefi-firmware (`echo "menuentry
    # '$LABEL' ..."`) restricted while the heredoc generators were fixed.
    grep -qE '(^[[:space:]]*|["'"'"'])menuentry ' "$gen" || continue
    grep -q 'menuentry --unrestricted' "$gen" && continue
    cp -a "$gen" "$gen.pre-grubpw" 2>/dev/null || true
    # Two emission styles in the wild: a literal line inside a heredoc, and a
    # quoted line inside echo/printf. Patching only the first left memtest and
    # the UEFI entry restricted on ASP-2.
    sed -i -E \
      -e 's/^([[:space:]]*)menuentry ([^-]|--[^u])/\1menuentry --unrestricted \2/' \
      -e 's/(["'"'"'])menuentry ([^-]|--[^u])/\1menuentry --unrestricted \2/g' \
      "$gen"
    echo "  patched $(basename "$gen") for --unrestricted"
  done

  echo "Generating a candidate grub.cfg (not installing it yet)..."
  grub-mkconfig -o /tmp/grub.cfg.candidate >/dev/null 2>&1 || { echo "grub-mkconfig failed" >&2; rm -f "$DROPIN"; exit 1; }

  # Refuse to install anything that would hang the next boot.
  local total restricted
  total=$(grep -cE '^\s*menuentry ' /tmp/grub.cfg.candidate 2>/dev/null || true); total=${total:-0}
  restricted=$(grep -E '^\s*menuentry ' /tmp/grub.cfg.candidate 2>/dev/null | grep -cv -- '--unrestricted' || true); restricted=${restricted:-0}
  if ! grep -q password_pbkdf2 /tmp/grub.cfg.candidate || [ "$total" -eq 0 ] || [ "${restricted:-0}" -gt 0 ]; then
    echo "REFUSING to install: credential=$(grep -qc password_pbkdf2 /tmp/grub.cfg.candidate && echo yes || echo no) entries=$total restricted=$restricted" >&2
    if [ "${restricted:-0}" -gt 0 ]; then
      # Naming them is the difference between a dead end and a fix. Without this
      # the operator sees a count and has nowhere to go.
      echo >&2
      echo "These entries would demand the password on EVERY boot:" >&2
      grep -E '^[[:space:]]*menuentry ' /tmp/grub.cfg.candidate \
        | grep -v -- '--unrestricted' > /tmp/grub.restricted.$$
      while IFS= read -r line; do
        # Title is the first single- or double-quoted string on the line.
        title=$(printf '%s' "$line" | sed -E "s/^[[:space:]]*menuentry[[:space:]]+//; s/^'([^']*)'.*/\1/; s/^\"([^\"]*)\".*/\1/; s/[[:space:]]*\{.*//")
        # Map it back to the generator, so this is actionable rather than a list.
        src=$(grep -Fls "$title" /etc/grub.d/* 2>/dev/null | grep -v '\.pre-grubpw$' | head -1)
        printf '    - %-52s %s\n' "$title" "${src:+<- ${src##*/}}" >&2
      done < /tmp/grub.restricted.$$
      rm -f /tmp/grub.restricted.$$
      echo >&2
      echo "Each is emitted by the generator named above. Options:" >&2
      echo "  * add --unrestricted to its menuentry line by hand, or" >&2
      echo "  * drop the entry entirely -- memtest and firmware-setup entries are" >&2
      echo "    not needed on a hardened box:  sudo chmod -x /etc/grub.d/<file>" >&2
      echo "then re-run: sudo it-grub set" >&2
    fi
    echo "Candidate left at /tmp/grub.cfg.candidate; $CFG untouched; drop-in removed." >&2
    rm -f "$DROPIN"; exit 1
  fi

  [ -f "$CFG.pre-grubpw" ] || cp -a "$CFG" "$CFG.pre-grubpw"
  install -o root -g root -m 0600 /tmp/grub.cfg.candidate "$CFG"
  rm -f /tmp/grub.cfg.candidate
  cat <<MSG

Applied.

  Username : $SUPERUSER      <-- NOT a Linux account, and not your login name
  Prompted : only when you press 'e' or 'c' at the GRUB menu.
             A normal boot does NOT prompt (every menu entry is --unrestricted,
             verified above before this was installed).

  This CANNOT affect logging in to Ubuntu. GRUB runs before the kernel; it has
  no connection to PAM, your password, or your account.

  If anything is wrong, you can still boot normally and undo it:
      sudo it-grub remove
  Or restore the pre-password config directly:
      sudo cp $CFG.pre-grubpw $CFG

  Vault the username and password now -- '$SUPERUSER' plus what you typed.
  Losing them costs you the ability to edit boot entries, which is the
  recovery path for a broken initramfs or fstab.
MSG
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
    # Print the token too. Without this an operator who ran `set` has no way to
    # get the hash for the rest of the fleet short of typing the password again.
    cat <<MSG

  For the FLEET, vault this same hash so every box gets it on the next pull:
      ansible-vault encrypt_string '$h' --name 'grub_password_pbkdf2'
  ...then paste the !vault block over grub_password_pbkdf2 in group_vars/all.yml.
  Until you do, the grub_password role SKIPS (the CHANGEME sentinel), so this
  box's local setting is not overwritten.

  Verify now:  sudo it-grub status
MSG
    ;;
  remove)
    echo "This removes the GRUB password from THIS box (recovery use)."
    printf 'Continue? [y/N] '; read -r a; [ "$a" = y ] || { echo aborted; exit 0; }
    rm -f "$DROPIN"
    # Put the generators back, or they keep emitting --unrestricted after the
    # password is gone -- harmless, but it is not the state we found.
    for b in /etc/grub.d/*.pre-grubpw; do
      [ -f "$b" ] || continue
      case "$(basename "$b")" in *.pre-grubpw.pre-grubpw) rm -f "$b"; continue ;; esac
      mv -f "$b" "${b%.pre-grubpw}"
      echo "  reverted $(basename "${b%.pre-grubpw}")"
    done
    sed -i 's/^CLASS="--unrestricted /CLASS="/' "$LINUX_TPL" 2>/dev/null || true
    grub-mkconfig -o "$CFG" >/dev/null 2>&1 && chmod 0600 "$CFG"
    echo "Removed. NOTE: the grub_password role re-applies it on the next"
    echo "ansible-pull if a real hash is vaulted in group_vars."
    ;;
  help|-h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown command '$1' -- try: it-grub help" >&2; exit 2 ;;
esac
