#!/usr/bin/env bash
# it-users -- every local account on one screen: state, password expiry, last
# login, groups.
#
# The question an assessor asks ("show me the accounts and when their passwords
# expire") and the question an admin asks ("who has not logged in since we built
# this box") are the same table, so this is one table.
#
# Usage:
#   it-users                 the table (the normal way)
#   it-users --all           include system accounts (uid < 1000) too
#   it-users --wide          do not truncate the group list
#   it-users --csv           machine-readable, for evidence or a spreadsheet
#   it-users --out FILE      write it to a file as well
#
# Reads only. To CHANGE anything: it-passwd <user> resets, unlocks and clears
# faillock; it-adduser creates. `it-passwd --list` adds the faillock counter.
set -uo pipefail

[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

ALL=0; WIDE=0; CSV=0; OUT=""

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
