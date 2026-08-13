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

bak(){ [ -e "$1" ] && cp -a "$1" "$1.bak-$TS" && echo "  backup: $1.bak-$TS"; }
# escape dots so an IP is matched literally, bounded by non-digits (so .10 != .104)
ipswap(){ # file old new
  local f="$1" o e n="$3"; e=$(printf '%s' "$2" | sed 's/\./\\./g')
  sed -i -E "s/(^|[^0-9])${e}([^0-9]|\$)/\1${n}\2/g" "$f"
}

usage(){ sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---- identify this node + its peer ----
HN=$(hostname)
case "$HN" in
  *ai1*) ROLE=system1; PEER_HOST=dev-ai2; PEER_VAR=ai_system2_addr ;;
  *ai2*) ROLE=system2; PEER_HOST=dev-ai1; PEER_VAR=ai_system1_addr ;;
  *)     ROLE=unknown; PEER_HOST=""; PEER_VAR="" ;;
esac
IFACE=$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
SELF_IP=$(ip -o -4 addr show "${IFACE:-lo}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
CUR_PEER=""
if [ -f "$ENVF" ]; then
  if [ "$ROLE" = system1 ]; then CUR_PEER=$(grep -E '^SYSTEM2_ADDR=' "$ENVF" | cut -d= -f2-)
  elif [ "$ROLE" = system2 ]; then CUR_PEER=$(grep -E '^OPEN_WEBUI_URL=' "$ENVF" | sed -E 's#.*://([^:/]+).*#\1#'); fi
fi

# ---- args ----
NEW_PEER=""; NEW_SELF=""; GW=""; DNS=""; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --peer) NEW_PEER="$2"; shift 2 ;;
    --self) NEW_SELF="$2"; shift 2 ;;
    --gateway) GW="$2"; shift 2 ;;
    --dns) DNS="$2"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown arg: $1"; usage 1 ;;
  esac
done

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
    if grep -qE "[[:space:]]${PEER_HOST}([[:space:]]|\$)" /etc/hosts; then
      sed -i -E "s|^[0-9.]+([[:space:]]+.*[[:space:]]${PEER_HOST}([[:space:]]|\$).*)|${NEW_PEER}\1|" /etc/hosts
    else
      printf '%s %s\n' "$NEW_PEER" "$PEER_HOST" >> /etc/hosts
    fi
    echo "   /etc/hosts: $PEER_HOST -> $NEW_PEER"
    # firewall: swap the old peer IP in ufw rules, then reload
    if [ -n "$CUR_PEER" ] && [ -f /etc/ufw/user.rules ]; then
      bak /etc/ufw/user.rules; [ -f /etc/ufw/user6.rules ] && bak /etc/ufw/user6.rules
      ipswap /etc/ufw/user.rules "$CUR_PEER" "$NEW_PEER"
      ufw reload >/dev/null 2>&1 && echo "   ufw: rules for $CUR_PEER -> $NEW_PEER (reloaded)"
    fi
    # recreate containers so they pick up the new env (each stack is its own project)
    _rc_n=0
    for d in $(stack_dirs); do
      ( cd "$d" && docker compose up -d ) >/dev/null 2>&1 && _rc_n=$((_rc_n+1)) || true
    done
    if [ "$_rc_n" -gt 0 ]; then
      echo "   containers recreated ($_rc_n stack(s), docker compose up -d)"
    else
      echo "   NOTE: no stacks recreated -- run 'it-ai up' by hand"
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
