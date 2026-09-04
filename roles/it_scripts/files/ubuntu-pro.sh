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
#   it-pro token <token>     store the token for future pulls and rebuilds,
#                            WITHOUT touching the running attachment
#   it-pro switch <token>    move this box to that token: detach, re-attach,
#                            re-enable the services it had, and store it
#   it-pro attach [<token>]  attach an UNATTACHED box
#   it-pro refresh           re-pull contract data from Canonical
#
# <token> is the token itself, a FILE containing it, `-` for standard input, or
# omitted for a prompt that is not echoed. An argument is classified by what it
# is -- anything that exists as a file, or looks like a path, is read as one --
# so a token and a filename cannot be confused.
#
# Passing the token as an argument puts it in `ps` for every user on the box
# while the command runs, and in the shell history of whoever ran it. The
# command says so once and gets on with it; omit the argument to be prompted
# instead.
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

service_enabled() {   # $1 = service name
  [ "$(jq_get "str(any(s.get('name')=='$1' and s.get('status')=='enabled' for s in d.get('services',[])))")" = "True" ]
}

# A token, from whichever of the three ways is convenient:
#
#   it-pro switch C1abc...        the token itself
#   it-pro switch /path/to/file   a file containing it
#   it-pro switch                 prompt, not echoed
#   it-pro switch -               standard input
#
# An argument is classified by what it IS, not by a flag: anything that exists
# as a file, or that looks like a path, is read as one. A Pro token is
# alphanumeric with no slashes, so the two cannot be confused.
read_token() {   # $1 = token, file, '-' , or empty to prompt
  local a="${1:-}" t
  if [ "$a" = "-" ]; then
    t="$(cat)"
  elif [ -z "$a" ]; then
    [ -t 0 ] || die "no token given and nothing on standard input"
    # -s: not echoed, and not in the terminal's scrollback afterwards.
    printf '  Ubuntu Pro token (not shown): ' >&2
    read -rs t; printf '\n' >&2
  elif [ -f "$a" ] || case "$a" in */*|./*|~*) true ;; *) false ;; esac; then
    [ -r "$a" ] || die "cannot read $a"
    t="$(cat "$a")"
  else
    t="$a"
    # Said once, not laboured: an argument is visible in `ps` to every user on
    # the box while the command runs, and it stays in the shell history of
    # whoever ran it. That matters more here than usual -- this token attaches
    # machines to your subscription.
    # >&2, all of it. This function's STDOUT is the token: a warning printed to
    # stdout is captured by the caller's $( ) and becomes part of the token,
    # which then fails to attach for a reason nothing on screen explains.
    {
      warn "token given on the command line -- visible in \`ps\` and left in shell history"
      say  "  ${DIM}clear it afterwards: history -d \$(history 1 | awk '{print \$1}')${R}"
      say  "  ${DIM}or next time: sudo it-pro switch     (prompts, not echoed)${R}"
    } >&2
  fi
  t="$(printf '%s' "$t" | tr -d '\r\n[:space:]')"
  [ -n "$t" ] || die "empty token"
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
      say "  ${B}sudo it-pro attach${R}${DIM}   (or: it-pro attach <token>)${R}"
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
      say  "  ${B}sudo it-pro switch${R}${DIM}   (prompts for the real token)${R}"
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
    say  "  ${DIM}and would come up unhardened with a POA&M. ${R}${B}sudo it-pro token${R}"
  fi
  say ""
}

cmd_token() {
  local f="${1:-}"
  # No argument is not an error here -- it means "prompt me".
  local t; t="$(read_token "$f")" || exit 1
  store_token "$t"
  say ""
  say "  Nothing about the running attachment changed. To move THIS box:"
  say "    ${B}sudo it-pro switch $f${R}"
  say ""
}

cmd_attach() {
  # No argument: use the stored token if there is one (that is the common case
  # on a box the pull could not attach), else prompt.
  local f="${1:-}" tok
  [ -n "$f" ] || { [ -r "$TOKEN_FILE" ] && f="$TOKEN_FILE"; }
  if attached; then
    bad "already attached -- attaching again does nothing."
    say "  To move this box to a different subscription:  ${B}sudo it-pro switch${R}"
    return 1
  fi
  tok="$(read_token "$f")" || exit 1
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
  # No argument means prompt; read_token handles it.
  tok="$(read_token "$f")" || exit 1

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
  #
  # ASK THE SERVICE, do not trust `pro enable`'s exit code. Attaching a full
  # subscription AUTO-ENABLES the default services, so by the time this loop
  # runs most of them are already on -- and `pro enable` exits non-zero for
  # "already enabled". Reporting that as a failure told an operator that
  # esm-apps, esm-infra and livepatch had not come back while the status table
  # printed three lines later showed all three enabled. A compliance command
  # that cries wolf is worse than one that says nothing.
  local s
  for s in $svcs; do
    if service_enabled "$s"; then
      ok "$s enabled (the attach turned it on)"
      continue
    fi
    pro enable "$s" --assume-yes >/dev/null 2>&1
    if service_enabled "$s"; then
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
