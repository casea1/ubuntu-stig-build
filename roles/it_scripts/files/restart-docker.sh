#!/usr/bin/env bash
# it-restart -- restart the AI-stack containers.
# Default: `docker compose restart` (fast, keeps containers, re-reads nothing).
# --up   : `docker compose up -d` instead, so edits to .env / compose take effect.
# A service name limits the action to that one container (e.g. it-restart oikb).
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"
DIR=/opt/it/docker
command -v docker >/dev/null 2>&1 || { echo "docker not installed"; exit 1; }
[ -f "$DIR/docker-compose.yaml" ] || { echo "no $DIR/docker-compose.yaml on this node"; exit 1; }

MODE=restart
case "${1:-}" in
  --up) MODE=up; shift ;;
esac
SVC="${1:-}"   # optional single service

cd "$DIR" || exit 1
if [ "$MODE" = up ]; then
  echo ">> docker compose up -d ${SVC:-(all)}  (applies .env / compose changes)"
  docker compose up -d $SVC
else
  echo ">> docker compose restart ${SVC:-(all)}"
  docker compose restart $SVC
fi

echo
docker compose ps | sed 's/^/  /'
