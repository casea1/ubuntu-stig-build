#!/usr/bin/env bash
# Master status: runs host + LUKS checks, plus the container/model checks when
# this is an AI node. The AI sub-scripts are only installed on the ai profile,
# so a missing one is expected here, not an error.
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

# RESOLVE THE SYMLINK. `it-status` is a symlink in /usr/local/sbin pointing at
# /opt/it/scripts/status.sh, and bash sets $0 to the path used to invoke, not
# the target -- so `dirname "$0"` was /usr/local/sbin, where none of the
# sub-scripts live. Every one of them was skipped by the -x test below and
# `it-status` printed its two banners with nothing between them, on every
# profile. It looked like a box with nothing to report rather than a broken
# command, which is why it survived.
D=$(dirname "$(readlink -f "$0")")

echo "################ IT STATUS  $(hostname)  $(date '+%Y-%m-%d %H:%M') ################"
ran=0
for s in status-host status-docker status-models status-luks; do
  [ -x "$D/$s.sh" ] || continue
  echo
  "$D/$s.sh"
  ran=$((ran + 1))
done

# A silent empty report is what hid the bug above. If nothing ran at all, the
# sub-scripts are not where this expects them -- say so instead of implying
# there is nothing to say.
if [ "$ran" -eq 0 ]; then
  echo
  echo "  No status sections found in $D."
  echo "  it-status runs the status-*.sh scripts from the directory it lives in;"
  echo "  none are there. Re-ship them with:  sudo it-pull scripts"
  echo
  echo "################ end ################"
  exit 1
fi

echo
echo "################ end ################"
