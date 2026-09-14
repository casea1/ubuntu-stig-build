#!/usr/bin/env bash
# it-fips -- check, repair and verify FIPS mode on this box.
#
# Written after `apt autoremove` took FIPS off six deployed workstations. The
# repair is half a dozen exact commands, and typing it six times is how a
# headless box ends up unbootable and needing a physical visit.
#
#   it-fips                 status: is it FIPS now, and will it still be after a reboot?
#   it-fips fix             repair the config. Changes NO boot order, reboots nothing.
#   it-fips boot            arm a ONE-SHOT boot into the FIPS kernel
#   it-fips confirm         after that reboot: verify, then make it permanent
#   it-fips undo            put the GRUB config back the way it was
#
# WHY IT IS FOUR STEPS. A kernel that does not come up is, on a headless box, a
# physical visit. `boot` arms one boot only -- GRUB clears it as it starts, so a
# failure brings the box back on the old kernel by itself (which is also why it
# sets GRUB_RECORDFAIL_TIMEOUT first: without that, a failed boot waits at the
# menu forever). Nothing becomes permanent until `confirm` has seen the box
# actually running FIPS.
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

cmd_status() {
  local running kver uuid rc=0
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

  if [ -s "$FIPSCFG" ] && grep -q 'fips=1' "$FIPSCFG" 2>/dev/null; then
    ok "$FIPSCFG sets fips=1"
  elif [ -e "$FIPSCFG" ]; then
    bad "$FIPSCFG exists but does not set fips=1 (apt autoremove empties it)"; rc=1
  else
    bad "$FIPSCFG is missing"; rc=1
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

  head2 "Boot selection"
  printf '  %-14s %s\n' "GRUB_DEFAULT" "$(sed -nE 's/^GRUB_DEFAULT=//p' /etc/default/grub 2>/dev/null)"
  grub-editenv list 2>/dev/null | sed 's/^/  /'
  say ""
  [ "$rc" = 0 ] && ok "nothing to do" || note "repair with: sudo it-fips fix"
  say ""
  return "$rc"
}

cmd_fix() {
  local kver line f stripped
  kver="$(newest_fips)"
  [ -n "$kver" ] || die "no FIPS kernel installed -- this cannot be repaired offline.
The kernel comes from Ubuntu Pro; the box needs Canonical or the packages carried in."

  head2 "Repairing the FIPS boot configuration"

  # Take boot= out wherever it is, before anything is written. A box carrying
  # one panics on EVERY kernel, FIPS or not, so this is the first repair.
  stripped=0
  while read -r f; do
    [ -f "$f" ] || continue
    if strip_boot_param "$f"; then ok "removed a boot= parameter from $f"; stripped=1; fi
  done <<< "$(grub_cfg_files)"
  [ "$stripped" = 0 ] && ok "no boot= parameter to remove"

  line="GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT fips=1\""

  [ -e "$FIPSCFG" ] && cp -a "$FIPSCFG" "$FIPSCFG.before-it-fips.$(date +%s)"
  install -d -m 0755 "$(dirname "$FIPSCFG")"
  { printf '# Managed by it-fips -- recreated after apt autoremove took it away.\n'
    printf '%s\n' "$line"; } > "$FIPSCFG"
  chmod 0644 "$FIPSCFG"
  ok "wrote $FIPSCFG"

  # Stop it happening again: `manual`, not `hold` -- hold would also block
  # security updates for the kernel, which is worse than the problem.
  local autos
  autos="$(apt-mark showauto 2>/dev/null | grep fips || true)"
  if [ -n "$autos" ]; then
    # shellcheck disable=SC2086
    apt-mark manual $autos >/dev/null 2>&1 \
      && ok "marked $(printf '%s\n' "$autos" | wc -l) FIPS package(s) manual"
  else
    ok "FIPS packages already manual"
  fi

  say ""
  update-grub 2>&1 | sed 's/^/  /'
  grep -q 'fips=1' "$GRUBCFG" 2>/dev/null \
    || die "update-grub ran but grub.cfg still has no fips=1 -- stopping before anything boots."
  ok "grub.cfg now carries fips=1"
  ! grubcfg_has_boot_param \
    || die "grub.cfg still hands the kernel a boot= parameter, which panics it.
Find it by hand -- check /etc/default/grub and /etc/default/grub.d/*.cfg for
GRUB_CMDLINE_LINUX lines -- and do NOT reboot this box until it is gone."
  ok "grub.cfg carries no boot= parameter"

  say ""
  note "This does NOT change which entry boots. It does add fips=1 to the"
  note "command line of EVERY normal entry, generic ones included -- that is"
  note "how Canonical's own fips.cfg works, and it is why a reboot after this"
  note "is not a no-op even though the menu looks identical."
  note ""
  note "Next:  sudo it-fips boot        (and 'it-fips undo' if this went wrong)"
  say ""
}

# Put back what fix/boot saved, newest backup per file, and rebuild grub.cfg.
# The lever for "I ran it, I rebooted, it did not come up, get me back".
cmd_undo() {
  local f bak n=0
  head2 "Restoring the GRUB config saved before it-fips"
  while read -r f; do
    bak="$(ls -1t "$f".before-it-fips.* 2>/dev/null | head -1)"
    [ -n "$bak" ] || continue
    cp -a "$bak" "$f"
    ok "$f  <-  $(basename "$bak")"
    n=$((n+1))
  done <<< "$(grub_cfg_files)"

  [ "$n" -gt 0 ] || die "no it-fips backups found -- nothing to undo.
The backups are <file>.before-it-fips.<epoch> beside each GRUB config."

  say ""
  update-grub 2>&1 | sed 's/^/  /'
  say ""
  note "Config restored and grub.cfg rebuilt. If a one-shot boot is still armed,"
  note "clear it with:  sudo grub-editenv - unset next_entry"
  say ""
}

cmd_boot() {
  local kver path
  kver="$(newest_fips)"
  [ -n "$kver" ] || die "no FIPS kernel installed."
  grep -q 'fips=1' "$GRUBCFG" 2>/dev/null \
    || die "grub.cfg has no fips=1 yet -- run 'sudo it-fips fix' first."

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
  note "This applies to the NEXT BOOT ONLY. GRUB clears it as it starts, so if"
  note "the FIPS kernel panics the box comes back on the current kernel by"
  note "itself -- power-cycle it and you are where you started."
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
  grub-editenv list 2>/dev/null | sed 's/^/  /'
  say ""
  note "An SMB mount using sec=ntlmssp will stop working now: NTLM needs"
  note "HMAC-MD5, which FIPS removes. Guest shares need sec=none."
  say ""
}

case "${1:-status}" in
  status|"") cmd_status ;;
  fix)       cmd_fix ;;
  boot)      cmd_boot ;;
  confirm)   cmd_confirm ;;
  undo)      cmd_undo ;;
  *) die "unknown command: $1
$(usage)" ;;
esac
