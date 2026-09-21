#!/usr/bin/env bash
# it-docker -- what this AI node is actually running, and the levers for it.
#
#   it-docker                  every container, grouped by compose project
#   it-docker ps [--all]       the same; --all includes stopped ones
#   it-docker check            the faults that bite here: not-running, unhealthy,
#                              restart-looping, no restart policy, LAN-published
#                              ports, disk
#   it-docker audit            DRIFT: what is RUNNING vs what the files say.
#                              A reboot does NOT apply a compose edit -- the
#                              daemon restarts the stored container and never
#                              reads compose.yaml -- so the two routinely
#                              disagree and only `compose up -d` closes it.
#                              Checks the GPU budget, restart policies, Open
#                              WebUI's live endpoints, port collisions,
#                              anonymous volumes, project/dir mismatches,
#                              literal IPs and missing ${VAR:?} guards.
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
    # NOT necessarily orphans. clamav-container is deliberately outside compose:
    # a systemd unit owns it (clamav-container.service, WantedBy=multi-user.target,
    # Restart=on-failure), so `restart=no` on the container is CORRECT -- a docker
    # policy would fight systemd for the same job. Say which ones have a unit
    # rather than implying every loose container is unmanaged.
    note "outside compose. A systemd unit may still own it -- checked below."
    for _n in $c; do
      if systemctl list-unit-files "${_n}.service" >/dev/null 2>&1 &&
         systemctl is-enabled --quiet "${_n}.service" 2>/dev/null; then
        note "  $_n: ${_n}.service is enabled -- systemd starts it at boot"
      else
        note "  $_n: no enabled systemd unit -- nothing recreates it after a wipe"
      fi
    done
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

# ---------------------------------------------------------------------------
# `audit` -- drift between what is RUNNING and what the files say.
#
# The distinction this exists for: **a reboot does not apply a compose edit.**
# The docker daemon restarts the EXISTING container from the configuration
# stored when it was created; it never reads compose.yaml -- the daemon does
# not know compose exists. Only `docker compose up -d` (or Dockge's deploy)
# recreates a container with new settings. So an edited file and a running
# container routinely disagree, a reboot faithfully restores the OLD value,
# and reading the file tells you nothing about what is serving traffic.
#
# Everything below therefore reports BOTH sides wherever both exist.
# Read-only: nothing is started, stopped or recreated.
# ---------------------------------------------------------------------------
# Pull a flag's value straight out of the container's JSON. Crude on purpose:
# the flag can live in .Args, .Config.Cmd or .Config.Entrypoint depending on
# how the image was built, and grepping the lot is more reliable than guessing.
runtime_flag() {   # $1 = container, $2 = flag name -> value
  docker inspect "$1" 2>/dev/null | grep -o -- "$2=[^\",]*" | head -1 | cut -d= -f2-
}
file_flag() {      # $1 = file, $2 = flag name -> value
  grep -ho -- "$2=[^\"' ,]*" "$1" 2>/dev/null | head -1 | cut -d= -f2-
}

cmd_audit() {
  local p d f n rt fl rc=0

  head2 "GPU budget -- running value vs the file"
  note "a reboot keeps the RUNNING value; only 'docker compose up -d' applies a file"
  local total=0 any=0
  for p in $(projects); do
    d="$(project_dir "$p")"; f=""
    [ -n "$d" ] && for c in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
      [ -f "$d/$c" ] && { f="$d/$c"; break; }
    done
    for n in $(project_containers "$p"); do
      rt="$(runtime_flag "$n" '--gpu-memory-utilization')"
      fl="$([ -n "$f" ] && file_flag "$f" '--gpu-memory-utilization')"
      [ -z "$rt" ] && [ -z "$fl" ] && continue
      any=1
      # `docker inspect` answers for a STOPPED container too, so the value above
      # is what the container was CREATED with, not proof it is holding memory.
      # Summing a stopped service's cap is how this reported a card as
      # oversubscribed while nvidia-smi showed it half empty.
      local live="no"
      [ "$(docker inspect -f '{{.State.Running}}' "$n" 2>/dev/null)" = true ] && live="yes"
      if [ -n "$rt" ] && [ -n "$fl" ] && [ "$rt" != "$fl" ]; then
        bad "$n  created=${rt}  file=${fl}  <-- NOT APPLIED (needs compose up -d)"
        rc=1
      else
        printf '    %-26s created=%-6s file=%-6s %s\n' "$n" "${rt:--}" "${fl:--}" \
          "$([ "$live" = yes ] && echo 'RUNNING' || echo '(stopped -- reserves nothing)')"
      fi
      [ "$live" = yes ] || continue
      case "$rt" in ''|*[!0-9.]*) ;; *) total="$(awk -v a="$total" -v b="$rt" 'BEGIN{print a+b}')" ;; esac
    done
  done
  if [ "$any" = 1 ]; then
    printf '    %-26s %s   %s\n' "TOTAL (running only)" "$total" \
      "$(command -v nvidia-smi >/dev/null 2>&1 && echo '<- compare with the card below' || true)"
    # Only worth warning when the CAPS are full AND the card actually is. vLLM
    # does not necessarily take its whole fraction, so the arithmetic alone has
    # already produced one false alarm here.
    local used_pct=""
    if command -v nvidia-smi >/dev/null 2>&1; then
      used_pct="$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null |
                  head -1 | awk -F', *' '{ if ($2>0) printf "%.2f", $1/$2 }')"
    fi
    if awk -v t="$total" 'BEGIN{ exit !(t+0 >= 0.95) }'; then
      if [ -n "$used_pct" ] && awk -v u="$used_pct" 'BEGIN{ exit !(u+0 < 0.85) }'; then
        note "caps sum to $total but the card is only ${used_pct} used -- vLLM is not"
        note "taking its whole fraction, so this is headroom, not oversubscription."
      else
        warn "caps sum to $total AND the card is ${used_pct:-?} used. Anything WITHOUT"
        note "a cap (docling) is working from what is left. Start order then decides"
        note "who wins after a reboot."
        rc=1
      fi
    fi
    command -v nvidia-smi >/dev/null 2>&1 &&
      nvidia-smi --query-gpu=index,memory.used,memory.total,utilization.gpu \
                 --format=csv,noheader 2>/dev/null | sed 's/^/    gpu /'
  else
    note "no GPU services on this node"
  fi

  head2 "Restart policy"
  local sect=0
  for n in $(docker ps --format '{{.Names}}'); do
    case "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$n" 2>/dev/null)" in
      ''|no) bad "$n has NO restart policy -- it will not come back after a reboot"; rc=1; sect=1 ;;
    esac
  done
  [ "$sect" = 0 ] && ok "every running container restarts by itself"

  head2 "Open WebUI -- the endpoints it is ACTUALLY using"
  if docker inspect open-webui >/dev/null 2>&1; then
    docker inspect open-webui --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
      grep -E '^(OPENAI_API_BASE_URLS|RAG_RERANKING_ENGINE|RAG_EXTERNAL_RERANKER_URL|RAG_OPENAI_API_BASE_URL|DOCLING_SERVER_URL)=' |
      sed 's/^/    /'
    note "every chat endpoint listed above must resolve to a RUNNING service"
  else
    note "not this node"
  fi

  head2 "Port collisions between projects"
  local dupes
  dupes="$(docker ps -a --format '{{.Names}}|{{.Ports}}' |
           grep -oE '0\.0\.0\.0:[0-9]+' | cut -d: -f2 | sort | uniq -d)"
  # A published port that two DEFINED stacks both want is invisible while one of
  # them is stopped, which is exactly how it gets to deployment unnoticed.
  local filep
  filep="$(grep -hoE '^\s+-\s+"?[0-9]+:[0-9]+' "$STACKS"/*/compose.y*ml 2>/dev/null |
           grep -oE '[0-9]+:' | tr -d ':' | sort | uniq -d)"
  if [ -n "$dupes$filep" ]; then
    for n in $dupes $filep; do
      bad "host port $n is claimed more than once:"
      grep -lE "^\s+-\s+\"?$n:" "$STACKS"/*/compose.y*ml 2>/dev/null | sed 's|.*/stacks/|          |;s|/compose.*||'
      rc=1
    done
  else
    ok "no host port is claimed twice"
  fi

  head2 "Storage that does not survive a recreate"
  for n in $(docker ps -a --format '{{.Names}}'); do
    docker inspect "$n" --format '{{range .Mounts}}{{.Type}} {{.Name}} {{.Destination}}{{println}}{{end}}' 2>/dev/null |
      awk -v c="$n" '$1=="volume" && length($2)==64 { print "  " c " -> " $3 }'
  done | while read -r line; do
    bad "ANONYMOUS volume:$line"
    note "tied to this one container: recreate it and the data is gone, silently"
  done
  ok "(any line above is a finding; no lines means none)"

  head2 "Project name vs directory"
  for n in $(docker ps -a --format '{{.Names}}'); do
    p="$(docker inspect -f "{{index .Config.Labels \"$L_PROJ\"}}" "$n" 2>/dev/null)"
    d="$(docker inspect -f "{{index .Config.Labels \"$L_WDIR\"}}" "$n" 2>/dev/null)"
    [ -n "$p" ] && [ -n "$d" ] || continue
    if [ "$p" != "$(basename "$d")" ]; then
      bad "$n: project '$p' but directory '$(basename "$d")'"
      note "compose in that directory will not find this container, and 'up -d'"
      note "tries to create a second one -- which then fails on the name."
      rc=1
    fi
  done

  head2 "Literal addresses in compose files"
  local lit
  # An image TAG is a false positive here -- apache/tika:3.3.1.0 matches an IPv4
  # perfectly well -- so image lines are dropped before anything is reported.
  lit="$(grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$STACKS"/*/compose.y*ml 2>/dev/null |
         grep -vE '127\.0\.0\.1|0\.0\.0\.0|([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' |
         grep -vE ':[0-9]+:[[:space:]]*image:')"
  if [ -n "$lit" ]; then
    warn "it-set-ip cannot update these when the box is renumbered:"
    printf '%s\n' "$lit" | sed "s|$STACKS/||" | sed 's/^/          /'
  else
    ok "no literal addresses -- a renumber will reach everything"
  fi

  head2 "Missing \${VAR:?} guards on secrets"
  local g
  g="$(grep -nE '\$\{[A-Z_]*(PASSWORD|SECRET|KEY)[A-Z_]*\}' "$STACKS"/*/compose.y*ml 2>/dev/null |
       grep -v ':?')"
  if [ -n "$g" ]; then
    warn "an unset value is accepted SILENTLY here (blank password, not an error):"
    printf '%s\n' "$g" | sed "s|$STACKS/||" | sed 's/^/          /'
  else
    ok "every secret reference fails loudly when unset"
  fi

  say ""
  [ "$rc" = 0 ] && ok "no drift found" || warn "findings above; nothing was changed"
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
  audit)        cmd_audit ;;
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
