#!/usr/bin/env bash
# it-ai -- control the AI Docker stacks under /opt/stacks from anywhere, without
# cd-ing into each dir or remembering compose flags. The AI stack is split into
# one Dockge stack PER SERVICE (/opt/stacks/<stack>/compose.yaml); this drives
# them all at once, or one at a time by name.
#
# Usage:
#   it-ai up [STACK]          start the default (daemon) stacks   (compose up -d)
#   it-ai down [STACK]        stop + remove containers  (named volumes are KEPT)
#   it-ai stop [STACK]        stop without removing
#   it-ai restart [STACK]     restart (fast; does not re-read .env/compose)
#   it-ai status | ps         container status across all stacks
#   it-ai logs STACK          follow a stack's logs (Ctrl-C to exit)
#   it-ai pull [STACK]        pull updated images
#   it-ai stacks              list the stacks on this node
#   it-ai oikb                start the opt-in oikb sync (--profile oikb up -d)
#   it-ai model gpt-oss|granite|status   switch System 1's chat model
#   it-ai run TOOL [ARGS...]  run a one-off utility stack (auto --rm); see `it-ai tools`
#   it-ai tools               list the on-demand utility stacks on this node
#   it-ai help
#
# Examples:
#   it-ai up                              # bring every default stack up
#   it-ai up open-webui                   # just one stack
#   it-ai run hfcli hf download ibm-granite/granite-embedding-small-english-r2 --local-dir /granite-embed
#   it-ai run openwiki openwiki --init     # generate the wiki into openwiki-out
#   it-ai restart openwiki-view            # then browse it at http://<dev-ai2>:4321
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

DIR=/opt/stacks
command -v docker >/dev/null 2>&1 || { echo "docker not installed"; exit 1; }
[ -d "$DIR" ] || { echo "no $DIR on this node (AI stacks not placed here)"; exit 1; }

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; }

# All stack dirs (those holding a compose.yaml). Ordered so cross-stack deps come
# up first: the datastores (pgvector/redis) and System 2's backends (mlflow-db is
# inside the mlflow stack) before their consumers (open-webui). A numeric rank
# prefix drives the sort, then it's stripped. Unranked stacks fall in the middle.
stacks() {
  for d in "$DIR"/*/; do
    [ -f "${d}compose.yaml" ] || continue
    s="$(basename "$d")"
    case "$s" in
      pgvector|redis)     rank=10 ;;   # System 1 datastores first
      mlflow|grafana-otel) rank=20 ;;  # System 2 backends
      open-webui)         rank=90 ;;   # consumers last
      *)                  rank=50 ;;
    esac
    printf '%d %s\n' "$rank" "$s"
  done | sort -k1,1n -k2,2 | awk '{print $2}'
}

# Print the stack dir for a name, or fail.
stack_dir() {
  local s="$1"
  [ -f "$DIR/$s/compose.yaml" ] || { echo "no such stack: $s (see: it-ai stacks)" >&2; return 1; }
  echo "$DIR/$s"
}

# Run `docker compose <args>` in one stack (by name) or across all stacks.
compose_each() {
  local action="$1"; shift
  local target="${1:-}"
  if [ -n "$target" ]; then
    local d; d="$(stack_dir "$target")" || return 1
    ( cd "$d" && eval "docker compose $action" )
  else
    local s
    for s in $(stacks); do
      echo "-- $s"
      ( cd "$DIR/$s" && eval "docker compose $action" ) || true
    done
  fi
}

cmd="${1:-help}"; shift 2>/dev/null || true

case "$cmd" in
  up)        echo ">> up ${1:-(all default stacks)}";       compose_each "up -d" "${1:-}" ;;
  down)      echo ">> down ${1:-(all)}  (containers removed; named volumes kept)"; compose_each "down" "${1:-}" ;;
  stop)      echo ">> stop ${1:-(all)}";                    compose_each "stop" "${1:-}" ;;
  restart)   echo ">> restart ${1:-(all)}";                 compose_each "restart" "${1:-}" ;;
  pull)      echo ">> pull ${1:-(all)}";                    compose_each "pull --ignore-pull-failures" "${1:-}" ;;
  status|ps)
    for s in $(stacks); do
      echo "== $s"
      ( cd "$DIR/$s" && docker compose ps ) | sed 's/^/  /'
    done
    ;;
  logs)
    s="${1:-}"; [ -n "$s" ] || { echo "usage: it-ai logs <stack>   (see: it-ai stacks)"; exit 1; }
    d="$(stack_dir "$s")" || exit 1
    ( cd "$d" && docker compose logs -f --tail=200 )
    ;;
  stacks)    stacks | sed 's/^/  /' ;;
  oikb)
    d="$(stack_dir oikb)" || exit 1
    echo ">> oikb: docker compose --profile oikb up -d"
    ( cd "$d" && docker compose --profile oikb up -d )
    ;;
  model)
    [ -x "$DIR/switch-model.sh" ] || { echo "no $DIR/switch-model.sh (System 1 only)"; exit 1; }
    exec "$DIR/switch-model.sh" "$@"
    ;;
  tools)
    # Utility stacks = those whose only services sit behind the `tools` profile
    # (nothing starts on a plain `up`). Detect by an empty default service list.
    for s in $(stacks); do
      def="$(cd "$DIR/$s" && docker compose config --services 2>/dev/null)"
      all="$(cd "$DIR/$s" && docker compose --profile tools config --services 2>/dev/null)"
      if [ -z "$def" ] && [ -n "$all" ]; then echo "  $s"; fi
    done
    echo "  (run with: it-ai run <stack> [args])"
    ;;
  run)
    tool="${1:-}"; shift 2>/dev/null || true
    [ -n "$tool" ] || { echo "usage: it-ai run <stack> [args]   (see: it-ai tools)"; exit 1; }
    d="$(stack_dir "$tool")" || exit 1
    echo ">> $tool: docker compose run --rm $tool $*"
    ( cd "$d" && docker compose run --rm "$tool" "$@" )
    ;;
  help|-h|--help) usage ;;
  *) echo "unknown command: $cmd"; echo; usage; exit 1 ;;
esac

# Show status of the touched stack(s) after any state-changing action.
case "$cmd" in
  up|down|stop|restart|oikb)
    echo
    tgt="${1:-}"
    if [ -n "$tgt" ] && [ -d "$DIR/$tgt" ]; then
      ( cd "$DIR/$tgt" && docker compose ps ) | sed 's/^/  /'
    else
      for s in $(stacks); do ( cd "$DIR/$s" && docker compose ps -q | grep -q . && echo "  [$s] running" ) 2>/dev/null || true; done
    fi
    ;;
esac
