#!/usr/bin/env bash
# it-rdp -- the RDP sessions on this workstation, and the stale ones.
#
# The failure this exists for: you authenticate over RDP and the window closes
# again a second later. The logs say
#
#   gnome-session-binary: WARNING: Session manager already running!
#   xrdp-sesman: [WARN] Window manager (pid N, display 11) exited with non-zero
#                       exit code 1
#
# and the cause is an EARLIER session for the same user that was never reaped.
# Its Xorg, its xrdp-chansrv and its per-session xrdp-sesman are all still
# running, so sesman finds /tmp/.X11-unix/X10 occupied and starts the new
# session on :11 -- but the orphan still owns org.gnome.SessionManager on that
# user's bus, gnome-session refuses to start a second one, exits 1, and xrdp
# tears the connection down. One GNOME session per user is a hard limit; this
# is what it looks like when the first one will not go away.
#
#   it-rdp                 sessions, orphans, and the sesman settings (default)
#   it-rdp status          the same
#   it-rdp reset [user]    end that user's sessions and sweep what is left
#                          behind. Their desktop closes -- unsaved work in it
#                          is lost -- so it names what it will do and asks.
#   it-rdp sweep           reap ORPHANS only; never touches a live session
#   it-rdp restart         restart xrdp + sesman, refusing while sessions are
#                          live (that is what creates the orphans)
#
# A timer (xrdp-reap.timer) runs `sweep` every few minutes, so a user who hits
# this gets their next login back without anyone being called. `status` says
# whether it is running.
#
# The pull will not restart sesman under live sessions either -- it defers and
# leaves /run/xrdp-sesman-restart-pending, which `status` reports.
set -uo pipefail

PENDING=/run/xrdp-sesman-restart-pending
SESMAN_INI=/etc/xrdp/sesman.ini

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; R=$'\033[0m'
else B=""; DIM=""; GRN=""; YEL=""; RED=""; R=""; fi
say()   { printf '%s\n' "$*"; }
head2() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }
ok()    { printf '  %s%s%s\n' "$GRN" "$*" "$R"; }
warn()  { printf '  %s%s%s\n' "$YEL" "$*" "$R"; }
bad()   { printf '  %s%s%s\n' "$RED" "$*" "$R"; }
die()   { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }

case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

# ---------------------------------------------------------------------------
# The X servers xrdp started, one per line:  <display> <pid> <ppid> <user>
#
# xrdp's Xorg is recognised by its command line, not by its user: it runs AS
# the person, so "an Xorg owned by a human" also matches a console session, and
# reaping one of those would log someone out of the machine in front of them.
# ---------------------------------------------------------------------------
xrdp_xservers() {
  local pid ppid user args disp
  while read -r pid ppid user args; do
    case "$args" in *xrdp*) ;; *) continue ;; esac
    disp="$(printf '%s' "$args" | grep -oE ' :[0-9]+' | head -1 | tr -d ' :')"
    [ -n "$disp" ] || continue
    printf '%s %s %s %s\n' "$disp" "$pid" "$ppid" "$user"
  done < <(ps -eo pid=,ppid=,user=,args= | awk '$4 ~ /Xorg$|\/Xorg$/ {print}')
}

# Is this X server orphaned?
#
# A live session's Xorg is a child of the per-session xrdp-sesman that forked
# it, and that sesman is a child of the main one. When the main sesman is
# restarted -- which an ansible-pull used to do on any sesman.ini change -- the
# per-session children are reparented to init and the main sesman comes back
# with an EMPTY session table. The processes keep running and serve nobody.
#
# So: PPID 1 anywhere in the chain means nothing is managing this session any
# more. That is the whole test, and it is the state that breaks the next login.
is_orphan() {   # $1 = Xorg pid, $2 = its ppid
  local pid="$1" ppid="$2" comm=""
  [ "$ppid" = "1" ] && return 0
  comm="$(ps -o comm= -p "$ppid" 2>/dev/null | tr -d ' ')"
  case "$comm" in
    xrdp-sesman)
      # The session sesman exists. Is IT still attached to the main one?
      local gp
      gp="$(ps -o ppid= -p "$ppid" 2>/dev/null | tr -d ' ')"
      [ "$gp" = "1" ] && return 0
      return 1 ;;
    "") return 0 ;;   # parent gone between the two ps calls
    *)  return 1 ;;
  esac
}

# The chansrv belonging to ONE display. Scoped by its DISPLAY, not by its user:
# somebody with a live session and an orphan has two, and killing both by name
# takes down the desktop they are sitting in front of.
chansrv_on() {   # $1 = display, $2 = user -> pids
  local pid d
  for pid in $(pgrep -u "$2" -x xrdp-chansrv 2>/dev/null); do
    d="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^DISPLAY=//p' | head -1)"
    [ "$d" = ":$1" ] && printf '%s\n' "$pid"
  done
}

# Everything belonging to one display: the X server, its chansrv, its sesman,
# and the socket that makes sesman skip the display next time.
kill_display() {   # $1 = display number, $2 = user
  local disp="$1" user="$2" pid
  for pid in $(pgrep -u "$user" -f "Xorg :$disp " 2>/dev/null) \
             $(chansrv_on "$disp" "$user"); do
    kill -TERM "$pid" 2>/dev/null
  done
  sleep 2
  for pid in $(pgrep -u "$user" -f "Xorg :$disp " 2>/dev/null); do
    kill -KILL "$pid" 2>/dev/null
  done
  # The socket outlives the process it belonged to, and sesman reads the
  # directory to pick a free display -- a leftover socket is why the next login
  # lands on :11 instead of reusing :10.
  rm -f "/tmp/.X11-unix/X$disp" "/tmp/.X$disp-lock" 2>/dev/null
  ok "display :$disp ($user) reaped"
}

sessions_live() {   # 0 when any xrdp X server is running at all
  [ -n "$(xrdp_xservers)" ]
}

# ---------------------------------------------------------------------------
cmd_status() {
  head2 "RDP sessions"
  local any=0 orph=0 disp pid ppid user age
  while read -r disp pid ppid user; do
    [ -n "$disp" ] || continue
    any=1
    age="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
    if is_orphan "$pid" "$ppid"; then
      orph=$((orph + 1))
      bad ":$disp  $user  pid $pid  up $age  ORPHANED (nothing is managing it)"
    else
      ok ":$disp  $user  pid $pid  up $age"
    fi
  done < <(xrdp_xservers)
  [ "$any" -eq 1 ] || say "  ${DIM}no RDP sessions${R}"

  if [ "$orph" -gt 0 ]; then
    say ""
    bad "$orph orphaned session(s). The next RDP login by that user will be"
    say  "  refused by gnome-session (\"Session manager already running!\") and"
    say  "  the connection will close immediately after authentication."
    say  "  ${B}sudo it-rdp sweep${R}   reaps them; live sessions are untouched"
  fi

  # Sockets with no process: harmless on their own, but they make sesman skip
  # a display, which is how a user ends up on :11 with an orphan on :10.
  head2 "X sockets"
  local s n stale=0
  for s in /tmp/.X11-unix/X*; do
    [ -e "$s" ] || continue
    n="${s##*/X}"
    if pgrep -f "Xorg :$n " >/dev/null 2>&1; then
      say "  X$n  in use"
    else
      stale=$((stale + 1))
      warn "X$n  no X server -- leftover, sesman will skip this display"
    fi
  done
  [ "$stale" -gt 0 ] && say "  ${DIM}sudo it-rdp sweep removes them${R}"

  head2 "Session reaping (sesman.ini)"
  local k v
  for k in KillDisconnected DisconnectedTimeLimit IdleTimeLimit MaxSessions; do
    v="$(sed -nE "s/^[[:space:]]*$k[[:space:]]*=[[:space:]]*//p" "$SESMAN_INI" 2>/dev/null | tail -1)"
    printf '  %-22s %s\n' "$k" "${v:-<unset -- xrdp default>}"
  done
  if [ "$(sed -nE 's/^[[:space:]]*DisconnectedTimeLimit[[:space:]]*=[[:space:]]*//p' "$SESMAN_INI" 2>/dev/null | tail -1)" = "0" ]; then
    warn "DisconnectedTimeLimit 0 means a disconnected session lives forever."
    say  "  ${DIM}Set dev_rdp_disconnected_time_limit and pull.${R}"
  fi

  head2 "Automatic reaping"
  if systemctl is-active --quiet xrdp-reap.timer 2>/dev/null; then
    ok "xrdp-reap.timer   running"
    say "  ${DIM}$(systemctl list-timers --no-pager --no-legend xrdp-reap.timer 2>/dev/null \
                    | awk '{print "next " $1, $2, $3 "  (" $4 " " $5 ")"}')${R}"
  else
    warn "xrdp-reap.timer   NOT running -- orphans sit until someone sweeps by hand"
    say  "  ${DIM}dev_rdp_reap_enabled: true, then pull${R}"
  fi

  if [ -e "$PENDING" ]; then
    say ""
    warn "a pull wanted to restart xrdp-sesman and DEFERRED it -- sessions were live."
    say  "  ${DIM}Restarting sesman orphans every session it is managing, which is${R}"
    say  "  ${DIM}the fault above. It applies on the next reboot, or run${R}"
    say  "  ${B}sudo it-rdp restart${R} ${DIM}when nobody is logged in.${R}"
  fi
  say ""
}

cmd_sweep() {
  head2 "Reaping orphaned sessions"
  local n=0 disp pid ppid user
  while read -r disp pid ppid user; do
    [ -n "$disp" ] || continue
    if is_orphan "$pid" "$ppid"; then
      kill_display "$disp" "$user"
      n=$((n + 1))
    fi
  done < <(xrdp_xservers)

  # Sockets whose X server is already gone.
  local s d
  for s in /tmp/.X11-unix/X*; do
    [ -e "$s" ] || continue
    d="${s##*/X}"
    if ! pgrep -f "Xorg :$d " >/dev/null 2>&1; then
      rm -f "$s" "/tmp/.X$d-lock" 2>/dev/null && { ok "removed leftover socket X$d"; n=$((n + 1)); }
    fi
  done

  [ "$n" -eq 0 ] && say "  ${DIM}nothing orphaned -- no live session was touched${R}"
  say ""
}

cmd_reset() {
  local user="${1:-}"
  [ -n "$user" ] || die "usage: it-rdp reset <user>   (whose sessions to end)"
  id "$user" >/dev/null 2>&1 || die "no such user: $user"

  head2 "Ending every session for $user"
  warn "This closes their desktop. Anything unsaved in it is lost."
  local disp pid ppid u found=0
  while read -r disp pid ppid u; do
    [ "$u" = "$user" ] || continue
    found=1
    say "  :$disp  pid $pid  up $(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
  done < <(xrdp_xservers)
  [ "$found" -eq 1 ] || say "  ${DIM}no X server for $user -- clearing logind and sockets anyway${R}"

  if [ -t 0 ]; then
    printf '  Type YES to go ahead: '
    local a; read -r a; [ "$a" = YES ] || die "not confirmed -- nothing was changed"
  fi

  # logind first: it owns the user's systemd --user instance, and that is what
  # keeps the D-Bus session bus (and the session manager registered on it)
  # alive after the processes below are gone.
  loginctl terminate-user "$user" 2>/dev/null && ok "logind sessions for $user terminated"
  sleep 2

  while read -r disp pid ppid u; do
    [ "$u" = "$user" ] || continue
    kill_display "$disp" "$u"
  done < <(xrdp_xservers)

  # Whatever is left of theirs.
  pkill -u "$user" -f xrdp-chansrv 2>/dev/null
  pkill -u "$user" -f xrdp-sesman 2>/dev/null
  ok "$user can log in again"
  say ""
}

cmd_restart() {
  local force=0
  [ "${1:-}" = "--force" ] && force=1
  head2 "Restarting xrdp"
  if sessions_live && [ "$force" -eq 0 ]; then
    bad "sessions are live -- not restarting xrdp-sesman."
    say "  Restarting it orphans every one of them: the per-session processes"
    say "  keep running, sesman comes back with an empty table, and the next"
    say "  login by those users fails immediately after authentication."
    say ""
    say "  ${B}sudo it-rdp status${R}          who is on"
    say "  ${B}sudo it-rdp restart --force${R} do it anyway, then sweep"
    return 1
  fi
  systemctl restart xrdp-sesman && ok "xrdp-sesman restarted"
  systemctl restart xrdp && ok "xrdp restarted"
  rm -f "$PENDING"
  [ "$force" -eq 1 ] && cmd_sweep
  say ""
}

case "${1:-status}" in
  status|"")  cmd_status ;;
  sweep)      cmd_sweep ;;
  reset)      shift; cmd_reset "$@" ;;
  restart)    shift; cmd_restart "$@" ;;
  *)          die "unknown command: ${1}
$(usage)" ;;
esac
