#!/usr/bin/env bash
# it-docker -- what this AI node is actually running, and the levers for it.
#
#   it-docker                  every container, grouped by compose project
#   it-docker ps [--all]       the same; --all includes stopped ones
#   it-docker check            the faults that bite here: not-running, unhealthy,
#                              restart-looping, no restart policy, LAN-published
#                              ports, disk
#   it-docker ports            every published port, and what that means for ufw
#   it-docker logs NAME [N]    last N lines from one container (default 60)
#   it-docker restart NAME | --project P | --all
#   it-docker stop NAME | start NAME
#   it-docker compose          every compose file on this box and where it came from
#   it-docker config [P]       validate compose files (docker compose config -q)
#   it-docker df               disk used by images, containers and volumes
#   it-docker top              live CPU and memory per container
#
# PROJECTS ARE DISCOVERED FROM THE ENGINE, NOT FROM A LIST. Every container
# `docker compose` starts carries com.docker.compose.project and
# .project.working_dir, so a stack added tomorrow shows up here with nothing to
# edit -- and a container started by hand, outside any compose file, shows up
# too instead of being invisible. /opt/stacks is folded in afterwards so a stack
# that is DEFINED but not running is still listed. The old version walked
# /opt/stacks/*/compose.yaml and saw only what that directory happened to hold.
#
# READ-ONLY BY DEFAULT. Only restart/stop/start touch a container, and each one
# names what it is about to act on. Nothing here ever rewrites a compose file --
# that is ai_compose's job and an on-box edit is lost on the next pull anyway
# (see the role's gotchas). Environment values are never printed: a container's
# env is where pgvector's password lives.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

STACKS="${IT_DOCKER_STACKS:-/opt/stacks}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; R=$'\033[0m'
else B=""; DIM=""; GRN=""; YEL=""; RED=""; R=""; fi
say()   { printf '%s\n' "$*"; }
head2() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }
ok()    { printf '  %sOK%s    %s\n' "$GRN" "$R" "$*"; }
warn()  { printf '  %sWARN%s  %s\n' "$YEL" "$R" "$*"; }
bad()   { printf '  %sFAIL%s  %s\n' "$RED" "$R" "$*"; }
note()  { printf '        %s%s%s\n' "$DIM" "$*" "$R"; }
die()   { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }
case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac

command -v docker >/dev/null 2>&1 || die "docker is not installed on this box."
docker info >/dev/null 2>&1 || die "the docker engine is not responding. Try: systemctl status docker"

L_PROJ='com.docker.compose.project'
L_WDIR='com.docker.compose.project.working_dir'
L_SVC='com.docker.compose.service'
L_FILE='com.docker.compose.project.config_files'

# ---- discovery ------------------------------------------------------------
# Containers first (that is the point), then the stack directory, so nothing is
# missed either way round.
projects() {
  { docker ps -a --format "{{.Label \"$L_PROJ\"}}" 2>/dev/null
    for d in "$STACKS"/*/; do
      [ -f "${d}compose.yaml" ] || [ -f "${d}compose.yml" ] || continue
      basename "${d%/}"
    done
  } | grep -v '^$' | sort -u
}
loose_containers() {   # running or not, belonging to no compose project
  docker ps -a --format "{{.Label \"$L_PROJ\"}}|{{.Names}}" 2>/dev/null |
    awk -F'|' '$1 == "" { print $2 }'
}
project_dir() {   # $1 = project -> its working dir, from a container or the stack tree
  local d
  d="$(docker ps -a --format "{{.Label \"$L_PROJ\"}}|{{.Label \"$L_WDIR\"}}" 2>/dev/null |
       awk -F'|' -v p="$1" '$1 == p && $2 != "" { print $2; exit }')"
  [ -n "$d" ] && { printf '%s' "$d"; return 0; }
  [ -d "$STACKS/$1" ] && printf '%s' "$STACKS/$1"
}
project_containers() {   # $1 = project
  docker ps -a --format "{{.Label \"$L_PROJ\"}}|{{.Names}}" 2>/dev/null |
    awk -F'|' -v p="$1" '$1 == p { print $2 }'
}
container_project() { docker inspect -f "{{index .Config.Labels \"$L_PROJ\"}}" "$1" 2>/dev/null; }

row() {   # $1 = container name
  local st hs rp img
  st="$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null)"
  hs="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$1" 2>/dev/null)"
  rp="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$1" 2>/dev/null)"
  img="$(docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null)"
  printf '    %-26s %-10s %-10s %-18s %s\n' \
    "$1" "$st" "${hs:--}" "restart=${rp:-no}" "$img"
}

# ---- commands -------------------------------------------------------------
cmd_ps() {
  local all=0 p c n
  case "${1:-}" in --all|-a) all=1 ;; esac
  head2 "Containers by compose project"
  printf '    %-26s %-10s %-10s %-18s %s\n' NAME STATE HEALTH POLICY IMAGE
  for p in $(projects); do
    say ""
    printf '  %s%s%s  %s%s%s\n' "$B" "$p" "$R" "$DIM" "$(project_dir "$p")" "$R"
    c="$(project_containers "$p")"
    if [ -z "$c" ]; then
      note "defined, nothing created -- a run-and-exit tool, or a profiles: guard"
      continue
    fi
    for n in $c; do
      [ "$all" = 1 ] || [ "$(docker inspect -f '{{.State.Running}}' "$n" 2>/dev/null)" = true ] || continue
      row "$n"
    done
  done
  c="$(loose_containers)"
  if [ -n "$c" ]; then
    say ""
    printf '  %s(no compose project)%s\n' "$B" "$R"
    note "started by hand, so nothing in this repo recreates them after a wipe"
    for n in $c; do row "$n"; done
  fi
  say ""
}

cmd_check() {
  local rc=0 sect n st hs rp pub
  head2 "Health"
  for n in $(docker ps -a --format '{{.Names}}'); do
    st="$(docker inspect -f '{{.State.Status}}' "$n" 2>/dev/null)"
    hs="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$n" 2>/dev/null)"
    case "$st" in
      running)
        case "$hs" in
          unhealthy) bad "$n is running but UNHEALTHY"; rc=1 ;;
          *) : ;;
        esac ;;
      restarting) bad "$n is RESTARTING -- a crash loop, check: it-docker logs $n"; rc=1 ;;
      exited)
        # A run-and-exit tool exiting 0 is correct; anything else is not.
        if [ "$(docker inspect -f '{{.State.ExitCode}}' "$n" 2>/dev/null)" != 0 ]; then
          bad "$n exited $(docker inspect -f '{{.State.ExitCode}}' "$n" 2>/dev/null)"; rc=1
        fi ;;
    esac
  done
  sect="$rc"
  [ "$sect" = 0 ] && ok "every container is running or exited cleanly"

  head2 "Restart policy"
  # A container with no policy does not come back after a reboot, and nobody
  # finds out until the reboot. This has already happened here to docling.
  sect=0
  for n in $(docker ps --format '{{.Names}}'); do
    rp="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$n" 2>/dev/null)"
    case "$rp" in
      ''|no) bad "$n has NO restart policy -- it will not come back after a reboot"; rc=1; sect=1 ;;
    esac
  done
  [ "$sect" = 0 ] && ok "every running container restarts by itself"

  head2 "Published ports"
  pub="$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E '0\.0\.0\.0|\[::\]' || true)"
  if [ -n "$pub" ]; then
    warn "these ports are on the LAN and ufw CANNOT filter them:"
    printf '%s\n' "$pub" | sed 's/^/          /'
    note "published ports are DNAT'd before ufw's INPUT chain. DOCKER-USER is"
    note "the only place a rule would apply, and it is empty. See it-docker ports."
  else
    ok "nothing is published to all interfaces"
  fi

  head2 "Disk"
  docker system df 2>/dev/null | sed 's/^/  /'
  say ""
  return "$rc"
}

cmd_ports() {
  head2 "Published ports"
  note "Anything bound to 0.0.0.0 is reachable from the LAN regardless of ufw:"
  note "Docker DNATs published ports before ufw's INPUT chain sees them."
  say ""
  printf '  %-26s %s\n' CONTAINER PORTS
  docker ps --format '{{.Names}}|{{.Ports}}' |
    awk -F'|' '$2 != "" { printf "  %-26s %s\n", $1, $2 }'
  head2 "DOCKER-USER chain"
  if iptables -S DOCKER-USER 2>/dev/null | grep -qv '^-N DOCKER-USER$'; then
    iptables -S DOCKER-USER 2>/dev/null | sed 's/^/  /'
  else
    warn "empty -- nothing filters published ports on this box"
  fi
  say ""
}

cmd_logs() {
  local n="${1:-}" c="${2:-60}"
  [ -n "$n" ] || die "usage: it-docker logs <container> [lines]"
  docker inspect "$n" >/dev/null 2>&1 || die "no such container: $n
$(docker ps -a --format '  {{.Names}}')"
  head2 "$n -- last $c lines"
  docker logs --tail "$c" --timestamps "$n" 2>&1 | sed 's/^/  /'
  say ""
}

# Restarting is the one thing here that interrupts service, so it always says
# what it is about to touch and never widens its own scope.
cmd_restart() {
  local target="${1:-}" p d n
  case "$target" in
    --all)
      head2 "Restarting every running container"
      n="$(docker ps --format '{{.Names}}')"
      [ -n "$n" ] || die "nothing is running."
      printf '%s\n' "$n" | sed 's/^/  /'
      read -r -p "  Restart all of these? [y/N] " a
      case "$a" in y|Y) ;; *) die "  aborted." ;; esac
      # shellcheck disable=SC2086
      docker restart $n | sed 's/^/  restarted /'
      ;;
    --project)
      p="${2:-}"; [ -n "$p" ] || die "usage: it-docker restart --project <name>"
      d="$(project_dir "$p")"
      head2 "Restarting project $p"
      if [ -n "$d" ] && [ -d "$d" ]; then
        # Through compose where we can: it honours depends_on ordering, which
        # `docker restart` on a list of names does not.
        ( cd "$d" && docker compose restart ) 2>&1 | sed 's/^/  /'
      else
        n="$(project_containers "$p")"
        [ -n "$n" ] || die "no containers for project $p"
        # shellcheck disable=SC2086
        docker restart $n | sed 's/^/  restarted /'
      fi
      ;;
    '') die "usage: it-docker restart <container> | --project <name> | --all" ;;
    *)
      docker inspect "$target" >/dev/null 2>&1 || die "no such container: $target"
      docker restart "$target" | sed 's/^/  restarted /'
      ;;
  esac
  say ""
}

cmd_startstop() {   # $1 = start|stop, $2 = container
  local act="$1" n="${2:-}"
  [ -n "$n" ] || die "usage: it-docker $act <container>"
  docker inspect "$n" >/dev/null 2>&1 || die "no such container: $n"
  docker "$act" "$n" | sed "s/^/  ${act}ed /"
}

cmd_compose() {
  local p d f
  head2 "Compose files this box is using"
  note "taken from the RUNNING containers' own labels, so it is what is"
  note "deployed rather than what a directory happens to contain."
  for p in $(projects); do
    d="$(project_dir "$p")"
    f="$(docker ps -a --format "{{.Label \"$L_PROJ\"}}|{{.Label \"$L_FILE\"}}" 2>/dev/null |
         awk -F'|' -v pp="$p" '$1 == pp && $2 != "" { print $2; exit }')"
    say ""
    printf '  %s%s%s\n' "$B" "$p" "$R"
    printf '    %-12s %s\n' "dir" "${d:-(unknown)}"
    printf '    %-12s %s\n' "file" "${f:-(not labelled -- never started by compose)}"
    if [ -n "$d" ] && [ -d "$d" ]; then
      ls -1 "$d" 2>/dev/null | grep -E 'compose|\.env$|override' | sed 's/^/      /'
      [ -f "$d/compose.override.yaml" ] && \
        note "compose.override.yaml is present -- nothing in this repo manages it,"
      [ -f "$d/compose.override.yaml" ] && \
        note "which is the supported way to keep a per-box exception."
    fi
  done
  say ""
  note "To see how these differ from what the repo would deploy: it-stack-diff"
  say ""
}

cmd_config() {
  local p d rc=0
  head2 "Validating compose files"
  for p in $(projects); do
    [ -z "${1:-}" ] || [ "$1" = "$p" ] || continue
    d="$(project_dir "$p")"
    if [ -z "$d" ] || [ ! -d "$d" ]; then
      warn "$p: no directory to validate"
      continue
    fi
    if ( cd "$d" && docker compose config -q ) 2>/tmp/it-docker-cfg.$$; then
      ok "$p validates"
    else
      bad "$p does NOT validate:"
      sed 's/^/          /' "/tmp/it-docker-cfg.$$"
      rc=1
    fi
    rm -f "/tmp/it-docker-cfg.$$"
  done
  say ""
  return "$rc"
}

cmd_df()  { head2 "Docker disk usage"; docker system df -v 2>/dev/null | sed 's/^/  /'; say ""; }
cmd_top() {
  head2 "Live resource use"
  note "one snapshot; ps -o pcpu would give a lifetime average instead"
  docker stats --no-stream --format \
    'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}' 2>/dev/null | sed 's/^/  /'
  say ""
}

case "${1:-ps}" in
  ps|status|"") shift 2>/dev/null; cmd_ps "${1:-}" ;;
  check)        cmd_check ;;
  ports)        cmd_ports ;;
  logs)         shift; cmd_logs "$@" ;;
  restart)      shift; cmd_restart "$@" ;;
  start|stop)   cmd_startstop "$1" "${2:-}" ;;
  compose)      cmd_compose ;;
  config)       shift 2>/dev/null; cmd_config "${1:-}" ;;
  df)           cmd_df ;;
  top)          cmd_top ;;
  *) die "unknown command: $1
$(usage)" ;;
esac
