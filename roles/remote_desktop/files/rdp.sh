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
#   it-rdp perf            is RDP configured to feel quick? Read-only. Run it in
#                          the LAB before deploying -- separates CHOPPY REDRAW
#                          from LATE TYPING, which have different fixes.
#   it-rdp client          the .rdp settings to use on the WINDOWS side. Half of
#                          this problem is decided by the client, and the
#                          obvious knob ("quality") makes it WORSE.
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

# The display numbers xrdp allocates. Everything outside this range belongs to
# somebody else and must not be touched: gdm keeps sockets at X1024/X1025 (seen
# on dev-13), and a sweep that deleted those would break the local greeter --
# on a box whose whole point is that people can still log in at the console
# when RDP is broken.
ini_get() {   # $1 = key, $2 = default
  local v
  v="$(sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$SESMAN_INI" 2>/dev/null | tail -1)"
  printf '%s' "${v:-$2}"
}
DISP_MIN="$(ini_get X11DisplayOffset 10)"
DISP_MAX="$(ini_get MaxDisplayNumber 63)"

ours() {   # $1 = display number -> 0 if xrdp could have allocated it
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge "$DISP_MIN" ] && [ "$1" -le "$DISP_MAX" ]
}

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
# Precisely: is it a descendant of the xrdp-sesman systemd is currently
# running? A live session was forked by that process and its chain leads back
# to it. When sesman is restarted -- which an ansible-pull used to do on any
# sesman.ini change -- the sessions it held are reparented to init and the new
# sesman starts with an empty table. Those sessions keep running, serve nobody,
# cannot be reconnected to, and block their owner's next login.
#
# Asking systemd for the PID rather than inferring one from the process tree:
# on a box mid-incident there are SEVERAL xrdp-sesman processes with PPID 1 --
# the live one and every session orphaned by a restart -- and picking the wrong
# one either spares an orphan or kills a working desktop. Observed on dev-13:
# the running sesman was PID 277906 while an orphaned session's was 182320,
# both PPID 1, and only systemd can say which is which.
# `ps -o etime=` prints [[DD-]hh:]mm:ss, so a 36-minute session reads "36:22"
# and a 36-HOUR one reads "1-12:22:14". Those are one glance apart and the
# short form has already been misread as hours during an incident, which sent
# the diagnosis after a stale session that did not exist. Print the unit.
fmt_age() {   # $1 = pid -> "36m 22s"
  local secs d h m
  secs="$(ps -o etimes= -p "$1" 2>/dev/null | tr -d ' ')"
  case "$secs" in ''|*[!0-9]*) printf 'unknown'; return ;; esac
  d=$(( secs / 86400 )); h=$(( (secs % 86400) / 3600 ))
  m=$(( (secs % 3600) / 60 )); s=$(( secs % 60 ))
  if   [ "$d" -gt 0 ]; then printf '%dd %dh %dm' "$d" "$h" "$m"
  elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
  else                      printf '%dm %ds' "$m" "$s"
  fi
}

MAIN_SESMAN=""
main_sesman() {
  [ -n "$MAIN_SESMAN" ] && { printf '%s' "$MAIN_SESMAN"; return; }
  MAIN_SESMAN="$(systemctl show -p MainPID --value xrdp-sesman.service 2>/dev/null)"
  case "$MAIN_SESMAN" in ''|0) MAIN_SESMAN="" ;; esac
  printf '%s' "$MAIN_SESMAN"
}

is_descendant() {   # $1 = pid, $2 = ancestor pid
  local p="$1" n=0
  while [ -n "$p" ] && [ "$p" != 1 ] && [ "$p" != 0 ] && [ "$n" -lt 32 ]; do
    [ "$p" = "$2" ] && return 0
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    n=$((n + 1))
  done
  return 1
}

is_orphan() {   # $1 = Xorg pid  (the second argument is no longer used)
  local main
  main="$(main_sesman)"
  # No running sesman means nothing can be judged -- and reaping on a guess is
  # how a sweep logs out a room. Fail safe: nothing is an orphan.
  [ -n "$main" ] || return 1
  is_descendant "$1" "$main" && return 1
  return 0
}

# Every process of this user bound to ONE display, found by its own DISPLAY
# rather than by name.
#
# Scoped that way on purpose: somebody with a live session and an orphan has two
# of each, and killing by name would take down the desktop they are sitting in
# front of.
#
# gnome-session is the one that matters and the one the first version missed.
# It owns org.gnome.SessionManager on the user's bus, and that name -- not the
# X server -- is what makes the NEXT login exit 1 with "Session manager already
# running!". Reaping the X server and leaving it behind fixes the symptom in
# `it-rdp status` and not the thing the user is complaining about.
procs_on() {   # $1 = display, $2 = user -> pids
  local pid d
  for pid in $(ps -u "$2" -o pid= 2>/dev/null); do
    # Braces around the redirect, not just 2>/dev/null on tr: a kernel thread or
    # a process that exited between `ps` and here makes the SHELL print "No such
    # process" when it opens the file, and that message does not go through the
    # command's stderr.
    d="$({ tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null | sed -n 's/^DISPLAY=//p' | head -1)"
    [ "$d" = ":$1" ] && printf '%s\n' "$pid"
  done
}

# Everything belonging to one display: the X server, its chansrv, its sesman,
# and the socket that makes sesman skip the display next time.
kill_display() {   # $1 = display number, $2 = user
  local disp="$1" user="$2" pid
  # The session's own processes first -- gnome-session among them -- so the bus
  # name is released, then the X server they were drawing on.
  for pid in $(procs_on "$disp" "$user"); do
    kill -TERM "$pid" 2>/dev/null
  done
  for pid in $(pgrep -u "$user" -f "Xorg :$disp " 2>/dev/null); do
    kill -TERM "$pid" 2>/dev/null
  done
  sleep 2
  for pid in $(procs_on "$disp" "$user") \
             $(pgrep -u "$user" -f "Xorg :$disp " 2>/dev/null); do
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
    age="$(fmt_age "$pid")"
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
  head2 "X sockets  ${DIM}(xrdp allocates :$DISP_MIN-:$DISP_MAX)${R}"
  local s n stale=0
  for s in /tmp/.X11-unix/X*; do
    [ -e "$s" ] || continue
    n="${s##*/X}"
    if ! ours "$n"; then
      say "  X$n  $(stat -c '%U' "$s" 2>/dev/null) -- outside xrdp's range, left alone"
    elif pgrep -f "Xorg :$n " >/dev/null 2>&1; then
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

  # Sockets whose X server is already gone -- inside xrdp's display range only.
  # gdm's live sockets sit at X1024/X1025 and deleting those breaks the console
  # greeter, which is the one way back in when RDP is the thing that is broken.
  local s d
  for s in /tmp/.X11-unix/X*; do
    [ -e "$s" ] || continue
    d="${s##*/X}"
    ours "$d" || continue
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
    say "  :$disp  pid $pid  up $(fmt_age "$pid")"
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

# ---------------------------------------------------------------------------
# `perf` -- the settings and processes that decide whether RDP feels quick.
#
# Read-only, and meant to be run in the LAB before a box is deployed, because
# every one of these is far easier to change with the machine in front of you.
#
# It separates the two complaints, which have different causes and different
# fixes: REDRAW (dragging a window is choppy) is compositing and encoding,
# TYPING (characters arrive late) is the input path, and a fix for one does
# nothing for the other.
# ---------------------------------------------------------------------------
INI=/etc/xrdp/xrdp.ini
ini_get() { sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$INI" 2>/dev/null | tail -1; }
note() { printf '       %s%s%s\n' "$DIM" "$*" "$R"; }

XRDP_LOG=/var/log/xrdp.log

# Which codecs did the CLIENT offer, the last time one connected?
#
# This is the question every other setting depends on and the only one the box
# can answer for itself. xrdp logs it at INFO, which is the shipped LogLevel,
# so it is already in the log -- nobody had read it.
codecs_offered() {
  sed -nE 's/.*xrdp_caps_process_codecs: ([A-Za-z0-9]+),.*/\1/p' "$XRDP_LOG" 2>/dev/null \
    | tail -8 | sort -u | tr '\n' ' '
}

cmd_perf() {
  local v

  # -------------------------------------------------------------------------
  # THE CEILING. Everything below this is trimming; this decides which of two
  # completely different code paths a session runs on.
  #
  # xrdp/xrdp_encoder.c:xrdp_encoder_create() refuses to build an encoder
  # unless ALL THREE hold:
  #   1. the client offered jpeg, RemoteFX or H.264       (codec selection)
  #   2. client_info->mcs_connection_type == CONNECTION_TYPE_LAN  (0x06)
  #   3. client_info->bpp >= 24
  # When it refuses, every update goes down the legacy bitmap path in xrdp's
  # SINGLE main thread. That is what a choppy drag is.
  # -------------------------------------------------------------------------
  head2 "Codec the client negotiated  (the ceiling on everything else)"
  local offered
  offered="$(codecs_offered)"
  if [ ! -r "$XRDP_LOG" ]; then
    warn "cannot read $XRDP_LOG -- run this as root"
  elif [ -z "$offered" ]; then
    say "  ${DIM}no client has connected since this log was rotated -- connect once, re-run${R}"
  elif printf '%s' "$offered" | grep -qi 'RemoteFX'; then
    ok "client offered: $offered"
    note "RemoteFX is present, so an accelerated encoder is possible."
    note "It is still only USED when the client says LAN and bpp is 24 or more --"
    note "see the client settings under 'it-rdp client'."
  else
    bad "client offered: $offered  -- no RemoteFX, no H.264"
    say  "  ${DIM}This session is on the LEGACY BITMAP PATH. xrdp builds no encoder${R}"
    say  "  ${DIM}at all, so every update is RLE bitmaps in its single main thread.${R}"
    say  "  ${DIM}Dragging a window is the worst case for it, which is why dragging is${R}"
    say  "  ${DIM}what people complain about while applications still open fast.${R}"
    say ""
    note "Windows 11's mstsc.exe stopped advertising RemoteFX (xrdp issue #2400),"
    note "and 0.9.24 -- what Ubuntu 24.04 ships -- has no GFX/H.264 to fall back on."
    note "NOTHING in $INI changes this. The fix is a newer xrdp or a different"
    note "server; see reference.md trap 12i before anyone spends a day on settings."
  fi

  head2 "Redraw path (choppy windows)"
  v="$(ini_get bitmap_compression)"
  case "$v" in
    false) ok "bitmap_compression=false -- right for a LAN" ;;
    "")    warn "bitmap_compression not set (xrdp defaults it TRUE)"
           note "on a LAN this spends CPU to save bandwidth you have. Set it false." ;;
    *)     warn "bitmap_compression=$v -- spends CPU to save bandwidth"
           note "this fleet is LAN-attached and xrdp is the bottleneck. Set it false." ;;
  esac
  # The second compressor. bitmap_compression is per-bitmap RLE; this one is
  # MPPC over the whole outgoing PDU stream, and it runs in the same thread.
  v="$(ini_get bulk_compression)"
  case "$v" in
    false) ok "bulk_compression=false -- right for a LAN" ;;
    "")    warn "bulk_compression not set (xrdp defaults it TRUE)"
           note "MPPC over every PDU, in the thread that is already the bottleneck." ;;
    *)     warn "bulk_compression=$v -- a second compressor on the same thread" ;;
  esac
  v="$(ini_get max_bpp)"
  if [ "${v:-24}" -lt 24 ] 2>/dev/null; then
    bad "max_bpp=$v -- BELOW 24 disables xrdp's encoder outright (xrdp_encoder.c)"
    note "not a quality trade: at 16 there is no codec path to fall back from."
  else
    ok "max_bpp=${v:-<unset>}"
    [ "${v:-24}" != 32 ] && note "if the client asks for 32, xrdp converts EVERY tile. Raising this to 32 can be faster."
  fi
  for k in bitmap_cache new_cursors tcp_nodelay; do
    v="$(ini_get "$k")"
    [ "$v" = true ] && ok "$k=true" || warn "$k=${v:-<unset>} -- should be true"
  done

  head2 "Input path (late characters)"
  # fastpath is the one that matters for TYPING: without it every keystroke
  # carries the older, heavier RDP input PDU. It is not set by this repo, so on
  # most boxes it is whatever the xrdp package shipped.
  v="$(ini_get use_fastpath)"
  case "$v" in
    both|input) ok "use_fastpath=$v" ;;
    "")         warn "use_fastpath not set -- xrdp's default applies"
                note "set it to 'both' in $INI and restart xrdp; it is the keystroke path." ;;
    *)          warn "use_fastpath=$v -- 'both' covers input and output" ;;
  esac
  if pgrep -x ibus-daemon >/dev/null 2>&1; then
    warn "ibus is running -- every keystroke passes through the input method"
    note "if nobody needs a non-Latin input method:  im-config -n none  (then log out)"
    note "that removes a hop from the typing path and is the usual fix for input lag."
  else
    ok "no ibus input-method hop"
  fi

  head2 "TCP socket buffer  (untried on this fleet)"
  v="$(ini_get tcp_send_buffer_bytes)"
  if [ -z "$v" ]; then
    say "  ${DIM}unset -- the kernel autotunes, which is xrdp's default and today's state${R}"
    note "A drag hands xrdp megabytes at once; a small socket buffer makes its"
    note "single thread block in write() mid-frame. Worth ONE experiment:"
    note "  sudo sed -i 's/^#tcp_send_buffer_bytes=.*/tcp_send_buffer_bytes=4194304/' $INI"
    note "  sudo sysctl -w net.core.wmem_max=4194304 && sudo systemctl restart xrdp"
    note "Reconnect, then re-run this -- the line below says what it actually got."
    note "If it helps, set dev_rdp_tcp_send_buffer_bytes so a pull keeps it."
  else
    ok "tcp_send_buffer_bytes=$v"
    # xrdp logs the value the KERNEL gave back, which is the one that matters:
    # SO_SNDBUF is clamped to net.core.wmem_max and the clamp is silent.
    local got
    got="$(grep -a 'send buffer set to' "$XRDP_LOG" 2>/dev/null | tail -1 | grep -oE '[0-9]+ bytes' | head -1)"
    if [ -n "$got" ]; then
      note "xrdp.log says the kernel gave it $got (it doubles what you ask for)"
      note "much smaller than asked -> net.core.wmem_max clamped it."
    fi
    printf '       %snet.core.wmem_max = %s%s\n' "$DIM" "$(sysctl -n net.core.wmem_max 2>/dev/null)" "$R"
  fi

  head2 "What the session is spending it on"
  if command -v ps >/dev/null 2>&1; then
    ps -eo pcpu,user,comm --sort=-pcpu 2>/dev/null | awk 'NR==1 || NR<=6' | sed 's/^/       /'
    note "measure DURING a window drag, with no FPGA tool open, or you are timing the tool."
    note "gnome-shell high -> compositing; xrdp high -> encoding; neither -> the link."
  fi

  head2 "Cheapest lever, and it is not on this box"
  say "  Lower the CLIENT resolution one step (1920x1080 -> 1600x900)."
  say "  It is the only change that cuts compositing AND encoding at once, needs"
  say "  nothing here, and beats every setting above on a machine with no GPU."
  say ""
  say "  ${DIM}A lighter desktop is NOT an option on this fleet: Flashback's panel${R}"
  say "  ${DIM}and the classification banner want the same screen edge.${R}"
  say ""
}

# ---------------------------------------------------------------------------
# `client` -- what to put in the .rdp file on the Windows box.
#
# This exists because the intuitive move is the wrong one. mstsc's "Experience"
# tab sets the connectionType byte in TS_UD_CS_CORE, and xrdp's encoder refuses
# to start unless that byte is exactly CONNECTION_TYPE_LAN (0x06). Choosing a
# slower connection type -- or leaving the Windows 11 default, "Detect
# connection quality automatically", which sends 0x07 -- puts the session on
# the legacy bitmap path. Turning the quality DOWN is what turns the fast path
# OFF, which is why nobody finds this by experimenting.
# ---------------------------------------------------------------------------
cmd_client() {
  head2 "Windows-side .rdp settings"
  say "  Save as dev-XX.rdp next to the shortcut and open THAT, or paste these"
  say "  into an existing .rdp with Notepad. The Experience tab cannot express"
  say "  the first two, which is the point."
  say ""
  cat <<'RDP'
       full address:s:dev-XX
       connection type:i:6
       networkautodetect:i:0
       bandwidthautodetect:i:0
       bitmapcachepersistenable:i:1
       use multimon:i:0
       desktopwidth:i:1600
       desktopheight:i:900
       audiomode:i:2
RDP
  say ""
  note "connection type 6 = LAN. It is the ONLY value that lets xrdp build an"
  note "encoder at all; 7 (autodetect, the Windows 11 default) does not count."
  note "networkautodetect MUST be 0 or mstsc overrides the line above with 7."
  note "use multimon 0 -- a second monitor doubles every pixel xrdp encodes."
  note "desktopwidth/height are the cheapest lever there is on a box with no GPU."
  note "audiomode 2 = do not play remote audio; drop it if anyone needs sound."
  say ""
  say "  ${DIM}On this fleet, with a Windows 11 client and xrdp 0.9.24, the encoder${R}"
  say "  ${DIM}still will not start -- mstsc no longer offers RemoteFX. These make${R}"
  say "  ${DIM}the legacy path as cheap as it gets and stop the client throttling${R}"
  say "  ${DIM}itself. Run 'it-rdp perf' to see which path a session actually took.${R}"
  say ""
}

case "${1:-status}" in
  perf)       cmd_perf ;;
  client)     cmd_client ;;
  status|"")  cmd_status ;;
  sweep)      cmd_sweep ;;
  reset)      shift; cmd_reset "$@" ;;
  restart)    shift; cmd_restart "$@" ;;
  *)          die "unknown command: ${1}
$(usage)" ;;
esac
