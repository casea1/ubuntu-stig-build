#!/usr/bin/env bash
# it-ai -- control the AI Docker stack in /opt/it/docker from anywhere, without
# cd-ing into the dir or remembering compose flags. Adds a `run` shortcut for the
# on-demand `tools`-profile utilities (hfcli / openwiki / repomix), which a plain
# `up` never starts.
#
# Usage:
#   it-ai up [SERVICE]        start the default (daemon) services  (compose up -d)
#   it-ai down                stop + remove containers  (named volumes are KEPT)
#   it-ai stop [SERVICE]      stop without removing
#   it-ai restart [SERVICE]   restart (fast; does not re-read .env/compose)
#   it-ai status | ps         container status
#   it-ai logs [SERVICE]      follow logs (Ctrl-C to exit)
#   it-ai pull                pull updated images
#   it-ai oikb                start the opt-in oikb sync (compose --profile oikb up -d)
#   it-ai run TOOL [ARGS...]  run a one-off utility (auto --rm); see `it-ai tools`
#   it-ai tools               list the on-demand utilities on this node
#   it-ai help
#
# Examples:
#   it-ai up
#   it-ai run hfcli hf download ibm-granite/granite-embedding-small-english-r2 --local-dir /granite-embed
#   it-ai run openwiki openwiki <args>
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

DIR=/opt/it/docker
command -v docker >/dev/null 2>&1 || { echo "docker not installed"; exit 1; }
[ -f "$DIR/docker-compose.yaml" ] || { echo "no $DIR/docker-compose.yaml on this node (AI stack not placed here)"; exit 1; }
cd "$DIR" || exit 1

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

cmd="${1:-help}"; shift 2>/dev/null || true

case "$cmd" in
  up)        echo ">> docker compose up -d ${*:-(all default services)}"; docker compose up -d "$@" ;;
  down)      echo ">> docker compose down  (containers removed; named volumes kept)"; docker compose down ;;
  stop)      echo ">> docker compose stop ${*:-(all)}"; docker compose stop "$@" ;;
  restart)   echo ">> docker compose restart ${*:-(all)}"; docker compose restart "$@" ;;
  status|ps) docker compose ps ;;
  logs)      docker compose logs -f --tail=200 "$@" ;;
  pull)      docker compose pull ;;
  oikb)      echo ">> docker compose --profile oikb up -d"; docker compose --profile oikb up -d ;;
  tools)
    # tools-only services = those present WITH --profile tools but not by default.
    comm -13 \
      <(docker compose config --services 2>/dev/null | sort) \
      <(docker compose --profile tools config --services 2>/dev/null | sort) \
      | sed 's/^/  /'
    echo "  (run with: it-ai run <name> [args])"
    ;;
  run)
    tool="${1:-}"; shift 2>/dev/null || true
    [ -n "$tool" ] || { echo "usage: it-ai run <tool> [args]   (see: it-ai tools)"; exit 1; }
    echo ">> docker compose run --rm $tool $*"
    docker compose run --rm "$tool" "$@"
    ;;
  help|-h|--help) usage ;;
  *) echo "unknown command: $cmd"; echo; usage; exit 1 ;;
esac

# Show status after any state-changing action.
case "$cmd" in
  up|down|stop|restart|oikb) echo; docker compose ps | sed 's/^/  /' ;;
esac
