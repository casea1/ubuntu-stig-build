#!/usr/bin/env bash
# it-restart -- restart the AI-stack containers. The AI stack is split into one
# Dockge stack per service under /opt/stacks/<stack>/.
# Default: `docker compose restart` (fast, keeps containers, re-reads nothing).
# --up   : `docker compose up -d` instead, so edits to .env / compose take effect.
# A STACK name limits the action to that one stack (e.g. it-restart oikb).
# (This is a thin convenience wrapper; `it-ai restart|up [STACK]` does the same.)
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"
DIR=/opt/stacks
command -v docker >/dev/null 2>&1 || { echo "docker not installed"; exit 1; }
[ -d "$DIR" ] || { echo "no $DIR on this node (AI stacks not placed here)"; exit 1; }

MODE=restart
case "${1:-}" in
  --up) MODE=up; shift ;;
esac
STACK="${1:-}"   # optional single stack

stacks() { for d in "$DIR"/*/; do [ -f "${d}compose.yaml" ] && basename "$d"; done | sort; }

run_one() {
  local s="$1"
  ( cd "$DIR/$s" || return 0
    if [ "$MODE" = up ]; then docker compose up -d; else docker compose restart; fi )
}

if [ -n "$STACK" ]; then
  [ -f "$DIR/$STACK/compose.yaml" ] || { echo "no such stack: $STACK (see: it-ai stacks)"; exit 1; }
  echo ">> $MODE $STACK"; run_one "$STACK"
else
  note=""; [ "$MODE" = up ] && note="  (applies .env / compose changes)"
  echo ">> $MODE (all stacks)$note"
  for s in $(stacks); do echo "-- $s"; run_one "$s"; done
fi

echo
for s in $(stacks); do
  ( cd "$DIR/$s" && docker compose ps -q 2>/dev/null | grep -q . && { echo "  == $s"; docker compose ps | sed 's/^/    /'; } ) 2>/dev/null || true
done
