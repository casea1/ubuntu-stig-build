#!/usr/bin/env bash
# Docker / AI-stack container status. The AI stack is split into one Dockge stack
# per service under /opt/stacks/<stack>/; this walks them all.
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"
DIR=/opt/stacks
echo "== CONTAINERS =="
if ! command -v docker >/dev/null 2>&1; then echo "  docker not installed"; exit 0; fi

stacks() { for d in "$DIR"/*/; do [ -f "${d}compose.yaml" ] && basename "$d"; done | sort; }

if [ -d "$DIR" ] && [ -n "$(stacks)" ]; then
  bad=""
  for s in $(stacks); do
    ps=$( cd "$DIR/$s" && docker compose ps 2>/dev/null )
    # Skip stacks with nothing running (profiled/on-demand), to keep it readable.
    [ "$( cd "$DIR/$s" && docker compose ps -q 2>/dev/null | wc -l )" -gt 0 ] || continue
    echo "  == $s"; echo "$ps" | sed 's/^/    /'
    b=$( cd "$DIR/$s" && docker compose ps --format '{{.Name}}  {{.Status}}' 2>/dev/null \
         | grep -iE 'restart|unhealthy|exited' )
    [ -n "$b" ] && bad="$bad$b"$'\n'
  done
  echo
  if [ -n "$bad" ]; then
    echo "  ATTENTION (not healthy):"; echo "$bad" | sed '/^$/d;s/^/    /'
  else
    echo "  All running containers up/healthy."
  fi
else
  echo "  no $DIR/<stack>/compose.yaml (AI stacks not placed here); raw docker ps:"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/  /'
fi
