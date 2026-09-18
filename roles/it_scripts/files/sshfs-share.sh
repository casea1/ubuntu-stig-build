#!/usr/bin/env bash
# it-sshfs -- mount a remote folder over SSH, and say why when one will not.
#
# WHY THIS EXISTS. On a FIPS box there is no SMB path to a Windows file server
# that is not domain-joined. NTLMv2 is built on MD5, FIPS removes MD5 from the
# kernel crypto API, and `sec=none` does not avoid it -- SMB2 and SMB3 carry
# even an anonymous session over NTLMSSP, so the client reaches for HMAC-MD5
# whatever sec= says. Confirmed against the deployed server at every dialect.
# Kerberos is the answer and needs a KDC, which arrives with the domain
# controller. SSH needs nothing, uses FIPS-approved crypto, and works today.
#
# It is also the same SHAPE as the eventual Kerberos design -- one machine
# credential, one mount, group access -- so when the DC lands the transport
# changes and the access model does not.
#
# Usage:
#   it-sshfs                     status of every managed share
#   it-sshfs list                the same
#   it-sshfs add --name NAME --remote USER@HOST:/PATH [options]
#        A Windows path keeps its drive letter: /C:/Shares/Sentry. If it
#        contains a space, QUOTE THE WHOLE --remote argument:
#          --remote 'svc_share@10.0.0.5:/E:/Shared Folders/Sentry_Share'
#        --group NAME            members of NAME may use the mount (default: root only)
#        --mountpoint PATH       default /media/<name>
#        --port N                ssh port (default 22)
#        --ro                    mount read-only
#        --uid N --gid N         owner of the mounted files (default 0:0)
#        --options "k=v,..."     extra sshfs options, appended last
#   it-sshfs key NAME            print the PUBLIC key to install on the server
#   it-sshfs test NAME           DNS, port, host key, key auth, sftp, then a mount
#   it-sshfs mount NAME|--all
#   it-sshfs umount NAME|--all
#   it-sshfs remove NAME [--keep-key]
#
# Shares are systemd AUTOMOUNT units, for the same three reasons as it-smb: a
# server that is down cannot delay the boot, the mount happens on first access
# and goes away when idle, and a failure leaves a real error in the journal
# instead of a boot-time message nobody sees.
#
# WHAT THIS DESIGN GIVES UP: PER-USER ATTRIBUTION. One machine credential and
# `allow_other` means every file under the mount appears owned by the single
# uid/gid the mount was given, and the server sees every write as the service
# account. That is right for a shared team folder and wrong for home
# directories or anywhere an audit needs to say WHICH person wrote a file. If
# you need that before the domain controller lands, use one share per person
# with their own key rather than one shared mount; afterwards, SMB with
# sec=krb5,multiuser gives each user their own ticket and is the better answer.
#
# NFS is not an alternative here. NFSv3/v4 with sec=sys does no cryptography at
# all, so FIPS does not block it -- and it authenticates nobody: the client
# asserts a uid and the server believes it. NFS with sec=krb5 needs the same KDC
# that SMB does, so it solves nothing sooner.
#
# THE PRIVATE KEY NEVER LEAVES THE BOX. It is generated here, 0600 root-only,
# and only the public half is ever printed. There is no password on disk.
set -uo pipefail

MOUNT_ROOT="${IT_SSHFS_ROOT:-/media}"
KEY_DIR="${IT_SSHFS_KEY_DIR:-/etc/stig-build/ssh}"
KNOWN_HOSTS="${IT_SSHFS_KNOWN_HOSTS:-$KEY_DIR/known_hosts}"
UNIT_DIR="${IT_SSHFS_UNIT_DIR:-/etc/systemd/system}"
LOG="${IT_SSHFS_LOG:-/var/log/it-sshfs.log}"
MARKER="# Managed by it-sshfs -- do not edit by hand."
NAME_TAG="# it-sshfs-name:"

[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; R=$'\033[0m'
else B=""; DIM=""; GRN=""; YEL=""; RED=""; R=""; fi
say()  { printf '%s\n' "$*"; }
head2(){ printf '\n%s%s%s\n' "$B" "$*" "$R"; }
ok()   { printf '  %s%s%s\n' "$GRN" "$*" "$R"; }
warn() { printf '  %s%s%s\n' "$YEL" "$*" "$R"; }
bad()  { printf '  %s%s%s\n' "$RED" "$*" "$R"; }
note() { printf '       %s%s%s\n' "$DIM" "$*" "$R"; }
logline() { printf '%s [%s] %s\n' "$(date -Is)" "${SUDO_USER:-root}" "$*" >> "$LOG" 2>/dev/null; chmod 0640 "$LOG" 2>/dev/null || true; }
die()  { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; logline "ERROR: $*"; exit 1; }
usage(){ awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }
case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac

unit_of()  { systemd-escape -p --suffix=mount "$1"; }
amount_of(){ systemd-escape -p --suffix=automount "$1"; }
key_of()   { printf '%s/%s\n' "$KEY_DIR" "$1"; }

# The unit records its own name, so a --mountpoint anywhere stays manageable.
# it-smb learned this the hard way: deriving the name from the path means the
# one option that moves a share is also the one that hides it.
shares() {
  local f n
  for f in "$UNIT_DIR"/*.mount; do
    [ -r "$f" ] || continue
    grep -q "^$MARKER" "$f" || continue
    n=$(sed -nE "s|^$NAME_TAG[[:space:]]*||p" "$f" | tail -1)
    [ -n "$n" ] && printf '%s\n' "$n"
  done | sort -u
}
mp_of() {
  local f
  for f in "$UNIT_DIR"/*.mount; do
    [ -r "$f" ] || continue
    grep -q "^$MARKER" "$f" || continue
    [ "$(sed -nE "s|^$NAME_TAG[[:space:]]*||p" "$f" | tail -1)" = "$1" ] || continue
    sed -nE 's/^Where=//p' "$f" | tail -1
    return 0
  done
  printf '%s/%s\n' "$MOUNT_ROOT" "$1"
}
share_field() {
  local u; u="$UNIT_DIR/$(unit_of "$(mp_of "$1")")"
  [ -r "$u" ] || return 1
  sed -nE "s/^$2=//p" "$u" | tail -1
}
have_share() { shares | grep -qx "$1"; }

split_remote() {   # USER@HOST:/PATH -> sets R_USER R_HOST R_PATH
  local r="$1"
  case "$r" in
    *@*:*) R_USER="${r%%@*}"; r="${r#*@}"; R_HOST="${r%%:*}"; R_PATH="${r#*:}" ;;
    *) die "remote must look like USER@HOST:/PATH  (got: $r)" ;;
  esac
  [ -n "$R_USER" ] && [ -n "$R_HOST" ] && [ -n "$R_PATH" ] \
    || die "remote must look like USER@HOST:/PATH  (got: $1)"
}

# ---- status ---------------------------------------------------------------
cmd_list() {
  local n mp what st
  head2 "SSH shares"
  if [ -z "$(shares)" ]; then
    note "none configured yet.  it-sshfs add --name NAME --remote USER@HOST:/PATH"
    say ""; return 0
  fi
  for n in $(shares); do
    mp="$(mp_of "$n")"
    what="$(share_field "$n" What)"
    st="$(systemctl is-active "$(unit_of "$mp")" 2>/dev/null || true)"
    printf '  %-18s %-34s %-22s %s\n' "$n" "$what" "$mp" "${st:-unknown}"
  done
  say ""
  note "mounts happen on first access; 'inactive' is normal for an idle share."
  say ""
}

# ---- add ------------------------------------------------------------------
cmd_add() {
  local name="" remote="" group="" mp="" port=22 ro=0 uid=0 gid=0 extra=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)       name="${2:?}"; shift 2 ;;
      --remote)     remote="${2:?}"; shift 2 ;;
      --group)      group="${2:?}"; shift 2 ;;
      --mountpoint) mp="${2:?}"; shift 2 ;;
      --port)       port="${2:?}"; shift 2 ;;
      --ro)         ro=1; shift ;;
      --uid)        uid="${2:?}"; shift 2 ;;
      --gid)        gid="${2:?}"; shift 2 ;;
      --options)    extra="${2:?}"; shift 2 ;;
      *) die "unknown option: $1
$(usage)" ;;
    esac
  done
  [ -n "$name" ]   || die "--name is required"
  [ -n "$remote" ] || die "--remote USER@HOST:/PATH is required"
  case "$name" in *[!A-Za-z0-9_-]*) die "--name may only contain letters, digits, _ and -" ;; esac
  have_share "$name" && die "a share named '$name' already exists. Remove it first, or pick another name."

  command -v sshfs >/dev/null 2>&1 || die "sshfs is not installed:  sudo apt-get install sshfs"
  split_remote "$remote"
  case "$R_PATH" in
    *'"'*) die "the remote path contains a double quote, which cannot be passed
safely to sftp. Rename the folder on the server." ;;
  esac
  [ -n "$mp" ] || mp="$MOUNT_ROOT/$name"

  head2 "Adding $name"
  printf '  %-12s %s\n' "remote" "$R_USER@$R_HOST:$R_PATH"
  printf '  %-12s %s\n' "port" "$port"
  printf '  %-12s %s\n' "mountpoint" "$mp"

  # ---- key ----------------------------------------------------------------
  local key; key="$(key_of "$name")"
  install -d -m 0700 "$KEY_DIR"
  if [ -f "$key" ]; then
    ok "reusing the existing key at $key"
  else
    ssh-keygen -t ed25519 -N '' -C "it-sshfs $name $(hostname -s)" -f "$key" >/dev/null \
      || die "could not generate a key"
    chmod 0600 "$key"; chmod 0644 "$key.pub"
    ok "generated $key  (private key stays on this box)"
  fi

  # ---- host key -----------------------------------------------------------
  # Pinned deliberately rather than accepted blindly. An unattended mount that
  # trusts whatever answers on port 22 is a man-in-the-middle waiting to happen,
  # and StrictHostKeyChecking=no would do exactly that.
  if ! ssh-keygen -F "[$R_HOST]:$port" -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
    say ""
    say "  Fetching the server's host key. CHECK THIS FINGERPRINT against the"
    say "  server before accepting it -- on Windows:  ssh-keygen -lf C:\\ProgramData\\ssh\\ssh_host_ed25519_key.pub"
    say ""
    local tmp; tmp="$(mktemp)"
    ssh-keyscan -p "$port" -H "$R_HOST" > "$tmp" 2>/dev/null
    [ -s "$tmp" ] || { rm -f "$tmp"; die "no SSH server answered on $R_HOST:$port"; }
    ssh-keygen -lf "$tmp" | sed 's/^/    /'
    say ""
    read -r -p "  Accept this host key? [y/N] " a
    case "$a" in y|Y) ;; *) rm -f "$tmp"; die "  aborted -- nothing was configured." ;; esac
    cat "$tmp" >> "$KNOWN_HOSTS"; rm -f "$tmp"
    chmod 0644 "$KNOWN_HOSTS"
    ok "host key pinned in $KNOWN_HOSTS"
  else
    ok "host key already pinned"
  fi

  # ---- access model -------------------------------------------------------
  # allow_other is what makes ONE machine-authenticated mount usable by every
  # entitled person; without it only root sees the mount. default_permissions
  # makes the kernel enforce the uid/gid/modes below rather than letting the
  # remote server's idea of ownership decide.
  local fmode=0640 dmode=0750
  if [ -n "$group" ]; then
    local ggid; ggid=$(getent group "$group" 2>/dev/null | cut -d: -f3)
    [ -n "$ggid" ] || die "group '$group' does not exist on this box"
    gid="$ggid"
    if [ "$ro" -eq 1 ]; then fmode=0640; dmode=0750; else fmode=0664; dmode=0775; fi
  fi
  if ! grep -qE '^[[:space:]]*user_allow_other' /etc/fuse.conf 2>/dev/null; then
    printf 'user_allow_other\n' >> /etc/fuse.conf
    ok "enabled user_allow_other in /etc/fuse.conf (needed for allow_other)"
  fi

  local opts="IdentityFile=$key,UserKnownHostsFile=$KNOWN_HOSTS,StrictHostKeyChecking=yes"
  opts="$opts,port=$port,allow_other,default_permissions,uid=$uid,gid=$gid"
  opts="$opts,idmap=none,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3"
  opts="$opts,_netdev,nofail"
  [ "$ro" -eq 1 ] && opts="$opts,ro"
  [ -n "$extra" ] && opts="$opts,$extra"

  install -d -m 0755 "$MOUNT_ROOT"
  if [ -n "$group" ]; then install -d -m 0755 -g "$group" "$mp" 2>/dev/null || install -d -m 0755 "$mp"
  else install -d -m 0750 "$mp"; fi

  local mu au; mu="$UNIT_DIR/$(unit_of "$mp")"; au="$UNIT_DIR/$(amount_of "$mp")"
  cat > "$mu" <<EOF
$MARKER
$NAME_TAG $name
[Unit]
Description=SSH share $name ($R_USER@$R_HOST:$R_PATH)
After=network-online.target
Wants=network-online.target

[Mount]
What=$R_USER@$R_HOST:$R_PATH
Where=$mp
Type=fuse.sshfs
Options=$opts
TimeoutSec=30

[Install]
WantedBy=multi-user.target
EOF
  cat > "$au" <<EOF
$MARKER
$NAME_TAG $name
[Unit]
Description=Automount for SSH share $name

[Automount]
Where=$mp
TimeoutIdleSec=600

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$mu" "$au"
  systemctl daemon-reload
  systemctl enable --now "$(amount_of "$mp")" >/dev/null 2>&1 \
    && ok "automount enabled -- it mounts on first access" \
    || warn "could not enable the automount; see: systemctl status $(amount_of "$mp")"
  logline "added $name -> $R_USER@$R_HOST:$R_PATH at $mp"

  say ""
  say "  ${B}NEXT: install this box's public key on the server.${R}"
  say ""
  cat "$key.pub" | sed 's/^/    /'
  say ""
  note "On Windows, as the service account (NOT an administrator -- admins use"
  note "C:\\ProgramData\\ssh\\administrators_authorized_keys instead, which trips"
  note "everyone up), append that line to:"
  note "    C:\\Users\\$R_USER\\.ssh\\authorized_keys"
  note ""
  note "Then:  sudo it-sshfs test $name"
  say ""
}

# ---- key ------------------------------------------------------------------
cmd_key() {
  local n="${1:-}"
  [ -n "$n" ] || die "usage: it-sshfs key NAME"
  local key; key="$(key_of "$n")"
  [ -f "$key.pub" ] || die "no key for '$n' at $key.pub"
  cat "$key.pub"
}

# ---- test -----------------------------------------------------------------
# Each step is a different failure with a different fix, so they are reported
# separately rather than as one "it did not work".
cmd_test() {
  local n="${1:-}" rc=0
  [ -n "$n" ] || die "usage: it-sshfs test NAME"
  have_share "$n" || die "no share named '$n'.
configured: $(shares | paste -sd' ' - || echo none)"

  local what mp key host port user path
  what="$(share_field "$n" What)"; mp="$(mp_of "$n")"; key="$(key_of "$n")"
  user="${what%%@*}"; host="${what#*@}"; host="${host%%:*}"; path="${what#*:}"
  port="$(share_field "$n" Options | tr ',' '\n' | sed -nE 's/^port=//p' | tail -1)"; port="${port:-22}"

  head2 "$n -> $what"

  if getent hosts "$host" >/dev/null 2>&1 || [[ "$host" =~ ^[0-9.]+$ ]]; then
    ok "host resolves: $host"
  else
    bad "cannot resolve $host"; note "fix DNS, or use the IP address"; rc=1
  fi

  if timeout 5 bash -c ">/dev/tcp/$host/$port" 2>/dev/null; then
    ok "port $port is open"
  else
    bad "nothing is listening on $host:$port"
    note "on Windows:  Get-Service sshd   /   New-NetFirewallRule ... -LocalPort 22"
    rc=1
  fi

  [ -f "$key" ] && ok "private key present: $key" || { bad "no private key at $key"; rc=1; }

  if ssh-keygen -F "[$host]:$port" -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
    ok "host key is pinned"
  else
    bad "host key is NOT pinned -- the mount will refuse to connect"
    note "re-add the share, or: ssh-keyscan -p $port -H $host >> $KNOWN_HOSTS"
    rc=1
  fi

  # The decisive one: can this key actually log in?
  local out
  out="$(ssh -n -o BatchMode=yes -o ConnectTimeout=8 \
            -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=yes \
            -i "$key" -p "$port" "$user@$host" "exit" 2>&1)"
  if [ $? -eq 0 ]; then
    ok "key authentication works as $user"
  else
    bad "key authentication FAILED as $user"
    printf '%s\n' "$out" | sed 's/^/       /'
    note "the public key must be in the server's authorized_keys for THAT user:"
    note "  it-sshfs key $n"
    note "Windows puts a normal user's keys in C:\\Users\\$user\\.ssh\\authorized_keys"
    note "and an ADMINISTRATOR's in C:\\ProgramData\\ssh\\administrators_authorized_keys."
    note "A service account should not be an administrator."
    rc=1
  fi

  if [ "$rc" = 0 ]; then
    # `cd "<path>"` in a batch rather than user@host:path on the command line:
    # sftp splits its own commands on whitespace, so an unquoted path containing
    # a space becomes two arguments and the cd fails on a directory that exists.
    if printf 'cd "%s"\nls\nquit\n' "$path" | timeout 15 sftp -q -b - \
         -o BatchMode=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
         -o StrictHostKeyChecking=yes -i "$key" -P "$port" "$user@$host" >/dev/null 2>&1; then
      ok "the remote path exists and is readable: $path"
    else
      bad "cannot list $path as $user"
      note "check the path and that the account has NTFS permissions on it."
      note "Windows paths look like /C:/Shares/Name, and a drive other than C:"
      note "is the same shape: /E:/Shared Folders/Sentry_Share"
      rc=1
    fi
  fi

  head2 "Mount"
  if mountpoint -q "$mp"; then
    ok "already mounted at $mp"
    ls -A "$mp" 2>/dev/null | head -5 | sed 's/^/       /'
  elif [ "$rc" = 0 ]; then
    if systemctl start "$(unit_of "$mp")" 2>/dev/null && mountpoint -q "$mp"; then
      ok "mounted at $mp"
      ls -A "$mp" 2>/dev/null | head -5 | sed 's/^/       /'
    else
      bad "the mount unit failed"
      journalctl -u "$(unit_of "$mp")" -n 12 --no-pager 2>/dev/null | sed 's/^/       /'
      rc=1
    fi
  else
    warn "not attempting the mount while the checks above are failing"
  fi
  say ""
  return "$rc"
}

# ---- mount / umount / remove ---------------------------------------------
cmd_mount() {
  local n="${1:-}"
  [ -n "$n" ] || die "usage: it-sshfs mount NAME|--all"
  if [ "$n" = --all ]; then for n in $(shares); do cmd_mount "$n"; done; return 0; fi
  have_share "$n" || die "no share named '$n'"
  local mp; mp="$(mp_of "$n")"
  systemctl start "$(unit_of "$mp")" 2>/dev/null && mountpoint -q "$mp" \
    && ok "$n mounted at $mp" \
    || { bad "$n did not mount"; journalctl -u "$(unit_of "$mp")" -n 10 --no-pager | sed 's/^/       /'; return 1; }
}
cmd_umount() {
  local n="${1:-}"
  [ -n "$n" ] || die "usage: it-sshfs umount NAME|--all"
  if [ "$n" = --all ]; then for n in $(shares); do cmd_umount "$n"; done; return 0; fi
  have_share "$n" || die "no share named '$n'"
  local mp; mp="$(mp_of "$n")"
  systemctl stop "$(unit_of "$mp")" 2>/dev/null && ok "$n unmounted" || warn "$n was not mounted"
}
cmd_remove() {
  local n="${1:-}" keep=0
  [ -n "$n" ] || die "usage: it-sshfs remove NAME [--keep-key]"
  case "${2:-}" in --keep-key) keep=1 ;; esac
  have_share "$n" || die "no share named '$n'"
  local mp; mp="$(mp_of "$n")"
  systemctl disable --now "$(amount_of "$mp")" >/dev/null 2>&1 || true
  systemctl stop "$(unit_of "$mp")" >/dev/null 2>&1 || true
  rm -f "$UNIT_DIR/$(unit_of "$mp")" "$UNIT_DIR/$(amount_of "$mp")"
  systemctl daemon-reload
  rmdir "$mp" 2>/dev/null || true
  ok "removed $n"
  if [ "$keep" = 0 ]; then
    rm -f "$(key_of "$n")" "$(key_of "$n").pub"
    ok "removed its key"
    note "the public key is still in the server's authorized_keys -- remove it there too"
  fi
  logline "removed $n"
}

case "${1:-list}" in
  list|status|"") cmd_list ;;
  add)     shift; cmd_add "$@" ;;
  key)     shift; cmd_key "${1:-}" ;;
  test)    shift; cmd_test "${1:-}" ;;
  mount)   shift; cmd_mount "${1:-}" ;;
  umount)  shift; cmd_umount "${1:-}" ;;
  remove)  shift; cmd_remove "${1:-}" "${2:-}" ;;
  log)     shift; tail -n "${1:-30}" "$LOG" 2>/dev/null || echo "(no log yet)" ;;
  *) die "unknown command: $1
$(usage)" ;;
esac
