#!/usr/bin/env bash
# run-powerstrux -- run the PowerStrux LA audit and say where the report went.
#
# PowerStrux is a PowerShell tool: the work is done by Initiate-PowerstruxLA.ps1,
# which lives with the ReportHTML module rather than in /opt/_AuditFiles. This
# wrapper exists so an auditor has ONE thing to run (or double-click) and does
# not have to know that path, remember `pwsh -File`, or find the output by hand.
#
# Runs as root: PowerStrux inventories the system and a non-root run silently
# produces a thinner report rather than failing, which is worse than not running.
#
# Usage:
#   run-powerstrux            run the audit now (prompts for sudo if needed)
#   run-powerstrux --quiet    no progress output; for the scheduled run
#   run-powerstrux --where    print the script + output paths and exit
set -uo pipefail

PS1_SCRIPT="${POWERSTRUX_SCRIPT:-/opt/microsoft/powershell/7/Modules/ReportHTML/Initiate-PowerstruxLA.ps1}"
AUDIT_DIR="${POWERSTRUX_DIR:-/opt/_AuditFiles}"
LOG_DIR="$AUDIT_DIR/logs"
KEEP="${POWERSTRUX_KEEP:-26}"

QUIET=0
for a in "$@"; do
  case "$a" in
    --quiet) QUIET=1 ;;
    --where)
      echo "script : $PS1_SCRIPT"
      echo "config : $(dirname "$PS1_SCRIPT")/PowerStruxLAConfig.txt"
      echo "logs   : $LOG_DIR"
      echo "reports: wherever PowerStruxLAConfig.txt puts them (see that file)"
      exit 0 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

# Re-exec under sudo AFTER parsing args, so --where and --help work unprivileged.
if [ "$(id -u)" -ne 0 ]; then
  say "PowerStrux needs administrator rights to inventory the system."
  exec sudo -- "$0" "$@"
fi

command -v pwsh >/dev/null 2>&1 || {
  echo "pwsh (PowerShell) is not installed -- base_packages installs it." >&2; exit 1; }
[ -f "$PS1_SCRIPT" ] || {
  echo "PowerStrux script not found: $PS1_SCRIPT" >&2
  echo "Set POWERSTRUX_SCRIPT=/path/to/Initiate-PowerstruxLA.ps1 if it moved." >&2
  exit 1; }

install -d -m 2770 -o root -g audit "$LOG_DIR" 2>/dev/null || mkdir -p "$LOG_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/powerstrux-$TS.log"

say "Running the PowerStrux audit on $(hostname). This takes a few minutes."
say "Log: $LOG"
say

start=$(date +%s)
# -NoProfile so an operator's PowerShell profile cannot change what the audit
# does; the report has to be reproducible.
pwsh -NoProfile -NonInteractive -File "$PS1_SCRIPT" 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
elapsed=$(( $(date +%s) - start ))

chmod 0640 "$LOG" 2>/dev/null || true
# Keep the newest N logs; the reports themselves are managed by PowerStrux.
ls -1t "$LOG_DIR"/powerstrux-*.log 2>/dev/null | tail -n +$((KEEP + 1)) \
  | while read -r old; do rm -f "$old"; done

say
if [ "$rc" -eq 0 ]; then
  say "AUDIT COMPLETE (${elapsed}s)."
  say "The report location is set in PowerStruxLAConfig.txt:"
  say "  $(dirname "$PS1_SCRIPT")/PowerStruxLAConfig.txt"
  # Surface anything the run produced recently, so the auditor is not hunting.
  found=$(find / -xdev -newermt "-${elapsed} seconds" \
            \( -iname '*PowerStrux*.htm*' -o -iname '*SystemReport*.htm*' \) \
            2>/dev/null | head -5)
  [ -n "$found" ] && { say; say "Report(s) written just now:"; printf '  %s\n' $found; }
else
  echo "AUDIT FAILED (exit $rc after ${elapsed}s). See $LOG" >&2
fi

if [ "$QUIET" = 0 ] && [ -t 0 ]; then
  # Launched by double-click: the terminal closes the instant this exits, so
  # hold it open long enough to read the result.
  printf '\nPress Enter to close... '
  read -r _
fi
exit "$rc"
