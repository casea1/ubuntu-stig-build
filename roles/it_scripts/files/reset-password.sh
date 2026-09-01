#!/usr/bin/env bash
# it-passwd -- reset a local account's password, unlock it, and clear its lockout.
#
# Does the whole job, because doing only part of it is the usual reason a user
# still cannot log in after a "password reset": the account is separately LOCKED,
# or faillock is still counting three bad attempts against them.
#
# Interactively it ASKS how to set the password: type one now, generate a
# temporary one, or keep the current one and just unlock. Either password must
# be changed at next login. --temp / --unlock-only skip the question.
#
# Usage:
#   it-passwd                     pick from a list
#   it-passwd <account>
#   it-passwd --list              accounts, lock state, expiry -- change nothing
#   it-passwd <account> --expire  ...and force a change at next login (default)
#   it-passwd <account> --no-expire
#   it-passwd <account> --temp    generate a temporary password, no prompt
#   it-passwd <account> --unlock-only    clear the lock + faillock, keep the password
set -uo pipefail

[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

ACCOUNT=""; FORCE_EXPIRE=1; LIST=0; UNLOCK_ONLY=0; TEMP=0
PW=""; PW_MODE=""

if [ -t 1 ]; then
  B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'
else
  B=""; DIM=""; R=""; RED=""; GRN=""; YEL=""
fi
say()  { printf '%s\n' "$*"; }
head2(){ printf '\n%s%s%s\n' "$B" "$*" "$R"; }
ok()   { printf '  %s%s%s\n' "$GRN" "$*" "$R"; }
warn() { printf '  %s%s%s\n' "$YEL" "$*" "$R"; }
bad()  { printf '  %s%s%s\n' "$RED" "$*" "$R"; }
die()  { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
usage(){ awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }

# Shared with it-adduser: the policy check, the generator and the prompt live in
# one file so a generated password is validated against the same rule a typed
# one is.
SELF_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=pw-common.sh
. "$SELF_DIR/pw-common.sh" 2>/dev/null || die "missing $SELF_DIR/pw-common.sh -- re-run the build (it-pull scripts)"

while [ $# -gt 0 ]; do
  case "$1" in
    --list)        LIST=1; shift ;;
    --expire)      FORCE_EXPIRE=1; shift ;;
    --no-expire)   FORCE_EXPIRE=0; shift ;;
    --unlock-only) UNLOCK_ONLY=1; shift ;;
    --temp)        TEMP=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            die "unknown option: $1 (try --help)" ;;
    *)             ACCOUNT="$1"; shift ;;
  esac
done

# Human accounts only: uid 1000..65533, which is what the checklist counts too.
humans() { awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd | sort; }

# The three things that independently stop a login, reported separately because
# fixing one and not the others is the usual failure.
pw_state() {  # -> LOCKED | NOPASS | ok
  case "$(passwd -S "$1" 2>/dev/null | awk '{print $2}')" in
    L|LK) echo LOCKED ;;
    NP)   echo NOPASS ;;
    *)    echo ok ;;
  esac
}
faillock_count() {
  command -v faillock >/dev/null 2>&1 || { echo 0; return; }
  faillock --user "$1" 2>/dev/null | awk 'NR>2 && NF' | wc -l
}
expiry_of() { chage -l "$1" 2>/dev/null | awk -F: '/^Password expires/{sub(/^ /,"",$2); print $2}'; }

if [ "$LIST" -eq 1 ]; then
  head2 "Local accounts"
  printf '  %-22s %-8s %-9s %s\n' USER STATE FAILLOCK "PASSWORD EXPIRES"
  while read -r u; do
    [ -n "$u" ] || continue
    printf '  %-22s %-8s %-9s %s\n' "$u" "$(pw_state "$u")" "$(faillock_count "$u")" "$(expiry_of "$u")"
  done < <(humans)
  printf '\n'
  exit 0
fi

if [ -z "$ACCOUNT" ]; then
  head2 "Which account?"
  mapfile -t USERS < <(humans)
  [ "${#USERS[@]}" -gt 0 ] || die "no local accounts found"
  select u in "${USERS[@]}"; do
    [ -n "${u:-}" ] && { ACCOUNT="$u"; break; }
    say "  pick a number"
  done
fi

id "$ACCOUNT" >/dev/null 2>&1 || die "no such account: $ACCOUNT"

head2 "$ACCOUNT"
printf '  %-14s %s\n' "state"     "$(pw_state "$ACCOUNT")"
printf '  %-14s %s\n' "faillock"  "$(faillock_count "$ACCOUNT") failed attempt(s) on record"
printf '  %-14s %s\n' "groups"    "$(id -nG "$ACCOUNT" | tr ' ' ',')"
chage -l "$ACCOUNT" 2>/dev/null | sed 's/^/  /'

# ---- password ---------------------------------------------------------------
# Three ways: type one, generate a temporary one, or keep the current password
# and only clear what is blocking the login. Whichever is chosen, the unlock and
# faillock reset below still run -- doing only part of that is the usual reason
# someone still cannot log in after a "password reset".
if [ "$UNLOCK_ONLY" -eq 1 ]; then
  PW_MODE=skip
elif [ "$TEMP" -eq 1 ]; then
  PW="$(gen_password)" || die "could not generate a password this box's policy accepts"
  PW_MODE=temp
  printf '\n  %sTEMPORARY PASSWORD for %s%s\n\n' "$B" "$ACCOUNT" "$R"
  printf '      %s%s%s\n\n' "$B" "$PW" "$R"
elif [ -t 0 ]; then
  pw_choose "$ACCOUNT" "Keep the current one" "change no password; just unlock and clear faillock" \
    || die "aborted"
  [ "$PW_MODE" = skip ] && UNLOCK_ONLY=1
else
  die "no terminal to ask on -- pass --temp or --unlock-only"
fi

if [ "$PW_MODE" = temp ] && [ "$FORCE_EXPIRE" -eq 0 ]; then
  warn "--no-expire ignored for a temporary password: it must be changed at next login"
  FORCE_EXPIRE=1
fi

if [ "$PW_MODE" != skip ]; then
  printf '%s:%s' "$ACCOUNT" "$PW" | chpasswd || die "chpasswd failed"
  unset PW
  ok "password set"
  [ "$PW_MODE" = temp ] && ok "temporary -- shown above, stored nowhere"
fi

# ---- unlock ------------------------------------------------------------------
head2 "Unlocking"
# usermod -U on an account whose hash is '!' (created locked, never given a
# password) leaves it with an EMPTY password, which is worse than locked. Only
# unlock where a real hash exists.
hash=$(awk -F: -v u="$ACCOUNT" '$1==u{print $2}' /etc/shadow)
case "$hash" in
  ""|"!"|"!!"|"*")
    warn "no password hash -- leaving locked (set one: it-passwd $ACCOUNT)" ;;
  *)
    usermod -U "$ACCOUNT" 2>/dev/null && ok "account unlocked" ;;
esac

if command -v faillock >/dev/null 2>&1; then
  n=$(faillock_count "$ACCOUNT")
  faillock --user "$ACCOUNT" --reset 2>/dev/null \
    && ok "faillock cleared ($n failed attempt(s) removed)"
fi

# An expired ACCOUNT (not password) blocks login no matter what the password is.
acct_exp=$(chage -l "$ACCOUNT" 2>/dev/null | awk -F: '/^Account expires/{sub(/^ /,"",$2); print $2}')
if [ -n "$acct_exp" ] && [ "$acct_exp" != "never" ]; then
  warn "account expires $acct_exp -- clear it with: chage -E -1 $ACCOUNT"
fi

if [ "$UNLOCK_ONLY" -eq 0 ] && [ "$FORCE_EXPIRE" -eq 1 ]; then
  chage -d 0 "$ACCOUNT" && ok "must be changed at next login"
fi

# ---- report ------------------------------------------------------------------
head2 "$ACCOUNT now"
printf '  %-14s %s\n' "state"    "$(pw_state "$ACCOUNT")"
printf '  %-14s %s\n' "faillock" "$(faillock_count "$ACCOUNT") failed attempt(s) on record"
chage -l "$ACCOUNT" 2>/dev/null | sed 's/^/  /'
printf '\n'
[ "$FORCE_EXPIRE" -eq 1 ] && [ "$UNLOCK_ONLY" -eq 0 ] && \
  say "  ${DIM}\"Password expires: password must be changed\" is expected -- that is the${R}" && \
  say "  ${DIM}forced change at next login. The real expiry appears once they change it.${R}"
exit 0
