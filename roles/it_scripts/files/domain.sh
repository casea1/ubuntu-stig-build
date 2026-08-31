#!/usr/bin/env bash
# it-domain -- join this box to Active Directory, and check it before you do.
#
# The join itself is one realm command. Everything that goes wrong goes wrong
# BEFORE it -- DNS that does not carry the SRV records, a clock more than five
# minutes out, a blocked port -- or AFTER it, in the PAM stack. This walks both.
#
# READ THIS BEFORE JOINING. `realm join` installs libpam-sss, whose postinst
# runs `pam-auth-update`, which REGENERATES /etc/pam.d/common-auth. This build
# keeps usg_fix_pam_stack false by default because regenerating that file is
# how a box in this fleet became unloggable and needed live-USB recovery.
# `join` therefore backs the PAM stack up first and verifies it after, but you
# should still do it on a throwaway box first and keep a second root TTY open.
#
# Usage:
#   it-domain                    status: joined? sssd healthy? can it resolve a user?
#   it-domain preflight DOMAIN   every check, changing nothing
#   it-domain stage              download the join packages for an OFFLINE join
#   it-domain join DOMAIN        preflight, back up PAM, join, verify
#   it-domain test USER          look a domain user up and show what PAM would do
#   it-domain leave              unjoin, and restore the PAM backup
#   it-domain pam-restore        put the pre-join PAM stack back (recovery)
set -uo pipefail

BACKUP_DIR=/opt/it/domain-backup
LOG=/var/log/it-domain.log
PAM_FILES="/etc/pam.d/common-auth /etc/pam.d/common-account /etc/pam.d/common-password /etc/pam.d/common-session /etc/nsswitch.conf"
JOIN_PKGS="sssd-ad sssd-tools libnss-sss libpam-sss"
STAGE_DIR=/opt/it/ad-packages

[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; R=$'\033[0m'
else B=""; DIM=""; GRN=""; YEL=""; RED=""; R=""; fi
say()  { printf '%s\n' "$*"; }
head2(){ printf '\n%s%s%s\n' "$B" "$*" "$R"; }
ok()   { printf '  %s[ OK ]%s %s\n' "$GRN" "$R" "$*"; }
warn() { printf '  %s[WARN]%s %s\n' "$YEL" "$R" "$*"; }
bad()  { printf '  %s[FAIL]%s %s\n' "$RED" "$R" "$*"; FAILED=$((FAILED+1)); }
die()  { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; logline "ERROR: $*"; exit 1; }
logline(){ printf '%s [%s] %s\n' "$(date -Is)" "${SUDO_USER:-root}" "$*" >> "$LOG" 2>/dev/null; chmod 0640 "$LOG" 2>/dev/null||true; }
FAILED=0

joined_realm() { realm list --name-only 2>/dev/null | head -1; }

# ---------------------------------------------------------------------------
# preflight -- everything that makes a join fail, checked before it can.
# ---------------------------------------------------------------------------
cmd_preflight() {
  local dom="${1:-$(joined_realm)}"
  [ -n "$dom" ] || die "usage: it-domain preflight <domain.example.mil>"
  FAILED=0
  head2 "Pre-flight for $dom"

  # --- the tools -----------------------------------------------------------
  local p
  for p in realm adcli kinit net; do
    command -v "$p" >/dev/null 2>&1 && ok "$p present" || bad "$p MISSING -- the ad_prep_packages set is not installed"
  done

  # --- identity ------------------------------------------------------------
  local fqdn; fqdn=$(hostname -f 2>/dev/null || hostname)
  case "$fqdn" in
    *.*) ok "FQDN is $fqdn" ;;
    *)   warn "hostname '$fqdn' is not fully qualified. AD wants host.domain;"
         say  "         set it in /etc/hostname + /etc/hosts before joining." ;;
  esac

  # --- DNS: the SRV records are what realmd actually discovers -------------
  if command -v dig >/dev/null 2>&1; then
    local srv; srv=$(dig +short -t SRV "_ldap._tcp.$dom" 2>/dev/null)
    if [ -n "$srv" ]; then
      ok "_ldap._tcp.$dom resolves:"
      printf '%s\n' "$srv" | sed 's/^/         /'
    else
      bad "_ldap._tcp.$dom returns NOTHING."
      say "         This box's DNS must be the domain controllers. Check /etc/resolv.conf"
      say "         and 'resolvectl status'. Nothing below will work until it does."
    fi
    # dig EXITS 0 with no records, so the exit code says nothing. Test the
    # output, exactly as the _ldap check above does.
    if [ -n "$(dig +short -t SRV "_kerberos._udp.$dom" 2>/dev/null)" ]; then
      ok "_kerberos._udp.$dom resolves"
    else
      warn "_kerberos._udp.$dom returns nothing -- Kerberos discovery will fall back"
    fi
  else
    warn "dig not installed (dnsutils) -- cannot check the SRV records"
  fi

  # --- clock: Kerberos refuses more than five minutes of skew --------------
  local off; off=$(chronyc tracking 2>/dev/null | awk -F': *' '/System time/{print $2}' | awk '{print $1}')
  if [ -n "$off" ]; then
    local abs; abs=$(printf '%s' "$off" | tr -d -- '-')
    if awk -v a="$abs" 'BEGIN{exit !(a < 60)}' 2>/dev/null; then
      ok "clock within 60s of its time source (offset ${off}s)"
    else
      bad "clock offset is ${off}s. Kerberos rejects more than 300s."
      say "         Point chrony at the domain controllers and let it settle."
    fi
  else
    warn "cannot read chrony tracking -- verify the clock by hand"
  fi
  case "$(grep -hE '^(server|pool)' /etc/chrony/chrony.conf 2>/dev/null | head -3)" in
    "") warn "no server/pool line in chrony.conf" ;;
    *)  say "         ${DIM}time sources: $(grep -hE '^(server|pool)' /etc/chrony/chrony.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')${R}" ;;
  esac

  # --- reachability --------------------------------------------------------
  local dc
  dc=$(dig +short -t SRV "_ldap._tcp.$dom" 2>/dev/null | awk '{print $4}' | sed 's/\.$//' | head -1)
  dc="${dc:-$dom}"
  local port name
  for port in 88:Kerberos 389:LDAP 445:SMB 464:kpasswd 3268:GlobalCatalog; do
    name="${port#*:}"; port="${port%%:*}"
    if timeout 4 bash -c "cat < /dev/null > /dev/tcp/$dc/$port" 2>/dev/null; then
      ok "$dc:$port reachable ($name)"
    else
      bad "$dc:$port NOT reachable ($name)"
    fi
  done

  # --- the firewall on THIS box -------------------------------------------
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ok "ufw active (outbound is allowed by default; a join needs no inbound rule)"
  fi

  # --- what a join will do to PAM -----------------------------------------
  head2 "What the join will change"
  say "  ${DIM}realm join installs $JOIN_PKGS.${R}"
  say "  ${DIM}libpam-sss's postinst runs pam-auth-update, which REGENERATES:${R}"
  local f
  for f in $PAM_FILES; do [ -e "$f" ] && say "    $f"; done
  if command -v pam-auth-check >/dev/null 2>&1; then
    local v; v=$(pam-auth-check 2>&1 | tail -1)
    case "$v" in *OK*) ok "the current PAM stack authenticates ($v)" ;;
                 *)    warn "pam-auth-check says: $v" ;; esac
  fi
  say "  ${DIM}it-domain join backs these up to $BACKUP_DIR first;${R}"
  say "  ${DIM}it-domain pam-restore puts them back.${R}"

  head2 "Result"
  if [ "$FAILED" -eq 0 ]; then
    ok "no blockers found -- a join should succeed"
  else
    bad "$FAILED blocker(s) above. Fix them before joining."
  fi
  logline "preflight $dom: $FAILED blocker(s)"
  [ "$FAILED" -eq 0 ]
}

cmd_stage() {
  head2 "Staging the join packages for an offline join"
  install -d -m 0750 "$STAGE_DIR"
  say "  Downloading: $JOIN_PKGS"
  if apt-get install --reinstall --download-only -y $JOIN_PKGS >/dev/null 2>&1; then
    cp -n /var/cache/apt/archives/*.deb "$STAGE_DIR"/ 2>/dev/null || true
    ok "staged $(ls -1 "$STAGE_DIR"/*.deb 2>/dev/null | wc -l) .deb in $STAGE_DIR"
    say "  ${DIM}Carry these with the box. Install at join time with:${R}"
    say "    sudo apt install $STAGE_DIR/*.deb"
  else
    bad "download failed -- is the box online, or is an apt source unreachable?"
    return 1
  fi
  logline "stage: $(ls -1 "$STAGE_DIR"/*.deb 2>/dev/null | wc -l) packages"
}

backup_pam() {
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  install -d -m 0750 "$BACKUP_DIR"
  local f
  for f in $PAM_FILES; do
    [ -e "$f" ] || continue
    cp -a "$f" "$BACKUP_DIR/$(basename "$f").$ts"
    cp -a "$f" "$BACKUP_DIR/$(basename "$f").latest"
  done
  ok "PAM stack backed up to $BACKUP_DIR (*.latest is what pam-restore uses)"
  logline "pam backup $ts"
}

cmd_pam_restore() {
  local f n=0
  for f in $PAM_FILES; do
    [ -e "$BACKUP_DIR/$(basename "$f").latest" ] || continue
    cp -a "$BACKUP_DIR/$(basename "$f").latest" "$f" && n=$((n+1))
  done
  [ "$n" -gt 0 ] && ok "restored $n file(s) from $BACKUP_DIR" || die "no backup found in $BACKUP_DIR"
  logline "pam-restore: $n file(s)"
}

cmd_join() {
  local dom="${1:-}" admin="${2:-}"
  [ -n "$dom" ] || die "usage: it-domain join <domain.example.mil> [admin-user]"

  cmd_preflight "$dom" || {
    printf '\n  %sPre-flight found blockers.%s\n' "$YEL" "$R"
    printf '  Join anyway? [y/N] '; read -r a
    case "$a" in [Yy]*) ;; *) die "aborted" ;; esac
  }

  head2 "Before we change anything"
  say "  This will regenerate the PAM stack. If it goes wrong you can be locked"
  say "  out of every account on this box."
  say ""
  say "  ${B}Open a second terminal, log in as root, and leave it open.${R}"
  say "  ${DIM}Recovery: sudo it-domain pam-restore${R}"
  say ""
  printf '  Ready to join %s? [y/N] ' "$dom"; read -r a
  case "$a" in [Yy]*) ;; *) die "aborted -- nothing changed" ;; esac

  backup_pam

  [ -n "$admin" ] || { printf '  AD account with rights to join: '; read -r admin; }
  [ -n "$admin" ] || die "an admin account is required"

  head2 "Joining"
  if realm join --user="$admin" "$dom"; then
    ok "joined $dom"
    logline "joined $dom as $admin"
  else
    bad "realm join FAILED -- nothing else was changed. The PAM backup is in $BACKUP_DIR."
    logline "join $dom FAILED"
    return 1
  fi

  head2 "Verifying the PAM stack survived"
  if command -v pam-auth-check >/dev/null 2>&1; then
    local v; v=$(pam-auth-check 2>&1 | tail -1)
    case "$v" in
      *OK*) ok "PAM stack still authenticates ($v)" ;;
      *)    bad "pam-auth-check says: $v"
            say "         ${B}Do not log out.${R} Recover with: sudo it-domain pam-restore" ;;
    esac
  else
    warn "pam-auth-check not installed -- verify a local login on the second TTY NOW"
  fi
  say ""
  say "  ${DIM}Next: it-domain test <a-domain-user>${R}"
  say "  ${DIM}Then decide sudo access -- AD group -> /etc/sudoers.d, or sssd's sudo provider.${R}"
  cmd_status
}

cmd_test() {
  local u="${1:-}"
  [ -n "$u" ] || die "usage: it-domain test <domain-user>"
  head2 "Looking up $u"
  if id "$u" 2>/dev/null; then ok "resolved through NSS"
  else bad "NSS cannot resolve $u -- check 'sssctl user-checks $u' and sssd's logs"; fi
  command -v sssctl >/dev/null 2>&1 && { head2 "What PAM would do"; sssctl user-checks "$u" 2>&1 | sed 's/^/  /' | head -25; }
}

cmd_status() {
  head2 "Domain"
  local r; r=$(joined_realm)
  if [ -n "$r" ]; then
    ok "joined: $r"
    realm list 2>/dev/null | sed 's/^/    /' | head -20
  else
    warn "not joined to any domain"
    say "    ${DIM}Check first: it-domain preflight <domain>   Then: it-domain join <domain>${R}"
  fi
  head2 "SSSD"
  if systemctl list-unit-files sssd.service >/dev/null 2>&1; then
    printf '  %-14s %s\n' "enabled" "$(systemctl is-enabled sssd 2>/dev/null)"
    printf '  %-14s %s\n' "active"  "$(systemctl is-active  sssd 2>/dev/null)"
  else
    say "  ${DIM}sssd not installed (installed at join time)${R}"
  fi
  head2 "Kerberos"
  klist 2>/dev/null | sed 's/^/  /' || say "  ${DIM}no ticket cache for this user${R}"
  head2 "Clock"
  chronyc tracking 2>/dev/null | grep -E 'Reference ID|System time|Stratum' | sed 's/^/  /' \
    || say "  ${DIM}chrony not reporting${R}"
  say ""
}

cmd_leave() {
  local r; r=$(joined_realm)
  [ -n "$r" ] || die "not joined to any domain"
  printf '  Leave %s? Local accounts are unaffected. [y/N] ' "$r"; read -r a
  case "$a" in [Yy]*) ;; *) die "aborted" ;; esac
  realm leave "$r" && ok "left $r" || bad "realm leave failed"
  printf '  Restore the pre-join PAM stack from backup? [Y/n] '; read -r a
  case "$a" in [Nn]*) warn "PAM left as-is" ;; *) cmd_pam_restore ;; esac
  logline "left $r"
}

case "${1:-status}" in
  ""|status)   cmd_status ;;
  preflight)   shift; cmd_preflight "${1:-}" ;;
  stage)       cmd_stage ;;
  join)        shift; cmd_join "${1:-}" "${2:-}" ;;
  test)        shift; cmd_test "${1:-}" ;;
  leave)       cmd_leave ;;
  pam-restore) cmd_pam_restore ;;
  log)         shift; [ -r "$LOG" ] || die "no log at $LOG"; tail -n "${1:-40}" "$LOG" ;;
  -h|--help)   awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0" ;;
  *) die "unknown command: $1  (try --help)" ;;
esac
