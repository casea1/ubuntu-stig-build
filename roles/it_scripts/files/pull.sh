#!/usr/bin/env bash
# it-pull -- re-run the baseline from the repo, without the curl and without
# remembering flags.
#
# A LIGHT pull is the default and is what you want for a config change or a new
# it-* script: no apt work, no image builds, no benchmark evaluation, and it
# never touches a running container. The heavy paths are one word away.
#
#   it-pull              light: config, scripts, hardening re-assert  (the default)
#   it-pull full         + packages/images + a fresh usg audit and SCAP scan
#   it-pull scripts      the it_scripts role alone -- fastest way to ship a script
#   it-pull ai           light + the Docker/compose stacks (ai nodes; see below)
#   it-pull check        Ansible --check. Changes nothing, but see the warning it
#                        prints: check mode cannot run a command, so a task that
#                        READS state gets no answer and the play can conclude the
#                        opposite of the truth. `it-pull status` is the reliable
#                        answer to "what is coming".
#   it-pull status       where this box pulls from, what it runs, and -- when it
#                        is behind -- the exact commits and files a pull brings in
#   it-pull log          follow / re-read the last run's output
#
# NEITHER `light` NOR `full` TOUCHES DOCKER. The ai-runtime and ai-gpu tags are
# skipped by both, so an AI node can take STIG, audit and script updates with
# its containers left alone. `it-pull ai` is the deliberate opt-in that
# rewrites the compose files and can recreate containers.
#
# What `light` leaves out, and why that is safe:
#   packages   -- apt installs and image builds. A package-list change needs `full`.
#   evidence   -- `usg audit` and `oscap xccdf eval`. Those run on a box's first
#                 build, on the weekly oscap-scan timer, and on `it-stig run`.
#                 (This is group_vars usg_audit_on_pull / scap_scan_on_pull, so
#                 a plain ansible-pull gets the same treatment; `full` overrides.)
#
# The repo and branch are read off the ansible-pull checkout, so a box built
# from a mirror keeps using that mirror. The DEPLOYMENT PROFILE is read from
# /etc/stig-build/profile and passed back to ansible-pull -- nothing else
# persists it, and without it group_vars would default an EMI laptop to the
# development profile and rebuild it as one. Override for one run with
#   REPO_URL=... BRANCH=... PROFILE=... it-pull
# or put REPO_URL / BRANCH in /etc/stig-build/pull.conf (plain KEY=value).
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

UNIT="stig-pull"
STATE_DIR="/var/lib/it-pull"
PROFILE_FILE="/etc/stig-build/profile"
CONF_FILE="/etc/stig-build/pull.conf"

# Last-resort default only. Every other source is preferred, because the URL
# the box is actually checked out from is the one proven to work on its network.
DEFAULT_REPO="https://git.asplab.com/ASPLAB/ubuntu-stig-build.git"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; RD=$'\033[31m'; R=$'\033[0m'
else B=""; DIM=""; G=""; Y=""; RD=""; R=""; fi

die() { printf '%s\n' "$*" >&2; exit 1; }

# Is a pull in flight? Deliberately NOT `systemctl is-active stig-pull`: the unit
# is transient and --collect frees it the moment it stops, so every query after
# that makes systemd log "Failed to open /run/systemd/transient/stig-pull.service"
# into the journal. On a box whose journal is audit evidence, a status command
# should not write errors into it. The process is the honest test anyway, and it
# also catches an ansible-pull someone started by hand.
pull_running() { pgrep -f '[a]nsible-pull' >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Where does this box pull from?
# ---------------------------------------------------------------------------
getkey() {  # $1 = key, $2 = file -> value on stdout, empty if unset
  [ -r "$2" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$2" | tail -1 | tr -d "\"'" | tr -d '\r'
}
getkey_or() { local v; v=$(getkey "$1" "$2"); [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$3"; }

CHECKOUT="/root/.ansible/pull/$(hostname -s 2>/dev/null || hostname)"
[ -d "$CHECKOUT/.git" ] || CHECKOUT=""

resolve_repo() {
  local v
  [ -n "${REPO_URL:-}" ] && { printf '%s' "$REPO_URL"; return; }         # this run
  v=$(getkey REPO_URL "$CONF_FILE");  [ -n "$v" ] && { printf '%s' "$v"; return; }   # local override
  if [ -n "$CHECKOUT" ]; then                                            # the live checkout
    v=$(git -C "$CHECKOUT" config --get remote.origin.url 2>/dev/null)
    [ -n "$v" ] && { printf '%s' "$v"; return; }
  fi
  v=$(getkey baseline_repo "$PROFILE_FILE")                              # last pull recorded it
  [ -n "$v" ] && [ "$v" != unknown ] && { printf '%s' "$v"; return; }
  printf '%s' "$DEFAULT_REPO"
}
resolve_branch() {
  local v
  [ -n "${BRANCH:-}" ] && { printf '%s' "$BRANCH"; return; }
  v=$(getkey BRANCH "$CONF_FILE"); [ -n "$v" ] && { printf '%s' "$v"; return; }
  v=$(getkey baseline_branch "$PROFILE_FILE")
  [ -n "$v" ] && [ "$v" != unknown ] && { printf '%s' "$v"; return; }
  printf 'main'
}
REPO="$(resolve_repo)"
BR="$(resolve_branch)"

# WHICH PROFILE IS THIS BOX? bootstrap.sh passes -e deployment_profile=<x> and
# nothing persists it: group_vars defaults to `development`, so an ansible-pull
# run WITHOUT that -e silently rebuilds an EMI laptop as a development
# workstation -- which turns off usb_storage_enabled, the dta carve-out and the
# camera/mic lockdown. it_scripts records the profile it was built with in
# /etc/stig-build/profile on every run, so pass that back. If it cannot be
# determined, REFUSE rather than let the default reprofile the box.
PROFILE_NAME="${PROFILE:-}"
[ -n "$PROFILE_NAME" ] || PROFILE_NAME="$(getkey deployment_profile "$PROFILE_FILE")"

# ---------------------------------------------------------------------------
# The modes. This is the whole point of the script: the skip-tags and -e
# strings live HERE, once, instead of in somebody's shell history.
# ---------------------------------------------------------------------------
NO_AI="ai-runtime,ai-gpu"

mode_args() {
  case "$1" in
    light)   printf '%s' "--skip-tags packages,$NO_AI" ;;
    full)    printf '%s' "--skip-tags $NO_AI -e usg_audit_on_pull=always -e scap_scan_on_pull=always" ;;
    scripts) printf '%s' "--tags scripts" ;;
    ai)      printf '%s' "--skip-tags packages" ;;
    check)   printf '%s' "--check --diff --skip-tags packages,$NO_AI" ;;
  esac
}
mode_desc() {
  case "$1" in
    light)   echo "no apt, no image builds, no scan, no container touched" ;;
    full)    echo "packages and images, plus a fresh usg audit and SCAP scan (still no container touched)" ;;
    scripts) echo "the it_scripts role only" ;;
    ai)      echo "${Y}INCLUDES the AI runtime -- rewrites compose files and may recreate containers${R}" ;;
    check)   echo "dry run -- reports what would change, changes nothing" ;;
  esac
}

# ---------------------------------------------------------------------------
# status / log
# ---------------------------------------------------------------------------
last_line() {
  local rc when mode
  [ -r "$STATE_DIR/last.rc" ] || { printf '%sno it-pull run recorded on this box%s' "$DIM" "$R"; return; }
  rc=$(cat "$STATE_DIR/last.rc" 2>/dev/null)
  mode=$(cat "$STATE_DIR/last.mode" 2>/dev/null || echo '?')
  when=$(date -r "$STATE_DIR/last.rc" '+%Y-%m-%d %H:%M' 2>/dev/null)
  if [ "$rc" = 0 ]; then printf '%slast run: %s (%s) OK%s' "$G" "$when" "$mode" "$R"
  else printf '%slast run: %s (%s) FAILED rc=%s -- see `it-pull log`%s' "$RD" "$when" "$mode" "$rc" "$R"; fi
}

do_status() {
  printf '%sit-pull status%s  (%s)\n\n' "$B" "$R" "$(hostname)"
  printf '  repo      : %s\n' "$REPO"
  printf '  branch    : %s\n' "$BR"
  printf '  checkout  : %s\n' "${CHECKOUT:-none yet -- the first it-pull clones it}"
  printf '  profile   : %s\n' "$(getkey_or deployment_profile "$PROFILE_FILE" unknown)"
  printf '  running   : %s\n' "$(getkey_or baseline_revision "$PROFILE_FILE" unknown)"

  if [ -n "$CHECKOUT" ]; then
    local local_sha remote_sha
    local_sha=$(git -C "$CHECKOUT" rev-parse --short HEAD 2>/dev/null)
    # Ask the server without fetching: cheap, and it cannot disturb the
    # checkout. A closed-network box just reports unreachable.
    remote_sha=$(GIT_TERMINAL_PROMPT=0 timeout 15 git -C "$CHECKOUT" ls-remote --heads origin "$BR" 2>/dev/null \
                 | awk 'NR==1{print substr($1,1,7)}')
    if [ -z "$remote_sha" ]; then
      printf '  remote    : %sunreachable%s -- %s\n' "$Y" "$R" "$REPO"
      printf '              Expected on a closed network. A pull will fail until it is reachable.\n'
    elif [ "$local_sha" = "$remote_sha" ]; then
      printf '  remote    : %sup to date (%s)%s\n' "$G" "$remote_sha" "$R"
    else
      printf '  remote    : %sbehind%s -- box %s, origin/%s %s   ->  run: it-pull\n' \
             "$Y" "$R" "$local_sha" "$BR" "$remote_sha"
      # What is actually coming. THIS is the honest answer to "what would a pull
      # change" -- Ansible check mode is not (see `it-pull check`). A fetch only
      # moves refs; it never touches the checkout's working tree, so reading
      # this cannot half-apply anything.
      if GIT_TERMINAL_PROMPT=0 timeout 30 git -C "$CHECKOUT" fetch --quiet origin "$BR" 2>/dev/null; then
        local n
        n=$(git -C "$CHECKOUT" rev-list --count HEAD..FETCH_HEAD 2>/dev/null)
        printf '\n  Incoming commits (%s):\n' "${n:-?}"
        git -C "$CHECKOUT" log --oneline --no-decorate -15 HEAD..FETCH_HEAD 2>/dev/null | sed 's/^/    /'
        [ "${n:-0}" -gt 15 ] 2>/dev/null && printf '    ... and %s more\n' "$((n-15))"
        printf '\n  Files they touch:\n'
        git -C "$CHECKOUT" diff --stat HEAD FETCH_HEAD 2>/dev/null | tail -12 | sed 's/^/    /'
      fi
    fi
  fi

  printf '\n  %s\n' "$(last_line)"
  pull_running \
    && printf '  %sA pull is running right now.%s  Follow it: it-pull log\n' "$Y" "$R"

  printf '\n  Evidence -- deliberately NOT part of a routine pull:\n'
  # is-enabled prints "not-found" AND exits non-zero, so a `|| echo` fallback
  # printed both. Capture it and normalise.
  local timer; timer=$(systemctl is-enabled oscap-scan.timer 2>/dev/null || true)
  case "${timer:-}" in ''|not-found) timer="NOT INSTALLED" ;; esac
  printf '    weekly scan : oscap-scan.timer %s\n' "$timer"
  printf '    on demand   : sudo it-stig run\n'
}

do_log() {
  if pull_running; then
    printf '%sFollowing the run in progress. Ctrl-C stops WATCHING, not the run.%s\n' "$DIM" "$R"
    journalctl -u "$UNIT" -f --no-pager -o cat
  else
    journalctl -u "$UNIT" --no-pager -o cat -n "${LOG_LINES:-200}"
  fi
}

# ---------------------------------------------------------------------------
# The run.
#
# Detached as a transient systemd unit, exactly as bootstrap.sh does it: a full
# pull can restart GDM, which kills anything launched from a GUI terminal and
# leaves the box half-configured. Detached means closing the terminal -- or
# losing the RDP session the pull just bounced -- cannot break the run.
# ---------------------------------------------------------------------------
galaxy_refresh() {
  # requirements.yml almost never changes, but when it does, ansible-pull will
  # not install the new collection for you -- the play just fails on a missing
  # module. Install it AFTER the run (the checkout is current by then) so the
  # next pull is sound, and say so rather than leaving a mystery failure.
  local req="$CHECKOUT/requirements.yml" sum old
  [ -n "$CHECKOUT" ] && [ -r "$req" ] || return 0
  sum=$(sha256sum "$req" | awk '{print $1}')
  old=$(cat "$STATE_DIR/requirements.sha" 2>/dev/null || echo "")
  [ "$sum" = "$old" ] && return 0
  printf '%srequirements.yml changed -- installing roles/collections...%s\n' "$DIM" "$R"
  if ansible-galaxy install -r "$req" >/dev/null 2>&1; then
    printf '%s' "$sum" > "$STATE_DIR/requirements.sha"
    echo "  done. If this run failed on a missing module, re-run it-pull."
  else
    printf '%s  ansible-galaxy install failed -- run it by hand: ansible-galaxy install -r %s%s\n' "$Y" "$req" "$R"
  fi
}

do_run() {
  local mode="$1" args rc runner follower
  args="$(mode_args "$mode")"

  command -v ansible-pull >/dev/null 2>&1 || die \
"ansible-pull is not installed -- this box was never bootstrapped, or ansible was removed.
  sudo apt-get install -y ansible git"

  [ -n "$PROFILE_NAME" ] || die \
"Cannot tell which profile this box was built as, so refusing to run.

/etc/stig-build/profile has no deployment_profile line. Without it ansible-pull
falls back to group_vars' default (development) and REBUILDS this box under the
wrong profile -- on an EMI laptop that turns off USB storage, the dta carve-out
and the camera/mic lockdown.

Pass it explicitly this once:   sudo PROFILE=emi it-pull
(development | ai | baseline | emi | emi-unclass)"

  pull_running && {
    echo "A pull is already running. Follow it with: it-pull log" >&2; exit 1; }

  mkdir -p "$STATE_DIR"; chmod 0750 "$STATE_DIR"
  printf '%s' "$mode" > "$STATE_DIR/last.mode"
  rm -f "$STATE_DIR/last.rc"

  printf '%s==> it-pull %s%s\n' "$B" "$mode" "$R"
  printf '    %s\n' "$(mode_desc "$mode")"
  printf '    %s  (%s)\n' "$REPO" "$BR"
  printf '    profile: %s\n' "$PROFILE_NAME"
  if [ "$mode" = check ]; then
    printf '    %sAnsible check mode does not run commands, so a task that READS state
' "$Y"
    printf '    with a command gets no answer and the play can conclude the opposite of
'
    printf '    the truth -- then stop at a safety assert. Nothing is changed either way.
'
    printf '    For "what is coming", use: it-pull status%s\n' "$R"
  fi
  echo

  local since; since=$(date '+%Y-%m-%d %H:%M:%S')
  # --wait, in the background, instead of polling `systemctl is-active` in a
  # loop. --collect frees the transient unit the instant it stops, and every
  # query after that makes systemd log "Failed to open
  # /run/systemd/transient/stig-pull.service" -- six of them, in the journal
  # that is this box's audit evidence. --wait blocks until the unit finishes
  # with no polling at all, so there is nothing to log.
  #
  # The exit code still goes to a file: `it-pull status` reads it back on a
  # later invocation, when the unit is long gone.
  systemd-run --unit="$UNIT" --collect --wait \
    /bin/sh -c "ansible-pull -U '$REPO' -C '$BR' -i localhost, local.yml \
                  -e deployment_profile='$PROFILE_NAME' $args; \
                rc=\$?; echo \$rc > '$STATE_DIR/last.rc'; exit \$rc" >/dev/null 2>&1 &
  runner=$!

  # journalctl -f never exits on its own; it is killed once the runner returns.
  journalctl -u "$UNIT" -f --no-pager -o cat --since "$since" 2>/dev/null &
  follower=$!
  wait "$runner"
  sleep 2                       # let the follower flush the closing lines
  kill "$follower" 2>/dev/null; wait "$follower" 2>/dev/null

  galaxy_refresh
  rc=$(cat "$STATE_DIR/last.rc" 2>/dev/null || echo "")
  echo
  case "$rc" in
    0)  printf '%s[OK]%s   it-pull %s finished.\n' "$G" "$R" "$mode" ;;
    "") printf '%s[?]%s    no exit code recorded -- check: it-pull log\n' "$Y" "$R" ;;
    *)  printf '%s[FAIL]%s ansible-pull exited %s. Full output: it-pull log\n' "$RD" "$R" "$rc" ;;
  esac
  [ "$mode" = light ] && [ "$rc" = 0 ] && \
    printf '%s        Packages and evidence were skipped by design -- `it-pull full` for those.%s\n' "$DIM" "$R"
  [ "$mode" = check ] && [ "$rc" != 0 ] && \
    printf '%s        A check-mode failure is not a box failure. Read the failing task: a
        probe that could not run is the usual cause, not a real fault.%s\n' "$DIM" "$R"
  return "${rc:-1}"
}

case "${1:-light}" in
  ""|light|quick)    do_run light ;;
  full)              do_run full ;;
  scripts)           do_run scripts ;;
  ai)                do_run ai ;;
  check|dry|dry-run) do_run check ;;
  status)            do_status ;;
  log|logs)          do_log ;;
  help|-h|--help)    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown: $1  (try: it-pull help)" >&2; exit 2 ;;
esac
