#!/usr/bin/env bash
# Master status: runs host + containers + models + LUKS checks.
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"
D=$(cd "$(dirname "$0")" && pwd)
echo "################ IT STATUS  $(hostname)  $(date '+%Y-%m-%d %H:%M') ################"
for s in status-host status-docker status-models status-luks; do
  echo
  if [ -x "$D/$s.sh" ]; then "$D/$s.sh"; else echo "(missing $s.sh)"; fi
done
echo
echo "################ end ################"
