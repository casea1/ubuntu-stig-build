#!/usr/bin/env bash
# it-users -- every local account on one screen: state, password expiry, last
# login, groups.
#
# The question an assessor asks ("show me the accounts and when their passwords
# expire") and the question an admin asks ("who has not logged in since we built
# this box") are the same table, so this is one table.
#
# Usage -- REPORTING (the default, read-only):
#   it-users                 the table (the normal way)
#   it-users --all           include system accounts (uid < 1000) too
#   it-users --wide          do not truncate the group list
#   it-users --csv           machine-readable, for evidence or a spreadsheet
#   it-users --out FILE      write it to a file as well
#   it-users show <user>     one account in full, including what a pull will do
#
# Usage -- ADMIN (changes the box; every one asks before it acts):
#   it-users lock <user>     disable the account  (alias: disable)
#   it-users unlock <user>   re-enable it         (alias: enable)
#   it-users delete <user>   remove it            (alias: remove)
#   it-users groups <user> [--add a,b] [--remove c] [--set a,b]
#
#   --yes        skip the confirmation (for scripts; think before you use it)
#   --keep-home  delete: leave /home/<user> in place
#   --kill       lock: also end the user's live sessions
#
# ANSIBLE IS AUTHORITATIVE, NOT THIS SCRIPT. An account listed in the
# baseline's `local_users` is recreated by the next pull, and its group list is
# rewritten to match (`append: false` -- the merged set is authoritative, so a
# group added here is REMOVED again). Every command below says so when it
# applies, and names the file to edit. Two things DO survive a pull, which is
# why `lock` uses them: the password lock (`update_password: on_create`) and
# the account expiry (ansible does not manage it). The shell does not.
#
# WHY `lock` SETS AN EXPIRY AND NOT JUST A PASSWORD LOCK: `passwd -l` only
# prefixes the hash with `!`, which stops PASSWORD auth. It does nothing to SSH
# PUBLIC-KEY auth -- the key path never looks at the hash. The account expiry is
# what makes the account stage fail, so it is the half that actually disables
# the account.
#
# Related: it-passwd <user> resets, unlocks and clears faillock; it-adduser
# creates. `it-passwd --list` adds the faillock counter.
set -uo pipefail

[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

ALL=0; WIDE=0; CSV=0; OUT=""
YES=0; KEEP_HOME=0; KILL_SESSIONS=0

# The subcommand is taken BEFORE the option loop below, because that loop dies
# on anything it does not recognise and a username is one of those things. The
# dispatch itself happens at the very bottom, once every function exists.
CMD=""; CARGS=()
case "${1:-}" in
  lock|disable)   CMD=lock;   shift; CARGS=("$@"); set -- ;;
  unlock|enable)  CMD=unlock; shift; CARGS=("$@"); set -- ;;
  delete|remove)  CMD=delete; shift; CARGS=("$@"); set -- ;;
  groups)         CMD=groups; shift; CARGS=("$@"); set -- ;;
  show)           CMD=show;   shift; CARGS=("$@"); set -- ;;
  list|table)     shift ;;
esac

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'
else
  B=""; DIM=""; R=""; RED=""; GRN=""; YEL=""
fi
die()   { printf '%s\n' "$*" >&2; exit 1; }
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all)  ALL=1; shift ;;
    --wide) WIDE=1; shift ;;
    --csv)  CSV=1; shift ;;
    --out)  OUT="${2:?--out needs a path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

TODAY=$(( $(date +%s) / 86400 ))

# Human accounts are uid 1000..65533, the same range the org checklist counts.
accounts() {
  if [ "$ALL" -eq 1 ]; then awk -F: '{print $1}' /etc/passwd | sort
  else awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd | sort
  fi
}

# The suffix convention it-adduser applies. Anything else was made another way,
# which is worth seeing in the table rather than guessing at.
type_of() {
  case "$1" in
    *_adm) echo admin ;;
    *_dta) echo dta ;;
    *_aud) echo audit ;;
    *)     echo standard ;;
  esac
}

# From /etc/shadow, not `chage -l`: the fields are integers and locale-free,
# where chage prints a localised date this would have to parse back.
#   $3 lastchg (days since epoch, 0 = must change now), $5 max, $7 inactive,
#   $8 account expiry.
pw_days() {   # -> "<sort key>|<text>"; sort key is days left, 99999 = n/a
  local u="$1" lastchg max left
  lastchg=$(awk -F: -v u="$u" '$1==u{print $3}' /etc/shadow)
  max=$(awk -F: -v u="$u" '$1==u{print $5}' /etc/shadow)
  case "$lastchg" in ''|*[!0-9]*) echo "99999|unknown"; return ;; esac
  [ "$lastchg" -eq 0 ] && { echo "-2|CHANGE NOW"; return; }
  case "$max" in ''|*[!0-9]*) echo "99999|never expires"; return ;; esac
  [ "$max" -ge 99999 ] && { echo "99999|never expires"; return; }
  left=$(( lastchg + max - TODAY ))
  if   [ "$left" -lt 0 ]; then echo "$left|EXPIRED ${left#-}d ago"
  elif [ "$left" -eq 0 ]; then echo "0|expires today"
  else echo "$left|$left days"
  fi
}

acct_expiry() {   # the ACCOUNT expiry, which blocks login on its own
  local u="$1" e
  e=$(awk -F: -v u="$u" '$1==u{print $8}' /etc/shadow)
  case "$e" in ''|*[!0-9]*) return ;; esac
  [ "$e" -le "$TODAY" ] && echo "acct expired" || echo "acct ends $(date -d "@$(( e * 86400 ))" '+%Y-%m-%d')"
}

state_of() {
  case "$(passwd -S "$1" 2>/dev/null | awk '{print $2}')" in
    L|LK) echo LOCKED ;;
    NP)   echo NOPASS ;;
    P|PS) echo ok ;;
    *)    echo '?' ;;
  esac
}

# LAST-LOGIN via lslogins where it has an answer, wtmp otherwise. Neither is
# authoritative on its own: lslogins reads /var/log/lastlog, which only gets
# written if pam_lastlog runs -- and pam_lastlog is deprecated and not in the
# 24.04 stack -- while wtmp is written by GDM and sshd but rotates.
declare -A LASTLOGIN
load_logins() {
  local u when
  while IFS=$'\t' read -r u when; do
    [ -n "${u:-}" ] || continue
    LASTLOGIN["$u"]="${when:-}"
  done < <(lslogins --user-accs --noheadings --raw -o USER,LAST-LOGIN 2>/dev/null | tr ' ' '\t')
}
last_login() {
  local u="$1" v raw
  v="${LASTLOGIN[$u]:-}"
  if [ -z "$v" ]; then
    # "user tty host Mon Sep 1 08:12:33 2026 - ..." -- the date is 5 fields
    # from field 4, and only when the line is a real login record.
    raw=$(last -w -F -n1 "$u" 2>/dev/null | awk 'NR==1 && NF>6 {print $4" "$5" "$6" "$7" "$8}')
    [ -n "$raw" ] && v=$(date -d "$raw" '+%Y-%m-%d %H:%M' 2>/dev/null)
  else
    v=$(date -d "$v" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$v")
  fi
  printf '%s' "${v:-never}"
}

groups_of() {
  local g; g=$(id -nG "$1" 2>/dev/null | tr ' ' ',')
  # The primary group repeats the username on every row and says nothing.
  g="${g#"$1",}"; g="${g#"$1"}"
  printf '%s' "${g:-none}"
}

trunc() {   # $1 = text, $2 = width
  [ "$WIDE" -eq 1 ] && { printf '%s' "$1"; return; }
  if [ "${#1}" -gt "$2" ]; then printf '%s...' "${1:0:$(( $2 - 3 ))}"; else printf '%s' "$1"; fi
}

load_logins

# ---- CSV --------------------------------------------------------------------
if [ "$CSV" -eq 1 ]; then
  out() { printf '%s\n' "$*"; }
  {
    out "user,type,state,password_days_left,password_status,account_expiry,last_login,groups"
    while read -r u; do
      [ -n "$u" ] || continue
      d="$(pw_days "$u")"
      out "$u,$(type_of "$u"),$(state_of "$u"),${d%%|*},\"${d#*|}\",\"$(acct_expiry "$u")\",\"$(last_login "$u")\",\"$(groups_of "$u")\""
    done < <(accounts)
  } | { [ -n "$OUT" ] && tee "$OUT" || cat; }
  [ -n "$OUT" ] && printf '\nWrote %s\n' "$OUT" >&2
  exit 0
fi

# ---- table ------------------------------------------------------------------
render() {
  local u t s d key text col acct ll grp n=0 warn=0 locked=0 expired=0

  printf '\n%sLocal accounts on %s%s   %s%s%s\n\n' \
    "$B" "$(hostname)" "$R" "$DIM" "$(date '+%Y-%m-%d %H:%M')" "$R"
  printf '  %-22s %-9s %-7s %-16s %-17s %s\n' USER TYPE STATE PASSWORD "LAST LOGIN" GROUPS
  printf '  %s\n' "$(printf '%.0s-' $(seq 1 96))"

  while read -r u; do
    [ -n "$u" ] || continue
    n=$((n + 1))
    t=$(type_of "$u"); s=$(state_of "$u")
    d=$(pw_days "$u"); key="${d%%|*}"; text="${d#*|}"
    acct=$(acct_expiry "$u"); ll=$(last_login "$u"); grp=$(groups_of "$u")

    # Colour carries the same information the words do, never only it: this
    # gets piped into evidence and read in black and white.
    col=""
    if   [ "$key" = "-2" ];               then col="$YEL"; warn=$((warn + 1))
    elif [ "$key" -lt 0 ] 2>/dev/null;    then col="$RED"; expired=$((expired + 1))
    elif [ "$key" -le 14 ] 2>/dev/null;   then col="$YEL"; warn=$((warn + 1))
    fi
    [ "$s" = LOCKED ] || [ "$s" = NOPASS ] && locked=$((locked + 1))
    [ -n "$acct" ] && text="$text ($acct)"

    printf '  %-22s %-9s %s%-7s%s %s%-16s%s %-17s %s\n' \
      "$(trunc "$u" 22)" "$t" \
      "$([ "$s" = ok ] && printf '%s' "$GRN" || printf '%s' "$RED")" "$s" "$R" \
      "$col" "$(trunc "$text" 16)" "$R" \
      "$ll" "$(trunc "$grp" 30)"
  done < <(accounts)

  printf '\n  %s account(s)' "$n"
  [ "$expired" -gt 0 ] && printf ', %s%s with an EXPIRED password%s' "$RED" "$expired" "$R"
  [ "$warn"    -gt 0 ] && printf ', %s%s needing a change soon%s'    "$YEL" "$warn" "$R"
  [ "$locked"  -gt 0 ] && printf ', %s locked or password-less' "$locked"
  printf '\n'
  printf '  %sLast login is from lastlog and wtmp; "never" can also mean the record\n' "$DIM"
  printf '  rotated away. Reset one: it-passwd <user>. Faillock: it-passwd --list.%s\n\n' "$R"
}

# ===========================================================================
# ADMIN SUBCOMMANDS
#
# Everything below CHANGES the box. Three rules they all follow:
#   1. Say what will happen, then ask. --yes skips the asking, nothing else.
#   2. Never strand the machine. Locking or deleting the last account that can
#      reach root is refused outright: LUKS plus a GRUB password means there is
#      no console rescue on these boxes.
#   3. Say when ansible will undo it, and name the file to edit instead.
# ===========================================================================
head2() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }
ok()    { printf '  %s%s%s\n' "$GRN" "$*" "$R"; }
warn()  { printf '  %s%s%s\n' "$YEL" "$*" "$R"; }
bad()   { printf '  %s%s%s\n' "$RED" "$*" "$R"; }
say()   { printf '  %s\n' "$*"; }
note()  { printf '       %s%s%s\n' "$DIM" "$*" "$R"; }

NOLOGIN=/usr/sbin/nologin
user_shell() { awk -F: -v u="$1" '$1==u{print $7}' /etc/passwd; }
user_home()  { awk -F: -v u="$1" '$1==u{print $6}' /etc/passwd; }

# Is this account written into the baseline? If it is, the PULL owns it and
# anything done here is temporary. Both places are checked: the ansible-pull
# clone's group_vars (the fleet default) and site.yml (this box's overrides).
BASELINE_SRC=""
baseline_files() {
  ls -1 /root/.ansible/pull/*/group_vars/all.yml 2>/dev/null
  [ -f /opt/it/site.yml ] && printf '%s\n' /opt/it/site.yml
}
baseline_listed() {   # $1 = user
  local f u="$1"
  BASELINE_SRC=""
  while read -r f; do
    [ -f "$f" ] || continue
    if grep -qE "(^|[[:space:]{,])name:[[:space:]]*${u}([[:space:],}]|$)" "$f" 2>/dev/null; then
      BASELINE_SRC="$f"; return 0
    fi
  done < <(baseline_files)
  return 1
}
baseline_warn() {   # $1 = user, $2 = what the pull will undo
  baseline_listed "$1" || return 0
  warn "$1 is listed in the baseline -- the next pull will $2."
  note "Listed in: $BASELINE_SRC"
  note "To make this permanent, remove the entry from local_users there and"
  note "commit it, or the change lasts until the next ansible-pull."
}

sudo_capable() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qxE 'sudo|admin|root'; }

# How many OTHER accounts can still reach root and still log in.
other_admins() {   # $1 = the user being changed
  local u c=0
  while read -r u; do
    [ "$u" = "$1" ] && continue
    sudo_capable "$u" || continue
    [ "$(state_of "$u")" = LOCKED ] && continue
    case "$(user_shell "$u")" in */nologin|*/false) continue ;; esac
    c=$((c + 1))
  done < <(awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd)
  printf '%s' "$c"
}

# Refuse the three ways an admin locks themselves out of a box they cannot
# reach a console on.
guard_target() {   # $1 = user, $2 = verb for the message
  id "$1" >/dev/null 2>&1 || die "no such user: $1"
  [ "$1" = root ] && die "refusing to $2 root"
  [ "$1" = "${SUDO_USER:-}" ] && die "$1 is the account you are sudo'd from -- refusing to $2 it"
  if sudo_capable "$1" && [ "$(other_admins "$1")" -eq 0 ]; then
    die "$1 is the LAST account that can reach root on this box -- refusing to $2 it.
Create or unlock another admin first. There is no console rescue here: the disk
is LUKS-encrypted and GRUB has a password."
  fi
  return 0
}

confirm() {   # $1 = prompt
  [ "$YES" -eq 1 ] && return 0
  [ -t 0 ] || die "not a terminal and --yes was not given -- refusing to act blind"
  printf '  %sType YES to %s: %s' "$B" "$1" "$R"
  local a; read -r a
  [ "$a" = YES ]
}

live_sessions() { loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$1" '$3==u' | wc -l; }

# code-server is one systemd instance per person (code-server@<user>.service).
# A disabled account must not keep an IDE with a shell in it running.
stop_code_server() {   # $1 = user
  systemctl list-unit-files "code-server@$1.service" >/dev/null 2>&1 || return 0
  if systemctl is-enabled --quiet "code-server@$1.service" 2>/dev/null ||
     systemctl is-active  --quiet "code-server@$1.service" 2>/dev/null; then
    systemctl disable --now "code-server@$1.service" >/dev/null 2>&1 &&
      ok "code-server@$1 stopped and disabled"
  fi
}

# ---------------------------------------------------------------------------
cmd_show() {
  local u="${1:-}"
  [ -n "$u" ] || die "usage: it-users show <user>"
  id "$u" >/dev/null 2>&1 || die "no such user: $u"
  local d; d="$(pw_days "$u")"
  head2 "$u"
  printf '  %-16s %s\n' "uid"        "$(id -u "$u")"
  printf '  %-16s %s\n' "type"       "$(type_of "$u")"
  printf '  %-16s %s\n' "state"      "$(state_of "$u")"
  printf '  %-16s %s\n' "shell"      "$(user_shell "$u")"
  printf '  %-16s %s\n' "home"       "$(user_home "$u")"
  printf '  %-16s %s\n' "password"   "${d#*|}"
  local acct; acct="$(acct_expiry "$u")"
  printf '  %-16s %s\n' "account"    "${acct:-no expiry}"
  printf '  %-16s %s\n' "groups"     "$(groups_of "$u")"
  printf '  %-16s %s\n' "root?"      "$(sudo_capable "$u" && echo 'YES -- can sudo' || echo no)"
  printf '  %-16s %s\n' "last login" "$(last_login "$u")"
  printf '  %-16s %s\n' "sessions"   "$(live_sessions "$u") live"
  if command -v faillock >/dev/null 2>&1; then
    printf '  %-16s %s\n' "faillock" "$(faillock --user "$u" 2>/dev/null | tail -n +3 | grep -c . ) failed attempt(s)"
  fi
  head2 "What a pull does to this account"
  if baseline_listed "$u"; then
    warn "listed in the baseline -- ansible owns it"
    note "recreated if deleted; groups rewritten to the baseline's list"
    note "(append: false, so a group added by hand is removed again)"
    note "survives a pull: the password lock, and the account expiry"
    note "does NOT survive: the shell -- ansible sets it back to /bin/bash"
    note "listed in: $BASELINE_SRC"
  else
    ok "not in the baseline -- changes here are permanent"
  fi
  printf '\n'
}

# ---------------------------------------------------------------------------
cmd_lock() {
  local u="${1:-}"
  [ -n "$u" ] || die "usage: it-users lock <user> [--kill]"
  guard_target "$u" lock

  head2 "Lock $u"
  say "This will:"
  say "  password lock      passwd -l       (stops password auth)"
  say "  account expiry     chage -E 1      (stops SSH KEY auth -- the half that matters)"
  say "  shell              $NOLOGIN"
  local n; n="$(live_sessions "$u")"
  if [ "$n" -gt 0 ]; then
    if [ "$KILL_SESSIONS" -eq 1 ]; then
      say "  sessions           $n live -- will be ENDED (--kill)"
    else
      warn "$n live session(s) will KEEP RUNNING. Re-run with --kill to end them."
    fi
  fi
  baseline_warn "$u" "set the shell back to /bin/bash (the lock and expiry survive)"
  confirm "lock $u" || die "not confirmed -- nothing was changed"

  passwd -l "$u" >/dev/null 2>&1 && ok "password locked" || warn "passwd -l failed"
  chage -E 1 "$u" 2>/dev/null && ok "account expired (1970-01-02)" || warn "chage -E failed"
  usermod -s "$NOLOGIN" "$u" 2>/dev/null && ok "shell -> $NOLOGIN" || warn "shell unchanged"
  stop_code_server "$u"
  if [ "$KILL_SESSIONS" -eq 1 ] && [ "$n" -gt 0 ]; then
    loginctl terminate-user "$u" 2>/dev/null && ok "live sessions ended"
  fi
  printf '\n'
  note "Re-enable with: it-users unlock $u   (then it-passwd $u to set a password)"
  printf '\n'
}

# ---------------------------------------------------------------------------
cmd_unlock() {
  local u="${1:-}"
  [ -n "$u" ] || die "usage: it-users unlock <user>"
  id "$u" >/dev/null 2>&1 || die "no such user: $u"

  head2 "Unlock $u"
  say "  account expiry     cleared"
  say "  shell              /bin/bash"
  say "  password lock      cleared, IF a password was ever set"
  say "  faillock counter   reset"
  confirm "unlock $u" || die "not confirmed -- nothing was changed"

  chage -E -1 "$u" 2>/dev/null && ok "account expiry cleared"
  usermod -s /bin/bash "$u" 2>/dev/null && ok "shell -> /bin/bash"
  # An account created by the baseline has the hash "!" -- never a real
  # password, just locked. passwd -u refuses that (it would leave the account
  # password-less), and it is right to: the fix is to SET one.
  if passwd -u "$u" >/dev/null 2>&1; then
    ok "password unlocked"
  else
    warn "no password to unlock -- this account has never had one set"
    note "That is normal for a baseline account. Set one:  it-passwd $u"
  fi
  command -v faillock >/dev/null 2>&1 && faillock --user "$u" --reset 2>/dev/null &&
    ok "faillock counter reset"
  printf '\n'
}

# ---------------------------------------------------------------------------
cmd_delete() {
  local u="${1:-}"
  [ -n "$u" ] || die "usage: it-users delete <user> [--keep-home]"
  guard_target "$u" delete

  local home procs n
  home="$(user_home "$u")"
  # pgrep -c PRINTS 0 and also exits 1 when nothing matches, so a `|| printf 0`
  # fallback appends a second zero. Take the first line and nothing else.
  procs="$(pgrep -u "$u" -c 2>/dev/null | head -1)"; procs="${procs:-0}"
  n="$(live_sessions "$u")"

  head2 "Delete $u"
  bad "This removes the account. It cannot be undone from here."
  printf '  %-16s %s\n' "home"     "$home$( [ -d "$home" ] && printf ' (%s)' "$(du -sh "$home" 2>/dev/null | cut -f1)" )"
  printf '  %-16s %s\n' "home will be" "$( [ "$KEEP_HOME" -eq 1 ] && echo 'KEPT (--keep-home)' || echo 'DELETED' )"
  printf '  %-16s %s\n' "processes" "$procs running"
  printf '  %-16s %s\n' "sessions"  "$n live"
  printf '  %-16s %s\n' "groups"    "$(groups_of "$u")"
  sudo_capable "$u" && warn "this account can sudo"
  crontab -l -u "$u" >/dev/null 2>&1 && warn "it has a crontab (it goes with the account)"
  baseline_warn "$u" "RECREATE this account, with a fresh empty home"
  confirm "delete $u" || die "not confirmed -- nothing was changed"

  stop_code_server "$u"
  [ "$n" -gt 0 ] && { loginctl terminate-user "$u" 2>/dev/null; sleep 2; }
  crontab -r -u "$u" 2>/dev/null && ok "crontab removed"
  pkill -KILL -u "$u" 2>/dev/null
  # userdel refuses while a process survives, so the kill above is not optional.
  if [ "$KEEP_HOME" -eq 1 ]; then
    userdel "$u" 2>/dev/null && ok "account removed, $home kept"
  else
    userdel -r "$u" 2>/dev/null && ok "account and home removed"
  fi
  id "$u" >/dev/null 2>&1 && bad "userdel did not complete -- $u still exists" || true
  printf '\n'
}

# ---------------------------------------------------------------------------
cmd_groups() {
  local u="${1:-}"; shift 2>/dev/null || true
  [ -n "$u" ] || die "usage: it-users groups <user> [--add a,b] [--remove c] [--set a,b]"
  id "$u" >/dev/null 2>&1 || die "no such user: $u"

  local ADD="" DEL="" SET="" have_op=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --add)    ADD="${2:?--add needs a list}";    have_op=1; shift 2 ;;
      --remove) DEL="${2:?--remove needs a list}"; have_op=1; shift 2 ;;
      --set)    SET="${2:?--set needs a list}";    have_op=1; shift 2 ;;
      --yes)    shift ;;
      *) die "unknown option: $1" ;;
    esac
  done

  if [ "$have_op" -eq 0 ]; then
    head2 "Groups for $u"
    say "  primary     $(id -gn "$u")"
    say "  secondary   $(groups_of "$u")"
    printf '\n'
    note "Change with --add a,b / --remove c / --set a,b"
    printf '\n'
    return 0
  fi

  # A group that does not exist is not created here. On this fleet groups are
  # made by the baseline (local_groups) precisely because local_accounts runs
  # long before the roles that use them -- creating one by hand here would
  # diverge from that and vanish from a rebuilt box.
  local g missing=""
  for g in $(printf '%s %s %s' "$ADD" "$SET" "$DEL" | tr ',' ' '); do
    [ -n "$g" ] || continue
    getent group "$g" >/dev/null 2>&1 || missing="$missing $g"
  done
  [ -n "$missing" ] && die "no such group(s):$missing
Add them to local_groups in the baseline and pull -- do not create them by hand."

  head2 "Groups for $u"
  say "  before      $(groups_of "$u")"
  case ",$ADD,$SET," in *,sudo,*)
    warn "sudo is in that list. This grants ROOT on this machine." ;;
  esac
  [ -n "$SET" ] && warn "--set is authoritative: every group NOT listed is removed."
  baseline_warn "$u" "rewrite this account's groups to the baseline's list (append: false)"
  confirm "change groups for $u" || die "not confirmed -- nothing was changed"

  if [ -n "$SET" ]; then
    usermod -G "$SET" "$u" 2>/dev/null && ok "groups set to: $SET" || die "usermod failed"
  fi
  [ -n "$ADD" ] && { usermod -aG "$ADD" "$u" 2>/dev/null && ok "added: $ADD" || warn "add failed"; }
  if [ -n "$DEL" ]; then
    for g in $(printf '%s' "$DEL" | tr ',' ' '); do
      gpasswd -d "$u" "$g" >/dev/null 2>&1 && ok "removed: $g" || warn "not a member of $g"
    done
  fi
  say "  after       $(groups_of "$u")"
  printf '\n'
  warn "Group membership is read at LOGIN. $u must log out and back in -- an"
  note "existing RDP or SSH session keeps the old groups until it ends."
  printf '\n'
}

# ---------------------------------------------------------------------------
if [ -n "$CMD" ]; then
  # Flags common to the admin commands, pulled out before the positional args.
  ARGS=()
  for a in ${CARGS+"${CARGS[@]}"}; do
    case "$a" in
      --yes)       YES=1 ;;
      --keep-home) KEEP_HOME=1 ;;
      --kill)      KILL_SESSIONS=1 ;;
      *)           ARGS+=("$a") ;;
    esac
  done
  # `groups` takes its own --add/--remove/--set, so it gets the list back intact.
  case "$CMD" in
    groups) cmd_groups ${CARGS+"${CARGS[@]}"} ;;
    lock)   cmd_lock   ${ARGS+"${ARGS[@]}"} ;;
    unlock) cmd_unlock ${ARGS+"${ARGS[@]}"} ;;
    delete) cmd_delete ${ARGS+"${ARGS[@]}"} ;;
    show)   cmd_show   ${ARGS+"${ARGS[@]}"} ;;
  esac
  exit $?
fi

if [ -n "$OUT" ]; then
  # The saved copy is the one that ends up in an evidence bundle, so write it
  # WITHOUT colour: the vars are blanked in a subshell, which is cheaper and
  # more reliable than stripping escape sequences back out afterwards.
  ( B=""; DIM=""; R=""; RED=""; GRN=""; YEL=""; render ) > "$OUT"
  chmod 0640 "$OUT" 2>/dev/null || true
  render
  printf '  Written to %s\n\n' "$OUT"
else
  render
fi
