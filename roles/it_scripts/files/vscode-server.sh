#!/usr/bin/env bash
# it-vscode-server -- stage Microsoft's VS Code Server for Remote-SSH, offline.
#
# Engineers connect from Microsoft's desktop VS Code on their own PC (Remote-SSH).
# VS Code then looks on this box for a server built for EXACTLY its own version,
# and on an air-gapped box it cannot download one. This installs ONE shared,
# read-only copy per version under /opt/vscode-server and links each engineer's
# ~/.vscode-server to it, instead of a 215 MB unpack per person.
#
# Usage:
#   it-vscode-server                     what is staged, who is linked, and checks
#   it-vscode-server status              ...the same
#   it-vscode-server stage <path>...     install a version carried in on media,
#                                        then link everyone. <path> is a folder
#                                        holding the downloads, or the files:
#                                          vscode-server-linux-x64.tar.gz   (required)
#                                          vscode_cli_alpine_x64_cli.tar.gz (optional)
#       --group G                        who gets linked (default: sentry)
#       --user U                         link only this person
#       --no-link                        install into /opt, link nobody
#       --force                          replace an already-staged copy of that version
#   it-vscode-server link   [--user U | --group G]
#                                        (re)create the links -- after adding someone
#   it-vscode-server unlink [--user U] [<version|commit>]
#   it-vscode-server remove <version|commit> [--force]
#                                        unlink everyone, delete it from /opt
#   it-vscode-server urls <version|commit>
#                                        what to download on an online machine
#   it-vscode-server settings            what each PC's settings.json needs
#
# BOTH Remote-SSH layouts are staged, so it works whichever mode the PC uses:
#   ~/.vscode-server/bin/<commit>                      remote.SSH.useExecServer: false
#   ~/.vscode-server/code-<commit>                     the default mode's CLI (a FILE)
#   ~/.vscode-server/cli/servers/Stable-<commit>/server   ...and its server
# The first is the one confirmed against Microsoft's own installer end to end,
# so `useExecServer: false` is what `settings` recommends.
#
# The version is read from the server's own product.json, never typed: a wrong
# commit in a folder name is the whole failure this exists to prevent. When the
# CLI is supplied too, its commit must match or nothing is installed.
set -uo pipefail

ROOT="${IT_VSCODE_SERVER_ROOT:-/opt/vscode-server}"
DEFAULT_GROUP=sentry

[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

if [ -t 1 ]; then
  B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'; RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'
else
  B=""; DIM=""; R=""; RED=""; GRN=""; YEL=""
fi
say()   { printf '%s\n' "$*"; }
head2() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }
ok()    { printf '  %s%s%s\n' "$GRN" "$*" "$R"; }
warn()  { printf '  %s%s%s\n' "$YEL" "$*" "$R"; }
bad()   { printf '  %s%s%s\n' "$RED" "$*" "$R"; }
note()  { printf '  %s%s%s\n' "$DIM" "$*" "$R"; }
die()   { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }

QUIET=0
qsay() { [ "$QUIET" = 1 ] || say "$@"; }

# ---------------------------------------------------------------------------
# what is staged
# ---------------------------------------------------------------------------
is_commit() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

# product.json field, no jq on these boxes.
pj() {   # $1 = product.json, $2 = key
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2" 2>/dev/null
}

staged_commits() {
  local d
  for d in "$ROOT"/*/; do
    d="${d%/}"; d="${d##*/}"
    is_commit "$d" && [ -f "$ROOT/$d/server/product.json" ] && printf '%s\n' "$d"
  done
}
version_of()   { pj "$ROOT/$1/server/product.json" version; }
quality_dir()  {   # stable -> Stable, the CLI's own naming
  case "$(pj "$ROOT/$1/server/product.json" quality)" in
    insider) echo Insiders ;; exploration) echo Exploration ;; *) echo Stable ;;
  esac
}

# Accept a version ("1.139.0") or a commit, return the staged commit.
resolve() {   # $1 = version|commit
  local c
  is_commit "$1" && { [ -d "$ROOT/$1" ] && echo "$1"; return; }
  for c in $(staged_commits); do [ "$(version_of "$c")" = "$1" ] && { echo "$c"; return; }; done
}

# ---------------------------------------------------------------------------
# who gets linked
# ---------------------------------------------------------------------------
# Supplementary members AND anyone whose PRIMARY group it is -- getent lists
# only the former, and a primary-group engineer is a plausible way to make one.
members() {   # $1 = group
  local g="$1" gid
  getent group "$g" >/dev/null 2>&1 || die "no such group: $g"
  gid=$(getent group "$g" | cut -d: -f3)
  { getent group "$g" | cut -d: -f4 | tr ',' '\n'
    getent passwd | awk -F: -v g="$gid" '$4==g {print $1}'
  } | sed '/^$/d' | sort -u | while read -r u; do
    real_person "$u" && printf '%s\n' "$u"
  done
}
# Everyone who could have links, for cleanup -- not only current members.
humans() { getent passwd | awk -F: '$3>=1000 && $3<65534 {print $1}' | while read -r u; do real_person "$u" && echo "$u"; done; }
real_person() {   # a login-capable human with a home
  local e uid sh h
  e=$(getent passwd "$1") || return 1
  uid=$(cut -d: -f3 <<<"$e"); h=$(cut -d: -f6 <<<"$e"); sh=$(cut -d: -f7 <<<"$e")
  [ "$uid" -ge 1000 ] && [ "$uid" -lt 65534 ] || return 1
  [ -n "$h" ] && [ -d "$h" ] || return 1
  case "$sh" in */nologin|*/false|"") return 1 ;; esac
}
home_of() { getent passwd "$1" | cut -d: -f6; }

# ---------------------------------------------------------------------------
# linking -- done AS THE USER
# ---------------------------------------------------------------------------
# Root must not create, follow or delete paths inside a home the user controls:
# a symlink they planted at ~/.vscode-server would aim root at anything on the
# box. Run as them, the worst a planted link can reach is what they could
# already touch. Values are passed as ARGUMENTS, never pasted into the script.
#
# A real file or directory already at a link's path is the engineer's own copy
# (they unpacked it by hand before this existed) and is never replaced.
# From / -- an admin's shell is usually in /root, which the engineer cannot
# read, and node fails at startup when it cannot resolve its working directory.
as_user() { ( cd / && runuser -u "$1" -- "${@:2}" ); }

LINK_SH='
set -u; umask 077
root=$1 c=$2 q=$3 home=$4 base="$home/.vscode-server"
res=""
one() {   # $1 = path, $2 = target
  if [ -L "$1" ]; then ln -sfn "$2" "$1" && res="$res linked"
  elif [ -e "$1" ]; then res="$res own"
  else ln -s "$2" "$1" && res="$res linked"; fi
}
mkdir -p "$base/bin" "$base/cli/servers/$q-$c" || { echo FAIL; exit 1; }
one "$base/bin/$c" "$root/$c/server"
one "$base/cli/servers/$q-$c/server" "$root/$c/server"
if [ -f "$root/$c/code" ]; then one "$base/code-$c" "$root/$c/code"; else res="$res none"; fi
echo $res
'

UNLINK_SH='
set -u
root=$1 c=$2 home=$3 base="$home/.vscode-server" n=0
for p in "$base/bin/$c" "$base/code-$c" "$base"/cli/servers/*-"$c"/server; do
  [ -L "$p" ] || continue
  case "$(readlink "$p")" in "$root/$c"/*|"$root/$c") rm -f "$p" && n=$((n+1)) ;; esac
done
rmdir "$base"/cli/servers/*-"$c" 2>/dev/null
echo $n
'

link_user() {   # $1 = user, $2 = commit
  local u="$1" c="$2" h out
  h=$(home_of "$u")
  out=$(as_user "$u" sh -c "$LINK_SH" link "$ROOT" "$c" "$(quality_dir "$c")" "$h" 2>&1) || {
    bad "$u: could not link ($out)"; return 1; }
  case "$out" in
    *own*) warn "$u: $(version_of "$c") -- has their OWN copy in ~/.vscode-server, left alone" ;;
    *)     [ "$QUIET" = 1 ] || ok "$u: $(version_of "$c") linked" ;;
  esac
}

unlink_user() {   # $1 = user, $2 = commit -> count
  as_user "$1" sh -c "$UNLINK_SH" unlink "$ROOT" "$2" "$(home_of "$1")" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# stage
# ---------------------------------------------------------------------------
find_one() {   # $1 = dir, $2.. = globs -> first match
  local d="$1" g f; shift
  for g in "$@"; do for f in "$d"/$g; do [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }; done; done
  return 1
}

cmd_stage() {
  local server="" cli="" group="$DEFAULT_GROUP" only="" link=1 force=0 a
  local -a paths=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --group)   group="${2:?--group needs a name}"; shift 2 ;;
      --user)    only="${2:?--user needs a name}"; shift 2 ;;
      --no-link) link=0; shift ;;
      --force)   force=1; shift ;;
      -*)        die "unknown option: $1" ;;
      *)         paths+=("$1"); shift ;;
    esac
  done
  [ ${#paths[@]} -gt 0 ] || die "usage: it-vscode-server stage <folder or files>"

  for a in "${paths[@]}"; do
    if [ -d "$a" ]; then
      [ -n "$server" ] || server=$(find_one "$a" 'vscode-server-linux-x64.tar.gz' 'vscode-server-linux-x64*.tar.gz') || true
      [ -n "$cli" ]    || cli=$(find_one "$a" 'vscode_cli_alpine_x64_cli.tar.gz' 'vscode_cli_linux_x64_cli.tar.gz' 'vscode_cli_*x64*cli.tar.gz') || true
    else
      case "${a##*/}" in
        *server-linux-x64-web*) die "${a##*/} is the BROWSER build. Remote-SSH needs vscode-server-linux-x64.tar.gz." ;;
        vscode-server-linux-x64*.tar.gz) server="$a" ;;
        vscode_cli_*.tar.gz)             cli="$a" ;;
        *) die "not a VS Code Server download: $a" ;;
      esac
    fi
  done
  case "${server##*/}" in *-web*) die "${server##*/} is the BROWSER build. Remote-SSH needs vscode-server-linux-x64.tar.gz." ;; esac
  [ -n "$server" ] && [ -r "$server" ] || die "no vscode-server-linux-x64.tar.gz found in: ${paths[*]}
  Download it on an online machine -- 'it-vscode-server urls <version>' prints the address."

  install -d -m 0755 -o root -g root "$ROOT"
  local tmp; tmp=$(mktemp -d "$ROOT/.staging.XXXXXX") || die "cannot create a staging dir under $ROOT"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  head2 "Staging $(basename "$server")"
  mkdir -p "$tmp/server"
  tar -xzf "$server" -C "$tmp/server" --strip-components=1 2>/dev/null || die "could not unpack $server"
  local pjf="$tmp/server/product.json" c ver q
  [ -f "$pjf" ] || die "$server has no product.json -- not a VS Code Server archive"
  c=$(pj "$pjf" commit); ver=$(pj "$pjf" version); q=$(pj "$pjf" quality)
  is_commit "$c" || die "could not read a commit from its product.json (got '$c')"
  [ -x "$tmp/server/node" ] && [ -x "$tmp/server/bin/code-server" ] \
    || die "the archive has no node / bin/code-server -- wrong download?"
  ok "VS Code $ver ($q)  commit $c"

  if [ -e "$ROOT/$c" ] && [ "$force" != 1 ]; then
    ok "already staged in $ROOT/$c -- nothing to install (--force replaces it)"
  else
    if [ -n "$cli" ]; then
      mkdir -p "$tmp/cli"
      tar -xzf "$cli" -C "$tmp/cli" 2>/dev/null || die "could not unpack $cli"
      local bin; bin=$(find "$tmp/cli" -maxdepth 1 -type f -name 'code*' | head -1)
      [ -n "$bin" ] || die "no CLI binary in $cli"
      local cc; cc=$(env -i HOME="$tmp" PATH=/usr/bin:/bin "$bin" --version 2>/dev/null | grep -oE '[0-9a-f]{40}' | head -1)
      [ "$cc" = "$c" ] || die "the CLI is for commit ${cc:-unknown}, the server for $c.
  Download both for the SAME version: it-vscode-server urls $ver"
      mv "$bin" "$tmp/code"; rm -rf "$tmp/cli"
      ok "CLI matches ($cc)"
    else
      note "no CLI archive -- only the useExecServer:false layout will be staged"
    fi

    # mktemp and the STIG's umask 077 both leave directories 0700, which would
    # make every engineer's connection fail with Permission denied on node. The
    # same trap as a sudo-run FPGA install. Readable and executable by all,
    # writable by nobody but root.
    chown -R root:root "$tmp"
    chmod -R u=rwX,go=rX "$tmp"

    {
      printf 'version=%s\ncommit=%s\nquality=%s\n' "$ver" "$c" "$q"
      printf 'staged=%s by %s\n' "$(date -Is)" "${SUDO_USER:-root}"
      printf 'server_sha256=%s  %s\n' "$(sha256sum "$server" | cut -d' ' -f1)" "${server##*/}"
      [ -n "$cli" ] && printf 'cli_sha256=%s  %s\n' "$(sha256sum "$cli" | cut -d' ' -f1)" "${cli##*/}"
    } > "$tmp/MANIFEST"; chmod 0644 "$tmp/MANIFEST"

    if [ -e "$ROOT/$c" ]; then
      mv "$ROOT/$c" "$ROOT/.old.$c.$$" && rm -rf "$ROOT/.old.$c.$$"
    fi
    mv "$tmp" "$ROOT/$c" || die "could not move it into $ROOT/$c"
    trap - EXIT
    ok "installed to $ROOT/$c"
  fi

  # Run it the way an engineer will: as someone who is not root. This is what
  # catches a noexec /opt, a permission left behind, or a bundled node that will
  # not start on this kernel -- here, instead of at the first connection.
  local sv
  if sv=$(cd / && runuser -u nobody -- env -i HOME=/tmp PATH=/usr/bin:/bin "$ROOT/$c/server/bin/code-server" --version 2>&1 | head -1) \
     && [ "$sv" = "$ver" ]; then
    ok "runs as a non-root user (reports $sv)"
  else
    bad "the server does not start as a non-root user: ${sv:-no output}"
    note "check: mount | grep /opt (noexec?), and the log above"
    return 1
  fi

  [ "$link" = 1 ] || { note "not linked (--no-link). Later: it-vscode-server link"; return 0; }
  head2 "Linking"
  if [ -n "$only" ]; then
    real_person "$only" || die "$only is not a login-capable account with a home"
    link_user "$only" "$c"
  else
    local n=0 u
    while read -r u; do [ -n "$u" ] && { link_user "$u" "$c"; n=$((n + 1)); }; done < <(members "$group")
    [ "$n" -gt 0 ] || warn "nobody in $group to link"
  fi
  say ""
  note "Each PC needs VS Code $ver exactly. Then: it-vscode-server settings"
  say ""
}

# ---------------------------------------------------------------------------
cmd_link() {
  local group="$DEFAULT_GROUP" only="" c u n=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --group) group="${2:?}"; shift 2 ;;
      --user)  only="${2:?}"; shift 2 ;;
      --quiet) QUIET=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$(staged_commits)" ] || { qsay "Nothing staged in $ROOT -- run: it-vscode-server stage <folder>"; return 0; }
  # The pull calls this; a box without the group simply has nobody to link.
  if [ -z "$only" ] && ! getent group "$group" >/dev/null 2>&1; then
    qsay "no group $group on this box -- nothing to link"; return 0
  fi
  local -a who
  if [ -n "$only" ]; then real_person "$only" || die "$only is not a login-capable account"; who=("$only")
  else mapfile -t who < <(members "$group"); fi
  for u in "${who[@]}"; do
    for c in $(staged_commits); do link_user "$u" "$c" && n=$((n + 1)); done
  done
  qsay ""; [ "$QUIET" = 1 ] || ok "$n link set(s) in place"
}

cmd_unlink() {
  local only="" want="" c u n
  while [ $# -gt 0 ]; do
    case "$1" in --user) only="${2:?}"; shift 2 ;; -*) die "unknown option: $1" ;; *) want="$1"; shift ;; esac
  done
  local -a cs
  if [ -n "$want" ]; then c=$(resolve "$want"); [ -n "$c" ] || die "not staged: $want"; cs=("$c")
  else mapfile -t cs < <(staged_commits); fi
  local -a who
  if [ -n "$only" ]; then who=("$only"); else mapfile -t who < <(humans); fi
  for u in "${who[@]}"; do
    for c in "${cs[@]}"; do
      n=$(unlink_user "$u" "$c"); [ "${n:-0}" -gt 0 ] && ok "$u: removed $n link(s) to $(version_of "$c")"
    done
  done
  return 0
}

# Processes EXECUTING a binary from this version -- node and the CLI resolve to
# /opt/vscode-server/<commit>/... in /proc/<pid>/exe. Not a command-line match:
# that also caught an admin with a log file under ~/.vscode-server open, and
# refused a removal nobody was blocking (found in testing).
in_use() {   # $1 = commit -> "pid user" per process
  local p e
  for p in /proc/[0-9]*; do
    e=$(readlink "$p/exe" 2>/dev/null) || continue
    case "$e" in "$ROOT/$1/"*) printf '%s %s\n' "${p#/proc/}" "$(stat -c %U "$p" 2>/dev/null)" ;; esac
  done
}

cmd_remove() {
  local want="" force=0 c
  while [ $# -gt 0 ]; do case "$1" in --force) force=1; shift ;; *) want="$1"; shift ;; esac; done
  [ -n "$want" ] || die "usage: it-vscode-server remove <version|commit> [--force]"
  c=$(resolve "$want"); [ -n "$c" ] || die "not staged: $want"
  # Deleting the files under a running server crashes that engineer's session.
  local running
  running=$(in_use "$c")
  if [ -n "$running" ] && [ "$force" != 1 ]; then
    bad "$(version_of "$c") is in use by:"
    printf '%s\n' "$running" | awk '{print $2}' | sort | uniq -c | awk '{printf "    %-16s %s process(es)\n", $2, $1}'
    die "not removed. Ask them to disconnect, or --force (their session will drop)."
  fi
  head2 "Removing $(version_of "$c")  ($c)"
  cmd_unlink "$c"
  rm -rf "${ROOT:?}/$c" && ok "deleted $ROOT/$c"
  say ""
}

# ---------------------------------------------------------------------------
cmd_urls() {
  local want="${1:-}" c
  [ -n "$want" ] || die "usage: it-vscode-server urls <version|commit>
  A version works only if it is already staged here; otherwise give the commit
  (VS Code on the PC: Help > About > Commit)."
  if is_commit "$want"; then c="$want"; else c=$(resolve "$want"); [ -n "$c" ] || die "version $want is not staged here -- give its commit instead (Help > About on the PC)"; fi
  local u="https://update.code.visualstudio.com/commit:$c"
  head2 "Downloads for commit $c"
  say "  On a machine with internet. Carry all of it in on the same media."
  say ""
  say "  ${B}For this box${R} (then: sudo it-vscode-server stage <folder>)"
  say "    $u/server-linux-x64/stable     -> vscode-server-linux-x64.tar.gz"
  say "    $u/cli-alpine-x64/stable       -> vscode_cli_alpine_x64_cli.tar.gz"
  say ""
  say "  ${B}For the PCs${R} -- the SAME version, or Remote-SSH cannot connect"
  say "    $u/win32-x64/stable            -> VSCodeSetup-x64-<version>.exe      (all users)"
  say "    $u/win32-x64-user/stable       -> VSCodeUserSetup-x64-<version>.exe  (one user)"
  say ""
  say "  ${B}Extensions${R}: Remote - SSH (ms-vscode-remote.remote-ssh) as a .vsix for the"
  say "  PCs. Extensions that run ON THE BOX are already shared by it-vscode; anything"
  say "  platform-specific you add by hand must be the ${B}Linux x64${R} build."
  say ""
}

cmd_settings() {
  head2 "Each PC: File > Preferences > Settings > Open Settings (JSON)"
  cat <<'EOF'
    "remote.SSH.useExecServer": false,
    "remote.SSH.localServerDownload": "off",
    "update.mode": "none",
    "extensions.autoUpdate": false,
EOF
  say ""
  note "useExecServer:false uses ~/.vscode-server/bin/<commit>, the layout confirmed"
  note "against Microsoft's installer. The default mode's layout is staged too when"
  note "the CLI was supplied, so leaving it at the default may work as well."
  note "update.mode:none -- ONE auto-update on a PC and that engineer can no longer"
  note "connect: the box has no server for the new version."
  say ""
}

# ---------------------------------------------------------------------------
cmd_status() {
  local c any=0
  head2 "Staged in $ROOT"
  for c in $(staged_commits); do
    any=1
    printf '  %s%-10s%s %s  %s  %s\n' "$B" "$(version_of "$c")" "$R" "$c" \
      "$(du -sh "$ROOT/$c" 2>/dev/null | cut -f1)" \
      "$([ -f "$ROOT/$c/code" ] && echo 'server + CLI' || echo 'server only')"
  done
  [ "$any" = 1 ] || { warn "nothing staged"; note "on an online machine: it-vscode-server urls <commit>"; note "then here: sudo it-vscode-server stage <folder>"; }

  head2 "Engineers (${DEFAULT_GROUP})"
  if ! getent group "$DEFAULT_GROUP" >/dev/null 2>&1; then
    note "no $DEFAULT_GROUP group on this box"
  else
    local u h st
    while read -r u; do
      [ -n "$u" ] || continue
      h=$(home_of "$u"); st=""
      for c in $(staged_commits); do
        if [ -L "$h/.vscode-server/bin/$c" ]; then st="$st $(version_of "$c"):linked"
        elif [ -e "$h/.vscode-server/bin/$c" ]; then st="$st $(version_of "$c"):own-copy"
        else st="$st $(version_of "$c"):MISSING"; fi
      done
      case "$st" in
        *MISSING*) printf '  %-20s %s%s%s\n' "$u" "$YEL" "${st# }" "$R" ;;
        *)         printf '  %-20s %s%s%s\n' "$u" "$GRN" "${st:- (nothing staged)}" "$R" ;;
      esac
    done < <(members "$DEFAULT_GROUP")
  fi

  # Remote-SSH reaches the server through an SSH port forward. The STIG content
  # can switch forwarding off, and then every connection fails with
  # "administratively prohibited" -- which looks like a VS Code fault.
  head2 "SSH forwarding (Remote-SSH needs it)"
  local t s d
  t=$(sshd -T 2>/dev/null | awk '$1=="allowtcpforwarding"{print $2}')
  s=$(sshd -T 2>/dev/null | awk '$1=="allowstreamlocalforwarding"{print $2}')
  d=$(sshd -T 2>/dev/null | awk '$1=="disableforwarding"{print $2}')
  if [ -z "$t" ]; then warn "could not read sshd's effective config (sshd -T)"
  elif [ "$d" = yes ] || [ "$t" = no ]; then
    bad "AllowTcpForwarding=$t DisableForwarding=${d:-no} -- Remote-SSH will be refused"
  else
    ok "AllowTcpForwarding=$t AllowStreamLocalForwarding=${s:-?}"
  fi
  say ""
  note "PC settings: it-vscode-server settings    Downloads: it-vscode-server urls <commit>"
  say ""
}

case "${1:-status}" in
  -h|--help|help) usage ;;
  status|"")      cmd_status ;;
  stage)          shift; cmd_stage "$@" ;;
  link)           shift; cmd_link "$@" ;;
  unlink)         shift; cmd_unlink "$@" ;;
  remove)         shift; cmd_remove "$@" ;;
  urls)           shift; cmd_urls "$@" ;;
  settings)       cmd_settings ;;
  *)              die "unknown command: $1  (try: it-vscode-server --help)" ;;
esac
