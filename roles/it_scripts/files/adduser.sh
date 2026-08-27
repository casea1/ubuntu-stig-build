#!/usr/bin/env bash
# it-adduser -- create a local account with the org's group policy applied.
#
# Account types decide BOTH the name suffix and the groups, so nobody has to
# remember either:
#
#   standard   first_last        sentry
#   dta        first_last_dta    dta, sentry
#   admin      first_last_adm    sudo, sentry
#   audit      first_last_aud    audit, sudo, sentry
#
# Usage:
#   it-adduser                        interactive (the normal way)
#   it-adduser --type admin --first Jane --last Doe
#   it-adduser ... --lock             create locked, set the password later
#   it-adduser ... --no-expire        do not force a password change at first login
#   it-adduser --dry-run              show what would happen, change nothing
set -uo pipefail

[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

TYPE=""; FIRST=""; LAST=""; LOCKED=0; FORCE_EXPIRE=1; DRY=0

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

while [ $# -gt 0 ]; do
  case "$1" in
    --type)  TYPE="${2:?--type needs a value}"; shift 2 ;;
    --first) FIRST="${2:?--first needs a value}"; shift 2 ;;
    --last)  LAST="${2:?--last needs a value}"; shift 2 ;;
    --lock)  LOCKED=1; shift ;;
    --no-expire) FORCE_EXPIRE=0; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ---- the org's type -> suffix + groups map ----------------------------------
# Keep in step with local_users / local_groups in group_vars/all.yml.
type_suffix() {
  case "$1" in
    standard) printf '' ;;
    dta)      printf '_dta' ;;
    admin)    printf '_adm' ;;
    audit)    printf '_aud' ;;
  esac
}
type_groups() {
  # sentry is local_users_common_groups -- every standing account joins it.
  case "$1" in
    standard) printf 'sentry' ;;
    dta)      printf 'dta,sentry' ;;
    admin)    printf 'sudo,sentry' ;;
    audit)    printf 'audit,sudo,sentry' ;;
  esac
}

# ---- gather ------------------------------------------------------------------
if [ -z "$TYPE" ]; then
  head2 "Account type"
  say "  standard   no special access          -> first_last"
  say "  dta        USB data transfer          -> first_last_dta"
  say "  admin      full sudo                  -> first_last_adm"
  say "  audit      /opt/_AuditFiles + sudo    -> first_last_aud"
  printf '\n'
  select t in standard dta admin audit; do
    [ -n "${t:-}" ] && { TYPE="$t"; break; }
    say "  pick 1-4"
  done
fi
case "$TYPE" in standard|dta|admin|audit) ;; *) die "unknown type: $TYPE (standard|dta|admin|audit)" ;; esac

norm() {  # a name part -> lowercase, letters/digits only
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]'
}

[ -n "$FIRST" ] || { read -r -p "First name: " FIRST; }
[ -n "$LAST"  ] || { read -r -p "Last name:  " LAST; }
F=$(norm "$FIRST"); L=$(norm "$LAST")
[ -n "$F" ] && [ -n "$L" ] || die "first and last name are both required"

USERNAME="${F}_${L}$(type_suffix "$TYPE")"
GROUPS_CSV=$(type_groups "$TYPE")

# Usernames must be portable and short enough for utmp.
printf '%s' "$USERNAME" | grep -qE '^[a-z][a-z0-9_-]{0,31}$' \
  || die "generated username is not valid: $USERNAME"
id "$USERNAME" >/dev/null 2>&1 && die "account already exists: $USERNAME (reset it with: it-passwd $USERNAME)"

# Only offer groups that exist. A missing one means local_accounts has not run.
MISSING=""
KEEP=""
for g in ${GROUPS_CSV//,/ }; do
  if getent group "$g" >/dev/null 2>&1; then KEEP="${KEEP:+$KEEP,}$g"
  else MISSING="$MISSING $g"; fi
done
[ -n "$MISSING" ] && warn "group(s) not present on this box, skipping:$MISSING (run the build to create them)"
GROUPS_CSV="$KEEP"

head2 "About to create"
printf '  %-12s %s\n' "username"  "$USERNAME"
printf '  %-12s %s\n' "type"      "$TYPE"
printf '  %-12s %s\n' "groups"    "${GROUPS_CSV:-none}"
printf '  %-12s %s\n' "home"      "/home/$USERNAME"
printf '  %-12s %s\n' "shell"     "/bin/bash"
printf '  %-12s %s\n' "password"  "$([ "$LOCKED" -eq 1 ] && echo 'locked (set later)' || echo 'set now')"
[ "$LOCKED" -eq 0 ] && [ "$FORCE_EXPIRE" -eq 1 ] && \
  printf '  %-12s %s\n' "" "must be changed at first login"

if [ "$DRY" -eq 1 ]; then warn "dry run -- nothing was created"; exit 0; fi
read -r -p $'\nCreate it? [y/N] ' a || exit 1
case "${a,,}" in y|yes) ;; *) die "aborted" ;; esac

# ---- password ----------------------------------------------------------------
# chpasswd does NOT go through pam_pwquality, so a password set that way skips
# the box's own complexity policy entirely. Check it here instead of pretending
# the policy applied.
PW=""
check_policy() {
  local pw="$1" rc=0 msg=""
  if command -v pwscore >/dev/null 2>&1; then
    msg=$(printf '%s' "$pw" | pwscore 2>&1) || rc=1
    [ "$rc" -ne 0 ] && { printf '%s' "$msg"; return 1; }
    return 0
  fi
  # No libpwquality-tools: check what pwquality.conf actually asks for.
  local conf=/etc/security/pwquality.conf minlen=15
  [ -r "$conf" ] && minlen=$(awk -F= '/^[[:space:]]*minlen/{gsub(/ /,"",$2); print $2}' "$conf" | tail -1)
  minlen=${minlen:-15}
  [ "${#pw}" -ge "$minlen" ] || { printf 'shorter than minlen=%s' "$minlen"; return 1; }
  local want cls
  for cls in d:'[0-9]' u:'[A-Z]' l:'[a-z]' o:'[^a-zA-Z0-9]'; do
    want=$(awk -F= "/^[[:space:]]*${cls%%:*}credit/{gsub(/ /,\"\",\$2); print \$2}" "$conf" 2>/dev/null | tail -1)
    # A NEGATIVE credit is a minimum count of that class.
    if [ -n "$want" ] && [ "$want" -lt 0 ] 2>/dev/null; then
      printf '%s' "$pw" | grep -q "${cls#*:}" || { printf 'missing a required character class (%scredit=%s)' "${cls%%:*}" "$want"; return 1; }
    fi
  done
  return 0
}

if [ "$LOCKED" -eq 0 ]; then
  head2 "Password for $USERNAME"
  command -v pwscore >/dev/null 2>&1 \
    || say "  ${DIM}(libpwquality-tools not installed -- checking minlen and character classes only)${R}"
  while :; do
    read -rs -p "  New password: " PW; printf '\n'
    read -rs -p "  Again:        " PW2; printf '\n'
    [ "$PW" = "$PW2" ] || { bad "they do not match"; continue; }
    [ -n "$PW" ] || { bad "empty passwords are not allowed"; continue; }
    if ! reason=$(check_policy "$PW"); then
      bad "rejected by this box's password policy: $reason"
      continue
    fi
    break
  done
fi

# ---- create ------------------------------------------------------------------
head2 "Creating"
useradd -m -s /bin/bash ${GROUPS_CSV:+-G "$GROUPS_CSV"} "$USERNAME" \
  || die "useradd failed"
ok "account created"

if [ "$LOCKED" -eq 1 ]; then
  usermod -L "$USERNAME"
  ok "password LOCKED -- set one with: it-passwd $USERNAME"
else
  printf '%s:%s' "$USERNAME" "$PW" | chpasswd || die "chpasswd failed"
  unset PW PW2
  usermod -U "$USERNAME" 2>/dev/null || true
  ok "password set"
  if [ "$FORCE_EXPIRE" -eq 1 ]; then
    chage -d 0 "$USERNAME" && ok "must be changed at first login"
  fi
fi

# ---- report ------------------------------------------------------------------
head2 "$USERNAME"
printf '  %-12s %s\n' "uid"    "$(id -u "$USERNAME")"
printf '  %-12s %s\n' "groups" "$(id -nG "$USERNAME" | tr ' ' ',')"
printf '  %-12s %s\n' "home"   "$(getent passwd "$USERNAME" | cut -d: -f6)"
chage -l "$USERNAME" 2>/dev/null | sed 's/^/  /'

head2 "Make it part of the baseline"
say "  This account was created BY HAND. The build does not know about it, so a"
say "  rebuilt or re-imaged box will not have it. Add it to local_users in"
say "  group_vars/all.yml to make it permanent:"
printf '\n    - { name: %s,%*sgroups: [%s] }\n\n' \
  "$USERNAME" $(( 18 - ${#USERNAME} > 1 ? 18 - ${#USERNAME} : 1 )) "" \
  "$(printf '%s' "${GROUPS_CSV//sentry/}" | sed 's/^,//; s/,$//; s/,/, /g')"
say "  ${DIM}sentry is added to every account by local_users_common_groups -- leave it out.${R}"
