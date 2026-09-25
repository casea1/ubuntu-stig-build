#!/usr/bin/env bash
# it-aiops -- read access to the AI stack's configuration for the AI review
# team (group `aiops`), applied when an admin runs it and not before.
#
# Usage:
#   it-aiops                 on or off, who is in the group, what they can read
#   it-aiops on              grant it now, and record ai_ops_enabled: true
#   it-aiops off             take it away now, and record false
#   it-aiops refresh         re-apply after files were added or rewritten
#   it-aiops add <user>      put someone in the group (effective at next login)
#   it-aiops remove <user>
#
# Nothing else is touched: no pull, no compose file, no container. A pull used
# to be the only way to turn this on, and `it-pull ai` also rewrites every
# stack's files -- arming whatever else the repo has changed for the next
# `docker compose up -d`.
#
# THE RULE: everything under the roots is readable -- compose files, every
# .env, hidden files, magpie's ssh folder -- EXCEPT private keys. OpenSSH
# refuses a key that anyone but its owner can read ("Permissions 0640 ... are
# too open"; verified on noble's 9.6p1), and an ACL entry is exactly that: the
# mode shows the mask. magpie mounts ./ssh live, so a grant on its key would
# break its git sync at the next run with no container restarted. Keys are
# found by content (a PEM or OpenSSH "PRIVATE KEY" header), not by name.
# Read only; symlinks are never followed (/opt/stacks/ai points into /opt/it).
#
# No default ACLs: under one, a file an admin creates by hand stops honouring
# the STIG's umask 077 and comes out readable. New files are covered by
# `it-aiops refresh` -- or by the next pull, which runs this same script.
#
# `on` and `off` also write ai_ops_enabled to /opt/it/site.yml, so a later
# `it-pull ai` agrees with what you did here instead of reverting it; the pull
# runs this script, so it cannot apply a different rule either.
set -uo pipefail

GROUP=aiops
ADMIN_GROUP="${IT_AIOPS_ADMIN_GROUP:-sudo}"
read -r -a ROOTS <<< "${IT_AIOPS_PATHS:-/opt/stacks /opt/docker}"
SUDOERS="${IT_AIOPS_SUDOERS:-/etc/sudoers.d/40-aiops}"
SITE_YML="${IT_AIOPS_SITE_YML:-/opt/it/site.yml}"

# Exact argument forms, every one look-only. A bare command in sudoers permits
# ANY arguments (trap 12ad) -- and `it-stack-diff --out FILE` writes as root.
# Left out on purpose: it-docker restart|stop|start (changes the stack),
# it-docker logs (application logs can carry secrets), it-stack-diff <stack>
# (a name wildcard would also match "<stack> --out /etc/shadow").
FORMS=(
  '/usr/local/sbin/it-docker ""'
  '/usr/local/sbin/it-docker ps'
  '/usr/local/sbin/it-docker ps --all'
  '/usr/local/sbin/it-docker check'
  '/usr/local/sbin/it-docker audit'
  '/usr/local/sbin/it-docker ports'
  '/usr/local/sbin/it-docker compose'
  '/usr/local/sbin/it-docker config'
  '/usr/local/sbin/it-docker df'
  '/usr/local/sbin/it-stack-diff ""'
  '/usr/local/sbin/it-stack-diff --full'
  '/usr/local/sbin/it-baseline --stdout'
  '/usr/local/sbin/it-baseline --stdout --brief'
)

[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

if [ -t 1 ]; then B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'; RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'
else B=""; DIM=""; R=""; RED=""; GRN=""; YEL=""; fi
QUIET=0; PERSIST=1
say()   { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
head2() { [ "$QUIET" = 1 ] || printf '\n%s%s%s\n' "$B" "$*" "$R"; }
ok()    { [ "$QUIET" = 1 ] || printf '  %s%s%s\n' "$GRN" "$*" "$R"; }
warn()  { printf '  %s%s%s\n' "$YEL" "$*" "$R"; }
bad()   { printf '  %s%s%s\n' "$RED" "$*" "$R"; }
note()  { [ "$QUIET" = 1 ] || printf '  %s%s%s\n' "$DIM" "$*" "$R"; }
die()   { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }

command -v setfacl >/dev/null 2>&1 || die "setfacl is not installed (package: acl)"

# ---------------------------------------------------------------------------
# Every directory and file under the roots, one per line as "<verdict> <type>
# <path>" -- `yes` to grant, `key` for a private key that must not be.
walk() {
  python3 - "${ROOTS[@]}" <<'PYEOF'
import os, stat, sys
def is_private_key(p):
    try:
        with open(p, 'rb') as f: head = f.read(64)
    except OSError: return False
    return head.startswith(b'-----BEGIN') and b'PRIVATE KEY' in head.split(b'\n')[0]
for root in sys.argv[1:]:
    if not os.path.isdir(root) or os.path.islink(root): continue
    for d, dirs, files in os.walk(root, followlinks=False):
        print("yes d", d)
        for f in files:
            p = os.path.join(d, f)
            try: st = os.lstat(p)
            except OSError: continue
            if not stat.S_ISREG(st.st_mode): continue      # symlinks, sockets
            print(("key" if is_private_key(p) else "yes"), "f", p)
PYEOF
}

has_entry() { getfacl -cp -- "$1" 2>/dev/null | grep -qE "^(default:)?group:$GROUP:"; }

# ---------------------------------------------------------------------------
cmd_on() {
  getent group "$GROUP" >/dev/null || { groupadd "$GROUP" || die "could not create group $GROUP"; ok "created group $GROUP"; }
  apply_acls
  install_grant
  [ "$PERSIST" = 1 ] && persist true
  say ""
  note "Add people: it-aiops add <user>    Check: it-aiops"
  say ""
}

apply_acls() {
  head2 "Read access for $GROUP"
  local v t p nd=0 nf=0 nk=0 stripped=0 root
  for root in "${ROOTS[@]}"; do [ -d "$root" ] || note "$root does not exist -- skipped"; done
  while read -r v t p; do
    [ -n "$p" ] || continue
    if [ "$v" = yes ]; then
      if [ "$t" = d ]; then setfacl -m "g:$GROUP:rx" -- "$p" && nd=$((nd + 1))
                            setfacl -x "d:g:$GROUP" -- "$p" 2>/dev/null
      else                  setfacl -m "g:$GROUP:r"  -- "$p" && nf=$((nf + 1)); fi
    else
      nk=$((nk + 1))
      has_entry "$p" || continue
      setfacl -x "g:$GROUP" -- "$p" 2>/dev/null; setfacl -x "d:g:$GROUP" -- "$p" 2>/dev/null
      stripped=$((stripped + 1)); warn "removed $GROUP from ${p} (private key -- ssh refuses it if others can read it)"
    fi
  done < <(walk)
  ok "$nd folder(s), $nf file(s) readable by $GROUP"
  [ "$nk" -gt 0 ] && note "$nk private key(s) held back -- ssh refuses a key others can read"
  [ "$stripped" -gt 0 ] && warn "$stripped private key(s) had an $GROUP entry -- removed"
  return 0
}

install_grant() {
  local tmp f first=1
  tmp=$(mktemp) || die "mktemp failed"
  {
    printf '# Managed by it-aiops -- do not edit by hand. Every form only LOOKS;\n'
    printf '# "" means no arguments at all. Not NOPASSWD: the STIG requires sudo\n'
    printf '# to authenticate.\n'
    printf '%%%s ALL=(root) ' "$GROUP"
    for f in "${FORMS[@]}"; do
      [ "$first" = 1 ] && first=0 || printf ', \\\n        '
      printf '%s' "$f"
    done
    printf '\n'
  } > "$tmp"
  # A malformed drop-in takes sudo away from EVERYONE on the box.
  if visudo -cf "$tmp" >/dev/null 2>&1; then
    install -m 0440 -o root -g root "$tmp" "$SUDOERS" && ok "sudo grant: ${#FORMS[@]} look-only commands ($SUDOERS)"
  else
    bad "the sudo grant did not validate -- NOT installed"; visudo -cf "$tmp" >&2
  fi
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
cmd_off() {
  head2 "Removing $GROUP access"
  local p n=0 root
  # Every entry, wherever it is -- including anything the first version of
  # this grant put somewhere the rule would not.
  for root in "${ROOTS[@]}"; do
    [ -d "$root" ] || continue
    while IFS= read -r p; do
      has_entry "$p" || continue
      setfacl -x "g:$GROUP" -- "$p" 2>/dev/null; setfacl -x "d:g:$GROUP" -- "$p" 2>/dev/null
      n=$((n + 1))
    done < <(find "$root" -xdev \( -type d -o -type f \) 2>/dev/null)
  done
  ok "removed $GROUP from $n item(s)"
  if [ -e "$SUDOERS" ]; then rm -f "$SUDOERS" && ok "removed the sudo grant"; fi
  [ "$PERSIST" = 1 ] && persist false
  note "The group and its members are kept, so 'it-aiops on' restores them."
  say ""
}

# ---------------------------------------------------------------------------
# site.yml is loaded above group_vars by every pull. Keep the edit only if the
# file still parses: a broken site.yml stops the NEXT pull at task 2.
persist() {   # $1 = true|false
  local bak="$SITE_YML.bak-$$"
  [ -f "$SITE_YML" ] || { warn "no $SITE_YML -- not recorded; a later 'it-pull ai' will not know"; return 0; }
  cp -a "$SITE_YML" "$bak" || return 0
  if grep -qE '^ai_ops_enabled[[:space:]]*:' "$SITE_YML"; then
    sed -i -E "s|^ai_ops_enabled[[:space:]]*:.*|ai_ops_enabled: $1|" "$SITE_YML"
  else
    printf '\n# Set by it-aiops on %s\nai_ops_enabled: %s\n' "$(date -I)" "$1" >> "$SITE_YML"
  fi
  if python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$SITE_YML" 2>/dev/null; then
    rm -f "$bak"; ok "recorded ai_ops_enabled: $1 in $SITE_YML (a later pull agrees)"
  else
    mv -f "$bak" "$SITE_YML"; bad "$SITE_YML would not parse after the edit -- left unchanged"
  fi
}

# ---------------------------------------------------------------------------
members() {
  getent group "$GROUP" >/dev/null || return 0
  local gid; gid=$(getent group "$GROUP" | cut -d: -f3)
  { getent group "$GROUP" | cut -d: -f4 | tr ',' '\n'
    getent passwd | awk -F: -v g="$gid" '$4==g {print $1}'; } | sed '/^$/d' | sort -u
}

cmd_add() {
  local u="${1:-}"; [ -n "$u" ] || die "usage: it-aiops add <user>"
  id -u "$u" >/dev/null 2>&1 || die "no such account: $u (create it first: it-adduser)"
  [ "$u" != root ] || die "not root"
  getent group "$GROUP" >/dev/null || die "the group does not exist yet -- run: it-aiops on"
  usermod -aG "$GROUP" "$u" && ok "$u added to $GROUP -- effective at their next login"
  note "They type sudo in front: sudo it-docker check  (it asks for THEIR password)"
}
cmd_remove() {
  local u="${1:-}"; [ -n "$u" ] || die "usage: it-aiops remove <user>"
  gpasswd -d "$u" "$GROUP" >/dev/null 2>&1 && ok "$u removed from $GROUP (a session already open keeps it until logout)" \
    || warn "$u was not in $GROUP"
}

# ---------------------------------------------------------------------------
cmd_status() {
  local p v t ngrant=0 site
  head2 "AI review-team access ($GROUP)"
  if [ -e "$SUDOERS" ]; then ok "sudo grant       installed ($SUDOERS)"; else note "sudo grant       not installed"; fi
  site=$(sed -nE 's/^ai_ops_enabled[[:space:]]*:[[:space:]]*//p' "$SITE_YML" 2>/dev/null | tail -1)
  printf '  %-16s %s\n' "site.yml" "ai_ops_enabled: ${site:-not set (a pull treats that as false and REMOVES access)}"
  printf '  %-16s %s\n' "members" "$(members | paste -sd' ' -)"
  [ -n "$(members)" ] || note "                 nobody yet -- it-aiops add <user>"

  head2 "What they can see"
  local nk=0 nkeyed=0
  while read -r v t p; do
    [ -n "$p" ] || continue
    if [ "$v" = yes ]; then has_entry "$p" && ngrant=$((ngrant + 1))
    else nk=$((nk + 1))
         if has_entry "$p"; then nkeyed=$((nkeyed + 1)); bad "KEY GRANTED: $p -- ssh will refuse it"; fi
    fi
  done < <(walk)
  printf '  %-16s %s\n' "readable items" "$ngrant (including every .env)"
  [ "$nk" -gt 0 ] && printf '  %-16s %s\n' "private keys" "$nk held back (ssh refuses a key others can read)"
  [ "$nkeyed" -gt 0 ] && bad "$nkeyed private key(s) carry an $GROUP entry -- 'it-aiops refresh' removes it"

  # Proof, not inference: every granted file, read by the kernel as one of
  # them, in one pass. Only paths from the walk -- a glob here once picked
  # /opt/stacks/ai/.env, which is the stale symlink into /opt/it, and reported
  # a failure the grant never had.
  local m miss
  m=$(members | head -1)
  if [ -n "$m" ]; then
    head2 "Checked as $m"
    miss=$(walk | awk '$1=="yes" {sub(/^yes [df] /, ""); print}' |
           runuser -u "$m" -- bash -c 'n=0; while IFS= read -r p; do [ -r "$p" ] || { n=$((n+1)); [ $n -le 5 ] && echo "$p"; }; done; [ $n -gt 5 ] && echo "... and $((n-5)) more"; exit 0' 2>/dev/null)
    if [ -z "$miss" ]; then
      ok "can read all $ngrant granted items (read-only: nothing in the grant allows editing)"
    else
      warn "cannot read:"; printf '%s\n' "$miss" | sed 's/^/    /'
      note "run: it-aiops refresh   (a file rewritten since 'on' loses its entry)"
    fi
  fi
  say ""
}

# ---------------------------------------------------------------------------
cmd=""; args=()
for a in "$@"; do
  case "$a" in
    --quiet) QUIET=1 ;;
    --no-persist) PERSIST=0 ;;
    -h|--help|help) usage; exit 0 ;;
    *) if [ -z "$cmd" ]; then cmd="$a"; else args+=("$a"); fi ;;
  esac
done
case "${cmd:-status}" in
  status)  cmd_status ;;
  on)      cmd_on ;;
  off)     cmd_off ;;
  refresh) getent group "$GROUP" >/dev/null || die "not on -- run: it-aiops on"; apply_acls; say "" ;;
  add)     cmd_add "${args[0]:-}" ;;
  remove)  cmd_remove "${args[0]:-}" ;;
  *)       die "unknown command: $cmd  (try: it-aiops --help)" ;;
esac
