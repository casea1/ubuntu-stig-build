#!/usr/bin/env bash
# it-codeserver -- who has a browser IDE, on which port, and its password.
#
# code-server is SINGLE-USER PER INSTANCE -- there is no multi-tenant mode -- so
# each user runs their own on their own port. The port is derived from the UID,
# not from a position in a list, so it is stable for a person: removing someone
# from the group does not move everyone else.
#
# FOR AN ENGINEER -- your own instance. NO SUDO, no admin, no ticket:
#
#   it-codeserver mine              your URL, your password, is it running
#   it-codeserver mine start        start it
#   it-codeserver mine stop
#   it-codeserver mine restart
#   it-codeserver mine enable       start it whenever I log in
#   it-codeserver mine disable
#   it-codeserver mine log [N]
#
# It is a systemd USER service, so it is yours to start and stop -- there is
# nothing to grant and nothing to ask for. `mine` takes no username: it acts on
# whoever is calling.
#
# FOR AN ADMIN -- the whole box:
#
#   it-codeserver              who is running, on what, and whether it is up
#   it-codeserver password <user>   show that user's password (root only)
#   it-codeserver url <user>        the URL to hand them
#   it-codeserver start <user>      start one in that user's own manager
#   it-codeserver stop <user>       stop one
#   it-codeserver restart <user>    after a config change
#   it-codeserver linger <user> on  let their IDE run while they are logged out
#   it-codeserver log <user> [N]    last N journal lines (default 40)
#
# NOTHING STARTS AT BOOT, AND NOTHING NEEDS ROOT. Those used to pull against
# each other: the instance was a SYSTEM unit, so it either ran for everybody
# from boot -- N node processes and N listening ports for the box's whole
# uptime, including accounts that can never log in -- or it stayed off and an
# engineer had no way to start their own.
#
# A systemd USER service settles both. It exists only inside its owner's
# session, so there is nothing at boot, and it is theirs to start, so there is
# no sudo and no grant. Lingering is what would put one back at boot, and it is
# off unless an admin turns it on for a named person
# (dev_code_server_linger_users, or `it-codeserver linger <user> on`).
#
# Entitlement is group membership (dev_code_server_group, `sentry` by default),
# applied by the pull -- add someone to the group and pull, do not enable the
# unit by hand or the next pull will not know about them. An account with a
# LOCKED PASSWORD is skipped: it cannot log in, so it cannot use an IDE.
set -uo pipefail

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; R=$'\033[0m'
else B=""; DIM=""; GRN=""; YEL=""; RED=""; R=""; fi
say()   { printf '%s\n' "$*"; }
head2() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }
die()   { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
warn()  { printf '  %sWARN%s %s\n' "$YEL" "$R" "$*"; }
bad()   { printf '  %sFAIL%s %s\n' "$RED" "$R" "$*"; }
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }

case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac

# `mine` is the ENGINEER's half of this command and NONE of it elevates. The
# instance is a systemd USER service, so starting and stopping it is something
# the account can already do for itself -- that is the point of the design, and
# it is why there is no sudoers grant to go with it.
_needs_root=1
[ "${1:-}" = mine ] && _needs_root=0
[ "$_needs_root" = 0 ] || [ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

# Who "mine" means. Run directly it is whoever is logged in; SUDO_USER is still
# honoured for anyone who types sudo out of habit. Never root -- root has no
# instance, and silently acting on an account called "root" is worse than
# refusing.
whoami_real() {
  local me="${SUDO_USER:-$(id -un)}"
  [ "$me" = root ] && die "run this as yourself, not with sudo -- your instance is your own (it-codeserver status lists everyone)"
  printf '%s' "$me"
}

# `systemctl --user` needs a running user manager, which means a real login
# session. Someone who arrives by `su -` or a bare `sudo -u` has no session
# bus, and systemctl's own error ("Failed to connect to bus") sends people
# looking for a broken service instead of a missing session.
user_bus_ok() {
  [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "${XDG_RUNTIME_DIR}/bus" ]
}

conf_of() { local h; h=$(getent passwd "$1" | cut -d: -f6); printf '%s/.config/code-server/config.yaml' "$h"; }
bind_of() { sed -nE 's/^bind-addr:[[:space:]]*//p' "$(conf_of "$1")" 2>/dev/null | tail -1; }

instances() {   # every account this box has configured an instance for
  # Entitlement used to be read from system units. There are none now -- the
  # instance is a user service -- so the thing that says "this person has one"
  # is the config the pull wrote for them. Old code-server@<user> units are
  # still listed so a box mid-migration shows them and the pull can clear them.
  {
    getent passwd | awk -F: '$3 >= 1000 && $3 < 65000 {print $1}' | while read -r n; do
      [ -r "$(conf_of "$n")" ] && printf '%s\n' "$n"
    done
    systemctl list-units --all --plain --no-legend 'code-server@*.service' 2>/dev/null \
      | awk '{print $1}' | sed 's/^code-server@//; s/\.service$//'
  } | grep -vE '^$' | sort -u
}

# What a user's own manager says about their instance. Needs the user manager
# to exist, which without lingering means they are logged in -- so "inactive"
# here legitimately means "nobody is using it", not "it is broken".
user_state() {   # $1 = user
  sctl1 systemctl --user --machine="$1@.host" is-active code-server.service
}

# systemctl's is-active/is-enabled PRINT their answer and also exit non-zero
# for every state but the good one. `$(cmd || echo inactive)` therefore yields
# TWO lines on a box where the unit exists and is simply stopped -- which is the
# normal case this command is for. Take the first line and ignore the status.
sctl1() {   # $@ = systemctl args -> one word, never empty
  local out
  out="$("$@" 2>/dev/null | head -1)"
  printf '%s' "${out:-unknown}"
}

lingers() {   # $1 = user -> "yes"/"no"
  case "$(loginctl show-user "$1" -p Linger --value 2>/dev/null)" in
    yes) printf 'yes' ;; *) printf 'no' ;;
  esac
}


# The ports these instances are actually configured for, as an alternation:
# "8080|8083". Used to ask what is listening and to find the ufw rule.
cs_ports() {
  local u b
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    b="$(bind_of "$u")"; [ -n "$b" ] && printf '%s\n' "${b##*:}"
  done < <(instances) | sort -u | paste -sd'|'
}

# Does a ufw LIMIT rule cover any of these ports? The rule is written as a
# RANGE (8080:8099/tcp), so a plain string match on one user's port misses it
# for everyone except the one whose port happens to start the range.
ufw_limits() {   # $1 = "8080|8083"
  ufw status 2>/dev/null | awk -v list="$1" '
    $2 == "LIMIT" {
      spec = $1; sub(/\/(tcp|udp)$/, "", spec)
      n = split(list, want, "|")
      if (spec ~ /:/) {
        split(spec, r, ":")
        for (i = 1; i <= n; i++)
          if (want[i]+0 >= r[1]+0 && want[i]+0 <= r[2]+0) { print spec; exit }
      } else {
        for (i = 1; i <= n; i++) if (want[i]+0 == spec+0) { print spec; exit }
      }
    }' | grep -q .
}

cmd_status() {
  local u bind state n=0 ports
  ports="$(cs_ports)"
  head2 "code-server -- $(hostname -s)"
  command -v code-server >/dev/null 2>&1 || die "code-server is not installed"

  printf '  %-20s %-20s %-9s %-7s %s\n' USER "BIND" STATE LINGER URL
  printf '  %s\n' "$(printf '%.0s-' $(seq 1 88))"
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    n=$((n + 1))
    bind="$(bind_of "$u")"
    state="$(user_state "$u")"
    printf '  %-20s %-20s %s%-9s%s %-7s %s\n' "$u" "${bind:-?}" \
      "$([ "$state" = active ] && printf '%s' "$GRN" || printf '%s' "$RED")" "$state" "$R" \
      "$(lingers "$u")" "$(url_for "$u")"
  done < <(instances)
  [ "$n" -eq 0 ] && say "  ${DIM}none enabled -- add someone to the entitlement group and run a pull${R}"

  head2 "Passwords"
  say "  ${DIM}One per user, generated once, root-only in /etc/code-server/.${R}"
  say "  ${DIM}Show one:  sudo it-codeserver password <user>${R}"

  # The thing worth noticing on a hardened box: what is actually listening.
  #
  # "(nothing, or ss is unavailable)" used to cover both, and they need
  # completely different answers -- one is a broken service, the other is a
  # missing tool. Worse, it filtered on the PROCESS name, so an instance
  # listening under any comm but node/code-server read as nothing listening at
  # all. Filter on the PORTS these instances are configured for instead.
  head2 "Listening"
  if ! command -v ss >/dev/null 2>&1; then
    warn "ss is not installed (iproute2) -- cannot tell what is bound"
  else
    local listening=""
    [ -n "$ports" ] && listening="$(ss -ltnH 2>/dev/null | awk -v p="^($ports)$" '{n=$4; sub(/.*:/,"",n); if (n ~ p) print}')"
    if [ -n "$listening" ]; then
      ss -ltnp 2>/dev/null | awk -v p="($ports)" 'NR==1 || $4 ~ ":"p"$"' | sed 's/^/  /'
    else
      bad "nothing is listening on ${ports:-the configured port(s)}"
      say "  ${DIM}A unit can be 'active' and still not be bound -- read its log:${R}"
      say "  ${DIM}  sudo it-codeserver log <user>${R}"
    fi
  fi
  say ""
  case "$(bind_of "$(instances | head -1)")" in
    127.0.0.1:*) say "  ${DIM}Loopback-only: reach it from the RDP desktop's browser, or over an${R}"
                 say "  ${DIM}SSH tunnel:  ssh -L 8080:127.0.0.1:<port> <box>${R}" ;;
    0.0.0.0:*|*) printf '  %sThese are on the LAN%s, one port per user, password-authed over\n' "$YEL" "$R"
                 say "  self-signed TLS. Set dev_code_server_bind_addr: 127.0.0.1 to"
                 say "  take them off the LAN."
                 say ""
                 say "  ${DIM}Reaching one from a Windows PC: use the URL above (an IP). The${R}"
                 say "  ${DIM}hostname only works where something publishes a DNS record for${R}"
                 say "  ${DIM}it. Expect a certificate warning -- the cert is self-signed.${R}"
                 if [ -n "$ports" ] && ufw_limits "$ports"; then
                   say ""
                   warn "the ufw rule for these ports is LIMIT, not ALLOW"
                   say "  ${DIM}ufw limit drops a source after 6 connections in 30s. A login page${R}"
                   say "  ${DIM}is a couple of requests; the editor that loads after it is dozens${R}"
                   say "  ${DIM}at once, so the first real page load trips it and everything after${R}"
                   say "  ${DIM}times out. Confirm:  sudo journalctl -kf | grep 'UFW LIMIT BLOCK'${R}"
                 fi ;;
  esac
  say ""
}

# The address a CLIENT can actually reach. Printing the hostname was wrong for
# the case this tool exists to serve: an engineer on a Windows PC on the lab
# LAN, where nothing publishes a DNS record for `dev-18`. Chrome then reports
# "dev-18 took too long to respond" and it reads as the service being down when
# it is the NAME that never resolved. The IP always works.
lan_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | sed -nE 's/.* src ([0-9.]+).*/\1/p' | head -1
}

url_for() {
  local u="$1" bind port host
  bind="$(bind_of "$u")"; port="${bind##*:}"
  [ -n "$port" ] || { printf '%s' "-"; return; }
  case "$bind" in
    127.0.0.1:*) host=localhost ;;
    *) host="$(lan_ip)"; [ -n "$host" ] || host="$(hostname -f 2>/dev/null || hostname)" ;;
  esac
  printf 'https://%s:%s/' "$host" "$port"
}

# ---------------------------------------------------------------------------
# THE ENGINEER'S VIEW. Everything above is written for an admin looking at the
# whole box. An engineer needs four things about their OWN account -- is it
# running, what is the URL, what is the password, how do I start it -- and has
# no sudo for the fleet view. `mine` takes no username argument on purpose:
# that is what makes the sudoers grant safe to give the whole group, since the
# account is derived here from who is calling rather than from an argument.
# ---------------------------------------------------------------------------
cmd_mine() {
  local me url state pw conf
  # `|| exit` is load-bearing: die() inside a command substitution exits the
  # SUBSHELL, so without this a refusal would print its message and then carry
  # on with an empty username.
  me="$(whoami_real)" || exit 1
  conf="$(conf_of "$me")"
  [ -r "$conf" ] || die "no code-server configured for $me -- ask an admin: you may not be in the entitled group"

  url="$(url_for "$me")"
  state="$(sctl1 systemctl --user is-active code-server.service)"
  # The password is in the user's OWN 0600 config, so reading it needs no
  # privilege. /etc/code-server/<user>.password is the root-only copy and is
  # only reachable on the elevated path.
  pw="$(sed -nE 's/^password:[[:space:]]*//p' "$conf" 2>/dev/null | tail -1)"
  [ -n "$pw" ] || { [ -r "/etc/code-server/$me.password" ] && pw="$(cat "/etc/code-server/$me.password")"; }

  head2 "code-server for $me"
  printf '  %-10s %s\n' "state" "$([ "$state" = active ] && printf '%s%s%s' "$GRN" "$state" "$R" || printf '%s%s%s' "$RED" "$state" "$R")"
  printf '  %-10s %s\n' "url" "$url"
  printf '  %-10s %s\n' "password" "${pw:-<not readable -- see ~/.config/code-server/config.yaml>}"
  # Only meaningful where there is a manager to ask; otherwise it reports
  # "not-found" about a unit that is installed and fine.
  user_bus_ok && printf '  %-10s %s\n' "at login" \
    "$(sctl1 systemctl --user is-enabled code-server.service)"
  say ""
  if ! user_bus_ok; then
    say "  ${YEL}No user session here.${R} systemctl --user needs a real login --"
    say "  ${DIM}log in over RDP or SSH as yourself rather than using su/sudo -u.${R}"
    say ""
    return 0
  fi
  if [ "$state" = active ]; then
    say "  ${DIM}Open the URL above. Your browser will warn about the certificate --${R}"
    say "  ${DIM}it is self-signed by this box. Accept it and log in with the password.${R}"
    say ""
    say "  ${DIM}Stop it when you are done:  it-codeserver mine stop${R}"
  else
    say "  ${YEL}Not running.${R} Start it with:"
    say ""
    say "      ${B}it-codeserver mine start${R}     ${DIM}(no sudo -- it is your own service)${R}"
    say ""
    say "  ${DIM}Or have it start whenever you log in:  it-codeserver mine enable${R}"
    say "  ${DIM}It never starts at boot; it runs while you are logged in.${R}"
  fi
  say ""
}

cmd_mine_action() {   # $1 = start|stop|restart|enable|disable
  local me action="$1"
  # Split from the declaration on purpose: `local me=$(...)` takes the exit
  # status of `local`, which is always 0, so a refusal could not stop it.
  me="$(whoami_real)" || exit 1
  [ -r "$(conf_of "$me")" ] \
    || die "no code-server configured for $me -- you may not be in the entitled group"
  user_bus_ok \
    || die "no user session: systemctl --user has no bus here. Log in over RDP or SSH as yourself, not via su or sudo -u."

  case "$action" in
    enable)  systemctl --user enable --now code-server.service \
               || die "could not enable it -- see: journalctl --user -u code-server -n 40"
             say "code-server will start whenever you log in   ${DIM}$(url_for "$me")${R}"
             say "  ${DIM}Still never at boot: it runs while you have a session.${R}"
             return 0 ;;
    disable) systemctl --user disable --now code-server.service >/dev/null 2>&1
             say "code-server will no longer start when you log in"
             return 0 ;;
  esac

  systemctl --user "$action" code-server.service \
    || die "code-server failed to $action -- see: journalctl --user -u code-server -n 40"
  case "$action" in
    start)   say "started   ${DIM}$(url_for "$me")${R}"
             say "  ${DIM}It runs while you are logged in. 'it-codeserver mine enable' to${R}"
             say "  ${DIM}have it start with every session.${R}" ;;
    stop)    say "stopped" ;;
    restart) say "restarted   ${DIM}$(url_for "$me")${R}" ;;
  esac
}

case "${1:-status}" in
  ""|status) cmd_status ;;
  mine)
    case "${2:-status}" in
      status|"")                            cmd_mine ;;
      start|stop|restart|enable|disable)    cmd_mine_action "$2" ;;
      log) journalctl --user -u code-server.service -n "${3:-40}" --no-pager ;;
      *) die "usage: it-codeserver mine [start|stop|restart|enable|disable|log]" ;;
    esac ;;
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
  # These reach into the named user's OWN manager. They exist for an admin
  # helping someone, not as the normal route -- the normal route is that the
  # engineer runs `it-codeserver mine start` and needs nobody.
  start|stop|restart)
    [ -n "${2:-}" ] || die "usage: it-codeserver $1 <user>   (or, as yourself: it-codeserver mine $1)"
    [ -r "$(conf_of "$2")" ] \
      || die "no instance configured for $2 -- is the account in the entitled group, unlocked, and has the pull run?"
    systemctl --user --machine="$2@.host" "$1" code-server.service \
      || die "could not $1 it for $2. Without lingering their manager only exists while they are logged in -- see: it-codeserver linger $2 on"
    say "${1}ed code-server for $2   ${DIM}$(url_for "$2")${R}" ;;
  # Whether this person's IDE may run while they are NOT logged in. Off for
  # everyone by default: that is what keeps instances off the boot entirely.
  # Persist it in site.yml too, or the next pull turns it back off.
  linger)
    [ -n "${2:-}" ] || die "usage: it-codeserver linger <user> [on|off]"
    case "${3:-show}" in
      show) printf '%s lingering: %s\n' "$2" "$(lingers "$2")" ;;
      on)   loginctl enable-linger "$2" && say "$2 lingers: their IDE can run while they are logged out"
            say "  ${DIM}Add them to dev_code_server_linger_users in /opt/it/site.yml or the${R}"
            say "  ${DIM}next pull will turn it off again.${R}" ;;
      off)  loginctl disable-linger "$2" && say "$2 no longer lingers -- their IDE stops when they log out" ;;
      *) die "usage: it-codeserver linger <user> [on|off]" ;;
    esac ;;
  log)
    [ -n "${2:-}" ] || die "usage: it-codeserver log <user> [N]"
    journalctl _SYSTEMD_USER_UNIT=code-server.service _UID="$(id -u "$2")" \
      -n "${3:-40}" --no-pager ;;
  *) die "unknown command: $1  (try: it-codeserver --help)" ;;
esac
