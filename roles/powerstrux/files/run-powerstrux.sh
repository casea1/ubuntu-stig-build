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
#   run-powerstrux                    run the audit now (the default)
#   run-powerstrux --quiet            no progress output; used by the schedule
#   run-powerstrux --where            print script/config/log paths and exit
#   run-powerstrux open               copy the newest report into your home and open it
#   run-powerstrux status             schedule state, last run, next run
#   run-powerstrux schedule           show the current schedule
#   run-powerstrux schedule "<spec>"  change it, e.g. "Wed *-*-* 03:00:00"
#   run-powerstrux enable | disable   turn the scheduled run on or off
#   run-powerstrux offload [...]      the weekly copy of the report to a file
#                                     share -- setup, creds, test, run, status.
#                                     `run-powerstrux offload --help` for those.
#
# A schedule change is written to BOTH the live timer and /opt/it/site.yml, so
# it survives the next ansible-pull. Change only the timer and the pull puts it
# back; that is the trap this avoids.
#
# WHY `open` COPIES THE REPORT INSTEAD OF JUST LAUNCHING A BROWSER AT IT:
# Firefox on 24.04 is a SNAP. A snap runs in its own mount namespace that
# contains the user's home and (if connected) removable media -- and does NOT
# contain /opt at all. Pointed at file:///opt/_AuditFiles/<report>.html it
# reports "File not found" for a file that is right there and readable. No
# amount of chmod fixes it; the path simply does not exist inside the sandbox.
# So the report is copied into the auditor's home, which the snap CAN see.
set -uo pipefail

PS1_SCRIPT="${POWERSTRUX_SCRIPT:-/opt/microsoft/powershell/7/Modules/ReportHTML/Initiate-PowerstruxLA.ps1}"
AUDIT_DIR="${POWERSTRUX_DIR:-/opt/_AuditFiles}"
LOG_DIR="$AUDIT_DIR/logs"
KEEP="${POWERSTRUX_KEEP:-26}"

SITE_YML="${SITE_YML:-/opt/it/site.yml}"
TIMER=/etc/systemd/system/powerstrux-audit.timer
CRON=/etc/cron.d/powerstrux-audit

# ---- report helpers --------------------------------------------------------

# Newest HTML report under the audit dir. -printf/sort beats `ls -t` here: a
# report name with a space would break the glob, and this is the one path an
# auditor uses when something has already gone wrong.
report_newest() {
  find "$AUDIT_DIR" -maxdepth 2 -type f \( -iname '*.html' -o -iname '*.htm' \) \
       -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-
}

# Who is the human here? Under sudo that is SUDO_USER, not root -- copying the
# report into /root would put it exactly where the auditor cannot reach it.
target_user() { printf '%s' "${SUDO_USER:-$(id -un)}"; }
target_home() { getent passwd "$(target_user)" | cut -d: -f6; }

# Copy one report into the auditor's home so a snap-confined browser can open
# it. 0600 in a 0700 directory: the report inventories the system and its
# handling does not relax because it moved.
stage_report() {   # $1 = report path -> prints the staged path
  local src="$1" u h dest out
  u="$(target_user)"; h="$(target_home)"
  [ -n "$h" ] && [ -d "$h" ] || { echo "no home directory for $u" >&2; return 1; }
  dest="$h/PowerStrux-Reports"
  out="$dest/$(basename "$src")"
  if [ "$(id -u)" -eq 0 ]; then
    install -d -m 0700 -o "$u" -g "$u" "$dest"  || return 1
    install -m 0600 -o "$u" -g "$u" "$src" "$out" || return 1
  else
    mkdir -p "$dest" && chmod 0700 "$dest" || return 1
    cp -f "$src" "$out" && chmod 0600 "$out"    || return 1
  fi
  printf '%s\n' "$out"
}

cmd_open() {
  local src staged
  src="$(report_newest)"
  if [ -z "$src" ]; then
    echo "No report found under $AUDIT_DIR." >&2
    echo "Run one first:  run-powerstrux" >&2
    return 1
  fi
  if [ ! -r "$src" ]; then
    echo "Cannot read $src as $(id -un)." >&2
    echo "$AUDIT_DIR is root:audit 2770 -- you need to be in the 'audit' group:" >&2
    echo "  id -nG   (should list 'audit')" >&2
    return 1
  fi
  staged="$(stage_report "$src")" || return 1
  echo "Report : $src"
  echo "Copy   : $staged"
  echo
  echo "The copy is what opens: Firefox is a snap and cannot see /opt at all,"
  echo "so opening the original reports \"File not found\" however readable it is."
  if command -v xdg-open >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    xdg-open "$staged" >/dev/null 2>&1 &
  else
    echo "No graphical session -- open it from the desktop, or read it with:"
    echo "  w3m -dump \"$staged\"   (or copy it off the box)"
  fi
}

# ---- schedule helpers ------------------------------------------------------
current_spec() {
  if [ -f "$TIMER" ]; then sed -n 's/^OnCalendar=//p' "$TIMER" | head -1
  elif [ -f "$CRON" ]; then awk '$1 !~ /^(#|SHELL|PATH|$)/ {print $1" "$2" "$3" "$4" "$5; exit}' "$CRON"
  fi
}

schedule_status() {
  local spec; spec="$(current_spec)"
  echo "PowerStrux schedule -- $(hostname)"
  echo
  if [ -f "$TIMER" ]; then
    printf '  method    : systemd timer (a run missed while powered off fires at next boot)\n'
    printf '  schedule  : %s\n' "${spec:-(none)}"
    printf '  enabled   : %s\n' "$(systemctl is-enabled powerstrux-audit.timer 2>/dev/null || echo no)"
    printf '  active    : %s\n' "$(systemctl is-active powerstrux-audit.timer 2>/dev/null || echo no)"
    local nxt; nxt=$(systemctl show powerstrux-audit.timer -p NextElapseUSecRealtime --value 2>/dev/null)
    [ -n "$nxt" ] && [ "$nxt" != "n/a" ] && printf '  next run  : %s\n' "$nxt"
    printf '  last run  : %s\n' "$(systemctl show powerstrux-audit.service -p ExecMainStartTimestamp --value 2>/dev/null || echo never)"
    printf '  last result: %s\n' "$(systemctl show powerstrux-audit.service -p Result --value 2>/dev/null || echo -)"
  elif [ -f "$CRON" ]; then
    printf '  method    : cron (a run missed while powered off is LOST)\n'
    printf '  schedule  : %s\n' "${spec:-(none)}"
    printf '  file      : %s\n' "$CRON"
  else
    printf '  NOT SCHEDULED. Enable with: sudo run-powerstrux enable\n'
  fi
  echo
  local last; last=$(ls -1t "$LOG_DIR"/powerstrux-*.log 2>/dev/null | head -1)
  [ -n "$last" ] && printf '  last log  : %s (%s)\n' "$(basename "$last")" "$(date -r "$last" '+%Y-%m-%d %H:%M')" \
                 || printf '  last log  : none in %s\n' "$LOG_DIR"
}

set_schedule() {
  local spec="$1"
  # systemd-analyze is the authority on whether a calendar spec is valid AND
  # shows when it would next fire -- better than accepting it and finding out
  # next week that it never ran.
  if command -v systemd-analyze >/dev/null 2>&1; then
    if ! systemd-analyze calendar "$spec" >/dev/null 2>&1; then
      echo "Not a valid systemd calendar spec: '$spec'" >&2
      echo "Examples:  \"Wed *-*-* 03:00:00\"   \"daily\"   \"Mon,Thu 02:30\"" >&2
      echo "Check one with:  systemd-analyze calendar \"<spec>\"" >&2
      return 2
    fi
  fi

  [ -f "$TIMER" ] || { echo "No timer at $TIMER -- is the schedule enabled?" >&2; return 1; }
  cp -a "$TIMER" "$TIMER.bak-$(date +%Y%m%d-%H%M%S)"
  sed -i "s|^OnCalendar=.*|OnCalendar=$spec|" "$TIMER"
  systemctl daemon-reload
  systemctl restart powerstrux-audit.timer 2>/dev/null

  # And persist it, or the next ansible-pull rewrites the unit from site.yml
  # and silently reverts this.
  if [ -f "$SITE_YML" ]; then
    cp -a "$SITE_YML" "$SITE_YML.bak-$(date +%Y%m%d-%H%M%S)"
    if grep -q '^powerstrux_oncalendar:' "$SITE_YML"; then
      sed -i "s|^powerstrux_oncalendar:.*|powerstrux_oncalendar: \"$spec\"|" "$SITE_YML"
    else
      printf '\n# Set by run-powerstrux on %s\npowerstrux_oncalendar: "%s"\n' \
        "$(date -Is)" "$spec" >> "$SITE_YML"
    fi
    echo "Updated $SITE_YML so the next ansible-pull keeps this schedule."
  else
    echo "WARNING: $SITE_YML not found -- the next ansible-pull will revert this." >&2
  fi

  echo "Schedule set to: $spec"
  command -v systemd-analyze >/dev/null 2>&1 && \
    systemd-analyze calendar "$spec" | sed -n 's/^ *Next elapse: */  next run  : /p'
}

QUIET=0
# Subcommands. `run` stays the DEFAULT so the desktop icon keeps working.
case "${1:-}" in
  # The offload is its own script: it is the half that talks to a file share
  # and it is long enough that mixing it in here would bury the launcher. It
  # self-elevates, so no sudo is forced on `offload --help`.
  offload)
    shift
    OFFLOAD="$AUDIT_DIR/powerstrux-offload.sh"
    [ -x "$OFFLOAD" ] || {
      echo "Offload not installed at $OFFLOAD -- run an ansible-pull." >&2; exit 1; }
    exec "$OFFLOAD" "$@" ;;
  open|report) cmd_open; exit $? ;;
  status)   LOG_DIR="$AUDIT_DIR/logs"; schedule_status; exit 0 ;;
  schedule)
    LOG_DIR="$AUDIT_DIR/logs"
    if [ -z "${2:-}" ]; then schedule_status; exit 0; fi
    [ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"
    set_schedule "$2"; exit $? ;;
  enable|disable)
    [ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"
    if [ "$1" = enable ]; then
      systemctl enable --now powerstrux-audit.timer && echo "Scheduled audit ENABLED."
    else
      systemctl disable --now powerstrux-audit.timer && echo "Scheduled audit DISABLED."
      echo "Note: an ansible-pull re-enables it unless you also set"
      echo "  powerstrux_schedule_enabled: false   in $SITE_YML"
    fi
    exit $? ;;
  run) shift ;;
esac

for a in "$@"; do
  case "$a" in
    --quiet) QUIET=1 ;;
    --where)
      echo "script : $PS1_SCRIPT"
      echo "config : $(dirname "$PS1_SCRIPT")/PowerStruxLAConfig.txt"
      echo "logs   : $LOG_DIR"
      echo "reports: wherever PowerStruxLAConfig.txt puts them (see that file)"
      exit 0 ;;
    -h|--help) awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit 0 ;;
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

  # Put a copy where the auditor's browser can actually open it. Firefox is a
  # snap and its sandbox contains no /opt, so the original is unopenable from
  # the desktop no matter what its permissions say.
  newest="$(report_newest)"
  if [ -n "$newest" ] && [ "$(target_user)" != root ]; then
    if staged="$(stage_report "$newest")"; then
      say
      say "Open this copy (the original is under /opt, which the browser cannot see):"
      say "  $staged"
      say "Or any time:  run-powerstrux open"
    fi
  fi
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
