#!/usr/bin/env bash
# AI model volumes + vLLM/service endpoint status.
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"
command -v docker >/dev/null 2>&1 || { echo "docker not installed"; exit 0; }

echo "== MODEL VOLUMES (config.json present?) =="
vols=$(docker volume ls -q 2>/dev/null | grep -E 'vllm|granite|encodings')
[ -z "$vols" ] && echo "  (none created yet)"
for v in $vols; do
  mp=$(docker volume inspect -f '{{.Mountpoint}}' "$v" 2>/dev/null)
  if [ -n "$mp" ] && test -f "$mp/config.json"; then st="POPULATED"; else st="EMPTY"; fi
  printf '  %-30s %s\n' "$v" "$st"
done

echo
echo "== SERVICE ENDPOINTS (local) =="
ep(){ # label url
  printf '  %-16s ' "$1"
  m=$(curl -s --max-time 3 "$2" 2>/dev/null | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -n "$m" ]; then echo "OK ($m)"; else echo "-- no response (not on this node, or down)"; fi
}
ep "chat   :8000" http://localhost:8000/v1/models
ep "chat-alt:8001" http://localhost:8001/v1/models
ep "embed  :8002" http://localhost:8002/v1/models
ep "vision :8003" http://localhost:8003/v1/models
printf '  %-16s ' "docling:5001"; r=$(curl -s --max-time 3 http://localhost:5001/health 2>/dev/null); [ -n "$r" ] && echo "OK ($r)" || echo "-- no response"
printf '  %-16s ' "tika   :9998"; c=$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' http://localhost:9998/tika 2>/dev/null); [ "$c" = "200" ] && echo "OK (HTTP 200)" || echo "-- HTTP ${c:-000}"
