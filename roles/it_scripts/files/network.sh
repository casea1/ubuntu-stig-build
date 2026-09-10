#!/usr/bin/env bash
# it-net -- set this box's address, DNS and time source before it is deployed.
#
# For the case this exists for: staging a machine in the lab so that when it is
# plugged in at the other site it is already on the right subnet, resolving
# against the right server, and stepping its clock off the right NTP host.
#
#   it-net                     what is set now, and where each piece comes from
#   it-net status              the same
#   it-net ip <CIDR> --gateway <IP> [--iface <NAME>] [--dns a,b] [--search dom]
#                              static address via netplan
#   it-net dhcp [--iface <NAME>]
#                              back to DHCP on that interface
#   it-net dns <a,b> [--search dom]
#                              nameservers only, leaving the address alone
#   it-net ntp <a,b>           chrony time source (STIG: server + maxpoll)
#   it-net apply               apply the pending netplan config
#   it-net check               is the network actually WORKING? Read-only.
#                              Times the lookups a deployed box pays for, and
#                              names what to run for anything it finds.
#
# NOTHING IS APPLIED UNTIL YOU SAY SO. Every write lands in
# /etc/netplan/99-it-net.yaml and then asks, because `netplan apply` on the
# interface you are connected over drops the session. Over SSH, prefer
# `netplan try` -- it rolls back on its own if you lose the connection.
#
# WHAT SURVIVES A PULL. The netplan file is ours and no role touches it. NTP is
# different: usg_remediate writes chrony.conf from usg_chrony_servers on every
# run, so `it-net ntp` writes BOTH chrony.conf (immediate) and /opt/it/site.yml
# (so the next pull agrees instead of reverting it).
set -uo pipefail
# `check` changes nothing and every probe in it works unprivileged, so it does
# not elevate: a diagnostic an engineer cannot run is a diagnostic that gets
# reported second-hand. Everything else writes, and still does.
case "${1:-}" in
  check) ;;
  *) [ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@" ;;
esac

NETPLAN_FILE=/etc/netplan/99-it-net.yaml
SITE=/opt/it/site.yml
CHRONY=/etc/chrony/chrony.conf
TS=$(date +%Y%m%d-%H%M%S)

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; R=$'\033[0m'
else B=""; DIM=""; GRN=""; YEL=""; RED=""; R=""; fi
say()   { printf '%s\n' "$*"; }
head2() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }
ok()    { printf '  %s%s%s\n' "$GRN" "$*" "$R"; }
warn()  { printf '  %s%s%s\n' "$YEL" "$*" "$R"; }
bad()   { printf '  %s%s%s\n' "$RED" "$*" "$R"; }
die()   { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; exit 1; }

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }
case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac

# ---------------------------------------------------------------------------
# The interface to act on. Default: whichever one carries the default route,
# because that is the one the operator means. Falls back to the first physical
# link with a carrier -- never lo, never a bridge this box made itself.
# ---------------------------------------------------------------------------
default_iface() {
  local i
  i=$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')
  [ -n "$i" ] && { printf '%s' "$i"; return; }
  ip -br link show up 2>/dev/null \
    | awk '$1 != "lo" && $1 !~ /^(docker|br-|veth|virbr)/ {print $1; exit}'
}

# The renderer already in use. Writing a file with the wrong one hands the
# interface to a manager that is not running, and the box comes up with no
# network at all -- so this is read from the box, never assumed.
detect_renderer() {
  local r
  r=$(grep -rhoE '^\s*renderer:\s*\S+' /etc/netplan/*.yaml 2>/dev/null \
        | awk '{print $2}' | grep -vx '' | head -1)
  [ -n "$r" ] && { printf '%s' "$r"; return; }
  systemctl is-active --quiet NetworkManager 2>/dev/null \
    && { printf 'NetworkManager'; return; }
  printf 'networkd'
}

# a,b,c -> "[a, b, c]" for netplan's flow sequences.
yaml_list() { printf '[%s]' "$(printf '%s' "$1" | tr -d ' ' | sed 's/,/, /g')"; }

backup() { [ -f "$1" ] && cp -p "$1" "$1.bak-$TS" && say "  ${DIM}backed up $1 -> $1.bak-$TS${R}"; }

# ---------------------------------------------------------------------------
cmd_status() {
  local ifc rend
  ifc=$(default_iface); rend=$(detect_renderer)

  head2 "Network -- $(hostname)"
  printf '  %-14s %s\n' "interface" "${ifc:-<none with a default route>}"
  printf '  %-14s %s\n' "renderer" "$rend"
  if [ -n "$ifc" ]; then
    printf '  %-14s %s\n' "address" "$(ip -br -4 addr show "$ifc" 2>/dev/null | awk '{$1=$1;print $3}')"
    printf '  %-14s %s\n' "gateway" "$(ip -o route show default 2>/dev/null | awk '{print $3; exit}')"
  fi

  head2 "DNS"
  if command -v resolvectl >/dev/null 2>&1; then
    resolvectl status "${ifc:-}" 2>/dev/null \
      | grep -E 'DNS Servers|DNS Domain|Current DNS' | sed 's/^ */  /'
  fi
  say "  ${DIM}/etc/resolv.conf:${R}"
  grep -E '^(nameserver|search|options)' /etc/resolv.conf 2>/dev/null | sed 's/^/    /'
  # Resolver options cannot be expressed in netplan. Say so here rather than
  # letting someone set them and watch them vanish on the next apply.
  if grep -q '^options' /etc/resolv.conf 2>/dev/null; then
    warn "resolv.conf carries 'options' -- netplan cannot express those"
    say  "  ${DIM}Under NetworkManager set them on the connection instead:${R}"
    say  "  ${DIM}nmcli con mod <name> ipv4.dns-options 'timeout:2,attempts:3'${R}"
  fi

  head2 "Time"
  if [ -r "$CHRONY" ]; then
    grep -E '^(server|pool|makestep)' "$CHRONY" 2>/dev/null | sed 's/^/  /' \
      || warn "no server/pool line in $CHRONY"
    command -v chronyc >/dev/null 2>&1 && {
      say "  ${DIM}current source:${R}"
      chronyc -n sources 2>/dev/null | sed 's/^/    /' | head -6
    }
  else
    warn 'chrony is not installed -- usg fix normally installs it'
  fi
  say "  ${DIM}site.yml usg_chrony_servers:${R} $(sed -nE 's/^usg_chrony_servers:\s*//p' "$SITE" 2>/dev/null || echo '(not set)')"

  head2 "Managed here"
  if [ -f "$NETPLAN_FILE" ]; then
    ok "$NETPLAN_FILE"
    sed 's/^/    /' "$NETPLAN_FILE"
  else
    say "  ${DIM}$NETPLAN_FILE does not exist -- this box's address is set elsewhere${R}"
    ls /etc/netplan/*.yaml 2>/dev/null | sed 's/^/    /'
  fi
  say ""
}

# ---------------------------------------------------------------------------
# Write our netplan file. Called by both `ip` and `dhcp`; $1 is the body of the
# interface stanza, already indented six spaces.
# ---------------------------------------------------------------------------
write_netplan() {   # $1 iface  $2 stanza
  local ifc="$1" body="$2" rend
  rend=$(detect_renderer)
  backup "$NETPLAN_FILE"
  cat > "$NETPLAN_FILE" <<EOF
# Managed by it-net. Edit with \`sudo it-net ...\`, not by hand.
# Written $(date -Is) on $(hostname).
network:
  version: 2
  renderer: $rend
  ethernets:
    $ifc:
$body
EOF
  # netplan refuses to read a world-readable file and warns loudly about a
  # group-readable one; it can hold a wifi PSK on other machines.
  chmod 0600 "$NETPLAN_FILE"
  ok "wrote $NETPLAN_FILE (renderer: $rend)"
}

confirm_apply() {
  say ""
  say "  ${B}Nothing has been applied yet.${R}"
  say ""
  if ! netplan generate 2>&1 | sed 's/^/  /'; then
    die "netplan rejected the config -- $NETPLAN_FILE is on disk but was NOT applied"
  fi
  ok "config is valid"
  say ""
  say "  Apply it with ONE of:"
  say "    ${B}sudo netplan try${R}      ${DIM}rolls back by itself if you lose the connection (use this over SSH)${R}"
  say "    ${B}sudo it-net apply${R}     ${DIM}applies immediately${R}"
  say ""
}

cmd_apply() {
  head2 "Applying netplan"
  warn "this can drop the session if you are connected over the interface being changed"
  if [ -t 0 ]; then
    printf '  Type YES to apply: '
    local a; read -r a; [ "$a" = YES ] || die "not confirmed -- nothing was applied"
  fi
  netplan apply && ok "applied" || die "netplan apply failed"
}

# ---------------------------------------------------------------------------
cmd_ip() {
  local cidr="${1:-}" gw="" ifc="" dns="" search=""
  shift || true
  [ -n "$cidr" ] || die "usage: it-net ip <CIDR> --gateway <IP> [--iface <NAME>] [--dns a,b] [--search dom]"
  case "$cidr" in */*) ;; *) die "address must include the prefix, e.g. 10.0.5.11/24 (got '$cidr')" ;; esac

  while [ $# -gt 0 ]; do
    case "$1" in
      --gateway) gw="${2:-}"; shift 2 ;;
      --iface)   ifc="${2:-}"; shift 2 ;;
      --dns)     dns="${2:-}"; shift 2 ;;
      --search)  search="${2:-}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$gw" ] || die "--gateway is required"
  ifc="${ifc:-$(default_iface)}"
  [ -n "$ifc" ] || die "could not work out which interface to use -- pass --iface"
  ip link show "$ifc" >/dev/null 2>&1 || die "no such interface: $ifc"

  head2 "Static address on $ifc"
  printf '  %-10s %s\n' "address" "$cidr"
  printf '  %-10s %s\n' "gateway" "$gw"
  [ -n "$dns" ]    && printf '  %-10s %s\n' "dns" "$dns"
  [ -n "$search" ] && printf '  %-10s %s\n' "search" "$search"

  local body
  body="      dhcp4: false
      addresses: [$cidr]
      routes:
        - to: default
          via: $gw"
  if [ -n "$dns" ] || [ -n "$search" ]; then
    body="$body
      nameservers:"
    [ -n "$dns" ]    && body="$body
        addresses: $(yaml_list "$dns")"
    [ -n "$search" ] && body="$body
        search: $(yaml_list "$search")"
  fi

  write_netplan "$ifc" "$body"
  confirm_apply
}

cmd_dhcp() {
  local ifc=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --iface) ifc="${2:-}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  ifc="${ifc:-$(default_iface)}"
  [ -n "$ifc" ] || die "could not work out which interface to use -- pass --iface"

  head2 "DHCP on $ifc"
  write_netplan "$ifc" "      dhcp4: true"
  confirm_apply
}

# DNS only, leaving whatever sets the address alone. Rewrites just the
# nameservers block of OUR file when it exists; otherwise says where the
# address actually comes from rather than silently taking it over.
cmd_dns() {
  local dns="${1:-}" search=""
  shift || true
  [ -n "$dns" ] || die "usage: it-net dns <a,b> [--search dom]"
  while [ $# -gt 0 ]; do
    case "$1" in
      --search) search="${2:-}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done

  local ifc; ifc=$(default_iface)
  [ -n "$ifc" ] || die "no interface with a default route -- set the address first with: it-net ip"

  head2 "Nameservers on $ifc"
  printf '  %-10s %s\n' "dns" "$dns"
  [ -n "$search" ] && printf '  %-10s %s\n' "search" "$search"

  local body
  if [ -f "$NETPLAN_FILE" ] && grep -q 'dhcp4: true' "$NETPLAN_FILE"; then
    body="      dhcp4: true
      dhcp4-overrides:
        use-dns: false
      nameservers:
        addresses: $(yaml_list "$dns")"
    [ -n "$search" ] && body="$body
        search: $(yaml_list "$search")"
  else
    # Keep the address this box already has, so `it-net dns` never renumbers it.
    local cidr gw
    cidr=$(ip -br -4 addr show "$ifc" 2>/dev/null | awk '{print $3; exit}')
    gw=$(ip -o route show default 2>/dev/null | awk '{print $3; exit}')
    [ -n "$cidr" ] && [ -n "$gw" ] \
      || die "could not read this box's current address/gateway -- set both with: it-net ip"
    warn "keeping the current address $cidr via $gw"
    body="      dhcp4: false
      addresses: [$cidr]
      routes:
        - to: default
          via: $gw
      nameservers:
        addresses: $(yaml_list "$dns")"
    [ -n "$search" ] && body="$body
        search: $(yaml_list "$search")"
  fi

  write_netplan "$ifc" "$body"
  confirm_apply
}

# ---------------------------------------------------------------------------
# NTP. Two places on purpose: chrony.conf so it takes effect now, and site.yml
# so usg_remediate writes the same thing on the next pull instead of reverting
# to group_vars. The line format is the STIG's, not chrony's default --
# `server <host> iburst maxpoll N` satisfies chronyd_specify_remote_server,
# chronyd_server_directive and chronyd_or_ntpd_set_maxpoll together.
# ---------------------------------------------------------------------------
cmd_ntp() {
  local servers="${1:-}"
  [ -n "$servers" ] || die "usage: it-net ntp <a,b>"
  [ -r "$CHRONY" ] || die "chrony is not installed ($CHRONY missing) -- run the build first"

  local maxpoll s
  maxpoll=$(sed -nE 's/^usg_chrony_maxpoll:\s*//p' "$SITE" 2>/dev/null | tail -1)
  maxpoll="${maxpoll:-16}"

  head2 "Time source"
  printf '  %-10s %s\n' "servers" "$servers"
  printf '  %-10s %s\n' "maxpoll" "$maxpoll"

  backup "$CHRONY"
  # Drop every server/pool line we or a previous run left, then write ours.
  sed -i -E '/^[[:space:]]*(server|pool)[[:space:]]/d' "$CHRONY"
  {
    printf '\n# Managed by it-net (%s). STIG: server + iburst + maxpoll.\n' "$(date -Is)"
    printf '%s\n' "$servers" | tr ',' '\n' | while read -r s; do
      s=$(printf '%s' "$s" | tr -d ' ')
      [ -n "$s" ] && printf 'server %s iburst maxpoll %s\n' "$s" "$maxpoll"
    done
    grep -qE '^\s*makestep' "$CHRONY" || printf 'makestep 1 -1\n'
  } >> "$CHRONY"
  ok "updated $CHRONY"

  # site.yml, so the next pull agrees. Replace an existing block rather than
  # appending a second one -- two usg_chrony_servers keys and the later wins,
  # silently, which is the kind of thing nobody finds for a month.
  install -d -m 2770 -o root -g sudo "$(dirname "$SITE")" 2>/dev/null || true
  [ -f "$SITE" ] || { printf -- '---\n' > "$SITE"; chmod 0660 "$SITE"; }
  backup "$SITE"
  python3 - "$SITE" "$servers" <<'PY'
import re, sys
path, servers = sys.argv[1], [s.strip() for s in sys.argv[2].split(',') if s.strip()]
text = open(path).read()
block = "usg_chrony_servers:\n" + "".join("  - %s\n" % s for s in servers)
# Drop any existing key and the list items under it, then append ours.
text = re.sub(r'(?m)^usg_chrony_servers:\s*\n(?:[ \t]*-[^\n]*\n)*', '', text)
if not text.endswith("\n"):
    text += "\n"
open(path, "w").write(text + block)
PY
  ok "recorded in $SITE (the next pull will keep it)"

  systemctl restart chrony 2>/dev/null || systemctl restart chronyd 2>/dev/null \
    || warn "could not restart chrony -- restart it yourself"
  command -v chronyc >/dev/null 2>&1 && chronyc -n sources 2>/dev/null | sed 's/^/  /' | head -5
  say ""
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# `check` -- the network half of "why is this box slow", in one read-only pass.
#
# It exists because the network faults that hurt a DEPLOYED box are all
# WAITING, not failing, and none of them are visible in `status`: an address is
# configured correctly, a resolver is listed, and every lookup on the box still
# takes five seconds because nothing answers. So this measures rather than
# lists, and prints the milliseconds.
#
# Read-only on purpose. Every finding names the command that fixes it, and
# nothing here reconfigures an interface -- doing that to a box you are on is
# how you end up driving to it.
# ---------------------------------------------------------------------------
FOUND=0
flag() { FOUND=$((FOUND + 1)); }
note() { printf '       %s%s%s\n' "$DIM" "$*" "$R"; }

ms_for() {   # $@ = command -> elapsed milliseconds
  local a b
  a=$(date +%s%N); "$@" >/dev/null 2>&1; b=$(date +%s%N)
  echo $(( (b - a) / 1000000 ))
}

cmd_check() {
  local t host ifc

  head2 "Link"
  if ! command -v ip >/dev/null 2>&1; then
    # Say what is missing rather than reporting "no default route", which is
    # what an absent iproute2 looks like and sends someone reconfiguring an
    # interface that was fine.
    bad "iproute2 is not installed -- cannot read the link state"
    flag
    ifc=""
  else
    ifc="$(default_iface 2>/dev/null || true)"
  fi
  if [ -n "$ifc" ]; then
    ok "$ifc carries the default route -- $(ip -4 addr show "$ifc" 2>/dev/null | awk '/inet /{print $2; exit}')"
    local gw; gw="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
    if [ -n "$gw" ]; then
      if ping -c1 -W1 "$gw" >/dev/null 2>&1; then ok "gateway $gw answers"
      else warn "gateway $gw does not answer a ping"
           note "not conclusive on its own -- many gateways drop ICMP by policy"
      fi
    fi
  elif command -v ip >/dev/null 2>&1; then
    bad "no default route"; flag
    note "set one:  sudo it-net ip <CIDR> --gateway <IP>"
  fi

  # THE ONE THAT MAKES EVERYTHING SLOW. Not "can it resolve" -- how LONG does it
  # take not to. A resolver that is listed but unreachable costs this on every
  # lookup, uncached, and it is paid by sudo, PAM, GNOME, D-Bus and X alike.
  head2 "Name resolution"
  host="$(hostname)"
  t=$(ms_for getent hosts "$host")
  if [ "$t" -gt 100 ]; then
    bad "this box's OWN name took ${t}ms to resolve -- it is going to DNS"
    note "every login, sudo and session start pays this. Fix:  sudo it-repair fix --only slow"
    flag
  else
    ok "own hostname resolves in ${t}ms"
  fi

  t=$(ms_for getent hosts does-not-exist.invalid)
  if [ "$t" -gt 1000 ]; then
    bad "a failed lookup took ${t}ms -- a configured resolver is not answering"
    note "see what is configured:  resolvectl status"
    note "point it somewhere real, or nowhere:  sudo it-net dns <a,b>"
    flag
  else
    ok "failed lookups return in ${t}ms"
  fi

  if command -v resolvectl >/dev/null 2>&1; then
    local srv
    srv="$(resolvectl status 2>/dev/null | awk '/DNS Servers/{$1=$2=""; print; exit}' | xargs)"
    [ -n "$srv" ] && note "resolvers: $srv" || warn "no DNS servers configured"
  fi

  head2 "Time"
  if command -v chronyc >/dev/null 2>&1; then
    local src
    src="$(chronyc -n sources 2>/dev/null | tail -n +3)"
    if [ -z "$src" ]; then
      warn "chrony has no sources"; flag
      note "set one:  sudo it-net ntp <host>"
    elif printf '%s' "$src" | grep -q '^\^\*'; then
      ok "clock is synchronised"
    else
      warn "chrony has sources but none selected -- the box is not synchronised"
      printf '%s\n' "$src" | sed 's/^/       /'
      flag
    fi
  else
    warn "chrony is not installed"
  fi

  head2 "Things that reach for a network that is not there"
  if [ -e /etc/NetworkManager/conf.d/20-no-connectivity-check.conf ]; then
    ok "NetworkManager connectivity check is off"
  elif [ -e /usr/sbin/NetworkManager ]; then
    warn "NetworkManager still probes connectivity.ubuntu.com"
    note "off-network that can only time out:  sudo it-repair fix --only slow"
    flag
  fi
  local u
  for u in systemd-networkd-wait-online.service NetworkManager-wait-online.service; do
    case "$(systemctl is-enabled "$u" 2>/dev/null | head -1)" in
      enabled|enabled-runtime)
        if systemctl is-failed --quiet "$u" 2>/dev/null; then
          bad "$u is enabled and FAILING -- it delays every boot"
          note "sudo it-repair --only net"
          flag
        fi ;;
    esac
  done

  head2 "Summary"
  if [ "$FOUND" -eq 0 ]; then
    ok "nothing here explains a slow box"
    note "if it is still slow, the cause is not the network:  sudo it-repair"
  else
    warn "$FOUND thing(s) to look at -- each is named above"
  fi
  say ""
  [ "$FOUND" -eq 0 ] || return 1
}

case "${1:-status}" in
  status|"") cmd_status ;;
  check)     cmd_check ;;
  ip)        shift; cmd_ip "$@" ;;
  dhcp)      shift; cmd_dhcp "$@" ;;
  dns)       shift; cmd_dns "$@" ;;
  ntp)       shift; cmd_ntp "$@" ;;
  apply)     cmd_apply ;;
  *)         die "unknown command: $1
$(usage)" ;;
esac
