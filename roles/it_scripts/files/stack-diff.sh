#!/usr/bin/env bash
# it-stack-diff -- show how /opt/stacks differs from what the repo would deploy.
#
# Every file ai_compose places is a plain copy/template, so an on-box edit is
# lost on the next pull. Before that happens, this is how you find out WHAT was
# edited and get it back into version control.
#
# SAFE TO PASTE. Compose files reference secrets as ${VAR:?set in .env}; they
# never contain them. This script does not read .env at all -- it only reports
# whether one exists.
#
# Usage:
#   it-stack-diff             diff every stack against the repo
#   it-stack-diff <stack>     just one
#   it-stack-diff --full      print whole files instead of diffs
#   it-stack-diff --out FILE  write to a file as well as the screen
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

STACKS="${STACKS_DIR:-/opt/stacks}"
ONLY=""; FULL=0; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --full) FULL=1; shift ;;
    --out)  OUT="${2:?}"; shift 2 ;;
    -h|--help) awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) ONLY="$1"; shift ;;
  esac
done

# ansible-pull clones to ~/.ansible/pull/<hostname>; running under sudo that is
# root's home. Without it we can still show the files, just not what changed.
REPO="$(ls -d /root/.ansible/pull/*/roles/ai_compose/files/stacks 2>/dev/null | head -1)"

emit() {
  echo "host: $(hostname)   date: $(date -Is)"
  echo "repo copy: ${REPO:-NOT FOUND -- printing full files (run an ansible-pull to enable diffs)}"
  echo
  echo "=== stacks present ======================================================"
  for d in "$STACKS"/*/; do
    [ -d "$d" ] || continue
    local n extra=""
    n=$(basename "$d")
    [ -f "$d/compose.override.yaml" ] && extra="  +override"
    [ -f "$d/.env" ] && extra="$extra  +env(not shown)"
    ls "$d"compose.y*ml "$d"docker-compose.y*ml >/dev/null 2>&1 || extra="$extra  NO-COMPOSE-FILE"
    printf '  %-18s%s\n' "$n" "$extra"
  done
  echo

  for d in "$STACKS"/*/; do
    [ -d "$d" ] || continue
    local n f r
    n=$(basename "$d")
    [ -n "$ONLY" ] && [ "$n" != "$ONLY" ] && continue
    # Dockge writes compose.yaml, but a hand-made or pre-split stack dir may use
    # any of the other three names -- skipping them silently hides a whole stack.
    f=""
    for c in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
      [ -f "$d/$c" ] && { f="$d/$c"; break; }
    done
    if [ -z "$f" ]; then
      echo "=== $n: NO COMPOSE FILE (stale dir? $(ls -A "$d" 2>/dev/null | tr '\n' ' '))"
      echo
      continue
    fi
    r="$REPO/$n/$(basename "$f")"
    if [ "$FULL" = 0 ] && [ -n "$REPO" ] && [ -f "$r" ]; then
      if diff -q "$r" "$f" >/dev/null 2>&1; then
        echo "=== $n: UNCHANGED"
      else
        echo "=== $n: CHANGED -----------------------------------------------------"
        diff -u "$r" "$f" | sed '1,2d'
      fi
    elif [ -n "$REPO" ] && [ ! -f "$r" ]; then
      echo "=== $n: NOT IN THE REPO (full file) ---------------------------------"
      cat "$f"
    else
      echo "=== $n: full file ---------------------------------------------------"
      cat "$f"
    fi
    echo
  done

  echo "=== compose.override.yaml (never managed by the repo) ===================="
  local found=0
  for d in "$STACKS"/*/; do
    [ -f "$d/compose.override.yaml" ] || continue
    found=1
    echo "--- $(basename "$d")/compose.override.yaml"
    cat "$d/compose.override.yaml"
    echo
  done
  [ "$found" = 0 ] && echo "(none)"
}

if [ -n "$OUT" ]; then
  emit | tee "$OUT"
  chmod 0640 "$OUT" 2>/dev/null || true
  echo
  echo "Also written to $OUT"
else
  emit
fi
