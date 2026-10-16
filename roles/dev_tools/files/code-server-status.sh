#!/usr/bin/env bash
# it-codeserver -- who has a browser IDE, on which port, and its password.
#
# code-server is SINGLE-USER PER INSTANCE -- there is no multi-tenant mode -- so
# each user runs their own on their own port. A port is ASSIGNED the first time
# that person runs `my-ide` (never ahead of time), recorded in the root-only
# /etc/code-server/ports, and kept for good.
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
#   it-codeserver claim <user>      assign a port now instead of at their first my-ide
#   it-codeserver release <user>    free that user's port (they get a new one next time)
#   it-codeserver reset             empty the ledger; everyone claims again at next my-ide
#   it-codeserver sync              what the pull runs: refresh configs, clear stale ones
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
# checked when the port is claimed and again on every pull. An account with a
# LOCKED PASSWORD is refused: it cannot log in, so it cannot use an IDE.
#
# HOW A FIRST RUN GETS A PORT WITHOUT SUDO. my-ide connects to
# /run/code-server-claim.sock; systemd starts code-server-claim@.service (root)
# for that one connection, which asks the KERNEL who connected (SO_PEERCRED) --
# so nobody can claim as someone else -- and runs `claim-peer`. No password and
# no sudoers rule, so it also works from the menu tile, which has no terminal.
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
[ "${1:-}" = claim-peer ] && [ "$(id -u)" -ne 0 ] && die "claim-peer is run by code-server-claim@.service, not by hand"
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
# Only a config written here counts. Started any other way, code-server writes
# its own default (127.0.0.1:8080 -- the first assigned port) and that is not
# this person's instance. OLD_MARK is what the pull wrote before ports were
# claimed; `sync` rewrites or clears those.
MARK='# Managed by it-codeserver -- do not edit by hand.'
OLD_MARK='# Managed by ansible (dev_tools/code_server_user.yml)'
managed() { grep -qsF "$MARK" "$(conf_of "$1")"; }
bind_of() { sed -nE 's/^bind-addr:[[:space:]]*//p' "$(conf_of "$1")" 2>/dev/null | tail -1; }

instances() {   # every account this box has configured an instance for
  # Entitlement used to be read from system units. There are none now -- the
  # instance is a user service -- so the thing that says "this person has one"
  # is the config the pull wrote for them. Old code-server@<user> units are
  # still listed so a box mid-migration shows them and the pull can clear them.
  {
    getent passwd | awk -F: '$3 >= 1000 && $3 < 65000 {print $1}' | while read -r n; do
      managed "$n" && printf '%s\n' "$n"
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
  managed "$me" || die "no code-server configured for $me -- ask an admin: a pull lists who is left out and why"

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
  managed "$me" \
    || die "no code-server configured for $me -- ask an admin: a pull lists who is left out and why"
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

# ---------------------------------------------------------------------------
# Port assignment. Root only. The ledger is the record; nothing else assigns.
# ---------------------------------------------------------------------------
SETTINGS=/etc/code-server/settings   # written by the pull from dev_code_server_*
LEDGER=/etc/code-server/ports
LEDGER_HEAD='# v2 user port -- assigned at first my-ide, never released automatically.'

load_settings() {
  [ -r "$SETTINGS" ] || die "$SETTINGS is missing -- code-server is not set up on this box (pull)"
  # shellcheck disable=SC1090
  . "$SETTINGS"
}
in_range() { [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge "$CS_PORT" ] && [ "$1" -lt $((CS_PORT + CS_SPAN)) ]; }
# Shorter than my-ide's 45 s wait, so a held lock is reported, not a silence.
lock_ledger() { exec 9>/etc/code-server/.lock && flock -w 15 9 || die "the port ledger is busy -- try again in a minute"; }
ledger_lines() { [ -r "$LEDGER" ] && grep -vE '^[[:space:]]*(#|$)' "$LEDGER"; }
ledger_get() { ledger_lines | awk -v u="$1" '$1 == u { print $2; exit }'; }
ledger_write() {   # stdin: "user port" lines
  local tmp; tmp="$(mktemp /etc/code-server/.ports.XXXXXX)" || return 1
  { printf '%s\n' "$LEDGER_HEAD"; sort -u; } > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$LEDGER"
}

# Why this account may NOT have an IDE; prints nothing when it may.
# Group membership via `id -nG`, which includes the PRIMARY group -- `getent
# group` lists only supplementary members.
why_not() {
  local u="$1" uid st x
  uid="$(id -u "$u" 2>/dev/null)" || { echo "no such account"; return; }
  { [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ]; } || { echo "system account (uid $uid)"; return; }
  if [ -n "${CS_GROUP:-}" ] && getent group "$CS_GROUP" >/dev/null 2>&1; then
    id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qxF "$CS_GROUP" \
      || { echo "not in the $CS_GROUP group"; return; }
  else
    [ "$u" = "${CS_FALLBACK_USER:-}" ] || { echo "not ${CS_FALLBACK_USER:-the configured user} (group ${CS_GROUP:-unset} does not exist)"; return; }
  fi
  case "$(getent passwd "$u" | cut -d: -f7)" in
    */nologin|*/false|"") echo "no login shell"; return ;;
  esac
  # passwd -S field 2: P usable, L locked, NP none. auto_audit is L with a
  # normal shell, which is why the shell check alone was never enough.
  st="$(passwd -S "$u" 2>/dev/null | awk '{print $2}')"
  [ "$st" = P ] || { echo "password ${st:-unknown} (locked or not set yet)"; return; }
  for x in ${CS_EXCLUDE:-}; do [ "$u" = "$x" ] && { echo "in dev_code_server_exclude"; return; }; done
}

# Written AS THE USER: root creating paths in a home the user controls would
# follow any symlink they planted there.
write_conf() {   # $1 user  $2 port
  local u="$1" p="$2" h pwf
  h="$(getent passwd "$u" | cut -d: -f6)"; [ -n "$h" ] && [ -d "$h" ] || return 1
  pwf="/etc/code-server/$u.password"
  [ -s "$pwf" ] || (umask 077; tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24 > "$pwf")
  printf '%s\nbind-addr: %s:%s\nauth: password\npassword: %s\ncert: %s\n' \
    "$MARK" "$CS_BIND" "$p" "$(head -1 "$pwf" | cut -d' ' -f1)" "$CS_TLS" |
    runuser -u "$u" -- /bin/sh -c 'umask 077; d="$1/.config/code-server"
      mkdir -p "$d" && cat > "$d/config.yaml.new" && mv -f "$d/config.yaml.new" "$d/config.yaml"' sh "$h"
}
remove_conf() {   # only a config written by us (either marker), as the user
  local u="$1" h f
  h="$(getent passwd "$u" | cut -d: -f6)"; f="$h/.config/code-server/config.yaml"
  grep -qsF -e "$MARK" -e "$OLD_MARK" "$f" || return 0
  runuser -u "$u" -- rm -f "$f"
}

# Prints "OK <port>" or "NO <reason>" -- the reason is shown to the engineer.
claim_for() {
  local u="$1" r p q
  load_settings
  r="$(why_not "$u")"; [ -z "$r" ] || { echo "NO $r"; return 1; }
  lock_ledger
  p="$(ledger_get "$u")"
  if ! in_range "$p"; then
    p=""
    for ((q = CS_PORT; q < CS_PORT + CS_SPAN; q++)); do
      ledger_lines | awk -v q="$q" '$2 == q { f = 1 } END { exit !f }' || { p=$q; break; }
    done
    [ -n "$p" ] || { echo "NO all $CS_SPAN IDE ports on this machine are taken -- ask IT"; return 1; }
    { ledger_lines | awk -v u="$u" '$1 != u'; echo "$u $p"; } | ledger_write \
      || { echo "NO could not record your port -- ask IT"; return 1; }
    logger -t it-codeserver "assigned port $p to $u"
  fi
  write_conf "$u" "$p" || { echo "NO could not write your IDE settings -- ask IT"; return 1; }
  echo "OK $p"
}

# The connection is stdin; ask the kernel whose it is. detach() so Python does
# not close fd 0 on exit.
cmd_claim_peer() {
  local uid u
  # Anything that stops this early must reach the person as a reason; stderr
  # goes only to the journal and they would see "did not answer".
  die() { printf 'ERR %s\n' "$*"; printf '%s\n' "$*" >&2; exit 1; }
  uid="$(python3 -Ic 'import socket, struct
s = socket.socket(fileno=0)
print(struct.unpack("3i", s.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1])
s.detach()')" || { echo "NO could not identify the caller"; exit 1; }
  u="$(getent passwd "$uid" | cut -d: -f1)"
  [ -n "$u" ] || { echo "NO unknown account (uid $uid)"; exit 1; }
  # Read (and ignore) the request line. Closing a Unix socket with unread data
  # RESETS it, and the caller loses the answer.
  read -r -t 5 _ || true
  claim_for "$u"
}

# Run by every pull. Prints USER/SKIP/KEPT/CLEARED lines for the play to show.
cmd_sync() {
  local u p r uid
  load_settings; lock_ledger
  # First run on a box that predates claiming: start EMPTY. It used to keep
  # anyone with ~/.local/share/code-server as "has used it" -- but older
  # baselines started an instance for every entitled account at boot, which
  # created that directory for people who never connected, so it kept the
  # first users on the box. The configs those builds wrote are cleared below.
  if ! head -1 "$LEDGER" 2>/dev/null | grep -qxF "$LEDGER_HEAD"; then
    : | ledger_write || die "could not write $LEDGER"
    echo "FRESH ledger started empty; ports are claimed at each person's next my-ide"
  fi
  # Everyone on file: refresh the config, or take it away while keeping the
  # port reserved for them.
  while read -r u p; do
    r="$(why_not "$u")"
    if [ -n "$r" ]; then
      remove_conf "$u"; echo "SKIP $u $r (port $p kept for them)"
    elif ! in_range "$p"; then
      remove_conf "$u"; echo "SKIP $u port $p is outside the range now; their next my-ide assigns a new one"
    else
      write_conf "$u" "$p" && echo "USER $u $p"
    fi
  done < <(ledger_lines)
  # Configs we wrote for people who never claimed (the old pull pre-assigned).
  while IFS=: read -r u _ uid _; do
    [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ] || continue
    [ -n "$(ledger_get "$u")" ] && continue
    h="$(getent passwd "$u" | cut -d: -f6)"
    grep -qsF -e "$MARK" -e "$OLD_MARK" "$h/.config/code-server/config.yaml" || continue
    remove_conf "$u" && echo "CLEARED $u"
  done < <(getent passwd)
  # Group members who could not claim one, and why.
  if [ -n "${CS_GROUP:-}" ] && getent group "$CS_GROUP" >/dev/null 2>&1; then
    { getent group "$CS_GROUP" | cut -d: -f4 | tr ',' '\n'
      awk -F: -v g="$(getent group "$CS_GROUP" | cut -d: -f3)" '$4 == g { print $1 }' /etc/passwd
    } | sed '/^$/d' | sort -u | while read -r u; do
      [ -n "$(ledger_get "$u")" ] && continue
      r="$(why_not "$u")"; [ -n "$r" ] && echo "SKIP $u $r"
    done
  fi
  return 0
}

# Empty the ledger and take back every config written here, so everyone
# claims afresh at their next my-ide. A running instance is stopped first, or
# it would keep a port the ledger no longer reserves for it.
cmd_reset() {
  local u uid h n=0
  load_settings; lock_ledger
  : | ledger_write || die "could not write $LEDGER"
  while IFS=: read -r u _ uid _; do
    [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ] || continue
    h="$(getent passwd "$u" | cut -d: -f6)"
    grep -qsF -e "$MARK" -e "$OLD_MARK" "$h/.config/code-server/config.yaml" || continue
    systemctl --user --machine="$u@.host" stop code-server.service >/dev/null 2>&1 || true
    remove_conf "$u" && n=$((n + 1)) && say "  cleared $u"
  done < <(getent passwd)
  logger -t it-codeserver "ledger reset; $n config(s) cleared"
  say "ledger is empty; $n config(s) cleared. Ports are claimed at each person's next my-ide."
}

cmd_release() {
  local u="$1" p
  load_settings; lock_ledger
  p="$(ledger_get "$u")"; [ -n "$p" ] || die "$u has no port on file"
  ledger_lines | awk -v u="$u" '$1 != u' | ledger_write || die "could not write $LEDGER"
  remove_conf "$u"
  logger -t it-codeserver "released port $p from $u"
  say "released $p from $u -- their next my-ide assigns a new one"
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
    # The config is what code-server checks; the root copy only seeds it.
    pw="$(sed -nE 's/^password:[[:space:]]*//p' "$(conf_of "$2")" 2>/dev/null | tail -1)"
    f="/etc/code-server/$2.password"
    [ -n "$pw" ] || { [ -r "$f" ] && pw="$(head -1 "$f" | cut -d' ' -f1)"; }
    [ -n "$pw" ] || die "no password for $2 -- they have not claimed a port yet (first my-ide)"
    head2 "code-server password for $2"
    printf '\n      %s%s%s\n\n' "$B" "$pw" "$R"
    say "  ${DIM}Hand it over the way your site hands over a password -- not by email.${R}"
    say "  ${DIM}URL: $(url_for "$2")${R}"; say "" ;;
  url)
    [ -n "${2:-}" ] || die "usage: it-codeserver url <user>"; url_for "$2"; echo ;;
  # These reach into the named user's OWN manager. They exist for an admin
  # helping someone, not as the normal route -- the normal route is that the
  # engineer runs `it-codeserver mine start` and needs nobody.
  start|stop|restart)
    [ -n "${2:-}" ] || die "usage: it-codeserver $1 <user>   (or, as yourself: it-codeserver mine $1)"
    # `stop` is allowed regardless: it is how an admin takes down an instance
    # started on code-server's own default config.
    [ "$1" = stop ] || managed "$2" \
      || die "no instance configured for $2 -- the pull lists who is left out and why"
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
  claim-peer) cmd_claim_peer ;;
  claim)
    [ -n "${2:-}" ] || die "usage: it-codeserver claim <user>   (engineers just run my-ide)"
    r="$(claim_for "$2")"; case "$r" in OK*) say "$2 has port ${r#OK }" ;; *) die "${r#NO }" ;; esac ;;
  release)
    [ -n "${2:-}" ] || die "usage: it-codeserver release <user>"; cmd_release "$2" ;;
  sync) cmd_sync ;;
  reset) cmd_reset ;;
  *) die "unknown command: $1  (try: it-codeserver --help)" ;;
esac
