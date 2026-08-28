#!/usr/bin/env bash
# it-help -- every it-* command on THIS box, what it does, and its options.
#
# DISCOVERED, NOT LISTED. The commands are read from the symlinks actually
# present in /usr/local/sbin and their descriptions from the scripts those
# symlinks point at. So it is right for this box's profile automatically -- an
# EMI laptop shows it-vulnscan, an AI node shows it-ai, and neither shows the
# other's tooling -- and it cannot drift from the scripts the way a hand-kept
# list in this file would.
#
# Usage:
#   it-help                one line per command (the default)
#   it-help <command>      the full usage block for one command
#   it-help --all          every command's full usage block
#   it-help --paths        where the scripts and their symlinks live
set -uo pipefail

BIN_DIR="${IT_BIN_DIR:-/usr/local/sbin}"
SCRIPTS_DIR="${IT_SCRIPTS_DIR:-/opt/it/scripts}"

# The scripts are 0750 root:sudo, so an admin reads them without elevating.
# Anyone else has to, and cannot run the tools anyway.
[ -r "$SCRIPTS_DIR" ] || [ ! -d "$SCRIPTS_DIR" ] || exec sudo -- "$0" "$@"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
else B=""; DIM=""; R=""; fi

# The comment block at the top of a script IS its documentation -- that is what
# each script's own -h prints. Take it from the file rather than executing the
# command with --help: no elevation, no side effects, and it works for a command
# that is broken.
header() {  # $1 = script path -> its leading comment block, markers stripped
  awk '
    NR == 1 && /^#!/ { next }                    # shebang
    /^[[:space:]]*$/ { if (started) exit; next }
    /^[[:space:]]*(#|""")/ {
      started = 1
      sub(/^[[:space:]]*"""/, ""); sub(/^[[:space:]]*#[[:space:]]?/, "")
      print; next
    }
    started { exit }
  ' "$1"
}

# First line of that block, minus the "it-name -- " prefix the scripts use.
# The status-* helpers have no such prefix, so fall back to the whole line.
describe() {
  local first
  first=$(header "$1" | head -1)
  case "$first" in
    *" -- "*) printf '%s\n' "${first#*" -- "}" ;;
    *)        printf '%s\n' "$first" ;;
  esac
}

# Resolve a command name to the script behind it.
target_of() {
  local t; t=$(readlink -f "$BIN_DIR/$1" 2>/dev/null)
  [ -n "$t" ] && [ -r "$t" ] && { printf '%s\n' "$t"; return 0; }
  [ -r "$BIN_DIR/$1" ] && { printf '%s\n' "$BIN_DIR/$1"; return 0; }
  return 1
}

commands() { find "$BIN_DIR" -maxdepth 1 -name 'it-*' 2>/dev/null | xargs -r -n1 basename | sort -u; }

cmd_list() {
  local n=0 c t d
  printf '\n%sit-* commands on %s%s\n\n' "$B" "$(hostname)" "$R"
  for c in $(commands); do
    t=$(target_of "$c") || { printf '  %-22s %s(cannot read its script)%s\n' "$c" "$DIM" "$R"; continue; }
    d=$(describe "$t"); n=$((n + 1))
    printf '  %-22s %s\n' "$c" "${d:0:100}"
  done
  [ "$n" -eq 0 ] && { printf '  %sNone found in %s%s\n\n' "$DIM" "$BIN_DIR" "$R"; return 1; }
  printf '\n  %s%d commands. Options for one:%s  it-help <command>\n' "$DIM" "$n" "$R"
  printf '  %sEverything, in full:%s          it-help --all   %s(pipe to less)%s\n\n' "$DIM" "$R" "$DIM" "$R"
}

cmd_one() {
  local c="$1" t
  case "$c" in it-*) ;; *) c="it-$c" ;; esac
  t=$(target_of "$c") || {
    printf '\n  No such command: %s\n\n' "$1" >&2
    printf '  Available:\n' >&2
    commands | sed 's/^/    /' >&2; echo >&2
    return 1
  }
  printf '\n%s%s%s  %s(%s)%s\n\n' "$B" "$c" "$R" "$DIM" "$t" "$R"
  header "$t" | sed 's/^/  /'
  echo
}

cmd_all() {
  local c
  for c in $(commands); do cmd_one "$c"; printf '  %s%s%s\n' "$DIM" "----------------------------------------------------------------" "$R"; done
}

cmd_paths() {
  printf '\n%sWhere they live%s\n\n' "$B" "$R"
  printf '  scripts   %s\n' "$SCRIPTS_DIR"
  printf '  commands  %s/it-*  %s(symlinks into the above)%s\n\n' "$BIN_DIR" "$DIM" "$R"
  ls -l "$BIN_DIR"/it-* 2>/dev/null | sed 's/^/  /'
  echo
}

case "${1:-}" in
  "")            cmd_list ;;
  --all|-a)      cmd_all | ${PAGER:-cat} ;;
  --paths)       cmd_paths ;;
  -h|--help)     header "$0" | sed 's/^/  /' ;;
  -*)            printf 'unknown option: %s (try it-help --help)\n' "$1" >&2; exit 2 ;;
  *)             cmd_one "$1" ;;
esac
