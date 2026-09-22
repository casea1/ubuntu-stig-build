#!/usr/bin/env bash
# it-serial -- see who is holding a serial port, and take it back.
#
# The problem: someone runs `screen /dev/ttyUSB0`, usually inside a tmux pane,
# and walks away or closes the SSH session without detaching. The port stays
# held. The next person gets "Device or resource busy" -- or, worse, minicom's
# "device is locked" from a lock file whose process died weeks ago -- and the
# only remedy anyone knows is to unplug the adapter, which resets the board on
# the far end of the cable.
#
# Usage:
#   it-serial                 which ports exist and who is holding them
#   it-serial list            ...the same thing
#   it-serial free <dev>      free one port (ttyUSB0, or /dev/ttyUSB0)
#   it-serial free --all      free every port that is held
#   it-serial free --mine     ...only the ones you are holding yourself
#   it-serial locks           lock files, and whether they are stale
#   -y | --yes                skip the confirmation
#
# It does NOT kill tmux or screen themselves. Killing the process that holds the
# port drops that pane back to a shell and leaves everything else in the session
# alone -- someone else's editor in the next window is not this tool's business.
# `list` prints the session name so a person can be told where to look.
#
# ---------------------------------------------------------------------------
# WHY IT NEEDS ROOT, AND WHY IT IS STILL SAFE TO HAND TO A NON-ADMIN
#
# /proc/<pid>/fd is 0500 owned by the process owner, so an unprivileged user
# cannot SEE which process holds a port someone else opened, never mind signal
# it. /run/lock is 1777 with the sticky bit, so another user's stale lock file
# cannot be removed either. Both facts are why "just use fuser" does not work
# here and why this self-elevates.
#
# What keeps the sudo grant narrow is that **no PID ever comes from the caller.**
# The only argument is a device name; it is matched against ^tty(USB|ACM|S)[0-9]+$
# and must be a real character device. The holder is then discovered on the root
# side by walking /proc, and checked before a signal is sent: PID 1, anything
# owned by uid 0, and anything running under system.slice (a getty on a serial
# console, ModemManager probing a port) are refused outright. So a user can free
# a serial port; they cannot name something else and have root kill it for them.
#
# Every kill is logged to authpriv naming the invoking user, the device, the PID
# and its owner. That is the audit trail for an action one person takes against
# another person's process.
# ---------------------------------------------------------------------------
set -uo pipefail

ASSUME_YES=0
GRACE_TERM=2      # seconds after SIGHUP before SIGTERM
GRACE_KILL=3      # seconds after SIGTERM before SIGKILL

# Devices this tool will ever touch. Anything not matching is refused, including
# before it is used to build a path -- this is the whole containment boundary.
DEV_RE='^tty(USB|ACM|S)[0-9]+$'

[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

# Who asked. SUDO_USER is the person; after the re-exec above id -un is root.
INVOKER="${SUDO_USER:-$(id -un)}"

if [ -t 1 ]; then
  B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'
else
  B=""; DIM=""; R=""; RED=""; GRN=""; YEL=""
fi
say()   { printf '%s\n' "$*"; }
head2() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }
ok()    { printf '  %s%s%s\n' "$GRN" "$*" "$R"; }
warn()  { printf '  %s%s%s\n' "$YEL" "$*" "$R"; }
bad()   { printf '  %s%s%s\n' "$RED" "$*" "$R"; }
note()  { printf '  %s%s%s\n' "$DIM" "$*" "$R"; }
die()   { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
audit() { logger -t it-serial -p authpriv.notice "$*" 2>/dev/null || true; }

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }
case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac

# ---------------------------------------------------------------------------
# devices
# ---------------------------------------------------------------------------
# Accept ttyUSB0 or /dev/ttyUSB0, return the full path. Refuses anything else,
# which is what stops a path being smuggled in through the one argument.
dev_path() {   # $1 = user-supplied name
  local n="${1##*/}"
  [[ "$n" =~ $DEV_RE ]] || die "not a serial device name: '$1'
  Expected something like ttyUSB0, ttyACM1 or ttyS0."
  [ -c "/dev/$n" ] || die "/dev/$n is not present (unplugged?), or is not a character device."
  printf '/dev/%s\n' "$n"
}

# USB and ACM nodes only exist while something is plugged in, so listing them is
# always meaningful. ttyS* is different: the kernel creates ttyS0-31 on every
# box whether or not the UART exists, so listing all of them is noise. Include a
# ttyS only when it has a real driver behind it.
list_devices() {
  local d n
  for d in /dev/ttyUSB* /dev/ttyACM*; do [ -c "$d" ] && printf '%s\n' "$d"; done
  for d in /dev/ttyS*; do
    [ -c "$d" ] || continue
    n="${d##*/}"
    # A populated port has a driver symlink; an unpopulated stub does not.
    [ -e "/sys/class/tty/$n/device" ] || continue
    printf '%s\n' "$d"
  done
}

# by-id names are what people actually label cables with, so show one if it
# exists. Several may point at the same node; the first is enough.
dev_byid() {   # $1 = /dev/ttyUSB0
  local l
  for l in /dev/serial/by-id/*; do
    [ -e "$l" ] || continue
    [ "$(readlink -f "$l")" = "$1" ] && { printf '%s\n' "${l##*/}"; return 0; }
  done
  return 0
}

# ---------------------------------------------------------------------------
# who holds it
# ---------------------------------------------------------------------------
# Walk every process's fd table. This is the only way to answer the question for
# ANOTHER user, which is the whole point -- fuser and lsof see the same /proc and
# are equally blind without root, and neither is installed by this baseline.
holders_of() {   # $1 = /dev/ttyUSB0 -> one PID per line
  local dev="$1" p fd
  for p in /proc/[0-9]*; do
    [ -r "$p/fd" ] || continue
    for fd in "$p"/fd/*; do
      if [ "$(readlink "$fd" 2>/dev/null)" = "$dev" ]; then
        printf '%s\n' "${p#/proc/}"
        break
      fi
    done
  done
}

p_user() { stat -c %U "/proc/$1" 2>/dev/null || echo '?'; }
p_uid()  { stat -c %u "/proc/$1" 2>/dev/null || echo -1; }
p_comm() { tr -d '\n' < "/proc/$1/comm" 2>/dev/null || true; }
p_cmd()  { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | sed 's/ *$//' || true; }
p_age()  { ps -o etime= -p "$1" 2>/dev/null | tr -d ' ' || true; }
p_envv() { tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | sed -n "s/^$2=//p" | head -1 || true; }

# Where a human should go to find this, in the words they would type to get
# there. Worth the lookup: "kill bob's screen" is a support conversation,
# "screen -r 41233.ttyUSB0-lab" is not.
p_where() {   # $1 = pid -> a short human location, or nothing
  local pid="$1" pane sess user comm s
  comm="$(p_comm "$pid")"
  user="$(p_user "$pid")"
  case "$comm" in
    SCREEN|screen)
      for s in "/run/screen/S-$user"/*; do
        [ -e "$s" ] || continue
        case "${s##*/}" in "$pid."*) printf 'screen -r %s' "${s##*/}"; return 0 ;; esac
      done
      printf 'a screen session'; return 0 ;;
  esac
  pane="$(p_envv "$pid" TMUX_PANE)"
  if [ -n "$pane" ]; then
    sess="$(p_envv "$pid" TMUX)"          # <socket>,<pid>,<session index>
    [ -n "$sess" ] && printf 'tmux pane %s (session %s)' "$pane" "${sess##*,}" \
                   || printf 'tmux pane %s' "$pane"
    return 0
  fi
  return 0
}

# ---------------------------------------------------------------------------
# what must never be signalled
# ---------------------------------------------------------------------------
# Returns a reason on stdout and 1 if this PID is off limits. Order matters:
# the cheapest and most absolute checks first.
refuse_reason() {   # $1 = pid
  local pid="$1" uid comm cg
  [ "$pid" = 1 ] && { echo "PID 1"; return 1; }
  [ -d "/proc/$pid" ] || { echo "already gone"; return 1; }
  uid="$(p_uid "$pid")"
  comm="$(p_comm "$pid")"
  # A root-owned holder is either a system service or an admin who used sudo.
  # Either way an unprivileged caller must not be able to have it killed.
  [ "$uid" = 0 ] && { echo "owned by root -- run the kill yourself if you meant it"; return 1; }
  case "$comm" in
    agetty|getty|login|ModemManager|systemd*|mmcli)
      echo "$comm -- a serial console or a system service"; return 1 ;;
  esac
  # The general form of the same rule: anything systemd is supervising as a
  # SERVICE, whatever it happens to be called on this site's boxes.
  cg="$(cat "/proc/$pid/cgroup" 2>/dev/null || true)"
  case "$cg" in *system.slice*) echo "running under system.slice (a systemd service)"; return 1 ;; esac
  return 0
}

# ---------------------------------------------------------------------------
# lock files
# ---------------------------------------------------------------------------
# The UUCP convention: /run/lock/LCK..ttyUSB0 holding the owning PID as text.
# minicom, picocom and cu all honour it and REFUSE to open a port that has one,
# so a crashed session leaves a port that is locked with nothing holding it --
# and because /run/lock is sticky, the next user cannot remove the file even
# though nothing is using it. That is a second, separate way a port gets stuck.
lock_file()  { printf '/run/lock/LCK..%s\n' "${1##*/}"; }
lock_pid()   { tr -dc '0-9' < "$1" 2>/dev/null | head -c 12 || true; }
lock_stale() { local p; p="$(lock_pid "$1")"; [ -n "$p" ] || return 0; [ -d "/proc/$p" ] && return 1 || return 0; }

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------
cmd_list() {
  local dev devs n=0 held=0 pid byid lf
  devs="$(list_devices)"
  head2 "Serial ports on $(hostname -s)"
  if [ -z "$devs" ]; then
    note "none present -- nothing is plugged in, or USBGuard has not been told"
    note "about the adapter yet (it blocks the cable before udev names it):"
    note "  it-usb list    then    sudo it-usb enroll <id>"
    say ""
    return 0
  fi

  while IFS= read -r dev; do
    n=$((n + 1))
    byid="$(dev_byid "$dev")"
    printf '\n  %s%s%s%s\n' "$B" "$dev" "$R" "${byid:+  ${DIM}$byid${R}}"

    local any=0
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      any=1; held=$((held + 1))
      local w reason
      w="$(p_where "$pid")"
      printf '      held by  %-10s pid %-7s %s\n' "$(p_user "$pid")" "$pid" "$(p_comm "$pid")"
      printf '      open for %s\n' "$(p_age "$pid")"
      [ -n "$w" ] && printf '      found at %s\n' "$w"
      printf '      %s%s%s\n' "$DIM" "$(p_cmd "$pid" | cut -c1-100)" "$R"
      if reason="$(refuse_reason "$pid")"; then :; else
        printf '      %sthis one will NOT be freed: %s%s\n' "$YEL" "$reason" "$R"
      fi
    done < <(holders_of "$dev")
    [ "$any" = 0 ] && printf '      %sfree%s\n' "$GRN" "$R"

    lf="$(lock_file "$dev")"
    if [ -e "$lf" ]; then
      if lock_stale "$lf"; then
        printf '      %sSTALE LOCK  %s (pid %s is gone)%s\n' "$RED" "$lf" "$(lock_pid "$lf")" "$R"
        printf '      %sminicom and picocom will refuse this port until it is cleared%s\n' "$DIM" "$R"
      else
        printf '      %slock        %s (pid %s)%s\n' "$DIM" "$lf" "$(lock_pid "$lf")" "$R"
      fi
    fi
  done <<< "$devs"

  say ""
  if [ "$held" -gt 0 ]; then
    note "Free one:  sudo it-serial free ttyUSB0"
    note "Free all:  sudo it-serial free --all        (yours only: --mine)"
  else
    ok "nothing is holding a port"
  fi
  say ""
}

# ---------------------------------------------------------------------------
# free
# ---------------------------------------------------------------------------
# SIGHUP first: screen, minicom and picocom all treat a hangup as "the terminal
# went away" and exit cleanly, closing the port and removing their own lock.
# SIGTERM then SIGKILL only for what ignores it. Going straight to SIGKILL
# leaves the lock file behind, which is the fault this tool exists to clear.
free_pid() {   # $1 = pid, $2 = device -- 0 if it is gone afterwards
  local pid="$1" dev="$2" user comm
  user="$(p_user "$pid")"; comm="$(p_comm "$pid")"

  audit "free $dev: $INVOKER killing pid $pid ($comm) owned by $user"
  kill -HUP "$pid" 2>/dev/null
  sleep "$GRACE_TERM"
  if [ ! -d "/proc/$pid" ]; then ok "$dev  pid $pid ($comm, $user) exited on SIGHUP"; return 0; fi

  kill -TERM "$pid" 2>/dev/null
  sleep "$GRACE_KILL"
  if [ ! -d "/proc/$pid" ]; then ok "$dev  pid $pid ($comm, $user) exited on SIGTERM"; return 0; fi

  kill -KILL "$pid" 2>/dev/null
  sleep 1
  if [ ! -d "/proc/$pid" ]; then
    warn "$dev  pid $pid ($comm, $user) needed SIGKILL"
    note "a SIGKILLed holder cannot clean up after itself -- its lock file is cleared below"
    return 0
  fi
  bad "$dev  pid $pid ($comm, $user) SURVIVED SIGKILL -- it is stuck in the driver"
  note "an uninterruptible wait in the USB layer. Unplugging the adapter is the"
  note "only remaining option, and the board on the far end will reset."
  return 1
}

# Clear the lock only when nothing holds the port any more. Never remove a lock
# belonging to a live process we did not kill -- that would hand the port to a
# second user while the first still has it open.
clear_lock() {   # $1 = device
  local lf; lf="$(lock_file "$1")"
  [ -e "$lf" ] || return 0
  if [ -n "$(holders_of "$1")" ]; then
    note "lock left in place -- something still holds $1"
    return 0
  fi
  rm -f "$lf" && { ok "cleared $lf"; audit "cleared stale lock $lf on behalf of $INVOKER"; }
}

free_device() {   # $1 = device, $2 = 1 for --mine
  local dev="$1" mine="${2:-0}" pid pids n=0 rc=0 reason
  pids="$(holders_of "$dev")"
  if [ -z "$pids" ]; then
    ok "$dev is already free"
    clear_lock "$dev"
    return 0
  fi

  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if [ "$mine" = 1 ] && [ "$(p_user "$pid")" != "$INVOKER" ]; then
      note "$dev  pid $pid belongs to $(p_user "$pid") -- skipped (--mine)"
      continue
    fi
    if reason="$(refuse_reason "$pid")"; then
      free_pid "$pid" "$dev" || rc=1
      n=$((n + 1))
    else
      bad "$dev  pid $pid ($(p_comm "$pid")) REFUSED: $reason"
      audit "refused $dev pid $pid for $INVOKER: $reason"
      rc=1
    fi
  done <<< "$pids"

  [ "$n" -gt 0 ] && clear_lock "$dev"
  return "$rc"
}

cmd_free() {
  local all=0 mine=0 targets="" a dev rc=0
  for a in "$@"; do
    case "$a" in
      --all)       all=1 ;;
      --mine)      all=1; mine=1 ;;
      -y|--yes)    ASSUME_YES=1 ;;
      -*)          die "unknown option: $a" ;;
      *)           targets="$targets $(dev_path "$a")" ;;
    esac
  done
  [ "$all" = 1 ] || [ -n "$targets" ] || die "usage: it-serial free <dev> | --all | --mine"

  if [ "$all" = 1 ]; then
    targets=""
    while IFS= read -r dev; do
      [ -n "$dev" ] || continue
      [ -n "$(holders_of "$dev")" ] && targets="$targets $dev"
    done < <(list_devices)
    if [ -z "$targets" ]; then
      head2 "Nothing to free"
      ok "no serial port on this box is held"
      for dev in $(list_devices); do clear_lock "$dev"; done
      say ""
      return 0
    fi
  fi

  head2 "About to free"
  for dev in $targets; do
    for pid in $(holders_of "$dev"); do
      printf '  %-14s pid %-7s %-10s %s  %s\n' "$dev" "$pid" "$(p_user "$pid")" \
        "$(p_comm "$pid")" "${DIM}$(p_where "$pid")${R}"
    done
  done
  say ""
  note "This ends someone's session on that port. Whatever they had on screen is"
  note "gone; the board on the far end of the cable is NOT reset."

  if [ "$ASSUME_YES" != 1 ]; then
    [ -t 0 ] || die "not a terminal -- pass --yes to confirm non-interactively"
    printf '  %sGo ahead? [y/N] %s' "$B" "$R"
    read -r yn
    case "$yn" in y|Y|yes|YES) ;; *) say "  nothing was done"; return 0 ;; esac
  fi

  say ""
  for dev in $targets; do free_device "$dev" "$mine" || rc=1; done
  say ""
  [ "$rc" = 0 ] && ok "done -- 'it-serial' to confirm" || warn "some ports could not be freed (above)"
  say ""
  return "$rc"
}

# ---------------------------------------------------------------------------
# locks
# ---------------------------------------------------------------------------
cmd_locks() {
  local lf n=0 stale=0 dev pid
  head2 "Serial lock files in /run/lock"
  for lf in /run/lock/LCK..*; do
    [ -e "$lf" ] || continue
    n=$((n + 1))
    dev="/dev/${lf##*/LCK..}"
    pid="$(lock_pid "$lf")"
    if lock_stale "$lf"; then
      stale=$((stale + 1))
      bad "$lf  pid ${pid:-?} is gone -- STALE"
    else
      printf '  %-34s pid %-7s %s (%s)\n' "$lf" "$pid" "$(p_comm "$pid")" "$(p_user "$pid")"
    fi
  done
  [ "$n" = 0 ] && { ok "none"; say ""; return 0; }

  if [ "$stale" -gt 0 ]; then
    say ""
    note "/run/lock is sticky, so the next user cannot remove another user's"
    note "lock file even when nothing is using the port. Clearing them:"
    if [ "$ASSUME_YES" != 1 ]; then
      [ -t 0 ] || { note "  sudo it-serial locks --yes"; say ""; return 0; }
      printf '  %sClear the stale ones? [y/N] %s' "$B" "$R"
      read -r yn
      case "$yn" in y|Y|yes|YES) ;; *) say "  left alone"; say ""; return 0 ;; esac
    fi
    for lf in /run/lock/LCK..*; do
      [ -e "$lf" ] || continue
      lock_stale "$lf" || continue
      dev="/dev/${lf##*/LCK..}"
      if [ -n "$(holders_of "$dev")" ]; then
        note "$lf kept -- $dev is genuinely held"
        continue
      fi
      rm -f "$lf" && { ok "removed $lf"; audit "cleared stale lock $lf on behalf of $INVOKER"; }
    done
  fi
  say ""
}

# ---------------------------------------------------------------------------
for a in "$@"; do case "$a" in -y|--yes) ASSUME_YES=1 ;; esac; done
case "${1:-list}" in
  list|status|"") cmd_list ;;
  free)           shift; cmd_free "$@" ;;
  locks)          cmd_locks ;;
  *)              die "unknown command: $1  (try: it-serial --help)" ;;
esac
