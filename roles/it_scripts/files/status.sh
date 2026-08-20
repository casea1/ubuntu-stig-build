#!/usr/bin/env bash
# Master status: runs host + LUKS checks, plus the container/model checks when
# this is an AI node. The AI sub-scripts are only installed on the ai profile,
# so a missing one is expected here, not an error.
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"
D=$(cd "$(dirname "$0")" && pwd)
echo "################ IT STATUS  $(hostname)  $(date '+%Y-%m-%d %H:%M') ################"
for s in status-host status-docker status-models status-luks; do
  [ -x "$D/$s.sh" ] || continue
  echo
  "$D/$s.sh"
done
echo
echo "################ end ################"
