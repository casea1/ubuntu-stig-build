#!/usr/bin/env bash
# pw-common.sh -- shared password handling for it-adduser and it-passwd.
#
# SOURCED, never executed. It exists so the two scripts cannot drift: the
# generator below is validated against the SAME check_policy the typed path
# uses, so a generated password can never be one this box would have rejected.
#
# Callers must already define: say / ok / warn / bad, and the colour vars.

# What this box actually asks for. Read it rather than assuming 15: a site that
# raised minlen would otherwise get generated passwords its own policy rejects.
pw_minlen() {
  local conf=/etc/security/pwquality.conf m=""
  [ -r "$conf" ] && m=$(awk -F= '/^[[:space:]]*minlen/{gsub(/ /,"",$2); print $2}' "$conf" 2>/dev/null | tail -1)
  case "$m" in ''|*[!0-9]*) m=15 ;; esac
  printf '%s' "$m"
}

# chpasswd does NOT go through pam_pwquality, so a password set that way skips
# the box's complexity policy entirely. Check it here instead of pretending the
# policy applied.
check_policy() {
  local pw="$1" rc=0 msg=""
  if command -v pwscore >/dev/null 2>&1; then
    msg=$(printf '%s' "$pw" | pwscore 2>&1) || rc=1
    [ "$rc" -ne 0 ] && { printf '%s' "$msg"; return 1; }
    return 0
  fi
  # No libpwquality-tools: check what pwquality.conf actually asks for.
  local conf=/etc/security/pwquality.conf minlen
  minlen=$(pw_minlen)
  [ "${#pw}" -ge "$minlen" ] || { printf 'shorter than minlen=%s' "$minlen"; return 1; }
  local want cls
  for cls in d:'[0-9]' u:'[A-Z]' l:'[a-z]' o:'[^a-zA-Z0-9]'; do
    want=$(awk -F= "/^[[:space:]]*${cls%%:*}credit/{gsub(/ /,\"\",\$2); print \$2}" "$conf" 2>/dev/null | tail -1)
    # A NEGATIVE credit is a minimum count of that class.
    if [ -n "$want" ] && [ "$want" -lt 0 ] 2>/dev/null; then
      printf '%s' "$pw" | grep -q "${cls#*:}" \
        || { printf 'missing a required character class (%scredit=%s)' "${cls%%:*}" "$want"; return 1; }
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Generated temporary password.
#
# Character set choices, both deliberate:
#   * No 0/O/1/l/I. This gets read off one screen and typed on another, once,
#     by someone who did not choose it. A misread character is indistinguishable
#     from "the reset did not work".
#   * No ':'. chpasswd reads user:password and splits on the first colon, so a
#     colon is survivable -- but the same string gets read aloud over a phone,
#     and a punctuation mark nobody can name is not worth the risk.
# ---------------------------------------------------------------------------
pw_rand() {   # $1 = character set, $2 = how many
  # head closes the pipe, which SIGPIPEs tr; under `set -o pipefail` that is a
  # non-zero pipeline for a command that did exactly what was asked.
  LC_ALL=C tr -dc "$1" < /dev/urandom 2>/dev/null | head -c "$2" || true
}

gen_password() {   # -> a password this box's own policy accepts, on stdout
  local U='ABCDEFGHJKLMNPQRSTUVWXYZ' L='abcdefghijkmnpqrstuvwxyz'
  local D='23456789' S='@#%+=,.?_-'
  local want tries=0 pw
  want=$(pw_minlen)
  # Comfortably over the floor: a 15-character minimum with a generated password
  # exactly 15 long fails the moment anyone raises minlen by one.
  [ "$want" -ge 20 ] 2>/dev/null || want=20

  while [ "$tries" -lt 50 ]; do
    tries=$((tries + 1))
    # One of each class up front guarantees the credits are satisfied; the
    # shuffle stops the classes appearing in a predictable order.
    pw="$(pw_rand "$U" 1)$(pw_rand "$L" 1)$(pw_rand "$D" 1)$(pw_rand "$S" 1)"
    pw="$pw$(pw_rand "$U$L$D$S" "$((want - 4))")"
    pw=$(printf '%s' "$pw" | fold -w1 | shuf | tr -d '\n')
    [ "${#pw}" -ge "$want" ] || continue
    check_policy "$pw" >/dev/null 2>&1 && { printf '%s' "$pw"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------------------
# The prompt both scripts share.
#
# Sets PW_MODE (typed | temp | skip) and, for the first two, PW.
# $1 = account name, $2 = the label for the third choice, $3 = its explanation.
# ---------------------------------------------------------------------------
pw_choose() {
  local who="$1" skip_label="$2" skip_help="$3" choice PW2 reason

  printf '\n%sPassword for %s%s\n' "${B:-}" "$who" "${R:-}"
  printf '  1) %-21s %s\n' "Set one now"        "you type it. This IS the password -- no forced change."
  printf '  2) %-21s %s\n' "Temporary password" "generated here and shown once. Must be changed at first login."
  printf '  3) %-21s %s\n' "$skip_label"        "$skip_help"
  printf '\n'

  while :; do
    read -r -p "  Choose [1-3]: " choice
    case "$choice" in
      1) PW_MODE=typed; break ;;
      2) PW_MODE=temp;  break ;;
      3) PW_MODE=skip;  return 0 ;;
      *) bad "pick 1, 2 or 3" ;;
    esac
  done

  if [ "$PW_MODE" = temp ]; then
    PW="$(gen_password)" || {
      bad "could not generate a password this box's policy accepts"
      say "  Set one by hand instead (choice 1), or check /etc/security/pwquality.conf"
      return 1
    }
    printf '\n  %sTEMPORARY PASSWORD for %s%s\n\n' "${B:-}" "$who" "${R:-}"
    printf '      %s%s%s\n\n' "${B:-}" "$PW" "${R:-}"
    say "  ${DIM:-}Hand it over the way your site hands over a password -- not by email."
    say "  It is on this screen and in this terminal's scrollback, nowhere else:"
    say "  nothing writes it to disk. They must change it at first login.${R:-}"
    return 0
  fi

  command -v pwscore >/dev/null 2>&1 \
    || say "  ${DIM:-}(libpwquality-tools not installed -- checking minlen and character classes only)${R:-}"
  while :; do
    read -rs -p "  New password: " PW; printf '\n'
    read -rs -p "  Again:        " PW2; printf '\n'
    [ "$PW" = "$PW2" ] || { bad "they do not match"; continue; }
    [ -n "$PW" ]       || { bad "empty passwords are not allowed"; continue; }
    if ! reason=$(check_policy "$PW"); then
      bad "rejected by this box's password policy: $reason"; continue
    fi
    break
  done
  unset PW2
  return 0
}
