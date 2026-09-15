#!/usr/bin/env bash
# it-fips -- check, repair and verify FIPS mode on this box.
#
# Written after `apt autoremove` took FIPS off six deployed workstations. The
# repair is half a dozen exact commands, and typing it six times is how a
# headless box ends up unbootable and needing a physical visit.
#
#   it-fips                 status: is it FIPS now, and will it still be after a reboot?
#   it-fips auto            DO ALL OF IT: repair everything repairable, then arm
#                           one FIPS boot -- or say exactly what is still wrong.
#                           Reboot, then `it-fips confirm`. Start here.
#   it-fips fix             the config repairs only. Arms nothing, reboots nothing.
#   it-fips luks            rewrite argon2 keyslots as pbkdf2, same passphrase
#   it-fips retire <slot>   remove a LUKS keyslot whose passphrase is gone
#   it-fips boot            arm a ONE-SHOT boot into the FIPS kernel
#   it-fips confirm         after that reboot: verify, then make it permanent
#   it-fips undo            put the GRUB config back the way it was
#
# WHAT `auto` REPAIRS: a boot= parameter (panics every kernel), an emptied
# fips.cfg, FIPS packages marked auto (one autoremove from removal), a missing
# GRUB_RECORDFAIL_TIMEOUT (a failed boot waits at the menu forever), GRUB menu
# entries that ask for the GRUB password before booting, and LUKS keyslots on
# argon2 (which FIPS mode will not process, so the disk never unlocks).
#
# WHY IT IS STAGED. A kernel that does not come up is, on a headless box, a
# physical visit. `boot` arms one boot, and nothing becomes permanent until
# `confirm` has seen the box actually running FIPS.
#
# READ THIS BEFORE TRUSTING THE ONE-SHOT. On a box with SECURE BOOT ENABLED it
# is not a one-shot at all: GRUB clears next_entry by writing grubenv, lockdown
# refuses the write ("error: prohibited by secure boot policy", before the
# menu), and the entry stays selected on every boot. A kernel that fails is
# then retried forever instead of falling back. `boot` says so when it arms,
# `status` fails the box while one is stuck, and `confirm` clears it.
#
# DO NOT ADD boot=UUID=... . It is a dracut/RHEL parameter and it is FATAL here:
# see the note above find_boot_param(). This script removes it.
#
# WHAT IT CANNOT DO. If the FIPS kernel packages are gone, this cannot help:
# that kernel comes from Ubuntu Pro and needs Canonical. An air-gapped box in
# that state has to be carried the packages or taken back to a network.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; R=$'\033[0m'
else B=""; DIM=""; GRN=""; YEL=""; RED=""; R=""; fi
say()   { printf '%s\n' "$*"; }
head2() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }
ok()    { printf '  %sOK%s    %s\n' "$GRN" "$R" "$*"; }
warn()  { printf '  %sWARN%s  %s\n' "$YEL" "$R" "$*"; }
bad()   { printf '  %sFAIL%s  %s\n' "$RED" "$R" "$*"; }
note()  { printf '        %s%s%s\n' "$DIM" "$*" "$R"; }
die()   { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }
case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac

FIPSCFG=/etc/default/grub.d/fips.cfg
GRUBCFG=/boot/grub/grub.cfg

# The FIPS kernel with the highest version, as GRUB names it.
fips_kernels() { ls -1 /boot/vmlinuz-*-fips 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V; }
newest_fips()  { fips_kernels | tail -1; }

# `boot=` DOES NOT NAME A PARTITION ON UBUNTU. It names an initramfs boot script:
# initramfs-tools' /init parses `BOOT=${x#boot=}`, defaults it to `local`, and
# ends with `. "/scripts/${BOOT}"`. So boot=UUID=<uuid> makes init try to source
# /scripts/UUID=<uuid>, which does not exist -- init exits and the kernel panics
# with "attempted to kill init", right after "Begin: mounting root file system".
# That is exactly what happened to dev-16. Valid values are local (the default),
# nfs and casper; nothing else.
#
# The parameter comes from Red Hat, where dracut's fips module really does use it
# to find /boot. Ubuntu's FIPS check runs from inside the initramfs and needs no
# such thing -- dev-16 printed "Fips check done" and panicked four lines later.
grub_cfg_files() {
  printf '%s\n' /etc/default/grub
  ls -1 /etc/default/grub.d/*.cfg 2>/dev/null
}

# Every boot= on a GRUB command line, as "file:line:text".
find_boot_param() {
  local f
  grub_cfg_files | while read -r f; do
    [ -f "$f" ] || continue
    grep -Hn '^[^#]*GRUB_CMDLINE_LINUX[A-Z_]*=.*[ "]boot=' "$f" 2>/dev/null
  done
}

# Remove it from one file. Returns 0 only if something was removed.
strip_boot_param() {   # $1 = file
  local f="$1"
  grep -q '^[^#]*GRUB_CMDLINE_LINUX[A-Z_]*=.*[ "]boot=' "$f" 2>/dev/null || return 1
  cp -a "$f" "$f.before-it-fips.$(date +%s)"
  # Two expressions: boot= after a space, and boot= as the FIRST word of the
  # value, where there is no space in front of it to match.
  sed -i -E '/^[^#]*GRUB_CMDLINE_LINUX[A-Z_]*=/ {
      s/[[:space:]]+boot=[^[:space:]"]*//g
      s/"boot=[^[:space:]"]*[[:space:]]*/"/g
    }' "$f"
}

# What GRUB will actually hand the kernel -- the generated file, not the intent.
grubcfg_has_boot_param() {
  grep -E '^[[:space:]]*linux[[:space:]]' "$GRUBCFG" 2>/dev/null \
    | grep -q '[[:space:]]boot='
}

# Which GRUB config file configures fips=1 -- ANY of them will do.
#
# ubuntu-fips ships 99-fips.cfg, this script writes fips.cfg, and a box can
# equally have it typed into /etc/default/grub by hand. dev-ai1 has no fips.cfg
# at all and has been running FIPS for months. Checking one hardcoded filename
# reported a working box as broken, so ask the question that matters: is fips=1
# configured anywhere the generator reads?
fips_cfg_source() {
  local f
  grub_cfg_files | while read -r f; do
    [ -f "$f" ] || continue
    grep -q '^[^#]*GRUB_CMDLINE_LINUX[A-Z_]*=.*fips=1' "$f" 2>/dev/null && printf '%s\n' "$f"
  done
}

# A GRUB superuser password with MENU ENTRIES that are not --unrestricted means
# GRUB demands a username and password before it boots. On a headless box that
# is a machine which never comes back.
#
# Two things this must NOT do, both learned from dev-ai1, which boots unattended
# and was reported as locked:
#
#  - Read /etc/grub.d/. Those are the generator's inputs, and a `set superusers`
#    in one of them (or in a .bak beside it) says nothing about what GRUB is
#    reading today. Only the generated grub.cfg decides.
#  - Count `submenu` lines. 10_linux emits `submenu ... $menuentry_id_option`
#    with no $CLASS, so the Advanced options submenu is ALWAYS gated and always
#    has been. It gates walking into the menu by hand, not the unattended boot
#    of the default entry, which is a top-level menuentry.
grub_superusers() { grep -qs '^[[:space:]]*set[[:space:]]\+superusers=' "$GRUBCFG"; }
grub_gated_entries() {
  grep -sE '^[[:space:]]*menuentry ' "$GRUBCFG" | grep -v -- '--unrestricted'
}
grub_gated_submenus() {
  grep -sE '^[[:space:]]*submenu ' "$GRUBCFG" | grep -v -- '--unrestricted'
}
grub_locked() { grub_superusers && [ -n "$(grub_gated_entries)" ]; }

# THE ONE THAT ASKS FOR A PASSWORD ON EVERY BOOT.
#
# `grub-set-default 'Advanced options for Ubuntu>Ubuntu, with Linux X-fips'`
# pins a NESTED entry. To reach it GRUB must enter the submenu -- and 10_linux
# emits `submenu` with no $CLASS, so the submenu is password-gated on every box
# in this fleet. The entry itself is --unrestricted and the check said so, which
# is true and useless: you cannot get to it without authenticating first.
#
# So `it-fips confirm` pinning the FIPS kernel is what started the GRUB password
# prompt on dev-16. Before it, GRUB_DEFAULT=0 booted the top-level entry.
#
# The fix is GRUB_DISABLE_SUBMENU=y: every kernel becomes a top-level menuentry,
# which DOES carry $CLASS and so is --unrestricted. The password still gates `e`
# and the GRUB command line, which is what the STIG actually requires.
grub_saved_entry() { grub-editenv list 2>/dev/null | sed -n 's/^saved_entry=//p'; }
grub_next_entry()  { grub-editenv list 2>/dev/null | sed -n 's/^next_entry=//p'; }
secure_boot_on()   { mokutil --sb-state 2>/dev/null | grep -qi enabled; }

# THE ONE-SHOT DOES NOT SELF-CLEAR UNDER SECURE BOOT, WHICH BREAKS THE WHOLE
# PREMISE OF `boot`.
#
# With GRUB_DEFAULT=saved, 00_header runs this before the menu is drawn:
#
#     if [ "${next_entry}" ] ; then
#        set default="${next_entry}"
#        set next_entry=
#        save_env next_entry          <-- writes to grubenv
#
# Under Secure Boot GRUB is locked down and that write is refused:
#
#     error: prohibited by secure boot policy
#
# printed exactly there -- before the menu, on every boot. So next_entry is
# never cleared, a one-shot becomes permanent, and a kernel that does not come
# up is retried forever instead of falling back. grub-reboot was chosen for this
# fleet precisely because a failure was supposed to self-recover; with Secure
# Boot on it does the opposite.
grub_stale_oneshot() { [ -n "$(grub_next_entry)" ]; }
grub_pin_is_nested() {
  grub_superusers || return 1
  case "$(grub_saved_entry)" in *">"*) return 0 ;; *) return 1 ;; esac
}

fix_grub_submenu() {
  grub_superusers || { ok "no GRUB password -- submenus cost nothing"; return 0; }
  if grep -qE '^GRUB_DISABLE_SUBMENU=(y|true)' /etc/default/grub 2>/dev/null; then
    ok "GRUB_DISABLE_SUBMENU already set -- kernels are top-level entries"
    return 0
  fi
  cp -a /etc/default/grub "/etc/default/grub.before-it-fips.$(date +%s)"
  if grep -qE '^[#[:space:]]*GRUB_DISABLE_SUBMENU=' /etc/default/grub 2>/dev/null; then
    sed -i -E 's|^[#[:space:]]*GRUB_DISABLE_SUBMENU=.*|GRUB_DISABLE_SUBMENU=y|' /etc/default/grub
  else
    printf 'GRUB_DISABLE_SUBMENU=y\n' >> /etc/default/grub
  fi
  ok "set GRUB_DISABLE_SUBMENU=y -- every kernel becomes a top-level entry"
  note "with a GRUB password, a kernel inside the Advanced options submenu"
  note "cannot be booted without authenticating: the submenu is gated even"
  note "when the entry is not. Flat menu, no prompt, password still on 'e'."
  # A pin into the old submenu is now a path that does not exist. Drop it and
  # let `confirm` set the flat one, rather than leaving GRUB to fall back
  # silently to entry 0 -- which may not be the FIPS kernel.
  if grub_pin_is_nested; then
    grub-editenv - unset saved_entry 2>/dev/null \
      && ok "cleared the now-invalid nested pin -- re-pin with: sudo it-fips confirm"
  fi
  NEEDGRUB=1
}

# Which LUKS keyslots use a KDF that FIPS mode will not process.
#
# Argon2 is not FIPS-approved, and LUKS2 defaults a NEW keyslot to argon2id. So
# a passphrase rotated while the box sat on a generic kernel writes a slot that
# cannot be used once fips=1 is on the command line. The box reaches the LUKS
# prompt, refuses every correct passphrase, and there is no shell to debug from.
# That is dev-15.
luks_device() { blkid -t TYPE=crypto_LUKS -o device 2>/dev/null | head -1; }
luks_kdfs() {
  local dev; dev="$(luks_device)"
  [ -n "$dev" ] && command -v cryptsetup >/dev/null 2>&1 || return 0
  cryptsetup luksDump "$dev" 2>/dev/null |
    awk '/^[[:space:]]*[0-9]+: luks2/{s=$1} /PBKDF:/{printf "%s%s ", s, $2}'
}
luks_has_argon()  { luks_kdfs | grep -qi argon; }
# At least one slot FIPS mode CAN use. This is the question that decides whether
# the box boots: dev-ai1 runs FIPS today with slots 0 and 1 on argon2, because
# slot 2 is pbkdf2 and that is the one that unlocks it. Argon2 slots are dead
# weight under FIPS -- their passphrases stop working -- but they are not fatal.
luks_has_usable() { luks_kdfs | grep -qi pbkdf2; }
luks_pbkdf2_slots() { luks_kdfs | tr ' ' '\n' | grep -i pbkdf2 | sed 's/:.*//' | paste -sd, -; }
luks_tpm_slots()    { clevis luks list -d "$(luks_device)" 2>/dev/null | awk -F: '{gsub(/ /,"",$1); print $1}'; }
# pbkdf2 slots that are NOT the TPM: the ones a person can actually type at a
# console while the box is in FIPS mode. If this is empty, the TPM is the only
# way in and a moved PCR 7 locks the machine.
luks_usable_passphrase_slots() {
  comm -23 <(luks_kdfs | tr ' ' '\n' | grep -i pbkdf2 | sed 's/:.*//' | sort -u) \
           <(luks_tpm_slots | sort -u) 2>/dev/null | paste -sd, -
}

# The GRUB submenu path for a kernel, read from grub.cfg rather than assembled
# from a template: the wording differs between releases, and a name that does
# not match is silently ignored by grub-reboot.
menu_path_for() {   # $1 = kernel version
  local kver="$1"
  awk -v kv="$kver" -F"'" '
    /^submenu / { sub_name=$2 }
    /^\t*menuentry / {
      name=$2
      if (index(name, kv) > 0 && index(name, "recovery") == 0) {
        if (sub_name != "") print sub_name ">" name; else print name
        exit
      }
    }' "$GRUBCFG" 2>/dev/null
}

# Which keyslots specifically, so a repair can name them.
luks_argon_slots() {
  local dev; dev="$(luks_device)"
  [ -n "$dev" ] && command -v cryptsetup >/dev/null 2>&1 || return 0
  cryptsetup luksDump "$dev" 2>/dev/null |
    awk '/^[[:space:]]*[0-9]+: luks2/{s=$1; sub(":","",s)} /PBKDF:/{if ($2 ~ /argon/) print s}'
}

NEEDGRUB=0

# --- repair primitives. Each one is idempotent and says what it did. --------

fix_boot_param_all() {
  local f n=0
  while read -r f; do
    [ -f "$f" ] || continue
    if strip_boot_param "$f"; then ok "removed a boot= parameter from $f"; n=1; fi
  done <<< "$(grub_cfg_files)"
  [ "$n" = 1 ] && NEEDGRUB=1 || ok "no boot= parameter to remove"
}

fix_fipscfg() {
  local line="GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT fips=1\""
  local src
  # Do not add a second fips=1 to a box that already has one somewhere else --
  # ubuntu-fips ships 99-fips.cfg, and dev-ai1 has it in neither of those places
  # and has been in FIPS mode for months.
  src="$(fips_cfg_source | tr '\n' ' ')"
  if [ -n "$src" ]; then
    ok "fips=1 already configured in ${src% } -- leaving it alone"
    return 0
  fi
  [ -e "$FIPSCFG" ] && cp -a "$FIPSCFG" "$FIPSCFG.before-it-fips.$(date +%s)"
  install -d -m 0755 "$(dirname "$FIPSCFG")"
  { printf '# Managed by it-fips -- recreated after apt autoremove took it away.\n'
    printf '%s\n' "$line"; } > "$FIPSCFG"
  chmod 0644 "$FIPSCFG"
  ok "wrote $FIPSCFG"
  NEEDGRUB=1
}

fix_aptmark() {
  local autos
  autos="$(apt-mark showauto 2>/dev/null | grep fips || true)"
  if [ -n "$autos" ]; then
    # shellcheck disable=SC2086
    apt-mark manual $autos >/dev/null 2>&1 \
      && ok "marked $(printf '%s\n' "$autos" | wc -l) FIPS package(s) manual -- autoremove can no longer take them"
  else
    ok "FIPS packages already manual"
  fi
}

fix_recordfail() {
  if grep -qE '^GRUB_RECORDFAIL_TIMEOUT=' /etc/default/grub 2>/dev/null; then
    ok "GRUB_RECORDFAIL_TIMEOUT already set ($(sed -nE 's/^GRUB_RECORDFAIL_TIMEOUT=//p' /etc/default/grub))"
    return 0
  fi
  cp -a /etc/default/grub "/etc/default/grub.before-it-fips.$(date +%s)"
  printf 'GRUB_RECORDFAIL_TIMEOUT=%s\n' "${FIPS_RECORDFAIL_TIMEOUT:-10}" >> /etc/default/grub
  ok "set GRUB_RECORDFAIL_TIMEOUT=${FIPS_RECORDFAIL_TIMEOUT:-10} -- a failed boot no longer waits forever"
  NEEDGRUB=1
}

fix_grub_default_saved() {
  grep -qE '^GRUB_DEFAULT=saved' /etc/default/grub 2>/dev/null && return 0
  cp -a /etc/default/grub "/etc/default/grub.before-it-fips.$(date +%s)"
  sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
  ok "set GRUB_DEFAULT=saved (grub-reboot needs somewhere to write next_entry)"
  NEEDGRUB=1
}

# Every generator, not just 10_linux: $CLASS does not reach the ones that write
# `menuentry` literally (UEFI firmware settings, memtest, os-prober), and one
# gated entry is still a password prompt. 40_custom/41_custom are the operator's.
fix_grub_unrestricted() {
  local g ts
  grub_locked || { ok "GRUB does not require its password to boot"; return 0; }
  ts="$(date +%s)"
  cp -a /etc/grub.d/10_linux "/etc/grub.d/10_linux.before-it-fips.$ts" 2>/dev/null
  sed -i 's/^CLASS="\(--unrestricted \)\?/CLASS="--unrestricted /' /etc/grub.d/10_linux 2>/dev/null
  for g in /etc/grub.d/*; do
    case "${g##*/}" in
      00_header|01_users|40_custom|41_custom|README) continue ;;
      *.pre-grubpw|*.bak|*.dpkg-*|*~|*.before-it-*) continue ;;
    esac
    [ -f "$g" ] && [ -r "$g" ] || continue
    grep -qE '(^[[:space:]]*|["'"'"'])menuentry ' "$g" 2>/dev/null || continue
    cp -a "$g" "$g.before-it-fips.$ts"
    sed -i -E 's/(^[[:space:]]*|["'"'"'])menuentry (--unrestricted )?/\1menuentry --unrestricted /g' "$g"
  done
  ok "patched /etc/grub.d so menu entries do not require the GRUB password"
  NEEDGRUB=1
}

# Rewrite argon2 keyslots as pbkdf2, KEEPING THE SAME PASSPHRASE.
# luksConvertKey re-encrypts the slot with a different KDF; it does not change
# the credential, so nothing has to be re-recorded or re-issued.
fix_luks_kdf() {
  local dev slots s bak clev done_any=0
  dev="$(luks_device)"
  [ -n "$dev" ] || { ok "no LUKS device on this box"; return 0; }
  slots="$(luks_argon_slots)"
  [ -n "$slots" ] || { ok "every LUKS keyslot already uses a FIPS-approved KDF"; return 0; }

  if ! cryptsetup --help 2>&1 | grep -q luksConvertKey; then
    bad "this cryptsetup has no luksConvertKey, so the slot cannot be converted"
    note "change the passphrase instead:  sudo it-luks-passwd   (forces pbkdf2)"
    return 1
  fi

  # HEADER BACKUP FIRST, ALWAYS. Keyslot edits are the one thing here that can
  # lose the disk, and a backup header restores every passphrase as it was.
  install -d -m 0700 /etc/stig-build
  bak="/etc/stig-build/luks-header-$(basename "$dev")-$(date +%Y%m%d%H%M%S).img"
  cryptsetup luksHeaderBackup "$dev" --header-backup-file "$bak" \
    || { bad "header backup failed -- refusing to touch any keyslot"; return 1; }
  chmod 0600 "$bak"
  ok "LUKS header backed up: $bak"
  note "that file unlocks this disk with any of its passphrases. It lives on the"
  note "encrypted volume; do not copy it off the box. Restore with:"
  note "  cryptsetup luksHeaderRestore $dev --header-backup-file $bak"

  clev="$(clevis luks list -d "$dev" 2>/dev/null | awk -F: '{gsub(/ /,"",$1); print $1}')"

  for s in $slots; do
    if [ -n "$clev" ] && printf '%s\n' "$clev" | grep -qx "$s"; then
      warn "slot $s is the TPM (clevis) slot and is left alone"
      note "re-binding it needs cryptsetup running UNDER the FIPS kernel, which"
      note "this box is not yet. Order: finish here, boot FIPS and type the"
      note "passphrase at the console once, then run 'sudo it-luks-rebind'."
      note "Until that is done this box asks for the passphrase at every boot."
      continue
    fi
    say ""
    say "  ${B}Keyslot $s uses argon2. Enter the passphrase for THAT slot.${R}"
    say "  ${DIM}The passphrase does not change -- only how the slot is derived.${R}"
    if cryptsetup luksConvertKey --pbkdf pbkdf2 --key-slot "$s" "$dev"; then
      ok "slot $s is now pbkdf2, same passphrase"
      done_any=1
    else
      bad "slot $s NOT converted (wrong passphrase for that slot, or refused)"
      note "that slot is unchanged. Header backup is at $bak"
    fi
  done
  [ "$done_any" = 1 ] && say ""
  return 0
}

# What still stands between this box and a FIPS boot. Deliberately does NOT
# include "is not running FIPS yet" -- that is the point of the exercise.
boot_blockers() {
  local n=0 dev
  [ -n "$(newest_fips)" ] || { say "  - no FIPS kernel installed"; n=$((n+1)); }
  grep -q 'fips=1' "$GRUBCFG" 2>/dev/null || { say "  - grub.cfg has no fips=1"; n=$((n+1)); }
  grubcfg_has_boot_param && { say "  - grub.cfg still hands the kernel a boot= parameter"; n=$((n+1)); }
  grub_locked && { say "  - GRUB asks for its password before booting any entry"; n=$((n+1)); }
  grep -qE '^GRUB_RECORDFAIL_TIMEOUT=' /etc/default/grub 2>/dev/null \
    || { say "  - GRUB_RECORDFAIL_TIMEOUT is unset"; n=$((n+1)); }
  dev="$(luks_device)"
  if [ -n "$dev" ] && [ -n "$(luks_argon_slots)" ] && ! luks_has_usable; then
    say "  - every LUKS keyslot uses argon2, so nothing can unlock this disk"
    n=$((n+1))
  fi
  return "$n"
}

cmd_status() {
  local running kver rc=0
  running="$(uname -r)"
  kver="$(newest_fips)"

  head2 "Now"
  printf '  %-14s %s\n' "running" "$running"
  case "$running" in
    *-fips)
      if [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" = 1 ]; then
        ok "in FIPS mode"
      else
        bad "running a -fips kernel with fips_enabled not 1"; rc=1
      fi ;;
    *) bad "not running a FIPS kernel"; rc=1 ;;
  esac

  head2 "After the next reboot"
  if [ -z "$kver" ]; then
    bad "no FIPS kernel installed -- this cannot be repaired offline"
    note "the kernel comes from Ubuntu Pro. The box needs Canonical, or the"
    note "packages carried in. Nothing here can fix it."
    return 1
  fi
  ok "FIPS kernel available: $kver"

  local src
  src="$(fips_cfg_source | tr '\n' ' ')"
  if [ -n "$src" ]; then
    ok "fips=1 is configured in: ${src% }"
  elif [ -e "$FIPSCFG" ]; then
    bad "$FIPSCFG exists but does not set fips=1 (apt autoremove empties it)"; rc=1
  else
    bad "nothing configures fips=1 -- no GRUB config file sets it"; rc=1
    note "checked /etc/default/grub and /etc/default/grub.d/*.cfg"
  fi

  local stale
  stale="$(find_boot_param)"
  if [ -n "$stale" ]; then
    bad "a boot= parameter is set -- this box will PANIC on any kernel:"
    printf '%s\n' "$stale" | sed 's/^/          /'
    note "on Ubuntu boot= names an initramfs script, not a partition, so"
    note "boot=UUID=... makes init source /scripts/UUID=... and die. FIPS does"
    note "not need it. Remove it with: sudo it-fips fix"
    rc=1
  else
    ok "no boot= parameter (it is a RHEL option, and it panics Ubuntu)"
  fi

  if grubcfg_has_boot_param; then
    bad "grub.cfg still hands the kernel a boot= -- it will panic. Run: it-fips fix"
    rc=1
  fi

  grep -q 'fips=1' "$GRUBCFG" 2>/dev/null \
    && ok "grub.cfg carries fips=1" \
    || { bad "grub.cfg has no fips=1 -- run: it-fips fix"; rc=1; }

  # The one that turns a failed boot into a site visit.
  if grep -qE '^GRUB_RECORDFAIL_TIMEOUT=' /etc/default/grub 2>/dev/null; then
    ok "GRUB_RECORDFAIL_TIMEOUT set -- a failed boot recovers on its own"
  else
    bad "GRUB_RECORDFAIL_TIMEOUT is unset: after ANY failed boot, GRUB waits"
    note "forever at the menu for a keypress. On a headless box that is a site"
    note "visit, and a power cycle does not clear it. 'it-fips boot' sets it."
    rc=1
  fi

  local auto
  auto="$(apt-mark showauto 2>/dev/null | grep -c fips || true)"
  [ "${auto:-0}" -eq 0 ] \
    && ok "FIPS packages are marked manual" \
    || { bad "$auto FIPS package(s) marked auto -- one autoremove from removal"; rc=1; }

  # ---- the two faults that cost site visits on dev-15 and dev-16 ----------
  #
  # Both are invisible until the box is at a prompt nobody can answer, and
  # neither has anything to do with fips=1 being set correctly.
  head2 "Will the FIPS kernel actually come up?"

  # 0. Can it boot WITHOUT a person at the console at all?
  if ! grub_superusers; then
    ok "no GRUB superuser password in grub.cfg -- nothing gates the boot"
  elif grub_locked; then
    bad "$(grub_gated_entries | wc -l) menu entry(s) need the GRUB password to BOOT:"
    grub_gated_entries | sed 's/^/          /' | head -8
    note "headless, this box does not come back from a reboot. Repair:"
    note "  sudo it-fips fix     (patches every generator in /etc/grub.d)"
    rc=1
  else
    ok "every bootable menu entry is --unrestricted"
    if grub_stale_oneshot; then
      bad "a one-shot boot is STILL ARMED and cannot clear itself:"
      note "  next_entry=$(grub_next_entry)"
      if secure_boot_on; then
        note "Secure Boot locks GRUB down, so its own 'save_env next_entry' is"
        note "refused -- that IS the 'error: prohibited by secure boot policy'"
        note "printed before the menu. The one-shot is therefore permanent: a"
        note "kernel that fails is retried forever instead of falling back."
      fi
      note "Clear it with:  sudo grub-editenv - unset next_entry"
      note "or let 'sudo it-fips confirm' clear it while pinning properly."
      rc=1
    fi
    if grub_pin_is_nested; then
      bad "but the pinned default is INSIDE the gated submenu:"
      note "  $(grub_saved_entry)"
      note "GRUB must enter the submenu to reach it, and the submenu is"
      note "password-gated, so this box asks for the GRUB password on EVERY"
      note "boot. Headless, it never comes back. Fix: sudo it-fips fix"
      note "(sets GRUB_DISABLE_SUBMENU=y), then: sudo it-fips confirm"
      rc=1
    elif [ -n "$(grub_gated_submenus)" ]; then
      note "the Advanced options submenu is password-gated. That is normal --"
      note "10_linux never puts \$CLASS on a submenu line -- and harmless only"
      note "while nothing pinned inside it is what boots."
    fi
  fi

  # 1. SECURE BOOT. Ubuntu ships linux-image-<ver>-fips (signed) and
  #    linux-image-unsigned-<ver>-fips. If autoremove took the signed one and
  #    left the unsigned image in place, GRUB refuses it with a Secure Boot
  #    policy error while the generic kernel boots normally -- which reads as
  #    "FIPS is broken" and is really "that image has no signature".
  local sb owner
  sb="$(mokutil --sb-state 2>/dev/null | head -1)"
  printf '  %-14s %s\n' "SecureBoot" "${sb:-unknown}"
  if printf '%s' "$sb" | grep -qi enabled; then
    owner="$(dpkg -S "/boot/vmlinuz-$kver" 2>/dev/null | cut -d: -f1)"
    case "$owner" in
      *unsigned*)
        bad "/boot/vmlinuz-$kver comes from $owner -- an UNSIGNED image"
        note "Secure Boot will refuse it. Reinstall the signed package:"
        note "  sudo apt-get install --reinstall linux-image-$kver"
        rc=1 ;;
      "")
        warn "no package owns /boot/vmlinuz-$kver -- cannot tell if it is signed"
        note "check with: sbverify --list /boot/vmlinuz-$kver" ;;
      *)
        ok "/boot/vmlinuz-$kver comes from $owner (signed)" ;;
    esac
  else
    ok "Secure Boot is off -- kernel signing cannot block the boot"
  fi

  # 2. LUKS KDF. Argon2 is not FIPS-approved, so cryptsetup under a FIPS kernel
  #    restricts itself to PBKDF2. A keyslot written while the box was on a
  #    generic kernel -- a passphrase rotation, say -- can be one the FIPS
  #    kernel will not process, and the symptom is a failed unlock at boot.
  local dev kdfs entries
  dev="$(luks_device)"
  kdfs="$(luks_kdfs)"
  if [ -n "$dev" ]; then
    printf '  %-14s %s\n' "LUKS $dev" "${kdfs:-unreadable}"
    if ! printf '%s' "$kdfs" | grep -qi argon; then
      [ -n "$kdfs" ] && ok "every keyslot uses a FIPS-approved KDF"
    elif luks_has_usable; then
      local tpmslots
      tpmslots="$(clevis luks list -d "$dev" 2>/dev/null | awk -F: '{gsub(/ /,"",$1); print $1}' | paste -sd, -)"
      warn "argon2 keyslot(s) present -- those passphrases will NOT work in FIPS"
      note "mode. The disk unlocks through slot(s) $(luks_pbkdf2_slots), which is"
      note "why this box is fine today."
      local typeable
      typeable="$(luks_usable_passphrase_slots)"
      if [ -z "$typeable" ]; then
        note ""
        note "AND THE ONLY WORKING SLOT IS THE TPM (${tpmslots:-?}). If that binding"
        note "breaks -- a firmware update or a Secure Boot change moves PCR 7 --"
        note "this box falls back to a passphrase, and NO passphrase works under"
        note "FIPS. That is a machine nobody can open, standing at the console."
        note "Convert one now:  sudo it-fips luks   (keeps the same passphrase)"
      else
        note "Slot(s) $typeable are typeable passphrases that DO work in FIPS mode,"
        note "so the TPM is not a single point of failure here."
        note "The argon2 slot(s) are inert: see 'sudo it-fips luks'."
      fi
    else
      bad "EVERY keyslot uses argon2, which FIPS mode will not process"
      note "this box will reach the LUKS prompt and refuse every correct"
      note "passphrase once fips=1 is on the command line. That is dev-15."
      note "Rewrite a slot FIRST:  sudo it-fips auto   (keeps the passphrase)"
      note "'it-fips boot' refuses to arm anything while this is true."
      rc=1
    fi
  fi

  # fips=1 comes from GRUB_CMDLINE_LINUX_DEFAULT, which update-grub stamps onto
  # EVERY normal entry. Canonical's own fips.cfg works the same way. So the
  # generic entry is NOT a clean fallback: whatever fips=1 breaks, it breaks
  # there too, and on dev-15 that was the disk unlock.
  entries="$(grep -cE '^[[:space:]]*linux[[:space:]].*fips=1' "$GRUBCFG" 2>/dev/null || true)"
  if [ "${entries:-0}" -gt 0 ]; then
    say ""
    note "fips=1 is on ${entries} menu entries, generic kernels included -- so"
    note "booting 'the other one' is not a way round anything fips=1 causes."
  fi

  head2 "Boot selection"
  printf '  %-14s %s\n' "GRUB_DEFAULT" "$(sed -nE 's/^GRUB_DEFAULT=//p' /etc/default/grub 2>/dev/null)"
  grub-editenv list 2>/dev/null | sed 's/^/  /'
  say ""
  [ "$rc" = 0 ] && ok "nothing to do" || note "repair with: sudo it-fips fix"
  say ""
  return "$rc"
}

cmd_fix() {
  local kver
  kver="$(newest_fips)"
  [ -n "$kver" ] || die "no FIPS kernel installed -- this cannot be repaired offline.
The kernel comes from Ubuntu Pro; the box needs Canonical or the packages carried in."

  head2 "Repairing the FIPS boot configuration"
  fix_boot_param_all          # first: a boot= panics EVERY kernel, not just FIPS
  fix_fipscfg
  fix_aptmark
  fix_recordfail
  fix_grub_unrestricted       # after the others; update-grub is what bakes it in
  fix_grub_submenu            # a pinned kernel behind a gated submenu = a prompt

  if [ "$NEEDGRUB" = 1 ]; then
    say ""
    update-grub 2>&1 | sed 's/^/  /'
  else
    say ""
    ok "grub.cfg already current -- nothing to regenerate"
  fi

  grep -q 'fips=1' "$GRUBCFG" 2>/dev/null \
    || die "update-grub ran but grub.cfg still has no fips=1 -- stopping before anything boots."
  ok "grub.cfg carries fips=1"
  ! grubcfg_has_boot_param \
    || die "grub.cfg still hands the kernel a boot= parameter, which panics it.
Check /etc/default/grub and /etc/default/grub.d/*.cfg for GRUB_CMDLINE_LINUX
lines, and do NOT reboot this box until it is gone."
  ok "grub.cfg carries no boot= parameter"
  ! grub_locked \
    || die "grub.cfg still requires the GRUB password to boot an entry, which
makes this box unbootable without someone at the console. Find what emits it:
  grep -rn menuentry /etc/grub.d/"
  ok "no entry requires the GRUB password to boot"

  say ""
  note "This does NOT change which entry boots. It DOES add fips=1 to the command"
  note "line of every normal entry, generic ones included -- that is how"
  note "Canonical's own fips.cfg works, so the generic entry is not a fallback"
  note "from anything fips=1 causes."
  note ""
  note "Next:  sudo it-fips auto       (or: boot, then confirm after the reboot)"
  note "       sudo it-fips undo       if this went wrong"
  say ""
}

cmd_luks() {
  local left typeable dev
  head2 "LUKS keyslots"
  fix_luks_kdf
  dev="$(luks_device)"
  say ""
  printf '  %-14s %s\n' "now" "$(luks_kdfs)"

  left="$(luks_argon_slots | paste -sd, -)"
  [ -n "$left" ] || { say ""; ok "every slot works in FIPS mode"; say ""; return 0; }

  typeable="$(luks_usable_passphrase_slots)"
  say ""
  if [ -n "$typeable" ]; then
    ok "slot(s) $typeable are typeable and work in FIPS mode -- the disk is openable"
  else
    bad "no typeable slot works in FIPS mode -- only the TPM can open this disk"
  fi

  warn "slot(s) $left still use argon2 and are inert while fips=1 is set"
  note "A keyslot whose passphrase nobody here knows is not just dead weight: it"
  note "can still decrypt this disk on a non-FIPS kernel, and it is an"
  note "unaccounted-for credential in front of an assessor. It is most likely the"
  note "TEMPORARY passphrase from imaging, which was meant to be retired at"
  note "deployment."
  note ""
  note "Either recover it and re-run this, or remove the slot:"
  note "  sudo cryptsetup luksKillSlot $dev <slot>"
  note "That asks for a passphrase from a DIFFERENT slot, so it cannot lock you"
  note "out, and the header backup above restores it if you change your mind."
  note "Do not remove a slot while it is the only one you can type."
  say ""
}

# Retire a keyslot whose passphrase nobody has. DELIBERATELY ITS OWN VERB and
# never part of `auto`: nothing here can tell a stale imaging passphrase apart
# from somebody's deliberate recovery key, and only a person knows which it is.
#
# What it will not do, because the fleet has eight of these and a typo is a slot
# number: remove the TPM binding, remove the last slot a person can type, or
# remove the last slot at all.
cmd_retire() {
  local slot="${1:-}" dev bak typeable left answer
  dev="$(luks_device)"
  [ -n "$dev" ] || die "no LUKS device found on this box."
  command -v cryptsetup >/dev/null 2>&1 || die "cryptsetup is not installed."

  case "$slot" in
    ''|*[!0-9]*) die "usage: sudo it-fips retire <slot number>
This disk: $(luks_kdfs)" ;;
  esac

  luks_kdfs | tr ' ' '\n' | grep -q "^${slot}:" \
    || die "slot $slot is not in use on $dev.
This disk: $(luks_kdfs)"

  if luks_tpm_slots | grep -qx "$slot"; then
    die "REFUSING: slot $slot is the TPM (clevis) binding. Removing it stops this
box unlocking itself at boot, and on a headless machine that is a site visit.
To replace a TPM slot, use:  sudo it-luks-rebind"
  fi

  [ "$(luks_kdfs | wc -w)" -gt 1 ] || die "REFUSING: slot $slot is the only keyslot on $dev.
Removing it destroys every way into this disk."

  typeable="$(luks_usable_passphrase_slots | tr ',' '\n' | grep -v "^${slot}$" | paste -sd, -)"
  [ -n "$typeable" ] || die "REFUSING: slot $slot is the last slot a person can type in FIPS mode.
Removing it leaves only the TPM, and a moved PCR 7 would then lock this box with
nobody able to open it. Convert another slot first:  sudo it-fips luks"

  head2 "Retiring LUKS keyslot $slot on $dev"
  printf '  %-14s %s\n' "slots now" "$(luks_kdfs)"
  printf '  %-14s %s\n' "TPM slot(s)" "$(luks_tpm_slots | paste -sd, - || true)"
  printf '  %-14s %s\n' "left after" "$typeable (typeable) + the TPM"
  say ""
  note "cryptsetup asks for a passphrase from a DIFFERENT slot, so this cannot"
  note "lock you out. A header backup is taken first either way."

  install -d -m 0700 /etc/stig-build
  bak="/etc/stig-build/luks-header-$(basename "$dev")-$(date +%Y%m%d%H%M%S).img"
  cryptsetup luksHeaderBackup "$dev" --header-backup-file "$bak" \
    || die "header backup failed -- refusing to remove anything."
  chmod 0600 "$bak"
  ok "header backed up: $bak"
  note "undo with: cryptsetup luksHeaderRestore $dev --header-backup-file $bak"

  say ""
  if [ "${FIPS_ASSUME_YES:-0}" != 1 ]; then
    read -r -p "  Type the slot number again to remove it: " answer
    [ "$answer" = "$slot" ] || die "  aborted -- nothing was removed."
  fi
  say ""

  cryptsetup luksKillSlot "$dev" "$slot" || die "
slot $slot was NOT removed. Nothing changed."

  # LUKS2 has no per-keyslot timestamp, so "was the imaging passphrase ever
  # retired?" is unanswerable later unless something records it now. Same
  # reasoning, and the same file, as it-luks-passwd.
  printf '%s %s %s keyslot %s retired (was %s)\n' \
    "$(date -Is)" "${SUDO_USER:-$(id -un)}" "$dev" "$slot" "argon2/unknown" \
    >> /etc/stig-build/credential-changes.log 2>/dev/null || true
  chmod 0644 /etc/stig-build/credential-changes.log 2>/dev/null || true

  left="$(luks_kdfs)"
  ok "slot $slot removed"
  printf '  %-14s %s\n' "slots now" "$left"
  say ""
  note "recorded in /etc/stig-build/credential-changes.log -- that is the only"
  note "evidence an assessor can read that the imaging credential was retired."
  say ""
}

# The whole repair, in the order the faults have to be cleared, ending with the
# box armed for one FIPS boot -- or, on a box already running FIPS, with that
# kernel pinned as the default instead. Arming a one-shot into the kernel the
# box is already on tells you nothing.
cmd_auto() {
  local n
  head2 "it-fips auto"
  note "config repairs, then the LUKS keyslots, then arm ONE boot into FIPS."
  note "Nothing reboots. Nothing becomes permanent until 'it-fips confirm'."

  cmd_fix

  head2 "LUKS keyslots"
  fix_luks_kdf

  # Already there? Then there is nothing to arm -- pin it instead, so a kernel
  # upgrade reordering the menu cannot quietly drop the box back to generic.
  case "$(uname -r)" in
    *-fips)
      if [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" = 1 ]; then
        head2 "This box is already in FIPS mode"
        note "nothing to arm. Making this kernel the default instead."
        cmd_confirm
        return 0
      fi ;;
  esac

  head2 "Anything still in the way?"
  # Capture the count before anything else runs: after `if ... fi` with no else,
  # $? is the status of the `if` itself, not of the command it tested.
  boot_blockers; n=$?
  if [ "$n" -eq 0 ]; then
    ok "nothing -- arming the boot"
    cmd_boot
    return 0
  fi
  say ""
  bad "$n item(s) above must be cleared first. Nothing has been armed."
  note "A TPM/clevis slot on argon2 is expected at this point and is NOT a"
  note "blocker you can clear from here: boot FIPS with the passphrase once,"
  note "then run 'sudo it-luks-rebind' under FIPS. Arm it anyway with:"
  note "  sudo FIPS_ALLOW_ARGON=1 it-fips boot"
  say ""
  return 1
}

cmd_boot() {
  local kver path
  kver="$(newest_fips)"
  [ -n "$kver" ] || die "no FIPS kernel installed."
  grep -q 'fips=1' "$GRUBCFG" 2>/dev/null \
    || die "grub.cfg has no fips=1 yet -- run 'sudo it-fips fix' first."

  # HARD STOP. Arming a boot the disk cannot unlock is the exact site visit this
  # script exists to avoid, and the generic entry does not save you: fips=1 is on
  # that one too.
  if [ "${FIPS_ALLOW_ARGON:-0}" != 1 ] && luks_has_argon && ! luks_has_usable; then
    die "REFUSING to arm a FIPS boot: EVERY LUKS keyslot uses argon2.
  $(luks_device):  $(luks_kdfs)
Argon2 is not FIPS-approved, so this box will reach the passphrase prompt and
refuse every correct passphrase. Rewrite the slot first:

    sudo it-luks-passwd        # forces pbkdf2

then run 'sudo it-fips' again. Override with FIPS_ALLOW_ARGON=1 only if you are
sitting in front of the machine."
  fi

  path="$(menu_path_for "$kver")"
  [ -n "$path" ] || die "could not find a GRUB menu entry for $kver.
Look for it yourself:  awk -F\\' '/menuentry |submenu /{print \$2}' $GRUBCFG"

  # HEADLESS SAFETY, and it is not optional on this fleet.
  #
  # Ubuntu's 00_header does:  if recordfail=1, timeout=${GRUB_RECORDFAIL_TIMEOUT:--1}
  # and -1 means WAIT FOREVER for a keypress. So any failed boot leaves a
  # headless box sitting at a GRUB menu that nobody can answer -- and a power
  # cycle does not help, because the flag is still set and it waits again. That
  # is what a panicking FIPS kernel actually costs: not a failed boot, an
  # unreachable machine.
  #
  # The one-shot boot below is only a safe experiment if a failure recovers on
  # its own, so this is set BEFORE arming anything.
  local regen=0
  if ! grep -qE '^GRUB_RECORDFAIL_TIMEOUT=' /etc/default/grub 2>/dev/null; then
    cp -a /etc/default/grub "/etc/default/grub.before-it-fips.$(date +%s)"
    printf 'GRUB_RECORDFAIL_TIMEOUT=%s\n' "${FIPS_RECORDFAIL_TIMEOUT:-10}" >> /etc/default/grub
    regen=1
    ok "set GRUB_RECORDFAIL_TIMEOUT=${FIPS_RECORDFAIL_TIMEOUT:-10} -- a failed boot will no longer hang at the menu"
  else
    ok "GRUB_RECORDFAIL_TIMEOUT already set ($(sed -nE 's/^GRUB_RECORDFAIL_TIMEOUT=//p' /etc/default/grub))"
  fi

  # grub-reboot needs a saved default to write next_entry against.
  if ! grep -qE '^GRUB_DEFAULT=saved' /etc/default/grub 2>/dev/null; then
    cp -a /etc/default/grub "/etc/default/grub.before-it-fips.$(date +%s)"
    sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
    regen=1
    ok "set GRUB_DEFAULT=saved"
  fi

  # /etc/default/grub is only intent. Nothing above reaches the box until
  # grub.cfg is rebuilt -- and an unregenerated GRUB_RECORDFAIL_TIMEOUT is a
  # safety net that is not actually there, which is worse than knowing it isn't.
  if [ "$regen" = 1 ]; then
    update-grub >/dev/null 2>&1 || die "update-grub failed -- not arming anything."
    ok "regenerated grub.cfg"
  fi

  head2 "Arming ONE boot into FIPS"
  printf '  %-10s %s\n' "kernel" "$kver"
  printf '  %-10s %s\n' "entry" "$path"
  grub-reboot "$path" || die "grub-reboot failed"
  ok "armed"
  say ""
  if secure_boot_on; then
    warn "SECURE BOOT IS ON, SO THIS IS NOT ACTUALLY A ONE-SHOT."
    note "GRUB clears next_entry by writing grubenv, and lockdown refuses that"
    note "write -- you get 'error: prohibited by secure boot policy' before the"
    note "menu. The entry stays selected on EVERY boot, and a kernel that fails"
    note "is retried rather than falling back to the old one."
    note ""
    note "Do not treat this as a safe experiment on a box you cannot walk up to."
    note "After the reboot, 'sudo it-fips confirm' clears next_entry and pins the"
    note "kernel properly. If it does not come up, you need the console."
  else
    note "This applies to the NEXT BOOT ONLY. GRUB clears it as it starts, so if"
    note "the FIPS kernel panics the box comes back on the current kernel by"
    note "itself -- power-cycle it and you are where you started."
  fi
  say ""
  say "  ${B}sudo reboot${R}   then, once it is back:   ${B}sudo it-fips confirm${R}"
  say ""
}

cmd_confirm() {
  head2 "Confirming"
  case "$(uname -r)" in
    *-fips) ok "running $(uname -r)" ;;
    *) die "this box is running $(uname -r), not a FIPS kernel.
The one-shot boot did not take, or it failed and GRUB fell back. Nothing has
been made permanent. Check:  sudo it-fips" ;;
  esac
  [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" = 1 ] \
    || die "FIPS kernel is running but fips_enabled is not 1 -- check /proc/cmdline for fips=1.
Nothing has been made permanent."
  ok "fips_enabled=1"

  local kver path
  kver="$(uname -r)"
  path="$(menu_path_for "$kver")"
  [ -n "$path" ] || die "running FIPS but cannot find its GRUB entry to make default."
  grub-set-default "$path" || die "grub-set-default failed"
  ok "default boot is now: $path"

  # Always, not only under Secure Boot: a next_entry that outlived its boot
  # overrides the default just set, and on a locked-down box it cannot clear
  # itself. This is the only place that reliably removes it.
  if grub_stale_oneshot; then
    grub-editenv - unset next_entry 2>/dev/null \
      && ok "cleared the armed one-shot -- the pin above now decides every boot"
  fi
  grub-editenv list 2>/dev/null | sed 's/^/  /'
  say ""
  note "An SMB mount using sec=ntlmssp will stop working now: NTLM needs"
  note "HMAC-MD5, which FIPS removes. Guest shares need sec=none."
  say ""
}

case "${1:-status}" in
  status|"") cmd_status ;;
  auto|all)  cmd_auto ;;
  fix)       cmd_fix ;;
  luks)      cmd_luks ;;
  retire)    shift; cmd_retire "$@" ;;
  boot)      cmd_boot ;;
  confirm)   cmd_confirm ;;
  undo)      cmd_undo ;;
  *) die "unknown command: $1
$(usage)" ;;
esac
