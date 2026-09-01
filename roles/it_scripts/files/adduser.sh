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
# Interactively it ASKS how to set the password: type one now, generate a
# temporary one, or leave the account locked. Either password must be changed
# at first login. --temp / --lock skip the question for scripted use.
#
# Usage:
#   it-adduser                        interactive (the normal way)
#   it-adduser --type admin --first Jane --last Doe
#   it-adduser ... --temp             generate a temporary password, no prompt
#   it-adduser ... --vscode           copy the VS Code extension set in (slow, GBs)
#   it-adduser ... --no-vscode        do not offer it
#   it-adduser ... --lock             create locked, set the password later
#   it-adduser ... --no-expire        do not force a password change at first login
#   it-adduser --dry-run              show what would happen, change nothing
set -uo pipefail

[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

TYPE=""; FIRST=""; LAST=""; LOCKED=0; FORCE_EXPIRE=1; DRY=0; TEMP=0; VSCODE=ask
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

# Password policy checking, the generator and the prompt are shared with
# it-passwd so the two cannot drift -- a generated password is validated
# against the same check a typed one gets.
SELF_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=pw-common.sh
. "$SELF_DIR/pw-common.sh" 2>/dev/null || die "missing $SELF_DIR/pw-common.sh -- re-run the build (it-pull scripts)"

# Written by it_scripts on every pull; empty on a profile that has no such thing.
PROFILE_FILE=/etc/stig-build/profile
boxkey() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$PROFILE_FILE" 2>/dev/null | tail -1; }
AVATAR="$(boxkey account_avatar)"
VSCODE_SRC="$(boxkey vscode_extensions_src)"

while [ $# -gt 0 ]; do
  case "$1" in
    --type)  TYPE="${2:?--type needs a value}"; shift 2 ;;
    --first) FIRST="${2:?--first needs a value}"; shift 2 ;;
    --last)  LAST="${2:?--last needs a value}"; shift 2 ;;
    --lock)  LOCKED=1; shift ;;
    --temp)  TEMP=1; shift ;;
    --vscode)    VSCODE=yes; shift ;;
    --no-vscode) VSCODE=no; shift ;;
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
if   [ "$LOCKED" -eq 1 ]; then pw_plan='locked (set one later with it-passwd)'
elif [ "$TEMP"   -eq 1 ]; then pw_plan='temporary, generated and shown once'
else                          pw_plan='you will be asked, after you confirm'
fi
printf '  %-12s %s\n' "password"  "$pw_plan"
[ "$LOCKED" -eq 0 ] && [ "$FORCE_EXPIRE" -eq 1 ] && \
  printf '  %-12s %s\n' "" "must be changed at first login"

if [ "$DRY" -eq 1 ]; then warn "dry run -- nothing was created"; exit 0; fi
read -r -p $'\nCreate it? [y/N] ' a || exit 1
case "${a,,}" in y|yes) ;; *) die "aborted" ;; esac

# ---- password ----------------------------------------------------------------
# Three ways, and the account ends up in a defensible state whichever is taken:
# a typed password, a generated temporary one, or locked. The first two are
# expired immediately, so neither the admin nor a generator ends up knowing the
# password the user actually logs in with.
if [ "$LOCKED" -eq 1 ]; then
  PW_MODE=skip
elif [ "$TEMP" -eq 1 ]; then
  PW="$(gen_password)" || die "could not generate a password this box's policy accepts"
  PW_MODE=temp
  printf '\n  %sTEMPORARY PASSWORD for %s%s\n\n' "$B" "$USERNAME" "$R"
  printf '      %s%s%s\n\n' "$B" "$PW" "$R"
elif [ -t 0 ]; then
  pw_choose "$USERNAME" "Leave it locked" "no password now; set one later with it-passwd $USERNAME" \
    || die "aborted"
  [ "$PW_MODE" = skip ] && LOCKED=1
else
  die "no terminal to ask on -- pass --temp or --lock"
fi

# A temporary password nobody has to change is not temporary.
if [ "$PW_MODE" = temp ] && [ "$FORCE_EXPIRE" -eq 0 ]; then
  warn "--no-expire ignored for a temporary password: it must be changed at first login"
  FORCE_EXPIRE=1
fi

# ---- create ------------------------------------------------------------------
# Say it takes a moment, because it does: `useradd -m` copies /etc/skel and
# chpasswd hashes with yescrypt, which is deliberately slow and slower again on
# a FIPS kernel. Several seconds of silence after "Creating" reads as a hang,
# and the wrong reaction to that is Ctrl-C BETWEEN the two -- which leaves a
# real account with no password rather than no account at all.
head2 "Creating"
say "  ${DIM}This takes a few seconds (home directory, then password hashing).${R}"
say "  ${DIM}Let it finish -- interrupting now can leave the account half-made.${R}"
useradd -m -s /bin/bash ${GROUPS_CSV:+-G "$GROUPS_CSV"} "$USERNAME" \
  || die "useradd failed"
ok "account created"

if [ "$LOCKED" -eq 1 ]; then
  usermod -L "$USERNAME"
  ok "password LOCKED -- set one with: it-passwd $USERNAME"
else
  printf '%s:%s' "$USERNAME" "$PW" | chpasswd || die "chpasswd failed"
  [ "$PW_MODE" = temp ] && ok "temporary password set (shown above -- it is not stored anywhere)"
  unset PW
  usermod -U "$USERNAME" 2>/dev/null || true
  ok "password set"
  if [ "$FORCE_EXPIRE" -eq 1 ]; then
    chage -d 0 "$USERNAME" && ok "must be changed at first login"
  fi
fi

# ---- account picture ----------------------------------------------------------
# useradd -m already gave them /etc/skel/.face, but GNOME does not read that:
# it asks AccountsService, and an account created between pulls has no
# AccountsService record at all. That is why a new user shows the generic
# avatar until the next ansible-pull runs desktop_branding over every user.
# Writing it here means the logo is there at first login.
if [ -n "$AVATAR" ] && [ -f "$AVATAR" ]; then
  install -d -m 0755 /var/lib/AccountsService/users
  as_file="/var/lib/AccountsService/users/$USERNAME"
  if [ -f "$as_file" ] && grep -q '^Icon=' "$as_file"; then
    sed -i "s|^Icon=.*|Icon=$AVATAR|" "$as_file"
  elif [ -f "$as_file" ]; then
    printf 'Icon=%s\n' "$AVATAR" >> "$as_file"
  else
    printf '[User]\nIcon=%s\n' "$AVATAR" > "$as_file"
  fi
  chmod 0644 "$as_file"
  ok "account picture set (AccountsService -> $AVATAR)"
elif [ -n "$AVATAR" ]; then
  warn "no avatar image at $AVATAR -- the generic picture will be used"
fi

# ---- VS Code extensions --------------------------------------------------------
# NOT inherited from /etc/skel any more: the set is measured in GB and useradd -m
# copies /etc/skel in full, which made creating one account take over a minute
# and gave every account its own copy. Offered here instead, with the size shown,
# so whoever waits for it knows what they are waiting for.
if [ -n "$VSCODE_SRC" ] && [ -d "$VSCODE_SRC" ] && [ "$VSCODE" != no ]; then
  vs_size=$(du -sh "$VSCODE_SRC" 2>/dev/null | cut -f1)
  do_vs=0
  if [ "$VSCODE" = yes ]; then
    do_vs=1
  elif [ -t 0 ]; then
    head2 "VS Code extensions"
    say "  A shared set is installed on this box: ${vs_size:-unknown} in $VSCODE_SRC"
    say "  ${DIM}Copying it takes about as long as it sounds, and uses that much disk again."
    say "  Skip it unless this user needs the full set -- they can install what they"
    say "  actually use with: code --install-extension <id>${R}"
    read -r -p "  Copy them into $USERNAME's home? [y/N] " a || a=n
    case "${a,,}" in y|yes) do_vs=1 ;; esac
  fi
  if [ "$do_vs" -eq 1 ]; then
    say "  copying ${vs_size:-} ..."
    install -d -m 0700 -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.vscode/extensions"
    if cp -a "$VSCODE_SRC/." "/home/$USERNAME/.vscode/extensions/" 2>/dev/null; then
      chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.vscode"
      chmod 0700 "/home/$USERNAME/.vscode" "/home/$USERNAME/.vscode/extensions"
      ok "VS Code extensions copied"
    else
      warn "the copy failed -- $USERNAME can install extensions themselves"
    fi
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
