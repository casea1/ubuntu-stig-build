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

[ -r "$CONF" ] || oops "You do not have a browser IDE set up on this machine.
Ask IT to add you to the group that gets one."

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

start_it() {
  have_session || oops "Your IDE can only start from a desktop or SSH login of your own.
This shell has no login session (su / sudo -u will not work)."
  running && return 0
  systemctl --user start "$UNIT" \
    || oops "Your IDE would not start. Show this to IT:  journalctl --user -u code-server -n 40"
  # Wait for the port rather than guessing: opening the browser first shows a
  # connection error and people conclude it is broken.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    # is-failed, not "not is-active": a unit that is still `activating` is not
    # active yet, and treating that as a failure would abort on a slow start.
    systemctl --user is-failed --quiet "$UNIT" 2>/dev/null \
      && oops "Your IDE stopped right after starting. Show this to IT:  journalctl --user -u code-server -n 40"
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && return 0
    sleep 1
  done
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
