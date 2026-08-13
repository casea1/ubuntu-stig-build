#!/usr/bin/env bash
# =============================================================================
# switch-model.sh -- swap System 1's active chat model.
# 2x 48GB (RTX 6000 Ada) can't hold gpt-oss-120B and Granite-4.1-30B at once,
# so they're alternates. gpt-oss and Granite are now SEPARATE Dockge stacks
# (/opt/stacks/vllm-gptoss and /opt/stacks/vllm-granite); they share the
# `chat-llm` network alias, so Open WebUI needs no change. This stops one stack
# and brings the other up.
#
#   sudo ./switch-model.sh gpt-oss     # 120B (default)
#   sudo ./switch-model.sh granite     # Granite-4.1-30B
#   sudo ./switch-model.sh status      # show which is running
# Placed by ansible (ai_compose) at /opt/stacks/switch-model.sh; run from anywhere.
# =============================================================================
set -euo pipefail
# Self-elevate: every action here (and `status`, which reads `docker compose ps`)
# needs Docker access. Without this, a non-root run silently sees no containers
# and `status` misreports "none" even while a model is serving.
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

STACKS="$(dirname "$(readlink -f "$0")")"   # /opt/stacks
GPTOSS_DIR="$STACKS/vllm-gptoss"
GRANITE_DIR="$STACKS/vllm-granite"

usage() { echo "usage: $(basename "$0") gpt-oss|granite|status"; exit 2; }

running() {
  if docker ps --filter "name=^vllm-server$" --filter "status=running" -q | grep -q .; then
    echo "gpt-oss-120b (stack: vllm-gptoss)"
  elif docker ps --filter "name=^vllm-granite$" --filter "status=running" -q | grep -q .; then
    echo "granite-4.1-30b (stack: vllm-granite)"
  else
    echo "none"
  fi
}

case "${1:-}" in
  gpt-oss|gptoss|gpt)
    echo "Switching to gpt-oss-120b ..."
    ( cd "$GRANITE_DIR" && docker compose --profile granite down ) 2>/dev/null || true
    ( cd "$GPTOSS_DIR" && docker compose up -d )
    name=vllm-server ;;
  granite|granite30b|granite-30b)
    echo "Switching to granite-4.1-30b ..."
    ( cd "$GPTOSS_DIR" && docker compose down ) 2>/dev/null || true
    ( cd "$GRANITE_DIR" && docker compose --profile granite up -d )
    name=vllm-granite ;;
  status|--status|-s)
    echo "Active chat model: $(running)"; exit 0 ;;
  *) usage ;;
esac

echo "Loading -- a 30-120B model takes a few minutes across both GPUs."
echo "Watch:  docker logs -f ${name}   (ready at 'Application startup complete')"
echo "Verify: curl -s http://localhost:8000/v1/models"
