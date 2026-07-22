#!/usr/bin/env bash
# =============================================================================
# switch-model.sh -- swap System 1's active chat model.
# 2x 48GB (RTX 6000 Ada) can't hold gpt-oss-120B and Granite-4.1-30B at once,
# so they're alternates. This stops the running one and starts the requested one
# (they share the `chat-llm` network alias, so Open WebUI needs no change).
#
#   sudo ./switch-model.sh gpt-oss     # 120B (default)
#   sudo ./switch-model.sh granite     # Granite-4.1-30B
#   sudo ./switch-model.sh status      # show which is running
# Placed by ansible (ai_compose) in the compose dir; run from anywhere.
# =============================================================================
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

usage() { echo "usage: $(basename "$0") gpt-oss|granite|status"; exit 2; }

running() {
  if docker compose ps --status running --services 2>/dev/null | grep -qx vllm; then
    echo "gpt-oss-120b (service: vllm)"
  elif docker compose ps --status running --services 2>/dev/null | grep -qx vllm-granite; then
    echo "granite-4.1-30b (service: vllm-granite)"
  else
    echo "none"
  fi
}

case "${1:-}" in
  gpt-oss|gptoss|gpt)
    echo "Switching to gpt-oss-120b ..."
    docker compose stop vllm-granite 2>/dev/null || true
    docker compose up -d vllm
    svc=vllm ;;
  granite|granite30b|granite-30b)
    echo "Switching to granite-4.1-30b ..."
    docker compose stop vllm 2>/dev/null || true
    docker compose --profile granite up -d vllm-granite
    svc=vllm-granite ;;
  status|--status|-s)
    echo "Active chat model: $(running)"; exit 0 ;;
  *) usage ;;
esac

echo "Loading -- a 30-120B model takes a few minutes across both GPUs."
echo "Watch:  docker compose logs -f ${svc}   (ready at 'Application startup complete')"
echo "Verify: curl -s http://localhost:8000/v1/models"
