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
#   run-powerstrux install            install PowerStrux from a staged vendor
#                                     zip: unpack it, put the module where
#                                     PowerShell looks, and set the reporting
#                                     window + report directory in its config.
#                                     --zip PATH, --days N, --dir PATH,
#                                     --force-config (replace a tuned config)
#   run-powerstrux config             set just the window/directory again:
#                                     --days N, --dir PATH
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

# What `install` / `config` write into PowerStruxLAConfig.txt.
#
# The KEY NAMES are a list of candidates, not one guess, and a key is only ever
# edited where it ALREADY EXISTS in the vendor's file. A name this script does
# not know produces "not found" and a printout of the real keys -- never an
# appended line the tool ignores, and never a mangled config that an assessor
# reads the output of months later. Add the right name here (or to
# powerstrux_days_keys / powerstrux_dir_keys in group_vars) if a release
# renames one.
POWERSTRUX_DAYS="${POWERSTRUX_DAYS:-8}"
POWERSTRUX_DAYS_KEYS="${POWERSTRUX_DAYS_KEYS:-EventLogDays LogDays DaysToReport ReportDays NumberOfDays Days}"
POWERSTRUX_DIR_KEYS="${POWERSTRUX_DIR_KEYS:-ReportPath ReportDirectory OutputPath OutputDirectory ReportLocation SavePath}"

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

# ---------------------------------------------------------------------------
# INSTALLING PowerStrux.
#
# The vendor ships a zip. Everything about unpacking it is mechanical and was
# being done by hand on every box: unzip, find the module, move it under
# PowerShell's Modules directory, then set two values in the config. Four
# manual steps, done from memory, on a tool an assessor reads the output of.
#
# The zip itself is NOT in this repo and never will be -- it is vendor
# software. Stage it and run this.
#
# What is deliberately NOT overwritten: an existing PowerStruxLAConfig.txt.
# It is hand-tuned per site and that is the whole reason the role never
# touches it. `install` keeps it and says so; `--force-config` replaces it.
# ---------------------------------------------------------------------------
INSTALLER_DIR="${POWERSTRUX_INSTALLER_DIR:-/opt/it/installers}"
MODULE_DIR="$(dirname "$PS1_SCRIPT")"        # .../Modules/ReportHTML
MODULES_ROOT="$(dirname "$MODULE_DIR")"      # .../Modules
CONFIG="$MODULE_DIR/PowerStruxLAConfig.txt"

isay()  { printf '%s\n' "$*"; }
iok()   { printf '  OK   %s\n' "$*"; }
iwarn() { printf '  WARN %s\n' "$*"; }
ibad()  { printf '  FAIL %s\n' "$*" >&2; }
idie()  { printf 'FAIL %s\n' "$*" >&2; exit 1; }

find_zip() {   # -> path of the newest PowerStrux zip we can see
  local d f
  for d in "$INSTALLER_DIR" /media/*/* /media/* /run/media/*/* /mnt/*; do
    [ -d "$d" ] || continue
    f=$(find "$d" -maxdepth 2 -type f -iname '*powerstrux*.zip' 2>/dev/null \
          | sort | tail -1)
    [ -n "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

unzip_to() {   # $1 = zip, $2 = destination directory
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$1" -d "$2"
  else
    # python3 is on every box; unzip is not guaranteed, and failing at this
    # point over a missing archiver would be a silly place to stop.
    python3 -m zipfile -e "$1" "$2"
  fi
}

# Set one KEY = VALUE in the vendor config, in place, WITHOUT inventing a key.
# It edits a key only where that key already exists -- so a wrong guess about
# the vendor's naming produces a clear "not found", never a silently appended
# line the tool ignores or a corrupted config an assessor later reads.
cfg_set() {   # $1 = key, $2 = value  -> 0 changed/already, 1 key absent
  local k="$1" v="$2" cur
  grep -qiE "^[[:space:]]*$k[[:space:]]*=" "$CONFIG" 2>/dev/null || return 1
  cur=$(sed -nE "s/^[[:space:]]*$k[[:space:]]*=[[:space:]]*//Ip" "$CONFIG" | tail -1)
  cur="${cur%"${cur##*[![:space:]]}"}"
  if [ "$cur" = "$v" ]; then
    iok "$k already $v"
    return 0
  fi
  sed -i -E "s|^([[:space:]]*$k[[:space:]]*=[[:space:]]*).*$|\1$v|I" "$CONFIG"
  iok "$k: ${cur:-<empty>} -> $v"
  return 0
}

cmd_config() {
  local days="" dir="" rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --days) days="${2:?--days needs a number}"; shift 2 ;;
      --dir)  dir="${2:?--dir needs a path}"; shift 2 ;;
      # Naming the key outright, for a release whose key names this script does
      # not know. A flag rather than an environment variable on purpose: the
      # command self-elevates with sudo, and sudo drops the environment (trap
      # 31), so `POWERSTRUX_DIR_KEYS=x sudo it-powerstrux` silently would not
      # take -- the same trap that ate LD_LIBRARY_PATH for the Libero installer.
      --days-key) POWERSTRUX_DAYS_KEYS="${2:?--days-key needs a name}"; shift 2 ;;
      --dir-key)  POWERSTRUX_DIR_KEYS="${2:?--dir-key needs a name}"; shift 2 ;;
      *) idie "usage: it-powerstrux config [--days N] [--dir PATH] [--days-key NAME] [--dir-key NAME]" ;;
    esac
  done
  [ -r "$CONFIG" ] || idie "no config at $CONFIG -- run: sudo it-powerstrux install"
  days="${days:-$POWERSTRUX_DAYS}"
  dir="${dir:-$AUDIT_DIR}"

  cp -p "$CONFIG" "$CONFIG.bak-$(date +%Y%m%d%H%M%S)"
  isay "PowerStrux configuration ($CONFIG)"

  local k hit=0
  for k in $POWERSTRUX_DAYS_KEYS; do
    cfg_set "$k" "$days" && { hit=1; break; }
  done
  [ "$hit" -eq 1 ] || { iwarn "no reporting-window key found (tried: $POWERSTRUX_DAYS_KEYS)"; rc=1; }

  hit=0
  for k in $POWERSTRUX_DIR_KEYS; do
    cfg_set "$k" "$dir" && { hit=1; break; }
  done
  [ "$hit" -eq 1 ] || { iwarn "no report-directory key found (tried: $POWERSTRUX_DIR_KEYS)"; rc=1; }

  if [ "$rc" -ne 0 ]; then
    isay ""
    iwarn "The vendor's key names in this release are not ones this script knows."
    isay  "  Nothing was guessed and nothing was appended -- the config is unchanged"
    isay  "  apart from the keys reported above. The settings it carries now:"
    grep -nE '^[[:space:]]*[A-Za-z].*=' "$CONFIG" | sed 's/^/      /'
    isay  "  Set the right names in POWERSTRUX_DAYS_KEYS / POWERSTRUX_DIR_KEYS"
    isay  "  (powerstrux_days_keys / powerstrux_dir_keys in group_vars) and re-run."
  fi
  return "$rc"
}

cmd_install() {
  local zip="" force_config=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --zip)          zip="${2:?--zip needs a path}"; shift 2 ;;
      --force-config) force_config=1; shift ;;
      --days)         POWERSTRUX_DAYS="${2:?--days needs a number}"; shift 2 ;;
      --dir)          AUDIT_DIR="${2:?--dir needs a path}"; shift 2 ;;
      --days-key)     POWERSTRUX_DAYS_KEYS="${2:?--days-key needs a name}"; shift 2 ;;
      --dir-key)      POWERSTRUX_DIR_KEYS="${2:?--dir-key needs a name}"; shift 2 ;;
      *) idie "usage: it-powerstrux install [--zip PATH] [--days N] [--dir PATH] [--days-key NAME] [--dir-key NAME] [--force-config]" ;;
    esac
  done

  isay "Installing PowerStrux"

  command -v pwsh >/dev/null 2>&1 \
    || idie "PowerShell (pwsh) is not installed. It comes from base_packages -- run: sudo it-pull full"
  [ -d "$MODULES_ROOT" ] \
    || idie "no PowerShell Modules directory at $MODULES_ROOT -- is pwsh 7 installed?"

  if [ -z "$zip" ]; then
    zip="$(find_zip)" || idie \
"no PowerStrux zip found.
Looked in $INSTALLER_DIR and on attached media for *powerstrux*.zip
Point at one:  sudo it-powerstrux install --zip /path/to/PowerStrux.zip"
  fi
  [ -r "$zip" ] || idie "cannot read $zip"
  iok "archive $zip"

  local tmp
  tmp="$(mktemp -d /tmp/powerstrux-install.XXXXXX)" || idie "mktemp failed"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  unzip_to "$zip" "$tmp" || idie "could not unpack $zip"

  # Find the module by its ENTRY POINT rather than by an expected folder name.
  # The zip's top level has been a bare ReportHTML/, a versioned folder, and a
  # wrapper containing both -- and the thing that matters is the same in all
  # three.
  local src
  src="$(find "$tmp" -type f -name 'Initiate-PowerstruxLA.ps1' 2>/dev/null | sort | head -1)"
  [ -n "$src" ] || idie \
"Initiate-PowerstruxLA.ps1 is not in that archive.
Unpacked it to a temporary directory and it contains:
$(find "$tmp" -maxdepth 2 | sed 's/^/    /' | head -20)"
  src="$(dirname "$src")"
  iok "module found at ${src#"$tmp"/}"

  # Keep the existing config: it is hand-tuned per site, which is exactly why
  # the pull never writes it either.
  local keep=""
  if [ -r "$CONFIG" ] && [ "$force_config" -eq 0 ]; then
    keep="$(mktemp /tmp/psconfig.XXXXXX)"
    cp -p "$CONFIG" "$keep"
    iok "keeping the existing PowerStruxLAConfig.txt (--force-config replaces it)"
  fi

  if [ -d "$MODULE_DIR" ]; then
    local bak="$MODULE_DIR.bak-$(date +%Y%m%d%H%M%S)"
    mv "$MODULE_DIR" "$bak" || idie "could not move the existing module aside"
    iwarn "previous install moved to $bak"
  fi

  install -d -m 0755 -o root -g root "$MODULE_DIR"
  cp -a "$src/." "$MODULE_DIR/" || idie "could not copy the module into $MODULE_DIR"

  # root-owned, world-readable, nothing writable: PowerShell only needs to READ
  # a module, and the STIG's umask 077 would otherwise leave it root-only after
  # a sudo install -- the same trap the FPGA trees hit.
  chown -R root:root "$MODULE_DIR"
  find "$MODULE_DIR" -type d -exec chmod 0755 {} +
  find "$MODULE_DIR" -type f -exec chmod 0644 {} +
  iok "installed to $MODULE_DIR (root:root, world-readable, nothing writable)"

  [ -n "$keep" ] && { cp -p "$keep" "$CONFIG"; rm -f "$keep"; }
  [ -r "$PS1_SCRIPT" ] || idie "entry point still missing at $PS1_SCRIPT after install"

  isay ""
  if [ -r "$CONFIG" ]; then
    cmd_config || true
  else
    iwarn "no PowerStruxLAConfig.txt in that archive -- nothing to configure"
  fi

  isay ""
  isay "Next:"
  isay "  sudo it-pull scripts     # desktop icon + the weekly schedule"
  isay "  sudo it-powerstrux       # run it once and check the report"
  isay ""
  isay "  The pull skipped those until now because the tool was not installed."
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
  install)
    shift
    [ "$(id -u)" -eq 0 ] || exec sudo -- "$0" install "$@"
    cmd_install "$@"; exit $? ;;
  config)
    shift
    [ "$(id -u)" -eq 0 ] || exec sudo -- "$0" config "$@"
    cmd_config "$@"; exit $? ;;
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
