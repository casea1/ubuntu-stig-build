#!/usr/bin/env bash
# it-offline-repo -- run apt off a hand-carried local repo on a standalone box.
#
# For the EMI laptop, which is air-gapped after imaging and has no ADM PC to
# serve packages over HTTP. The same repo tree the ADM-Toolkit mirrors is copied
# onto this box and apt reads it over file://.
#
# Usage:
#   it-offline-repo                 what apt is pointed at, and is the tree sane
#   it-offline-repo status          ...the same thing
#   it-offline-repo load <PATH>     copy/refresh the repo tree from media
#   it-offline-repo enable          park the online sources, switch apt over
#   it-offline-repo disable         put the online sources back
#   it-offline-repo verify          apt-get update + prove a package resolves
#   --dry-run                       (load) show what would change, copy nothing
#   --yes                           skip the confirmation prompts
set -uo pipefail

CONF_DEFAULT_DIR=/srv/repo
SITE_YML=/opt/it/site.yml
SOURCE_FILE=/etc/apt/sources.list.d/offline-repo.sources
BACKUP_DIR=/opt/it/apt-sources-backup
LOG=/var/log/offline-repo.log
DRY=0
ASSUME_YES=0

[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

if [ -t 1 ]; then
  B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'
else
  B=""; DIM=""; R=""; RED=""; GRN=""; YEL=""
fi
say()  { printf '%s\n' "$*"; }
head2(){ printf '\n%s%s%s\n' "$B" "$*" "$R"; }
ok()   { printf '  %s%s%s\n' "$GRN" "$*" "$R"; }
warn() { printf '  %s%s%s\n' "$YEL" "$*" "$R"; }
bad()  { printf '  %s%s%s\n' "$RED" "$*" "$R"; }
die()  { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; exit 1; }
logline() { printf '%s  %s\n' "$(date -Is)" "$*" >> "$LOG"; }

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local a
  read -r -p "$1 [y/N] " a || return 1
  [ "${a,,}" = "y" ] || [ "${a,,}" = "yes" ]
}

# offline_repo_dir / offline_repo_suite are configurable in group_vars, so read
# what this box was actually built with rather than assuming the defaults.
# site.yml wins, exactly as it does for the playbook (later files win).
site_var() {   # key -> value, or empty
  local key="$1" f v d=""
  for f in /opt/it/site.yml /opt/it/site.d/*.yml; do
    [ -r "$f" ] || continue
    v=$(sed -nE "s/^${key}[[:space:]]*:[[:space:]]*//p" "$f" | tail -1)
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    [ -n "$v" ] && d="$v"
  done
  printf '%s\n' "$d"
}

repo_dir() {
  local d
  d=$(site_var offline_repo_dir)
  # Failing that, the source file apt is using is authoritative.
  if [ -z "$d" ] && [ -r "$SOURCE_FILE" ]; then
    d=$(awk '/^URIs:/ {print $2}' "$SOURCE_FILE" | sed 's|^file://||; s|/ubuntu/.*$||')
  fi
  printf '%s\n' "${d:-$CONF_DEFAULT_DIR}"
}

SUITE="$(site_var offline_repo_suite)"; SUITE="${SUITE:-noble}"
REPO_DIR="$(repo_dir)"
TREE="$REPO_DIR/ubuntu/$SUITE"
RELEASE="$TREE/dists/$SUITE/Release"

# ---- shared checks ----------------------------------------------------------

# Structural, not name-based: a folder called "ubuntu" proves nothing (the SCAP
# content libraries are full of them). A Release file under dists/<suite> is
# what apt actually needs.
tree_ok() { [ -f "$1/ubuntu/$SUITE/dists/$SUITE/Release" ]; }

# Count .deb anywhere under the suite tree -- the builder puts them in pool/,
# but do not depend on that: a layout change would silently report zero.
pkg_count() {
  local t="$1" n=0
  n=$(find "$t" -name '*.deb' 2>/dev/null | wc -l)
  printf '%s\n' "$n"
}

switched() { [ -f "$SOURCE_FILE" ]; }

# ---- status -----------------------------------------------------------------

cmd_status() {
  head2 "Local repo"
  say "  location   $REPO_DIR"
  if tree_ok "$REPO_DIR"; then
    local n bt
    n=$(pkg_count "$TREE")
    bt=$(date -r "$RELEASE" '+%Y-%m-%d %H:%M' 2>/dev/null || echo unknown)
    ok "present -- $n .deb, index built $bt"
  elif [ -d "$REPO_DIR" ]; then
    bad "directory exists but there is no $RELEASE"
    say "  ${DIM}Load a repo tree: it-offline-repo load /media/<user>/<SSD>/repo${R}"
  else
    warn "not loaded (no $REPO_DIR)"
  fi

  head2 "apt sources"
  if switched; then
    ok "switched to the local repo"
    sed 's/^/    /' "$SOURCE_FILE" | grep -v '^    #' | grep -v '^    $'
  else
    say "  using the online sources:"
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list \
             /etc/apt/sources.list.d/*.sources; do
      [ -e "$f" ] || continue
      printf '    %s\n' "$f"
    done
  fi

  if [ -d "$BACKUP_DIR" ] && [ -n "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
    head2 "Parked online sources ($BACKUP_DIR)"
    ls -1 "$BACKUP_DIR" | sed 's/^/    /'
  fi

  head2 "Persisted setting"
  if grep -qE '^offline_repo_enabled[[:space:]]*:[[:space:]]*true' "$SITE_YML" 2>/dev/null; then
    ok "offline_repo_enabled: true in $SITE_YML -- survives the next pull"
  elif switched; then
    warn "apt is switched but $SITE_YML does not set offline_repo_enabled: true."
    warn "The next ansible-pull will revert it. Run: it-offline-repo enable"
  else
    say "  not set (default false)"
  fi
  printf '\n'
}

# ---- load -------------------------------------------------------------------

cmd_load() {
  local src="${1:-}"
  [ -n "$src" ] || die "load needs a source path, e.g. /media/$SUDO_USER/SSD/repo"
  [ -d "$src" ] || die "no such directory: $src"

  # Accept either the repo root (…/repo) or the ubuntu/ level, so the operator
  # does not have to remember which one the media was packed at.
  if ! tree_ok "$src"; then
    if [ -f "$src/dists/$SUITE/Release" ]; then
      die "that is the suite directory. Pass the repo ROOT instead: ${src%/ubuntu/$SUITE}"
    fi
    die "no $SUITE Release file under $src -- expected $src/ubuntu/$SUITE/dists/$SUITE/Release"
  fi

  local n
  n=$(pkg_count "$src/ubuntu/$SUITE")
  head2 "Source"
  say "  $src"
  ok  "$n .deb, index built $(date -r "$src/ubuntu/$SUITE/dists/$SUITE/Release" '+%Y-%m-%d %H:%M')"

  head2 "Destination"
  say "  $REPO_DIR"
  if tree_ok "$REPO_DIR"; then
    say "  currently $(pkg_count "$TREE") .deb, index built $(date -r "$RELEASE" '+%Y-%m-%d %H:%M')"
  else
    say "  ${DIM}(empty)${R}"
  fi

  # --delete so a package pulled from the repo upstream also leaves this box;
  # otherwise a withdrawn (say, vulnerable) .deb stays installable forever.
  local rsync_args=(-a --delete --info=stats2)
  [ "$DRY" -eq 1 ] && rsync_args+=(--dry-run)

  if [ "$DRY" -eq 0 ]; then
    confirm "Copy $src -> $REPO_DIR (removing anything here that is not there)?" \
      || die "aborted"
  fi

  install -d -o root -g root -m 0755 "$REPO_DIR"
  command -v rsync >/dev/null 2>&1 || die "rsync is not installed -- install it from the media first"

  head2 "Copying"
  rsync "${rsync_args[@]}" "$src"/ "$REPO_DIR"/ || die "rsync failed"

  [ "$DRY" -eq 1 ] && { warn "dry run -- nothing was copied"; return 0; }

  # Root-owned, world-readable: apt's unprivileged _apt sandbox user has to read
  # it, and nothing but root may write it. A group-writable repo plus Trusted=yes
  # is a local root escalation.
  chown -R root:root "$REPO_DIR"
  find "$REPO_DIR" -type d -exec chmod 0755 {} +
  find "$REPO_DIR" -type f -exec chmod 0644 {} +

  logline "load from $src -> $REPO_DIR ($(pkg_count "$TREE") .deb)"
  ok "loaded -- $(pkg_count "$TREE") .deb at $REPO_DIR"
  say "  ${DIM}Now switch apt over: it-offline-repo enable${R}"
}

# ---- enable -----------------------------------------------------------------

persist_setting() {  # true|false
  local want="$1"
  install -d -o root -g "$(stat -c %G /opt/it 2>/dev/null || echo sudo)" -m 2770 /opt/it 2>/dev/null || true
  touch "$SITE_YML"
  if grep -qE '^offline_repo_enabled[[:space:]]*:' "$SITE_YML"; then
    sed -i -E "s|^offline_repo_enabled[[:space:]]*:.*|offline_repo_enabled: $want|" "$SITE_YML"
  else
    printf '\n# Set by it-offline-repo -- keeps the switch across ansible-pull runs.\noffline_repo_enabled: %s\n' \
      "$want" >> "$SITE_YML"
  fi
}

cmd_enable() {
  tree_ok "$REPO_DIR" || die "no repo loaded at $REPO_DIR. Run: it-offline-repo load <path>"

  if switched; then
    ok "apt is already on the local repo"
  else
    head2 "Parking the online sources"
    install -d -o root -g "$(stat -c %G /opt/it 2>/dev/null || echo sudo)" -m 0750 "$BACKUP_DIR"
    local moved=0 dest b
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list \
             /etc/apt/sources.list.d/*.sources; do
      [ -e "$f" ] || continue
      [ "$f" = "$SOURCE_FILE" ] && continue
      b=$(basename "$f"); dest="$BACKUP_DIR/$b"
      [ -e "$dest" ] && dest="$dest.$(date +%Y%m%d-%H%M%S)"
      mv "$f" "$dest" && { say "    $f -> $dest"; moved=$((moved+1)); }
    done
    ok "parked $moved"

    head2 "Writing the local source"
    cat > "$SOURCE_FILE" <<EOF
# Written by it-offline-repo. The offline_repo role rewrites this on each pull.
Types: deb
URIs: file://$TREE
Suites: $SUITE
Components: main
Trusted: yes
EOF
    chmod 0644 "$SOURCE_FILE"
    sed 's/^/    /' "$SOURCE_FILE"
    logline "enable -- apt switched to $TREE"
  fi

  persist_setting true
  ok "offline_repo_enabled: true written to $SITE_YML"

  cmd_verify
}

# ---- disable ----------------------------------------------------------------

cmd_disable() {
  switched || { warn "apt is not on the local repo -- nothing to revert"; persist_setting false; return 0; }

  confirm "Put the online apt sources back and stop using $REPO_DIR?" || die "aborted"

  rm -f "$SOURCE_FILE"
  local restored=0 dest b
  for f in "$BACKUP_DIR"/*; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    case "$b" in
      sources.list)     dest=/etc/apt/sources.list ;;
      *.list|*.sources) dest="/etc/apt/sources.list.d/$b" ;;
      *) continue ;;   # timestamped duplicates; apt ignores them anyway
    esac
    [ -e "$dest" ] && continue
    mv "$f" "$dest" && { say "    $dest"; restored=$((restored+1)); }
  done
  ok "restored $restored source file(s)"
  [ "$restored" -eq 0 ] && warn "nothing was parked -- write /etc/apt/sources.list by hand"

  persist_setting false
  logline "disable -- reverted to the online sources"
  say "  ${DIM}The tree at $REPO_DIR was left in place. Delete it by hand if this box is not going back offline.${R}"

  head2 "Refreshing the apt cache"
  apt-get update 2>&1 | tail -5 | sed 's/^/    /'
}

# ---- verify -----------------------------------------------------------------

cmd_verify() {
  head2 "apt-get update"
  local out rc
  out=$(apt-get update 2>&1); rc=$?
  printf '%s\n' "$out" | tail -8 | sed 's/^/    /'
  if [ "$rc" -ne 0 ]; then
    bad "apt-get update FAILED (rc=$rc)"
    say "  ${DIM}Revert with: it-offline-repo disable${R}"
    return 1
  fi
  # `update` exits 0 even when a source 404s, so look for the warning too.
  if printf '%s\n' "$out" | grep -qiE '^(E|W): '; then
    warn "apt-get update reported warnings -- read them above"
  else
    ok "clean"
  fi

  # Proof the repo actually serves packages, not just an index: resolve one and
  # confirm apt would take it from the local source.
  head2 "Can apt install from it?"
  local probe
  probe=$(apt-cache --no-generate pkgnames 2>/dev/null | head -1)
  if [ -z "$probe" ]; then
    bad "apt knows about no packages at all"
    return 1
  fi
  local n
  n=$(apt-cache pkgnames 2>/dev/null | wc -l)
  if switched; then
    if apt-get install --print-uris --reinstall -y "$probe" 2>/dev/null | grep -q "file://"; then
      ok "$n packages available, served from file://$TREE"
    else
      warn "$n packages available, but '$probe' would not come from the local repo"
    fi
  else
    ok "$n packages available"
  fi
  printf '\n'
}

# ---- dispatch ---------------------------------------------------------------

ARGS=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]:-}"

case "${1:-status}" in
  status|check|"") cmd_status ;;
  load)            shift; cmd_load "${1:-}" ;;
  enable)          cmd_enable ;;
  disable)         cmd_disable ;;
  verify)          cmd_verify ;;
  *)               usage; exit 1 ;;
esac
