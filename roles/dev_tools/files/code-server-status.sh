#!/usr/bin/env bash
# it-codeserver -- who has a browser IDE, on which port, and its password.
#
# code-server is SINGLE-USER PER INSTANCE -- there is no multi-tenant mode -- so
# each user runs their own on their own port. The port is derived from the UID,
# not from a position in a list, so it is stable for a person: removing someone
# from the group does not move everyone else.
#
#   it-codeserver              who is running, on what, and whether it is up
#   it-codeserver password <user>   show that user's password (root only)
#   it-codeserver url <user>        the URL to hand them
#   it-codeserver restart <user>    after a config change
#   it-codeserver log <user> [N]    last N journal lines (default 40)
#
# Entitlement is group membership (dev_code_server_group, `sentry` by default),
# applied by the pull -- add someone to the group and pull, do not enable the
# unit by hand or the next pull will not know about them.
set -uo pipefail

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; R=$'\033[0m'
else B=""; DIM=""; GRN=""; YEL=""; RED=""; R=""; fi
say()   { printf '%s\n' "$*"; }
head2() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }
die()   { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }

case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

instances() {   # every enabled code-server@<user>
  systemctl list-unit-files 'code-server@*' --no-legend 2>/dev/null \
    | awk '$2=="enabled"{print $1}' | sed 's/^code-server@//; s/\.service$//' | sort
}

conf_of() { local h; h=$(getent passwd "$1" | cut -d: -f6); printf '%s/.config/code-server/config.yaml' "$h"; }
bind_of() { sed -nE 's/^bind-addr:[[:space:]]*//p' "$(conf_of "$1")" 2>/dev/null | tail -1; }

cmd_status() {
  local u bind state n=0
  head2 "code-server -- $(hostname -s)"
  command -v code-server >/dev/null 2>&1 || die "code-server is not installed"

  printf '  %-24s %-22s %-10s %s\n' USER "BIND" STATE URL
  printf '  %s\n' "$(printf '%.0s-' $(seq 1 88))"
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    n=$((n + 1))
    bind="$(bind_of "$u")"
    state="$(systemctl is-active "code-server@$u" 2>/dev/null || echo inactive)"
    printf '  %-24s %-22s %s%-10s%s %s\n' "$u" "${bind:-?}" \
      "$([ "$state" = active ] && printf '%s' "$GRN" || printf '%s' "$RED")" "$state" "$R" \
      "$(url_for "$u")"
  done < <(instances)
  [ "$n" -eq 0 ] && say "  ${DIM}none enabled -- add someone to the entitlement group and run a pull${R}"

  head2 "Passwords"
  say "  ${DIM}One per user, generated once, root-only in /etc/code-server/.${R}"
  say "  ${DIM}Show one:  sudo it-codeserver password <user>${R}"

  # The thing worth noticing on a hardened box: what is actually listening.
  head2 "Listening"
  ss -ltnp 2>/dev/null | grep -i 'code-server\|node' | sed 's/^/  /' \
    || say "  ${DIM}(nothing, or ss is unavailable)${R}"
  say ""
  case "$(bind_of "$(instances | head -1)")" in
    127.0.0.1:*) say "  ${DIM}Loopback-only: reach it from the RDP desktop's browser, or over an${R}"
                 say "  ${DIM}SSH tunnel:  ssh -L 8080:127.0.0.1:<port> <box>${R}" ;;
    0.0.0.0:*|*) printf '  %sThese are on the LAN%s, one port per user, password-authed over\n' "$YEL" "$R"
                 say "  self-signed TLS. ufw rate-limits the range. Set"
                 say "  dev_code_server_bind_addr: 127.0.0.1 to take them off the LAN." ;;
  esac
  say ""
}

url_for() {
  local u="$1" bind port host
  bind="$(bind_of "$u")"; port="${bind##*:}"
  [ -n "$port" ] || { printf '%s' "-"; return; }
  case "$bind" in
    127.0.0.1:*) host=localhost ;;
    *) host="$(hostname -f 2>/dev/null || hostname)" ;;
  esac
  printf 'https://%s:%s/' "$host" "$port"
}

case "${1:-status}" in
  ""|status) cmd_status ;;
  password|passwd)
    [ -n "${2:-}" ] || die "usage: it-codeserver password <user>"
    f="/etc/code-server/$2.password"
    [ -r "$f" ] || die "no password on file for $2 -- has the pull configured them?"
    head2 "code-server password for $2"
    printf '\n      %s%s%s\n\n' "$B" "$(cat "$f")" "$R"
    say "  ${DIM}Hand it over the way your site hands over a password -- not by email.${R}"
    say "  ${DIM}URL: $(url_for "$2")${R}"; say "" ;;
  url)
    [ -n "${2:-}" ] || die "usage: it-codeserver url <user>"; url_for "$2"; echo ;;
  restart)
    [ -n "${2:-}" ] || die "usage: it-codeserver restart <user>"
    systemctl restart "code-server@$2" && echo "restarted code-server@$2" ;;
  log)
    [ -n "${2:-}" ] || die "usage: it-codeserver log <user> [N]"
    journalctl -u "code-server@$2" -n "${3:-40}" --no-pager ;;
  *) die "unknown command: $1  (try: it-codeserver --help)" ;;
esac
