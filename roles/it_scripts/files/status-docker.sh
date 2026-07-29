#!/usr/bin/env bash
# Docker / AI-stack container status.
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"
DIR=/opt/it/docker
echo "== CONTAINERS =="
if ! command -v docker >/dev/null 2>&1; then echo "  docker not installed"; exit 0; fi
if [ -f "$DIR/docker-compose.yaml" ]; then
  ( cd "$DIR" && docker compose ps ) | sed 's/^/  /'
  echo
  bad=$( cd "$DIR" && docker compose ps --format '{{.Name}}  {{.Status}}' 2>/dev/null \
         | grep -iE 'restart|unhealthy|exited' )
  if [ -n "$bad" ]; then
    echo "  ATTENTION (not healthy):"; echo "$bad" | sed 's/^/    /'
    echo "  (oikb restarting is expected until its API key is set.)"
  else
    echo "  All containers up/healthy."
  fi
else
  echo "  no /opt/it/docker/docker-compose.yaml (AI stack not placed here); raw docker ps:"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | sed 's/^/  /'
fi
