#!/usr/bin/env bash
# it-smb -- mount Windows/SMB file shares, and say why when one will not mount.
#
# Shares are systemd AUTOMOUNT units, not fstab entries. Three reasons:
#   * a share that is unreachable at boot cannot delay or block the boot;
#   * it mounts on first access and unmounts when idle, so a server that is
#     down costs nothing until something actually wants the share;
#   * `systemctl status <unit>` and the journal give a real error, where a
#     failed fstab line gives you a boot-time message you will never see.
#
# The units ARE the registry -- there is no second state file to drift out of
# step with what is actually configured.
#
# Credentials live in /etc/stig-build/smb/<name>.cred, root-only 0600, one file per
# share. They are NEVER written to the repo and never leave the box.
#
# Usage:
#   it-smb                       status of every managed share
#   it-smb list                  the same
#   it-smb add                   add a share, interactively
#   it-smb add --name NAME --share //SERVER/SHARE [options]
#        --user U --domain D     credentials (prompted if not given)
#        --mountpoint PATH       default /mnt/smb/<name>
#        --vers 3.1.1|3.0|2.1    SMB dialect (default 3.1.1)
#        --ro                    mount read-only
#        --uid N --gid N         owner of the mounted files (default 0:0)
#        --options "k=v,..."     extra mount options, appended last
#   it-smb test NAME             diagnose: DNS, port 445, credentials, mount
#   it-smb mount NAME|--all
#   it-smb umount NAME|--all
#   it-smb creds NAME            set/replace this share's credentials
#   it-smb remove NAME [--keep-creds]
#   it-smb log [N]               last N lines of the action log (default 40)
set -uo pipefail

MOUNT_ROOT="${IT_SMB_ROOT:-/mnt/smb}"
CRED_DIR="${IT_SMB_CRED_DIR:-/etc/stig-build/smb}"
UNIT_DIR="${IT_SMB_UNIT_DIR:-/etc/systemd/system}"
LOG="${IT_SMB_LOG:-/var/log/it-smb.log}"
MARKER="# Managed by it-smb -- do not edit by hand."

[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; R=$'\033[0m'
else B=""; DIM=""; GRN=""; YEL=""; RED=""; R=""; fi
say()  { printf '%s\n' "$*"; }
head2(){ printf '\n%s%s%s\n' "$B" "$*" "$R"; }
ok()   { printf '  %s%s%s\n' "$GRN" "$*" "$R"; }
warn() { printf '  %s%s%s\n' "$YEL" "$*" "$R"; }
bad()  { printf '  %s%s%s\n' "$RED" "$*" "$R"; }
die()  { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; logline "ERROR: $*"; exit 1; }
logline() { printf '%s [%s] %s\n' "$(date -Is)" "${SUDO_USER:-root}" "$*" >> "$LOG" 2>/dev/null; chmod 0640 "$LOG" 2>/dev/null || true; }

unit_of()  { systemd-escape -p --suffix=mount "$1"; }
amount_of(){ systemd-escape -p --suffix=automount "$1"; }
mp_of()    { printf '%s/%s\n' "$MOUNT_ROOT" "$1"; }
cred_of()  { printf '%s/%s.cred\n' "$CRED_DIR" "$1"; }

# Every managed share, by name. Derived from the units, so it cannot go stale.
shares() {
  local f mp
  for f in "$UNIT_DIR"/*.mount; do
    [ -r "$f" ] || continue
    grep -q "^$MARKER" "$f" || continue
    mp=$(sed -nE 's/^Where=//p' "$f" | tail -1)
    case "$mp" in "$MOUNT_ROOT"/*) basename "$mp" ;; esac
  done | sort -u
}

share_field() {  # name, key -> value from its .mount unit
  local u; u="$UNIT_DIR/$(unit_of "$(mp_of "$1")")"
  [ -r "$u" ] || return 1
  sed -nE "s/^$2=//p" "$u" | tail -1
}

# ---- the interesting part: WHY did it not mount --------------------------
# A cifs mount failure is famously uninformative -- "mount error(13)" and
# nothing else. The detail is in the KERNEL log, not on stderr, so read both
# and translate the status codes into something actionable.
explain_cifs() {  # stderr-text, dmesg-text
  local out="$1$2"
  case "$out" in
    *NT_STATUS_LOGON_FAILURE*|*"error(13)"*Session*|*STATUS_LOGON_FAILURE*)
      bad "Authentication failed -- the username, password or domain is wrong."
      say "    Check with: it-smb creds <name>" ;;
    *NT_STATUS_ACCESS_DENIED*|*STATUS_ACCESS_DENIED*)
      bad "Authenticated, but ACCESS DENIED to that share."
      say "    The account is valid; it lacks permission on the share itself." ;;
    *NT_STATUS_BAD_NETWORK_NAME*|*STATUS_BAD_NETWORK_NAME*|*"error(2)"*)
      bad "The share name does not exist on that server."
      say "    Check the //SERVER/SHARE spelling and that the share is published." ;;
    *NT_STATUS_ACCOUNT_LOCKED_OUT*)  bad "The account is LOCKED OUT on the domain." ;;
    *NT_STATUS_PASSWORD_EXPIRED*)    bad "The account password has EXPIRED." ;;
    *NT_STATUS_ACCOUNT_DISABLED*)    bad "The account is DISABLED." ;;
    *"Host is down"*|*"error(112)"*|*NT_STATUS_HOST_UNREACHABLE*)
      bad "Host is down, or SMB is not answering on port 445." ;;
    *"No route to host"*|*"error(113)"*) bad "No route to the server -- routing or firewall." ;;
    *"Connection timed out"*|*"error(110)"*) bad "Timed out reaching the server." ;;
    *"Name or service not known"*|*"error(-2)"*|*"Unknown host"*)
      bad "The server name did not resolve -- DNS, or use an IP address." ;;
    *"Protocol not supported"*|*NT_STATUS_INVALID_PARAMETER*|*"error(95)"*)
      bad "Dialect negotiation failed."
      say "    The server may not accept this SMB version. Try --vers 3.0 or 2.1."
      say "    Windows servers with SMB1 disabled reject vers=1.0 outright." ;;
    *"Permission denied"*|*"error(1)"*)
      bad "Operation not permitted -- check the credentials file mode and format." ;;
    *"Key has been revoked"*|*"error(128)"*)
      bad "Kernel keyring rejected the credentials (often a FIPS/crypto issue)." ;;
    *"cifs"*"not supported"*|*"unknown filesystem type"*)
      bad "The kernel has no cifs support -- is cifs-utils installed?" ;;
    "") warn "No error text captured. Check: journalctl -u $(unit_of "$(mp_of "$SHARE_NAME")")" ;;
    *)  warn "Unrecognised failure. Raw output below." ;;
  esac
}

diagnose() {  # name -- read-only checks, then a real mount attempt
  local name="$1" server share mp cred out dmesg_before rc
  SHARE_NAME="$name"
  mp=$(mp_of "$name"); cred=$(cred_of "$name")
  local what; what=$(share_field "$name" What) || die "no such share: $name"
  server=$(printf '%s' "$what" | sed -E 's#^//([^/]+)/.*#\1#')
  share=$(printf '%s' "$what" | sed -E 's#^//[^/]+/##')

  head2 "Diagnosing $name  ($what -> $mp)"

  # 1. client present
  if command -v mount.cifs >/dev/null 2>&1; then ok "cifs-utils installed"
  else bad "cifs-utils NOT installed -- apt install cifs-utils"; return 2; fi

  # 2. credentials
  if [ -r "$cred" ]; then
    local mode; mode=$(stat -c %a "$cred")
    [ "$mode" = 600 ] && ok "credentials $cred ($mode)" || warn "credentials $cred is $mode -- should be 0600"
    grep -q '^username=' "$cred" || bad "credentials file has no username= line"
    grep -q '^password=' "$cred" || bad "credentials file has no password= line"
  else
    bad "no credentials at $cred -- run: it-smb creds $name"; return 2
  fi

  # 3. name resolution
  if printf '%s' "$server" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    ok "server is an IP address ($server) -- no DNS needed"
  elif getent hosts "$server" >/dev/null 2>&1; then
    ok "resolves: $server -> $(getent hosts "$server" | awk '{print $1}' | tr '\n' ' ')"
  else
    bad "$server does NOT resolve. DNS, /etc/hosts, or use an IP."
    return 2
  fi

  # 4. is anything listening on 445
  if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$server/445" 2>/dev/null; then
    ok "port 445 reachable"
  else
    bad "port 445 NOT reachable on $server -- server down, or blocked in between."
    say "    Nothing below can succeed until this does."
    return 2
  fi

  # 5. FIPS note. NTLM leans on legacy hashes; on a FIPS kernel that is the
  #    first thing to suspect if auth fails while everything above passed.
  if [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo 0)" = 1 ]; then
    case "$(share_field "$name" Options)" in
      *sec=krb5*) : ;;
      *) warn "FIPS is enabled and this share uses NTLM. If authentication fails"
         say  "    with everything above green, that is the first thing to test." ;;
    esac
  fi

  # 6. the real attempt, with the kernel log captured around it
  head2 "Mount attempt"
  dmesg_before=$(dmesg 2>/dev/null | wc -l)
  out=$(systemctl start "$(unit_of "$mp")" 2>&1); rc=$?
  local kern; kern=$(dmesg 2>/dev/null | tail -n +$((dmesg_before + 1)) | grep -i cifs || true)
  if [ "$rc" -eq 0 ] && mountpoint -q "$mp"; then
    ok "MOUNTED"
    say "    $(findmnt -n -o SOURCE,TARGET,FSTYPE,OPTIONS "$mp" 2>/dev/null | head -1)"
    logline "test $name: mounted OK"
    return 0
  fi
  out="$out
$(systemctl status "$(unit_of "$mp")" --no-pager -l 2>/dev/null | tail -12)"
  explain_cifs "$out" "$kern"
  say ""
  say "  ${DIM}--- raw ---${R}"
  printf '%s\n' "$out" | sed 's/^/    /' | tail -20
  [ -n "$kern" ] && { say "  ${DIM}--- kernel ---${R}"; printf '%s\n' "$kern" | sed 's/^/    /' | tail -10; }
  logline "test $name: FAILED rc=$rc"
  return 1
}

# ---- prompt helpers ---------------------------------------------------------
# Every one of these RE-ASKS on bad input rather than dying. A wizard that
# throws you back to the shell for a typo is worse than the flags it replaces.
# THE PROMPTS GO TO STDERR. The caller captures stdout with $(...), so a
# prompt written to stdout ends up inside the answer -- which is exactly what
# happened the first time this was written: every field came back containing
# the text that asked for it.
ask() {  # prompt, default, validator-fn (optional), hint-on-failure
  local prompt="$1" def="${2:-}" check="${3:-}" hint="${4:-}" ans
  while :; do
    if [ -n "$def" ]; then printf '  %s [%s]: ' "$prompt" "$def" >&2
    else printf '  %s: ' "$prompt" >&2; fi
    read -r ans
    [ -z "$ans" ] && ans="$def"
    if [ -z "$ans" ]; then printf '    %s(required)%s\n' "$YEL" "$R" >&2; continue; fi
    if [ -n "$check" ] && ! $check "$ans"; then
      printf '    %s%s%s\n' "$YEL" "$hint" "$R" >&2; continue
    fi
    printf '%s' "$ans"; return 0
  done
}

ask_optional() {  # prompt -- blank is a valid answer
  local prompt="$1" ans
  printf '  %s: ' "$prompt" >&2; read -r ans; printf '%s' "$ans"
}

ask_yn() {  # prompt, default(y|n) -> 0 yes 1 no
  local prompt="$1" def="${2:-n}" ans hint
  [ "$def" = y ] && hint="[Y/n]" || hint="[y/N]"
  while :; do
    printf '  %s %s ' "$prompt" "$hint"; read -r ans
    ans="${ans:-$def}"
    case "$ans" in [Yy]*) return 0 ;; [Nn]*) return 1 ;;
      *) printf '    %sanswer y or n%s\n' "$YEL" "$R" ;; esac
  done
}

ask_secret() {  # prompt -> masked, asked twice, re-asks until they match
  local prompt="$1" p p2
  while :; do
    printf '  %s: ' "$prompt" >&2; stty -echo 2>/dev/null; read -r p; stty echo 2>/dev/null; echo >&2
    if [ -z "$p" ]; then printf '    %s(required)%s\n' "$YEL" "$R" >&2; continue; fi
    printf '  %s (again): ' "$prompt" >&2; stty -echo 2>/dev/null; read -r p2; stty echo 2>/dev/null; echo >&2
    [ "$p" = "$p2" ] && { printf '%s' "$p"; return 0; }
    printf '    %sthey do not match -- try again%s\n' "$YEL" "$R" >&2
  done
}

v_name()   { printf '%s' "$1" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$' && ! [ -e "$UNIT_DIR/$(unit_of "$(mp_of "$1")")" ]; }
v_server() { printf '%s' "$1" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'; }
v_share()  { printf '%s' "$1" | grep -qE '^[^/\\]+$'; }
v_abspath(){ case "$1" in /*) return 0 ;; *) return 1 ;; esac; }
v_vers()   { printf '%s' "$1" | grep -qE '^(1\.0|2\.0|2\.1|3\.0|3\.02|3\.1\.1)$'; }
v_num()    { printf '%s' "$1" | grep -qE '^[0-9]+$'; }

cmd_creds() {
  local name="${1:-}" cred u p p2 dom
  [ -n "$name" ] || die "usage: it-smb creds <name>"
  cred=$(cred_of "$name")
  head2 "Credentials for $name -> $cred"
  printf '  username: '; read -r u; [ -n "$u" ] || die "username cannot be empty"
  printf '  domain (blank for none): '; read -r dom
  printf '  password: '; stty -echo 2>/dev/null; read -r p; stty echo 2>/dev/null; echo
  printf '  again:    '; stty -echo 2>/dev/null; read -r p2; stty echo 2>/dev/null; echo
  [ "$p" = "$p2" ] || die "passwords do not match"
  [ -n "$p" ] || die "password cannot be empty"
  install -d -m 0700 -o root -g root "$CRED_DIR"
  umask 077
  { printf 'username=%s\n' "$u"; printf 'password=%s\n' "$p"
    [ -n "$dom" ] && printf 'domain=%s\n' "$dom"; } > "$cred"
  chmod 0600 "$cred"; chown root:root "$cred" 2>/dev/null || true
  ok "written 0600 root:root"
  logline "creds set for $name (user=$u domain=${dom:-none})"
}

cmd_add() {
  local name="" what="" mp="" vers="3.1.1" ro=0 uid=0 gid=0 extra="" user="" dom=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) name="${2:?}"; shift 2 ;;
      --share) what="${2:?}"; shift 2 ;;
      --mountpoint) mp="${2:?}"; shift 2 ;;
      --vers) vers="${2:?}"; shift 2 ;;
      --user) user="${2:?}"; shift 2 ;;
      --domain) dom="${2-}"; shift 2 ;;   # may legitimately be empty (workgroup)
      --uid) uid="${2:?}"; shift 2 ;;
      --gid) gid="${2:?}"; shift 2 ;;
      --options) extra="${2-}"; shift 2 ;;
      --ro) ro=1; shift ;;
      *) die "unknown option to add: $1" ;;
    esac
  done

  # ---- interactive: ask for one thing at a time ---------------------------
  # The flags above exist for scripting. A share gets added by hand perhaps
  # twice a year, so the prompts -- not the syntax -- are the real interface.
  local server="" sharename="" wizard=0 pw=""
  if [ -z "$name" ] || [ -z "$what" ]; then
    wizard=1
    head2 "Add an SMB share"
    say "  ${DIM}Enter is the shown default. Ctrl-C to abort -- nothing is written"
    say "  until you confirm at the end.${R}"
    say ""

    name=$(ask "Short name for this share" "" v_name \
      "letters, digits, . _ - only, and not already in use")
    say "    ${DIM}mounts at $(mp_of "$name")${R}"
    say ""

    server=$(ask "File server (hostname or IP)" "" v_server "hostname or IP, no slashes")
    # Probe NOW, before they type a password -- finding out the server is
    # unreachable after entering credentials wastes the operator's time.
    if printf '%s' "$server" | grep -qE '^[0-9.]+$' || getent hosts "$server" >/dev/null 2>&1; then
      if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$server/445" 2>/dev/null; then
        ok "$server is reachable on port 445"
      else
        warn "$server resolves but is NOT answering on port 445"
        say "    ${DIM}Carry on if the server is simply down for now -- the automount"
        say "    will pick it up when it returns.${R}"
      fi
    else
      warn "$server does not resolve right now"
      say "    ${DIM}Fine if DNS is not up yet; otherwise use an IP address.${R}"
    fi
    say ""

    sharename=$(ask "Share name on that server" "" v_share "just the share name, e.g. audit\$ or Engineering")
    what="//$server/$sharename"
    say ""

    user=$(ask "Username to connect as" "" "" "")
    dom=$(ask_optional "Domain (blank for a workgroup / local account)")
    pw=$(ask_secret "Password")
    say ""

    mp=$(ask "Mount point" "$(mp_of "$name")" v_abspath "must be an absolute path")
    ask_yn "Mount read-only?" n && ro=1 || ro=0
    vers=$(ask "SMB version" "$vers" v_vers "one of 1.0 2.0 2.1 3.0 3.02 3.1.1")

    if ask_yn "Set advanced options (file owner, extra mount options)?" n; then
      uid=$(ask "Owner uid for the mounted files" "0" v_num "a number")
      gid=$(ask "Owner gid" "0" v_num "a number")
      extra=$(ask_optional "Extra mount options (comma-separated, blank for none)")
    fi

    # ---- confirm before anything is written ------------------------------
    head2 "Review"
    printf '  %-16s %s\n' "name"        "$name"
    printf '  %-16s %s\n' "share"       "$what"
    printf '  %-16s %s\n' "mount point" "$mp"
    printf '  %-16s %s%s\n' "user"      "${dom:+$dom\\}" "$user"
    printf '  %-16s %s\n' "access"      "$([ "$ro" -eq 1 ] && echo read-only || echo read-write)"
    printf '  %-16s %s\n' "SMB version" "$vers"
    printf '  %-16s %s:%s\n' "files owned by" "$uid" "$gid"
    [ -n "$extra" ] && printf '  %-16s %s\n' "extra options" "$extra"
    printf '  %-16s %s\n' "credentials" "$(cred_of "$name")"
    say ""
    ask_yn "Write this?" y || { say "  ${DIM}Nothing written.${R}"; return 1; }
  fi
  [ -n "$name" ] || die "a name is required"
  printf '%s' "$name" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$' \
    || die "name must be alphanumeric with . _ - only (it becomes a directory and a unit name)"
  printf '%s' "$what" | grep -qE '^//[^/]+/.+' || die "share must look like //SERVER/SHARE"
  mp="${mp:-$(mp_of "$name")}"

  local cred; cred=$(cred_of "$name")
  if [ "$wizard" -eq 1 ]; then
    install -d -m 0700 -o root -g root "$CRED_DIR"; umask 077
    { printf 'username=%s\n' "$user"; printf 'password=%s\n' "$pw"
      [ -n "$dom" ] && printf 'domain=%s\n' "$dom"; } > "$cred"
    chmod 0600 "$cred"; chown root:root "$cred" 2>/dev/null || true
    ok "credentials written 0600 root:root"
  elif [ ! -r "$cred" ]; then
    if [ -n "$user" ]; then
      local p p2
      printf '  password for %s: ' "$user"; stty -echo 2>/dev/null; read -r p; stty echo 2>/dev/null; echo
      printf '  again:            '; stty -echo 2>/dev/null; read -r p2; stty echo 2>/dev/null; echo
      [ "$p" = "$p2" ] || die "passwords do not match"
      install -d -m 0700 -o root -g root "$CRED_DIR"; umask 077
      { printf 'username=%s\n' "$user"; printf 'password=%s\n' "$p"
        [ -n "$dom" ] && printf 'domain=%s\n' "$dom"; } > "$cred"
      chmod 0600 "$cred"
    else
      cmd_creds "$name"
    fi
  else
    ok "using existing credentials at $cred"
  fi

  local opts="credentials=$cred,vers=$vers,uid=$uid,gid=$gid,file_mode=0640,dir_mode=0750,iocharset=utf8,_netdev,nofail"
  [ "$ro" -eq 1 ] && opts="$opts,ro"
  [ -n "$extra" ] && opts="$opts,$extra"

  install -d -m 0755 "$MOUNT_ROOT"
  install -d -m 0750 "$mp"

  local mu au; mu="$UNIT_DIR/$(unit_of "$mp")"; au="$UNIT_DIR/$(amount_of "$mp")"
  cat > "$mu" <<EOF
$MARKER
[Unit]
Description=SMB share $name ($what)
After=network-online.target
Wants=network-online.target

[Mount]
What=$what
Where=$mp
Type=cifs
Options=$opts
TimeoutSec=30

[Install]
WantedBy=multi-user.target
EOF
  cat > "$au" <<EOF
$MARKER
[Unit]
Description=Automount for SMB share $name

[Automount]
Where=$mp
TimeoutIdleSec=600

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$mu" "$au"
  systemctl daemon-reload
  systemctl enable --now "$(amount_of "$mp")" >/dev/null 2>&1 \
    && ok "automount enabled -- the share mounts on first access" \
    || warn "could not enable the automount unit; see: systemctl status $(amount_of "$mp")"
  logline "add $name -> $what at $mp (vers=$vers ro=$ro)"
  say ""
  if [ "$wizard" -eq 1 ] && ask_yn "Test the mount now?" y; then
    diagnose "$name"
  else
    say "  ${DIM}Prove it: it-smb test $name${R}"
  fi
}

cmd_status() {
  local n what mp state
  head2 "SMB shares"
  local any=0
  for n in $(shares); do
    any=1
    mp=$(mp_of "$n"); what=$(share_field "$n" What)
    if mountpoint -q "$mp" 2>/dev/null; then
      state="${GRN}MOUNTED${R}"
    elif systemctl is-enabled --quiet "$(amount_of "$mp")" 2>/dev/null; then
      state="${DIM}idle (automount armed)${R}"
    else
      state="${YEL}not enabled${R}"
    fi
    printf '  %-18s %-34s %b\n' "$n" "$what" "$state"
    printf '    %smount %s   creds %s%s\n' "$DIM" "$mp" \
      "$([ -r "$(cred_of "$n")" ] && echo "$(cred_of "$n")" || echo MISSING)" "$R"
    if mountpoint -q "$mp" 2>/dev/null; then
      printf '    %s%s%s\n' "$DIM" "$(df -h --output=size,used,avail,pcent "$mp" 2>/dev/null | tail -1 | tr -s ' ')" "$R"
    fi
  done
  [ "$any" -eq 1 ] || say "  ${DIM}none configured -- add one with: it-smb add${R}"
  head2 "All CIFS mounts on this box (including any not managed here)"
  findmnt -t cifs -o SOURCE,TARGET,OPTIONS 2>/dev/null | sed 's/^/  /' || say "  ${DIM}none${R}"
  say ""
  say "  ${DIM}Diagnose one: it-smb test <name>     Log: it-smb log${R}"
  say ""
}

cmd_mount()  { local n="$1"; systemctl start  "$(unit_of "$(mp_of "$n")")" && ok "mounted $n" || { bad "failed -- diagnosing"; diagnose "$n"; }; }
cmd_umount() { local n="$1"; systemctl stop   "$(unit_of "$(mp_of "$n")")" && ok "unmounted $n" || bad "could not unmount $n"; }

cmd_remove() {
  local name="${1:-}" keep=0
  [ -n "$name" ] || die "usage: it-smb remove <name> [--keep-creds]"
  [ "${2:-}" = "--keep-creds" ] && keep=1
  local mp; mp=$(mp_of "$name")
  systemctl disable --now "$(amount_of "$mp")" >/dev/null 2>&1
  systemctl stop "$(unit_of "$mp")" >/dev/null 2>&1
  rm -f "$UNIT_DIR/$(unit_of "$mp")" "$UNIT_DIR/$(amount_of "$mp")"
  systemctl daemon-reload
  rmdir "$mp" 2>/dev/null || true
  if [ "$keep" -eq 0 ]; then
    shred -u "$(cred_of "$name")" 2>/dev/null || rm -f "$(cred_of "$name")"
    ok "removed $name and its credentials"
  else
    ok "removed $name (credentials kept at $(cred_of "$name"))"
  fi
  logline "remove $name (keep-creds=$keep)"
}

case "${1:-status}" in
  ""|status|list) cmd_status ;;
  add)     shift; cmd_add "$@" ;;
  test)    shift; [ -n "${1:-}" ] || die "usage: it-smb test <name>"; diagnose "$1" ;;
  creds)   shift; cmd_creds "${1:-}" ;;
  mount)   shift; [ "${1:-}" = "--all" ] && { for n in $(shares); do cmd_mount "$n"; done; } || cmd_mount "${1:?usage: it-smb mount <name>|--all}" ;;
  umount)  shift; [ "${1:-}" = "--all" ] && { for n in $(shares); do cmd_umount "$n"; done; } || cmd_umount "${1:?usage: it-smb umount <name>|--all}" ;;
  remove)  shift; cmd_remove "$@" ;;
  log)     shift; [ -r "$LOG" ] || die "no log at $LOG"; tail -n "${1:-40}" "$LOG" ;;
  -h|--help) awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0" ;;
  *) die "unknown command: $1  (try --help)" ;;
esac
