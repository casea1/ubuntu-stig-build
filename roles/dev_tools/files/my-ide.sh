#!/usr/bin/env bash
# my-ide -- your browser IDE (code-server). Yours to start and stop: no sudo,
# no admin, nothing to ask for.
#
#   my-ide              start it if it is not running, then open it
#   my-ide stop         stop it
#   my-ide status       is it running, and where
#   my-ide password     show the password (it is yours, kept in your own config)
#   my-ide remote       the address to use from another PC on the network
#   my-ide always       start it every time I log in
#   my-ide never        stop doing that
#
# There is an "IDE" tile in the applications grid that runs this with no
# arguments -- clicking it is the whole workflow.
#
# It is a systemd USER service, so it lives inside your login session: nothing
# runs at boot, and it stops when you log out. If you need it reachable while
# you are logged out, ask an admin to enable lingering for you.
#
# Admins: this is a thin front on the same unit `it-codeserver` manages.
set -uo pipefail

CONF="${XDG_CONFIG_HOME:-$HOME/.config}/code-server/config.yaml"
UNIT=code-server.service

if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[0m'
else B=""; DIM=""; G=""; Y=""; R=""; fi

# Errors have to reach a person who launched this from a MENU TILE, where there
# is no terminal to print to and a silent exit looks like a broken machine.
# ALWAYS to stderr, and a desktop notification as WELL when there is a display
# and no terminal to have printed to. Choosing one or the other on `[ -t 1 ]`
# was wrong twice over: piping the output of a perfectly ordinary command run
# from a shell took the notify-send branch and the person got a silent exit
# with status 1, and a notification that fails (no daemon, no display) left
# nothing behind either.
oops() {
  printf '%s%s%s\n' "$Y" "$*" "$R" >&2
  if [ ! -t 2 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    notify-send -u critical "IDE" "$*" 2>/dev/null || true
  fi
  exit 1
}

MARK='# Managed by it-codeserver -- do not edit by hand.'

# FIRST RUN: no config of ours yet, so ask for a port. The claim service is
# root, started by systemd for this one connection; it asks the kernel who we
# are, so there is nothing to type and nothing to fake. A config without MARK
# is code-server's own default (port 8080, someone else's) and is replaced.
claim() {
  python3 -Ic 'import os, socket, sys
p = "/run/code-server-claim.sock"
if not os.path.exists(p):
    print("ERR the setup service is not installed or not running ({} is missing). IT: sudo it-pull, then systemctl status code-server-claim.socket".format(p)); sys.exit()
s = socket.socket(socket.AF_UNIX); s.settimeout(45)
try:
    s.connect(p); s.sendall(b"claim\n")
except OSError as e:
    print("ERR could not reach the setup service ({}). IT: systemctl status code-server-claim.socket".format(e.strerror or e)); sys.exit()
out = b""
while True:
    try:
        d = s.recv(4096)
    except ConnectionResetError:
        break
    except socket.timeout:
        print("ERR the setup service did not answer within 45 seconds. IT: journalctl -u code-server-claim@\\* -n 30"); sys.exit()
    if not d: break
    out += d
if not out:
    print("ERR the setup service started but gave no answer. IT: journalctl -u code-server-claim@\\* -n 30"); sys.exit()
sys.stdout.write(out.decode())' 2>&1
}
case "${1:-open}" in -h|--help|help) awk 'NR>1&&/^#/{sub(/^# ?/,"");print;next}NR>1{exit}' "$0"; exit 0 ;; esac
if ! grep -qsF "$MARK" "$CONF"; then
  case "${1:-open}" in open|start) ;;
    *) oops "You have no browser IDE on this machine yet. Run my-ide on its own to set one up." ;;
  esac
  r="$(claim)"
  case "$r" in
    OK*) printf '  %sThis machine has given you port %s for your IDE. It stays yours.%s\n' "$G" "${r#OK }" "$R" ;;
    NO*) oops "You cannot have a browser IDE on this machine: ${r#NO }.
Ask IT if you should." ;;
    ERR*) oops "Could not set up your browser IDE: ${r#ERR }" ;;
    *)   oops "Could not set up your browser IDE (unexpected answer: ${r:-none}). Ask IT, or IT can run: sudo it-codeserver claim $(id -un)" ;;
  esac
  grep -qsF "$MARK" "$CONF" || oops "Your IDE settings were not written. Ask IT."
  # One started on code-server's own default config is on someone else's port.
  systemctl --user is-active --quiet "$UNIT" 2>/dev/null && systemctl --user restart "$UNIT" 2>/dev/null
fi

port="$(sed -nE 's/^bind-addr:.*:([0-9]+)[[:space:]]*$/\1/p' "$CONF" | tail -1)"
pass="$(sed -nE 's/^password:[[:space:]]*//p' "$CONF" | tail -1)"
[ -n "$port" ] || oops "Your IDE settings look wrong -- no port in $CONF. Ask IT."

# On this machine, localhost. The certificate this thing generates is issued for
# "localhost", so using that name is also what keeps the browser from warning
# about it -- reaching it by IP is what makes the warning appear.
LOCAL_URL="https://localhost:$port/"

lan_url() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p' | head -1)"
  [ -n "$ip" ] || ip="$(hostname -f 2>/dev/null || hostname)"
  printf 'https://%s:%s/' "$ip" "$port"
}

running() { systemctl --user is-active --quiet "$UNIT" 2>/dev/null; }

have_session() {
  [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "${XDG_RUNTIME_DIR}/bus" ]
}

# Whose process is listening on a port: its uid, or nothing. From the kernel's
# own table, so it works without root and without ss.
port_owner() {
  local f fs=()
  for f in /proc/net/tcp /proc/net/tcp6; do [ -r "$f" ] && fs+=("$f"); done
  awk -v p="$(printf '%04X' "$1")" \
    'FNR > 1 && $4 == "0A" { n = split($2, a, ":"); if (a[n] == p) { print $8; exit } }' "${fs[@]}"
}

# Someone else's instance on OUR port: ours cannot bind, and the browser
# reaches theirs -- whose password is not ours. Left over from a renumber.
not_on_someone_elses() {
  local o who; o="$(port_owner "$port")"
  [ -z "$o" ] || [ "$o" = "$(id -u)" ] && return 0
  who="$(getent passwd "$o" | cut -d: -f1)"; who="${who:-uid $o}"
  oops "Your port ($port) is being used by $who's IDE, so the password is not
yours there. Ask IT to run:  sudo it-codeserver stop $who"
}

# code-server reads its config only when it starts. A config changed since
# (a new port or password) is not what the running one is using.
stale() {
  local pid el
  pid="$(systemctl --user show -p MainPID --value "$UNIT" 2>/dev/null)"
  [ "${pid:-0}" -gt 0 ] 2>/dev/null || return 1
  el="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"; [ -n "$el" ] || return 1
  [ "$(stat -c %Y "$CONF")" -gt $(( $(date +%s) - el )) ]
}

start_it() {
  have_session || oops "Your IDE can only start from a desktop or SSH login of your own.
This shell has no login session (su / sudo -u will not work)."
  if running; then
    stale || { not_on_someone_elses; return 0; }
    systemctl --user restart "$UNIT" \
      || oops "Your IDE would not restart. Show this to IT:  journalctl --user -u code-server -n 40"
  else
    not_on_someone_elses
    systemctl --user start "$UNIT" \
      || oops "Your IDE would not start. Show this to IT:  journalctl --user -u code-server -n 40"
  fi
  # Wait for OUR process on the port rather than guessing: opening the browser
  # first shows a connection error and people conclude it is broken.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    # is-failed, not "not is-active": a unit that is still `activating` is not
    # active yet, and treating that as a failure would abort on a slow start.
    systemctl --user is-failed --quiet "$UNIT" 2>/dev/null \
      && oops "Your IDE stopped right after starting. Show this to IT:  journalctl --user -u code-server -n 40"
    [ "$(port_owner "$port")" = "$(id -u)" ] && return 0
    sleep 1
  done
  not_on_someone_elses
  return 0
}

open_it() {
  if command -v xdg-open >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    xdg-open "$LOCAL_URL" >/dev/null 2>&1 &
    return 0
  fi
  return 1
}

case "${1:-open}" in
  open|start|"")
    start_it
    if open_it; then
      printf '  %sYour IDE is open.%s  %s\n' "$G" "$R" "$LOCAL_URL"
    else
      printf '  %sYour IDE is running.%s\n\n    %s%s%s\n' "$G" "$R" "$B" "$LOCAL_URL" "$R"
    fi
    printf '    password: %s%s%s\n\n' "$B" "${pass:-see $CONF}" "$R"
    printf '  %sIt stops when you log out. `my-ide always` to start it every login.%s\n\n' "$DIM" "$R" ;;
  stop)
    have_session || oops "No login session here."
    systemctl --user stop "$UNIT" && printf '  Your IDE is stopped.\n' ;;
  restart)
    have_session || oops "No login session here."
    systemctl --user restart "$UNIT" && printf '  Your IDE restarted.  %s\n' "$LOCAL_URL" ;;
  status)
    printf '\n  %sYour IDE%s\n' "$B" "$R"
    printf '    state     %s\n' "$(running && echo "${G}running${R}" || echo "${Y}stopped${R}")"
    printf '    on here   %s\n' "$LOCAL_URL"
    printf '    from a PC %s\n' "$(lan_url)"
    have_session && printf '    at login  %s\n' \
      "$(systemctl --user is-enabled "$UNIT" 2>/dev/null | head -1)"
    printf '\n' ;;
  password|pass)
    printf '%s\n' "${pass:-}" ;;
  remote|url)
    printf '%s\n' "$(lan_url)"
    printf '  %sExpect a certificate warning from another PC -- the certificate is%s\n' "$DIM" "$R"
    printf '  %sissued to this machine by itself. Accept it and log in.%s\n' "$DIM" "$R" ;;
  always)
    have_session || oops "No login session here."
    systemctl --user enable --now "$UNIT" >/dev/null 2>&1 \
      && printf '  Your IDE will start whenever you log in.\n' ;;
  never)
    have_session || oops "No login session here."
    systemctl --user disable "$UNIT" >/dev/null 2>&1 \
      && printf '  Your IDE will no longer start when you log in.\n' ;;
  -h|--help|help)
    awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0" ;;
  *) printf 'my-ide: do not know "%s". Try: my-ide help\n' "$1" >&2; exit 2 ;;
esac
