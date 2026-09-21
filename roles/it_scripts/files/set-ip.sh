#!/usr/bin/env bash
# it-set-ip -- renumber an AI node when it moves to a new network (out of the lab).
#
# Updates the cross-node wiring the AI stack depends on so it keeps working at the
# new site, and (optionally) this box's own static IP:
#   PEER : the OTHER box's IP -> /opt/it/site.yml (ai_systemN_addr + any firewall
#          `from:` rules), the live .env (SYSTEM2_ADDR / OPEN_WEBUI_URL + *_HOSTS_
#          ENTRY), /etc/hosts, and the ufw rules; then recreates the containers so
#          Open WebUI picks up the new address.
#   SELF : this box's static IP via netplan (dhcp off, address/gateway/DNS).
#
# Works OFFLINE (edits files directly -- no ansible-pull / internet needed) and
# still updates site.yml so a later online pull stays consistent. Backs up every
# file it touches to <file>.bak-<timestamp>.
#
# Usage:
#   sudo it-set-ip                              # interactive
#   sudo it-set-ip --peer 10.0.5.20             # just the peer/cross-node update
#   sudo it-set-ip --self 10.0.5.11/24 --gateway 10.0.5.1 --dns 10.0.5.2
#   sudo it-set-ip --self 10.0.5.11/24 --gateway 10.0.5.1 --peer 10.0.5.20 --yes
#   sudo it-set-ip --peer 10.0.5.20 --no-recreate   # files only; containers untouched
#
#   sudo it-set-ip --peer <ip> --as lan|link   record WHICH of the peer's two
#                           addresses this is, so --use can find it again
#   sudo it-set-ip --use lan|link   switch the peer to the stored LAN or link
#                           address. THIS IS THE FAILOVER: when the direct
#                           cable dies the peer's link address is simply
#                           unreachable -- it does not fall back to the LAN,
#                           because that is a different address.
#
#   sudo it-set-ip scan     list every literal address in the compose files
#   sudo it-set-ip fix      replace them, one address at a time, after asking.
#                           Suggests the .env variable that already holds that
#                           address, so the value stays current from then on.
#
# A literal address written into a compose file is NOT updated (and not edited)
# -- it is reported, because nothing else on the box would notice it.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

IT_DIR=/opt/it
SITE="$IT_DIR/site.yml"
STACKS_DIR=/opt/stacks               # per-service Dockge stacks (each has its own .env)
COMPOSE_DIR="$IT_DIR/docker"         # dormant consolidated fallback (also carries a .env)
TS=$(date +%Y%m%d-%H%M%S)

# Every stack's .env, plus the fallback .env -- they all carry the same peer vars.
env_files() {
  for f in "$STACKS_DIR"/*/.env "$COMPOSE_DIR/.env"; do [ -f "$f" ] && echo "$f"; done
}
# Stack dirs holding a compose.yaml (for the recreate step).
stack_dirs() {
  for d in "$STACKS_DIR"/*/; do [ -f "${d}compose.yaml" ] && echo "$d"; done
}

# Literal IPv4 addresses written INTO a compose file.
#
# Everything this script rewrites -- .env, /etc/hosts, ufw, site.yml -- is
# invisible to an address that was typed into compose.yaml instead of left as
# ${SYSTEM2_ADDR}. The renumber then reports success, the containers are
# recreated, and the endpoint still points at the lab. dev-ai2 has exactly
# that: vllm-gptoss carries 192.168.1.110 where the repo uses the variable.
#
# REPORTED, NEVER EDITED. Every file ai_compose places is a plain copy, an
# on-box edit is the operator's deliberate exception, and this script is not
# the thing that gets to overwrite it. Loopback and wildcard binds are not
# interesting; a CIDR in a networks: block is not either.
compose_literals() {
  local f rel
  for f in "$STACKS_DIR"/*/compose*.y*ml "$STACKS_DIR"/*/docker-compose*.y*ml; do
    [ -f "$f" ] || continue
    rel="${f#$STACKS_DIR/}"
    # An image TAG parses as an IPv4 -- apache/tika:3.3.1.0 -- so drop image
    # lines before reporting anything as an address that needs renumbering.
    grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$f" 2>/dev/null \
      | grep -vE '127\.0\.0\.1|0\.0\.0\.0|([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' \
      | grep -vE '^[0-9]+:[[:space:]]*image:' \
      | sed "s|^|  $rel:|"
  done
}

# Not previously defined in this script, while several call sites used it --
# a `die` that does not exist prints "die: command not found" and CARRIES ON,
# which is the opposite of what every one of those call sites wanted.
die(){ printf '%s\n' "$*" >&2; exit 1; }
bak(){ [ -e "$1" ] && cp -a "$1" "$1.bak-$TS" && echo "  backup: $1.bak-$TS"; }
# escape dots so an IP is matched literally, bounded by non-digits (so .10 != .104)
ipswap(){ # file old new
  local f="$1" o e n="$3"; e=$(printf '%s' "$2" | sed 's/\./\\./g')
  sed -i -E "s/(^|[^0-9])${e}([^0-9]|\$)/\1${n}\2/g" "$f"
}

usage(){ sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---------------------------------------------------------------------------
# `scan` / `fix` -- literal addresses typed INTO a compose file.
#
# Everything the renumber above rewrites -- .env, site.yml, /etc/hosts, ufw --
# is invisible to an address written directly into compose.yaml, so the move
# reports success and that endpoint quietly keeps pointing at the old network.
#
# `fix` is the one place in this repo that edits a compose file, and it only
# does it when a person picks a replacement and confirms. Two things it always
# says, because both have caught people out:
#   1. Editing a compose file does NOT change the running container. The daemon
#      restarts the container it already has and never re-reads the file --
#      `docker compose up -d` in that directory is what applies it.
#   2. ai_compose OVERWRITES these files on the next pull (gotcha 2). A fix made
#      only here lasts until then; it has to go into the baseline as well.
# ---------------------------------------------------------------------------
compose_files() {
  local f
  for f in "$STACKS_DIR"/*/compose.y*ml "$STACKS_DIR"/*/docker-compose.y*ml; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

# Lines carrying a literal IPv4, minus the ones that are never an endpoint:
# loopback, the wildcard bind, a CIDR in a networks: block, and image TAGS --
# apache/tika:3.3.1.0 parses as an address perfectly well.
literal_lines() {
  local f
  while read -r f; do
    grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$f" 2>/dev/null |
      grep -vE '127\.0\.0\.1|0\.0\.0\.0|([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' |
      grep -vE '^[0-9]+:[[:space:]]*image:' |
      sed "s|^|$f:|"
  done < <(compose_files)
}
literal_addrs() { literal_lines | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u; }

# The replacement worth suggesting is a variable ALREADY carrying this address
# in one of the stacks' .env files -- that is the form the rest of the compose
# uses, and it is the one it-set-ip can keep current from then on.
suggest_vars() {   # $1 = address
  local f v val
  for f in "$STACKS_DIR"/*/.env "$COMPOSE_DIR/.env"; do
    [ -f "$f" ] || continue
    while IFS='=' read -r v val; do
      case "$v" in ''|\#*) continue ;; esac
      case "$val" in *"$1"*) printf '%s\n' "$v" ;; esac
    done < "$f"
  done | sort -u
}

show_addr() {   # $1 = address -- where it is used, and what could replace it
  local n
  printf '\n  %s\n' "$1"
  literal_lines | grep -F "$1" | sed "s|$STACKS_DIR/||" | sed 's/^/      /'
  n="$(suggest_vars "$1")"
  if [ -n "$n" ]; then
    printf '      %ssuggested: %s%s\n' "" \
      "$(printf '%s' "$n" | sed 's/^/${/;s/$/}/' | tr '\n' ' ')" ""
  else
    printf '      %sno .env variable on this node carries that address --%s\n' "" ""
    printf '      %sit is probably this node itself, so a container name on the%s\n' "" ""
    printf '      %s`oi` network (e.g. open-webui-lgtm:4317) is the stabler fix.%s\n' "" ""
  fi
}

cmd_scan() {
  local a n=0
  echo ">> Literal addresses in $STACKS_DIR/*/compose.yaml"
  for a in $(literal_addrs); do show_addr "$a"; n=$((n + 1)); done
  if [ "$n" = 0 ]; then
    echo "   none -- a renumber reaches everything on this node."
  else
    echo
    echo "   $n address(es). None of these are updated by a renumber."
    echo "   Change them with:  sudo it-set-ip fix"
  fi
  echo
}

cmd_fix() {
  local a repl n sel f files bak_made="" touched=""
  [ -t 0 ] || { echo "fix is interactive -- run it from a terminal." >&2; exit 1; }

  echo ">> Literal addresses in $STACKS_DIR/*/compose.yaml"
  [ -n "$(literal_addrs)" ] || { echo "   none -- nothing to do."; echo; return 0; }

  for a in $(literal_addrs); do
    show_addr "$a"
    n="$(suggest_vars "$a")"
    echo
    local i=1
    for v in $n; do printf '      %d) ${%s}\n' "$i" "$v"; i=$((i + 1)); done
    printf '      t) type a replacement myself\n'
    printf '      s) skip this address\n'
    printf '      %sReplace %s with? [s] %s' "" "$a" ""
    read -r sel
    repl=""
    case "$sel" in
      ''|s|S) echo "      skipped"; continue ;;
      t|T) printf '      New value (a name, an address, or ${VAR}): '; read -r repl ;;
      *)
        case "$sel" in
          ''|*[!0-9]*) echo "      not a choice -- skipped"; continue ;;
        esac
        repl="$(printf '%s\n' $n | sed -n "${sel}p")"
        [ -n "$repl" ] || { echo "      not a choice -- skipped"; continue; }
        repl="\${$repl}"
        ;;
    esac
    [ -n "$repl" ] || { echo "      empty -- skipped"; continue; }

    files="$(literal_lines | grep -F "$a" | cut -d: -f1 | sort -u)"
    echo "      $a -> $repl  in:"
    printf '%s\n' "$files" | sed "s|$STACKS_DIR/||" | sed 's/^/        /'
    printf '      %sApply? [y/N] %s' "" ""
    read -r yn
    case "$yn" in y|Y) ;; *) echo "      not applied"; continue ;; esac

    for f in $files; do
      bak "$f"
      # ipswap bounds the match with non-digits so .10 never eats .104, and the
      # replacement is a shell VARIABLE's value -- the shell does not expand it
      # a second time, so ${SYSTEM2_ADDR} lands as literal text.
      ipswap "$f" "$a" "$repl"
      touched="$touched $(dirname "$f")"
    done
    echo "      replaced in $(printf '%s\n' "$files" | grep -c .) file(s)"
  done

  [ -n "$touched" ] || { echo; echo "   nothing was changed."; echo; return 0; }

  echo
  echo "   >> THESE FILES ARE EDITED. THE RUNNING CONTAINERS ARE NOT."
  echo "      The daemon restarts the container it already has and never"
  echo "      re-reads compose.yaml. A reboot keeps the OLD value. Apply with:"
  for d in $(printf '%s\n' $touched | sort -u); do
    echo "        cd $d && docker compose up -d"
  done
  echo
  echo "   >> AND THE NEXT PULL OVERWRITES THEM."
  echo "      ai_compose places every compose.yaml as a plain copy, so this"
  echo "      lasts until the next 'it-pull ai'. Make the same change in the"
  echo "      baseline, or keep it in compose.override.yaml, which nothing manages."
  echo
}


# ---- identify this node + its peer ----
HN=$(hostname)
case "$HN" in
  *ai1*) ROLE=system1; PEER_HOST=dev-ai2; PEER_VAR=ai_system2_addr ;;
  *ai2*) ROLE=system2; PEER_HOST=dev-ai1; PEER_VAR=ai_system1_addr ;;
  *)     ROLE=unknown; PEER_HOST=""; PEER_VAR="" ;;
esac
IFACE=$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
SELF_IP=$(ip -o -4 addr show "${IFACE:-lo}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
# The .env to READ the current peer out of. Any of them will do -- they all
# carry the same peer vars -- but it MUST be assigned before the probe below:
# this script runs under `set -u`, ENVF was only ever assigned at the top of the
# rewrite loop further down, and referencing it here therefore killed the script
# on startup with "ENVF: unbound variable" before it could do anything at all.
ENVF="$(env_files | head -1)"

CUR_PEER=""
if [ -n "$ENVF" ] && [ -f "$ENVF" ]; then
  if [ "$ROLE" = system1 ]; then CUR_PEER=$(grep -E '^SYSTEM2_ADDR=' "$ENVF" | cut -d= -f2-)
  elif [ "$ROLE" = system2 ]; then CUR_PEER=$(grep -E '^OPEN_WEBUI_URL=' "$ENVF" | sed -E 's#.*://([^:/]+).*#\1#'); fi
fi

# ---- the peer's TWO addresses -------------------------------------------
# A node has one peer but two ways to reach it: the LAN, and the direct cable.
# Only one can be active -- the peer var is a single address and every consumer
# (SYSTEM2_ADDR, OPEN_WEBUI_URL, the hosts entries, prometheus' scrape target)
# takes exactly one. So BOTH are remembered in site.yml and `--use` switches
# between them.
#
# This is the failover. There is no automatic one and there cannot easily be:
# when the link drops, the kernel withdraws the connected /30 route and the
# peer's LINK address becomes unreachable -- it does not fall back to the LAN,
# because the LAN address is a DIFFERENT address. Making one address reachable
# both ways needs a routing protocol or a bond, and a bond cannot span a switch
# port and a direct cable. For two boxes in one rack, where the failure is a
# visible physical thing, one command is the better trade.
LAN_VAR="${PEER_VAR%_addr}_lan_addr"
LINK_VAR="${PEER_VAR%_addr}_link_addr"
site_get() {   # $1 = key
  sed -nE "s/^[[:space:]]*$1:[[:space:]]*\"?([^\"#]*)\"?.*/\1/p" "$SITE" 2>/dev/null |
    tail -1 | tr -d ' '
}
site_set() {   # $1 = key, $2 = value
  [ -f "$SITE" ] || return 0
  if grep -qE "^[[:space:]]*#?[[:space:]]*$1:" "$SITE"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*$1:.*|$1: \"$2\"|" "$SITE"
  else
    printf '\n%s: "%s"\n' "$1" "$2" >> "$SITE"
  fi
}

# ---- args ----
case "${1:-}" in
  scan)             cmd_scan; exit 0 ;;
  fix|fix-literals) cmd_fix;  exit 0 ;;
esac

NEW_PEER=""; NEW_SELF=""; GW=""; DNS=""; YES=0; RECREATE=1; PEER_AS=""; PEER_USE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --peer) NEW_PEER="$2"; shift 2 ;;
    --as)   PEER_AS="${2:?--as needs lan or link}"; shift 2 ;;
    --use)  PEER_USE="${2:?--use needs lan or link}"; shift 2 ;;
    --no-recreate) RECREATE=0; shift ;;
    --self) NEW_SELF="$2"; shift 2 ;;
    --gateway) GW="$2"; shift 2 ;;
    --dns) DNS="$2"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown arg: $1"; usage 1 ;;
  esac
done

# --use lan|link: take the address out of site.yml so nobody has to remember it.
# This is the failover command, and it is deliberately one word plus a side.
if [ -n "$PEER_USE" ]; then
  [ -n "$PEER_VAR" ] || die "hostname is not dev-ai1/dev-ai2 -- cannot tell which peer to switch"
  case "$PEER_USE" in
    lan)  NEW_PEER="$(site_get "$LAN_VAR")";  _src="$LAN_VAR" ;;
    link) NEW_PEER="$(site_get "$LINK_VAR")"; _src="$LINK_VAR" ;;
    *)    die "--use takes 'lan' or 'link' (got '$PEER_USE')" ;;
  esac
  [ -n "$NEW_PEER" ] || die "$_src is not set in $SITE.
Record both addresses once, then --use switches between them:
  sudo it-set-ip --peer <peer LAN address>  --as lan
  sudo it-set-ip --peer <peer link address> --as link"
  echo ">> --use $PEER_USE: peer = $NEW_PEER  (from $_src)"
fi

# --as lan|link: RECORD ONLY, and then stop.
#
# Recording is what you do in the lab, weeks before the cable exists. Activating
# an address that is not reachable yet would rewrite every .env, /etc/hosts and
# the ufw rules, recreate the containers, and leave the stack pointing at
# nothing. So --as writes the slot and exits; --use activates, later, deliberately.
if [ -n "$PEER_AS" ]; then
  [ -n "$NEW_PEER" ] || die "--as needs --peer <address> to record"
  [ -n "$PEER_VAR" ] || die "hostname is not dev-ai1/dev-ai2 -- cannot tell whose peer this is"
  case "$PEER_AS" in
    lan)  site_set "$LAN_VAR"  "$NEW_PEER"; echo "   site.yml: $LAN_VAR = $NEW_PEER" ;;
    link) site_set "$LINK_VAR" "$NEW_PEER"; echo "   site.yml: $LINK_VAR = $NEW_PEER" ;;
    *)    die "--as takes 'lan' or 'link' (got '$PEER_AS')" ;;
  esac
  echo "   recorded only -- nothing else was changed."
  echo "   Activate it when the path exists:  sudo it-set-ip --use $PEER_AS"
  exit 0
fi


echo "== it-set-ip =="
echo "  node        : $HN ($ROLE)"
echo "  interface   : ${IFACE:-?}   self IP: ${SELF_IP:-?}"
echo "  peer        : ${PEER_HOST:-?}   current peer IP: ${CUR_PEER:-<unknown>}"
echo

# ---- interactive fill ----
if [ -z "$NEW_PEER" ] && [ -z "$NEW_SELF" ]; then
  if [ "$ROLE" != unknown ]; then
    read -r -p "New PEER IP ($PEER_HOST) [blank = leave ${CUR_PEER:-unset}]: " NEW_PEER
  fi
  read -r -p "Change THIS box's own IP? new IP[/CIDR] [blank = no]: " NEW_SELF
  if [ -n "$NEW_SELF" ]; then
    read -r -p "  gateway [blank = keep current]: " GW
    read -r -p "  DNS (comma-ok) [blank = keep current]: " DNS
  fi
fi
[ -z "$NEW_PEER" ] && [ -z "$NEW_SELF" ] && { echo "Nothing to do."; exit 0; }

echo; echo "Planned changes:"
[ -n "$NEW_PEER" ] && echo "  PEER $PEER_HOST : ${CUR_PEER:-?} -> $NEW_PEER  (site.yml/.env/hosts/ufw + recreate containers)"
[ -n "$NEW_SELF" ] && echo "  SELF $IFACE     : ${SELF_IP:-?} -> $NEW_SELF  (netplan; gw ${GW:-keep}, dns ${DNS:-keep}) -- MAY DROP THIS SSH SESSION"
if [ "$YES" -ne 1 ]; then read -r -p "Proceed? [y/N] " a; case "$a" in y|Y) ;; *) echo aborted; exit 1;; esac; fi

# ---- PEER update (do first, while the network is still stable) ----
if [ -n "$NEW_PEER" ]; then
  echo; echo ">> PEER update -> $NEW_PEER"
  if [ "$ROLE" = unknown ]; then
    echo "   hostname isn't dev-ai1/dev-ai2 -- can't map the peer; skipping peer update."
  else
    # site.yml (source of truth for future pulls)
    if [ -f "$SITE" ]; then
      bak "$SITE"
      if grep -qE "^[[:space:]]*#?[[:space:]]*${PEER_VAR}:" "$SITE"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${PEER_VAR}:.*|${PEER_VAR}: \"${NEW_PEER}\"|" "$SITE"
      else
        printf '\n%s: "%s"\n' "$PEER_VAR" "$NEW_PEER" >> "$SITE"
      fi
      [ -n "$CUR_PEER" ] && ipswap "$SITE" "$CUR_PEER" "$NEW_PEER"   # firewall from: etc.
      echo "   site.yml: $PEER_VAR = $NEW_PEER"
    fi
    # live .env files the containers read (one per stack + the fallback)
    _env_n=0
    for ENVF in $(env_files); do
      bak "$ENVF"
      if [ "$ROLE" = system1 ]; then
        sed -i -E "s|^SYSTEM2_ADDR=.*|SYSTEM2_ADDR=${NEW_PEER}|" "$ENVF"
        sed -i -E "s|^SYSTEM2_HOSTS_ENTRY=.*|SYSTEM2_HOSTS_ENTRY=${PEER_HOST}:${NEW_PEER}|" "$ENVF"
      else
        sed -i -E "s|^OPEN_WEBUI_URL=.*|OPEN_WEBUI_URL=http://${NEW_PEER}:3000|" "$ENVF"
        sed -i -E "s|^SYSTEM1_HOSTS_ENTRY=.*|SYSTEM1_HOSTS_ENTRY=${PEER_HOST}:${NEW_PEER}|" "$ENVF"
      fi
      _env_n=$((_env_n+1))
    done
    [ "$_env_n" -gt 0 ] && echo "   .env updated ($_env_n file(s))"
    # host-side peer resolution
    bak /etc/hosts
    # Delete then append, rather than substitute. The previous version used | as
    # the s/// delimiter while its own regex contained | as an ERE alternation,
    # so sed saw the command end early and died with "unknown option to `s'" --
    # and the success line printed anyway, so /etc/hosts was never updated and
    # nothing said so. Delete-and-append needs no delimiter gymnastics and is
    # idempotent whether or not an entry was there.
    sed -i -E "/[[:space:]]${PEER_HOST}([[:space:]]|$)/d" /etc/hosts
    printf '%s %s\n' "$NEW_PEER" "$PEER_HOST" >> /etc/hosts
    if ! grep -qE "^${NEW_PEER}[[:space:]]+${PEER_HOST}([[:space:]]|$)" /etc/hosts; then
      echo "   !! /etc/hosts update FAILED -- check it by hand" >&2
    fi
    echo "   /etc/hosts: $PEER_HOST -> $NEW_PEER"
    # firewall: swap the old peer IP in ufw rules, then reload
    if [ -n "$CUR_PEER" ] && [ -f /etc/ufw/user.rules ]; then
      bak /etc/ufw/user.rules; [ -f /etc/ufw/user6.rules ] && bak /etc/ufw/user6.rules
      ipswap /etc/ufw/user.rules "$CUR_PEER" "$NEW_PEER"
      ufw reload >/dev/null 2>&1 && echo "   ufw: rules for $CUR_PEER -> $NEW_PEER (reloaded)"
    fi
    # An address typed into a compose file is the one thing none of the above
    # reaches. Check before the recreate, so it is on screen when the operator
    # is still standing at the box.
    _lit="$(compose_literals)"
    if [ -n "$_lit" ]; then
      echo
      echo "   !! LITERAL ADDRESSES IN COMPOSE FILES -- not updated, not touched:"
      printf '%s\n' "$_lit" | sed 's/^/  /'
      if [ -n "$CUR_PEER" ] && printf '%s' "$_lit" | grep -q "$CUR_PEER"; then
        echo "   !! One of them IS the old peer ($CUR_PEER). That endpoint is now dead."
      fi
      echo "   Fix them in the repo and pull, or edit the file and recreate that"
      echo "   stack by hand. This script does not edit compose files."
      echo
    fi
    # recreate containers so they pick up the new env (each stack is its own project)
    if [ "$RECREATE" -eq 0 ]; then
      echo "   --no-recreate: containers left alone. They keep the OLD peer address"
      echo "   until something recreates them:  sudo it-ai up"
      _rc_n=-1
    else
      _rc_n=0
      for d in $(stack_dirs); do
        ( cd "$d" && docker compose up -d ) >/dev/null 2>&1 && _rc_n=$((_rc_n+1)) || true
      done
      if [ "$_rc_n" -gt 0 ]; then
        echo "   containers recreated ($_rc_n stack(s), docker compose up -d)"
      else
        echo "   NOTE: no stacks recreated -- run 'it-ai up' by hand"
      fi
    fi
    _thisip="${NEW_SELF%%/*}"; [ -n "$_thisip" ] || _thisip="$SELF_IP"
    echo "   PEER update done. On $PEER_HOST, point it back at THIS box:  sudo it-set-ip --peer ${_thisip}"
  fi
fi

# ---- SELF update (netplan; last, since it can drop the session) ----
if [ -n "$NEW_SELF" ]; then
  echo; echo ">> SELF update -> $NEW_SELF on ${IFACE:-?}"
  [[ "$NEW_SELF" == */* ]] || NEW_SELF="${NEW_SELF}/24"
  if [ -z "$IFACE" ]; then
    echo "   can't detect the interface; skipping self update."
  else
    NP=/etc/netplan/99-it-set-ip.yaml
    for f in /etc/netplan/*.yaml; do [ "$f" = "$NP" ] || bak "$f"; done
    {
      echo "network:"
      echo "  version: 2"
      echo "  ethernets:"
      echo "    ${IFACE}:"
      echo "      dhcp4: false"
      echo "      addresses: [${NEW_SELF}]"
      [ -n "$GW" ]  && echo "      routes: [{to: default, via: ${GW}}]"
      [ -n "$DNS" ] && echo "      nameservers: {addresses: [${DNS//,/, }]}"
    } > "$NP"
    chmod 600 "$NP"
    echo "   wrote $NP:"; sed 's/^/     /' "$NP"
    if netplan generate; then
      echo "   WARNING: applying changes this box's IP and will DROP an SSH session."
      echo "            Reconnect afterward on ${NEW_SELF%%/*}. Best run from the console."
      if [ "$YES" -ne 1 ]; then read -r -p "   Apply netplan now? [y/N] " a; case "$a" in y|Y) ;; *) echo "   wrote config but did NOT apply. Apply later: sudo netplan apply"; exit 0;; esac; fi
      echo "   applying in 5s (Ctrl-C to abort)..."; sleep 5
      netplan apply && echo "   applied. Reconnect on ${NEW_SELF%%/*}."
      echo "   REMINDER: on $PEER_HOST run:  sudo it-set-ip --peer ${NEW_SELF%%/*}"
    else
      echo "   netplan generate failed -- left $NP in place but did NOT apply."
    fi
  fi
fi
echo; echo "Done."
