#!/usr/bin/env bash
# it-pro -- the Ubuntu Pro subscription this box is on, and how to change it.
#
# WHY THIS EXISTS. USG (the DISA-STIG hardening), FIPS and ESM all come from
# Ubuntu Pro, so the subscription is not a billing detail here -- it is what
# makes the box compliant. And the pull cannot fix a WRONG one: usg_harden
# attaches only when the box is NOT already attached, so a box brought up on a
# free personal or trial token stays on it forever. Updating
# /etc/ubuntu-advantage/pro-token changes what a REBUILD would use and nothing
# about the box in front of you. That gap is what `it-pro switch` closes.
#
#   it-pro                   subscription, expiry, services  (the default)
#   it-pro status            the same
#   it-pro token <file>      store the token for future pulls and rebuilds,
#                            WITHOUT touching the running attachment
#   it-pro switch <file>     move this box to that token: detach, re-attach,
#                            re-enable the services it had, and store it
#   it-pro attach [<file>]   attach an UNATTACHED box (the token file by default)
#   it-pro refresh           re-pull contract data from Canonical
#
# A token is a SECRET. It is read from a file, never typed as an argument --
# a command line is visible in `ps` to every user on the box and lands in the
# shell history of whoever ran it. `-` reads standard input.
set -uo pipefail

TOKEN_FILE="${UBUNTU_PRO_TOKEN_FILE:-/etc/ubuntu-advantage/pro-token}"

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

command -v pro >/dev/null 2>&1 || die "ubuntu-pro-client is not installed -- run: sudo it-pull full"

# `pro status --format json` is the only stable interface; the human output is
# a table whose columns move between releases.
pro_json() { pro status --format json 2>/dev/null; }

# A field out of `pro status --format json`.
#
# The expression is passed as a DOUBLE-quoted shell argument and uses SINGLE
# quotes internally. Written the other way round -- single-quoted shell, \" in
# the expression -- the backslashes reach Python literally and every call is a
# SyntaxError. Which is survivable only if something reports it: the first
# version wrapped the print in try/except and sent stderr to /dev/null, so it
# silently answered "not attached" for every box on the fleet. Only the JSON
# LOAD is tolerated quietly (pro absent, or output that is not JSON); a broken
# expression is meant to be loud.
jq_get() {   # $1 = python expression over the parsed status document `d`
  pro_json | python3 -c "
import json,sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
print($1)
"
}

attached() { [ "$(jq_get "str(d.get('attached', False))")" = "True" ]; }

# Services that are ENABLED right now. Re-enabled after a switch, because
# `pro detach` turns every one of them off and a silently-unhardened box is a
# far worse outcome than a failed switch.
enabled_services() {
  jq_get "' '.join(sorted(s['name'] for s in d.get('services',[]) if s.get('status')=='enabled'))"
}

read_token() {   # $1 = file or '-'
  local f="$1" t
  if [ "$f" = "-" ]; then
    t="$(cat)"
  else
    [ -r "$f" ] || die "cannot read $f"
    t="$(cat "$f")"
  fi
  t="$(printf '%s' "$t" | tr -d '\r\n[:space:]')"
  [ -n "$t" ] || die "no token in $f"
  printf '%s' "$t"
}

store_token() {   # $1 = token
  install -d -m 0755 -o root -g root "$(dirname "$TOKEN_FILE")"
  # 0600 root:root, and written with umask so it is never briefly world-readable.
  ( umask 077; printf '%s\n' "$1" > "$TOKEN_FILE" )
  chown root:root "$TOKEN_FILE"; chmod 0600 "$TOKEN_FILE"
  ok "stored in $TOKEN_FILE (0600 root:root) -- a rebuild or a fresh box will use it"
}

cmd_status() {
  head2 "Ubuntu Pro"
  if ! attached; then
    bad "NOT ATTACHED"
    say "  ${DIM}USG hardening, FIPS and ESM all come from Pro. An unattached box${R}"
    say "  ${DIM}is not hardened -- usg_harden self-skips and records a POA&M.${R}"
    say ""
    if [ -r "$TOKEN_FILE" ]; then
      ok "a token IS on disk at $TOKEN_FILE"
      say "  ${B}sudo it-pro attach${R}   use it now"
    else
      say "  ${B}sudo it-pro attach /path/to/token${R}"
    fi
    say ""
    return 1
  fi

  ok "attached"
  local acct sub exp
  acct="$(jq_get "d.get('account',{}).get('name','')")"
  sub="$(jq_get "d.get('contract',{}).get('name','')")"
  exp="$(jq_get "d.get('expires','') or ''")"
  printf '  %-18s %s\n' "account"      "${acct:-<unknown>}"
  printf '  %-18s %s\n' "subscription" "${sub:-<unknown>}"
  printf '  %-18s %s\n' "expires"      "${exp:-<none reported>}"

  # The whole point of the command: is this the free one?
  #
  # Canonical's free personal subscription is what a token from ubuntu.com/pro
  # gives an individual, and it is capped at 5 machines. It entitles USG and
  # FIPS exactly like a paid one, so NOTHING about the box looks wrong -- the
  # difference only shows up as an entitlement problem later, on the sixth box
  # or at renewal. The contract name is the only place it is visible.
  case "$(printf '%s %s' "$acct" "$sub" | tr '[:upper:]' '[:lower:]')" in
    *free*|*personal*|*trial*|*evaluation*)
      warn "this looks like a FREE / trial subscription"
      say  "  ${DIM}It entitles USG and FIPS just like a paid one, so the box looks${R}"
      say  "  ${DIM}fine -- the limit bites later, on the machine count or at renewal.${R}"
      say  "  ${B}sudo it-pro switch /path/to/real-token${R}"
      ;;
  esac

  head2 "Services"
  pro status 2>/dev/null | sed -n '/SERVICE/,/^$/p' | sed 's/^/  /'

  # A token on disk that does not match what is attached is the trap this
  # command exists for: the pull attaches only an UNATTACHED box, so the file
  # governs rebuilds and nothing else. It cannot be compared to the live
  # contract (the token is not readable back out of pro), so say so plainly
  # rather than implying agreement.
  head2 "Token on disk"
  if [ -r "$TOKEN_FILE" ]; then
    printf '  %-18s %s (%s)\n' "file" "$TOKEN_FILE" "$(stat -c '%a %U:%G' "$TOKEN_FILE")"
    say "  ${DIM}Used only when a box is NOT yet attached -- so it governs a REBUILD,${R}"
    say "  ${DIM}not this attachment. Changing it does not move a box that is already${R}"
    say "  ${DIM}attached; ${R}${B}it-pro switch${R}${DIM} does that.${R}"
  else
    warn "no token at $TOKEN_FILE -- a rebuild of this box would NOT attach,"
    say  "  ${DIM}and would come up unhardened with a POA&M. ${R}${B}sudo it-pro token <file>${R}"
  fi
  say ""
}

cmd_token() {
  local f="${1:-}"
  [ -n "$f" ] || die "usage: it-pro token <file>   (or - for stdin)"
  store_token "$(read_token "$f")"
  say ""
  say "  Nothing about the running attachment changed. To move THIS box:"
  say "    ${B}sudo it-pro switch $f${R}"
  say ""
}

cmd_attach() {
  local f="${1:-$TOKEN_FILE}" tok
  if attached; then
    bad "already attached -- attaching again does nothing."
    say "  To move this box to a different subscription:  ${B}sudo it-pro switch <file>${R}"
    return 1
  fi
  tok="$(read_token "$f")"
  head2 "Attaching"
  # The token must not reach the command line: `ps` shows it to every user.
  if printf '%s\n' "$tok" | pro attach --format json - >/dev/null 2>&1 \
     || pro attach "$tok" >/dev/null 2>&1; then
    ok "attached"
  else
    die "attach failed -- check the token and that this box can reach contracts.canonical.com"
  fi
  [ "$f" = "$TOKEN_FILE" ] || store_token "$tok"
  say ""
  say "  ${B}sudo it-pull full${R}   apply USG hardening now that Pro is available"
  say ""
}

cmd_switch() {
  local f="${1:-}" tok svcs
  [ -n "$f" ] || die "usage: it-pro switch <file>   (or - for stdin)"
  tok="$(read_token "$f")"

  head2 "Moving this box to a different Pro subscription"
  if ! attached; then
    say "  Not attached, so this is just an attach."
    cmd_attach "$f"; return $?
  fi

  svcs="$(enabled_services)"
  say "  currently enabled: ${svcs:-<none>}"
  say ""
  bad "DETACH DISABLES EVERY ONE OF THOSE, including FIPS and USG."
  say "  They are re-enabled straight afterwards, but between the two this box"
  say "  is not receiving Pro updates, and if the new token does not entitle a"
  say "  service it will NOT come back -- fips-updates especially, which also"
  say "  pins a kernel. Do this on a box you can reboot, not mid-workday."
  say ""
  if [ -t 0 ]; then
    printf '  Type YES to continue: '
    local a; read -r a; [ "$a" = YES ] || die "not confirmed -- nothing was changed"
  fi

  pro detach --assume-yes >/dev/null 2>&1 || die "detach failed -- box left as it was"
  ok "detached"

  if ! { printf '%s\n' "$tok" | pro attach --format json - >/dev/null 2>&1 \
         || pro attach "$tok" >/dev/null 2>&1; }; then
    bad "ATTACH FAILED and this box is now DETACHED -- it is unhardened."
    say "  Re-attach with the previous token:  ${B}sudo it-pro attach <old-token-file>${R}"
    exit 1
  fi
  ok "attached to the new subscription"
  store_token "$tok"

  # Re-enable exactly what was on before, and say plainly which did not return.
  local s
  for s in $svcs; do
    if pro enable "$s" --assume-yes >/dev/null 2>&1; then
      ok "re-enabled $s"
    else
      bad "$s did NOT come back -- the new subscription may not entitle it"
    fi
  done
  say ""
  cmd_status
  say "  ${B}sudo it-pull full${R}   re-apply hardening against the new entitlements"
  say ""
}

case "${1:-status}" in
  status|"") cmd_status ;;
  token)     shift; cmd_token "$@" ;;
  attach)    shift; cmd_attach "$@" ;;
  switch)    shift; cmd_switch "$@" ;;
  refresh)   pro refresh && ok "contract data refreshed"; cmd_status ;;
  *)         die "unknown command: ${1}
$(usage)" ;;
esac
