#!/usr/bin/env bash
# it-repo -- run apt off a hand-carried local repo on a standalone box.
#
# For the EMI laptop, which is air-gapped after imaging and has no ADM PC to
# serve packages over HTTP. The same repo tree the ADM-Toolkit mirrors is copied
# onto this box and apt reads it over file://.
#
# Usage:
#   it-repo                 what apt is pointed at, and is the tree sane
#   it-repo status          ...the same thing
#   it-repo scan            find repo trees on attached media, mirror nothing
#   it-repo load [PATH]     mirror from media. With no PATH it AUTO-DETECTS.
#   it-repo enable          park the online sources, switch apt over
#   it-repo disable         put the online sources back
#   it-repo verify          apt-get update + prove a package resolves
#   it-repo howto [topic]   package-management cheat sheet: apt, dpkg, pip, the
#                           local repo. Prints commands, runs none.
#   --dry-run                       (load) show what would change, copy nothing
#   --yes                           skip the confirmation prompts
#   --prune                         (load) also DELETE packages the media no longer has
#   --suite <name>                  override the release codename to mirror
#
# `load` mirrors INCREMENTALLY and only this box's Ubuntu release. The media the
# ADM-Toolkit produces carries several releases side by side (jammy for 22.04,
# noble for 24.04); everything that is not this box's codename is listed and
# skipped, so a 24.04 laptop never copies the 22.04 half. Within the codename,
# noble / noble-updates / noble-security are all mirrored -- noble-security is
# where the patches you actually care about live.
#
# Packages are copied additively (an unchanged .deb is never re-read) and the
# dists/ indexes are copied last with --delete, so an interrupted transfer
# leaves an index that under-promises rather than one pointing at packages that
# never arrived. Use --prune to also drop withdrawn packages.
set -uo pipefail

CONF_DEFAULT_DIR=/srv/repo
SITE_YML=/opt/it/site.yml
SOURCE_FILE=/etc/apt/sources.list.d/offline-repo.sources
BACKUP_DIR=/opt/it/apt-sources-backup
LOG=/var/log/offline-repo.log
DRY=0
ASSUME_YES=0
PRUNE=0
SUITE_OVERRIDE=""

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

# Which Ubuntu release this box IS. The box is the authority: mirroring the
# wrong codename is the failure this is here to prevent, and a stale
# offline_repo_suite in site.yml after a release upgrade would do exactly that.
box_codename() {
  local c=""
  [ -r /etc/os-release ] && c=$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}")
  [ -z "$c" ] && command -v lsb_release >/dev/null 2>&1 && c=$(lsb_release -cs 2>/dev/null)
  printf '%s' "${c:-noble}"
}

CODENAME="$(box_codename)"
SUITE="$(site_var offline_repo_suite)"; SUITE="${SUITE:-$CODENAME}"
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

# Every suite directory under a tree's dists/ that has a Release file, one per
# line. A real mirror carries noble, noble-updates and noble-security; the
# security pocket is where the patches are, so all three have to come across
# and all three have to appear in the apt source.
suites_in() {   # $1 = suite tree (…/ubuntu/<codename>)
  local d
  # Sorted, and sorted the same way the offline_repo role sorts it: the glob
  # alone puts "noble-security/" before "noble/" (the '-' sorts under the '/'),
  # so the script and the next ansible-pull would write the suite list in
  # different orders and rewrite the source file on alternate runs.
  { for d in "$1"/dists/*/; do
      [ -f "$d/Release" ] || continue
      valid_suite "$(basename "$d")" || continue
      printf '%s\n' "$(basename "$d")"
    done
  } | LC_ALL=C sort
}

# A suite name is pasted straight into a filesystem path, and it comes from two
# places that are not fully trusted: --suite on the command line, and the
# directory names ON THE MEDIA. A name containing a slash or ".." walks out of
# the repo directory -- `--suite ../../../etc` would aim the mirror at /etc --
# which matters more now that the dta group can sudo this command. Debian suite
# names are lowercase alphanumerics plus . + _ - ; refuse anything else.
valid_suite() {
  case "$1" in
    ''|*/*|*..*) return 1 ;;
  esac
  [[ "$1" =~ ^[a-z0-9][a-z0-9.+_-]*$ ]]
}

# Does this dists/ entry belong to the release this box runs? `noble` and
# `noble-security` yes, `jammy` no. This is the whole point of the version
# filter -- the ADM media carries both.
suite_matches() {  # $1 = suite name
  case "$1" in "$SUITE"|"$SUITE"-*) return 0 ;; *) return 1 ;; esac
}

# ---- media detection --------------------------------------------------------

# Where to look. The desktop automount paths, plus whatever the kernel says is
# on removable or USB-attached media. Deliberately NOT "/": a find over the root
# filesystem is exactly the slow scan this feature exists to avoid.
media_mounts() {
  local mp
  { for mp in /media/*/* /media/* /run/media/*/* /mnt/* /mnt; do
      [ -d "$mp" ] && mountpoint -q "$mp" 2>/dev/null && printf '%s\n' "$mp"
    done
    lsblk -rno MOUNTPOINT,RM,TRAN 2>/dev/null \
      | awk '$1 != "" && $1 != "/" && ($2 == "1" || $3 == "usb") {print $1}'
  } | sort -u
}

# Find repo trees by STRUCTURE, not by a folder called "repo": media gets packed
# differently by different people. A suite tree is the parent of a dists/
# directory that holds at least one Release. Depth-limited so this stays fast on
# a 2 TB SSD.
find_trees() {   # $1 = mount point -> lines "<suite tree>"
  find "$1" -maxdepth 7 -type d -name dists -not -path '*/.*' 2>/dev/null \
    | while read -r d; do
        [ -n "$(suites_in "$(dirname "$d")")" ] && dirname "$d"
      done
}

# ---- scan -------------------------------------------------------------------

cmd_scan() {
  head2 "This box"
  say "  release    $SUITE ($(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION:-unknown}"))"
  say "  repo dir   $REPO_DIR"

  head2 "Attached media"
  local mounts found=0
  mounts=$(media_mounts)
  if [ -z "$mounts" ]; then
    warn "nothing mounted under /media, /run/media or /mnt, and no removable device"
    say  "  ${DIM}Plug the SSD in and let the desktop mount it, or mount it by hand.${R}"
    return 1
  fi
  local mp t name suites n
  while read -r mp; do
    [ -n "$mp" ] || continue
    say "  $mp"
    while read -r t; do
      [ -n "$t" ] || continue
      name=$(basename "$t")
      suites=$(suites_in "$t" | tr '\n' ' ')
      n=$(pkg_count "$t")
      if suite_matches "$name"; then
        ok "$t"
        say "      release $name -- MATCHES this box. $n .deb, suites: ${suites:-none}"
        found=$((found+1))
      else
        warn "$t"
        say "      release $name -- not $SUITE, will be SKIPPED"
      fi
    done < <(find_trees "$mp")
  done <<< "$mounts"

  printf '\n'
  if [ "$found" -eq 0 ]; then
    bad "no $SUITE repo tree found on attached media"
    return 1
  fi
  ok "$found matching tree(s). Mirror with: it-repo load"
  return 0
}

# ---- status -----------------------------------------------------------------

cmd_status() {
  head2 "Local repo"
  say "  location   $REPO_DIR"
  if tree_ok "$REPO_DIR"; then
    local n bt
    n=$(pkg_count "$TREE")
    bt=$(date -r "$RELEASE" '+%Y-%m-%d %H:%M' 2>/dev/null || echo unknown)
    ok "present -- $n .deb, index built $bt"
    say "  release    $SUITE"
    say "  suites     $(suites_in "$TREE" | tr '\n' ' ')"
    # A repo with no -security pocket cannot deliver a security update, which is
    # most of why this box has a local repo at all. Say so rather than letting
    # `apt upgrade` report "0 to upgrade" and look healthy.
    #
    # Tested with `case`, not `| grep -q`: grep -q exits at the first match and
    # SIGPIPEs the producer, and under `set -o pipefail` that makes the whole
    # pipeline non-zero -- the warning fired on repos that DID have the suite.
    case " $(suites_in "$TREE" | tr '\n' ' ')" in
      *" ${SUITE}-security "*) : ;;
      *) warn "no ${SUITE}-security suite here -- security updates cannot come from this repo" ;;
    esac
  elif [ -d "$REPO_DIR" ]; then
    bad "directory exists but there is no $RELEASE"
    say "  ${DIM}Load a repo tree: it-repo load /media/<user>/<SSD>/repo${R}"
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
    warn "The next ansible-pull will revert it. Run: it-repo enable"
  else
    say "  not set (default false)"
  fi
  printf '\n'
}

# ---- load (mirror from media) -----------------------------------------------

# One suite tree, copied in two passes.
#
# PASS 1, packages: additive and --size-only. A .deb filename carries its
# version, so a file of the same name and size IS the same file -- there is
# nothing to re-read, which is what makes a re-load of a mostly-unchanged repo
# take seconds instead of re-hashing 40 GB off a USB bus. Nothing is deleted
# unless --prune: a withdrawn package that stays on disk is unreachable anyway
# once the index below no longer lists it.
#
# PASS 2, indexes: --checksum and --delete. dists/ is a few MB, its files change
# content at the same size, and it must match the media exactly or apt reports
# hashes that do not verify.
#
# Packages FIRST is deliberate. Interrupt the transfer between the passes and
# the index still describes the old, complete package set; the other order
# leaves an index promising packages that never arrived, and every apt-get
# install 404s.
# rsync, reduced to one honest line. The full output is kept and printed only
# when it fails -- a 40 GB mirror should not scroll a stats block past the one
# number the operator wants, but a failure must not hide it either.
run_rsync() {   # $1 = label, rest = rsync args
  local label="$1"; shift
  local out rc moved bytes total
  out=$(rsync "$@" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "    $label: rsync exited $rc"
    printf '%s\n' "$out" | sed 's/^/      /'
    return 1
  fi
  moved=$(printf '%s\n' "$out" | sed -n 's/^Number of regular files transferred: //p' | tr -d ',')
  bytes=$(printf '%s\n' "$out" | sed -n 's/^Total transferred file size: //p')
  total=$(printf '%s\n' "$out" | sed -n 's/^Number of files: \([0-9,]*\).*/\1/p')
  say "    $label: ${moved:-0} of ${total:-?} file(s) transferred${bytes:+, $bytes}"
  return 0
}

# One suite tree, copied in two passes.
#
# PASS 1, packages: additive and --size-only. A .deb filename carries its
# version, so a file of the same name and size IS the same file -- there is
# nothing to re-read, which is what makes re-loading a mostly-unchanged repo
# take seconds instead of re-hashing 40 GB across a USB bus. Nothing is deleted
# unless --prune: a withdrawn package left on disk is unreachable anyway once
# the index below stops listing it.
#
# PASS 2, indexes: --checksum and --delete. dists/ is a few MB, its files change
# content at the same size (so size+mtime is not enough), and it must match the
# media exactly or apt reports hashes that do not verify.
#
# Packages FIRST is deliberate. Interrupt the transfer between the passes and
# the index still describes the old, complete package set. The other order
# leaves an index promising packages that never arrived, and every install 404s.
mirror_tree() {   # $1 = source suite tree, $2 = dest suite tree
  local src="$1" dst="$2" rc=0 sfx
  local common=(-rlt --stats --human-readable
                --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r)
  [ "$DRY" -eq 1 ] && common+=(--dry-run)

  local pkg=("${common[@]}" --size-only --exclude=/dists/)
  [ "$PRUNE" -eq 1 ] && pkg+=(--delete)

  run_rsync "packages" "${pkg[@]}" "$src"/ "$dst"/ || return 1

  # Only the suites for THIS release. A stray jammy directory inside a noble
  # tree would otherwise ride along.
  [ "$DRY" -eq 1 ] || install -d -m 0755 "$dst/dists"
  while read -r sfx; do
    [ -n "$sfx" ] || continue
    if ! suite_matches "$sfx"; then
      say "    dists/$sfx: skipped (not $SUITE)"
      continue
    fi
    [ "$DRY" -eq 1 ] || install -d -m 0755 "$dst/dists/$sfx"
    run_rsync "dists/$sfx" "${common[@]}" --checksum --delete \
      "$src/dists/$sfx"/ "$dst/dists/$sfx"/ || rc=1
  done < <(suites_in "$src")
  return "$rc"
}

cmd_load() {
  local src="${1:-}" trees=""

  command -v rsync >/dev/null 2>&1 || die "rsync is not installed -- install it from the media first"

  if [ -n "$src" ]; then
    [ -d "$src" ] || die "no such directory: $src"
    # Accept the repo ROOT (…/repo), the ubuntu/ level, or the suite tree
    # itself, so nobody has to remember how the media was packed.
    if [ -n "$(suites_in "$src")" ]; then
      trees="$src"
    elif [ -d "$src/ubuntu" ]; then
      trees=$(find_trees "$src")
    else
      trees=$(find_trees "$src")
    fi
    [ -n "$trees" ] || die "no repo tree under $src -- expected a dists/<suite>/Release somewhere beneath it"
  else
    head2 "Looking for a repo on attached media"
    local mp
    while read -r mp; do
      [ -n "$mp" ] || continue
      trees="$trees$(find_trees "$mp")
"
    done <<< "$(media_mounts)"
    trees=$(printf '%s' "$trees" | sed '/^$/d')
    [ -n "$trees" ] || die "no repo tree found on attached media. Plug the SSD in, then: it-repo scan"
  fi

  # Keep only this box's release. Everything else is REPORTED, not silently
  # dropped -- "why is my 22.04 half missing" should never be a mystery.
  local t name keep="" skipped=0
  while read -r t; do
    [ -n "$t" ] || continue
    name=$(basename "$t")
    if suite_matches "$name" && valid_suite "$name"; then
      keep="$keep$t
"
    else
      warn "skipping $t -- release '$name', this box is '$SUITE'"
      skipped=$((skipped+1))
    fi
  done <<< "$trees"
  keep=$(printf '%s' "$keep" | sed '/^$/d')
  [ -n "$keep" ] || die "found $skipped repo tree(s) on media, none of them $SUITE"

  head2 "Plan"
  say "  this box   $SUITE"
  say "  into       $REPO_DIR"
  local total=0 n
  while read -r t; do
    [ -n "$t" ] || continue
    n=$(pkg_count "$t"); total=$((total+n))
    say "  from       $t"
    say "             $n .deb, suites: $(suites_in "$t" | tr '\n' ' ')"
  done <<< "$keep"
  if tree_ok "$REPO_DIR"; then
    say "  already    $(pkg_count "$TREE") .deb here, index built $(date -r "$RELEASE" '+%Y-%m-%d %H:%M' 2>/dev/null || echo unknown)"
  else
    say "  already    ${DIM}(nothing loaded yet)${R}"
  fi
  [ "$PRUNE" -eq 1 ] && warn "--prune: packages the media no longer carries will be DELETED here"

  if [ "$DRY" -eq 0 ]; then
    confirm "Mirror $total package(s) worth of tree into $REPO_DIR?" || die "aborted"
  fi

  install -d -o root -g root -m 0755 "$REPO_DIR" "$REPO_DIR/ubuntu"

  head2 "Mirroring"
  local failed=0 dst
  while read -r t; do
    [ -n "$t" ] || continue
    dst="$REPO_DIR/ubuntu/$(basename "$t")"
    say "  $(basename "$t")  ->  $dst"
    install -d -o root -g root -m 0755 "$dst"
    mirror_tree "$t" "$dst" || failed=$((failed+1))
  done <<< "$keep"

  if [ "$DRY" -eq 1 ]; then
    warn "dry run -- nothing was copied"
    return 0
  fi
  [ "$failed" -eq 0 ] || die "$failed tree(s) failed to mirror -- see the rsync output above"

  # rsync already lands new files root-owned 0644/0755 (--chmod, running as
  # root), so this only repairs anything an older load left wrong. `! -perm`
  # means a steady-state tree is walked but not written to.
  find "$REPO_DIR" ! -user root -exec chown root:root {} + 2>/dev/null
  find "$REPO_DIR" -type d ! -perm 0755 -exec chmod 0755 {} + 2>/dev/null
  find "$REPO_DIR" -type f ! -perm 0644 -exec chmod 0644 {} + 2>/dev/null

  logline "load from ${src:-auto-detected media} -> $REPO_DIR ($(pkg_count "$TREE") .deb, suites: $(suites_in "$TREE" | tr '\n' ' '))"
  head2 "Result"
  ok "$(pkg_count "$TREE") .deb at $TREE"
  say "  suites     $(suites_in "$TREE" | tr '\n' ' ')"
  if switched; then
    say "  ${DIM}apt is already on the local repo -- refresh it: it-repo verify${R}"
  else
    say "  ${DIM}Now switch apt over: it-repo enable${R}"
  fi
}

# ---- enable -----------------------------------------------------------------

persist_setting() {  # true|false
  local want="$1"
  install -d -o root -g "$(stat -c %G /opt/it 2>/dev/null || echo sudo)" -m 2770 /opt/it 2>/dev/null || true
  touch "$SITE_YML"
  if grep -qE '^offline_repo_enabled[[:space:]]*:' "$SITE_YML"; then
    sed -i -E "s|^offline_repo_enabled[[:space:]]*:.*|offline_repo_enabled: $want|" "$SITE_YML"
  else
    printf '\n# Set by it-repo -- keeps the switch across ansible-pull runs.\noffline_repo_enabled: %s\n' \
      "$want" >> "$SITE_YML"
  fi
}

cmd_enable() {
  tree_ok "$REPO_DIR" || die "no repo loaded at $REPO_DIR. Run: it-repo load <path>"

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
    # Every suite the tree actually carries, not just the bare codename:
    # noble-security is a separate suite and apt reads only what is listed here.
    local suites
    suites=$(suites_in "$TREE" | tr '\n' ' ')
    suites="${suites% }"
    [ -n "$suites" ] || suites="$SUITE"
    cat > "$SOURCE_FILE" <<EOF
# Written by it-repo. The offline_repo role rewrites this on each pull.
Types: deb
URIs: file://$TREE
Suites: $suites
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
    say "  ${DIM}Revert with: it-repo disable${R}"
    return 1
  fi
  # `update` exits 0 even when a source 404s, so look for the warning too.
  # grep on a here-string, not through a pipe: grep -q exits at the first match
  # and SIGPIPEs the producer, and `set -o pipefail` then returns 141 for the
  # whole pipeline -- so a pipeline that FOUND something reports failure and the
  # warning never prints.
  if grep -qiE '^(E|W): ' <<< "$out"; then
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
    local uris
    uris=$(apt-get install --print-uris --reinstall -y "$probe" 2>/dev/null)
    if grep -q "file://" <<< "$uris"; then
      ok "$n packages available, served from file://$TREE"
    else
      warn "$n packages available, but '$probe' would not come from the local repo"
    fi
  else
    ok "$n packages available"
  fi
  printf '\n'
}

# ---- howto (package-management reference) ------------------------------------
#
# A cheat sheet, not a wrapper: it PRINTS commands and never runs one. Written
# for whoever is at the box with no internet to search from -- which on an
# air-gapped EMI laptop is everyone. Sections are marked `## <key>` so
# `it-repo howto apt` shows one and `it-repo howto | grep -i remove` still works.

howto_text() {
cat <<'HOWTO'
## apt -- everyday
sudo apt update                     refresh the package lists. Do this first, always.
sudo apt upgrade                    install available updates. Never removes a package.
sudo apt full-upgrade               same, but MAY remove one if that is the only way to upgrade.
sudo apt install <pkg>              install it and whatever it depends on
sudo apt install --only-upgrade <pkg>   upgrade just that one
apt list --upgradable               what an upgrade would do, before doing it
sudo apt autoremove                 delete dependencies nothing needs any more
sudo apt clean                      empty the downloaded-.deb cache (/var/cache/apt/archives)

## find -- what exists, what is installed, where it came from
apt search <text>                   search names and descriptions
apt show <pkg>                      version, size, dependencies, description
apt policy <pkg>                    installed vs available, AND WHICH REPO it comes from
apt list --installed | grep <text>  installed packages matching text
dpkg -l | grep <text>               the same from dpkg, which also shows broken states
dpkg -L <pkg>                       every file that package installed
dpkg -S /path/to/file               which package owns a file
apt-cache depends <pkg>             what it needs
apt-cache rdepends <pkg>            what needs IT. Check this before removing anything.

## fix -- when apt is unhappy
sudo apt --fix-broken install       resolve half-installed or missing dependencies. Try this first.
sudo dpkg --configure -a            finish packages that unpacked but never configured
sudo apt update --fix-missing       retry after a failed download
sudo dpkg --audit                   list packages in a broken state
"Could not get lock /var/lib/dpkg/lock" -- another apt is already running.
   ps aux | grep -E 'apt|dpkg|unattended'   then WAIT. Never delete the lock file.
"The following packages have been kept back" -- the upgrade needs to add or remove
   something, and `upgrade` is not allowed to. That is what `full-upgrade` is for.

## remove -- taking software off
sudo apt remove <pkg>               remove the program, KEEP its config in /etc
sudo apt purge <pkg>                remove the program AND its config
sudo apt autopurge <pkg>            purge it and the dependencies nothing else needs
apt-cache rdepends <pkg>            LOOK FIRST. Removing something others depend on takes them too.

## hold -- keep a version where it is
sudo apt-mark hold <pkg>            never upgrade this package
sudo apt-mark unhold <pkg>          release it
apt-mark showhold                   what is currently held
apt-mark showmanual                 what was installed deliberately, vs pulled in as a dependency

## deb -- one file, by hand
sudo apt install ./thing.deb        BEST: installs it and resolves its dependencies from the repo
sudo dpkg -i thing.deb              installs ONLY that file. Dependencies become your problem:
                                       sudo apt --fix-broken install
apt-get download <pkg>              fetch the .deb, install nothing
sudo apt-get install --download-only <pkg>   fetch it AND its dependencies -> /var/cache/apt/archives
dpkg-deb -c thing.deb               list what is inside, without installing
dpkg-deb -I thing.deb               its version and dependencies

## offline -- this box's local repo
sudo it-repo status                 is a repo loaded, which suites, is apt pointed at it
sudo it-repo scan                   what repo trees are on the attached media
sudo it-repo load                   mirror the media into /srv/repo (DTAs may run this)
sudo it-repo enable                 park the online sources, point apt at /srv/repo (admin)
sudo it-repo disable                put the online sources back (admin)
sudo it-repo verify                 apt-get update, and prove a package really resolves
After any load:   sudo apt update   then   sudo apt upgrade
apt policy <pkg>                    confirm it comes from file:///srv/repo, not the internet
"0 to upgrade" when you expected some? Check the -security suite is actually there:
   sudo it-repo status

## python -- pip on Ubuntu 24.04
24.04 refuses to pip-install into the system Python:
   "error: externally-managed-environment"
That is correct, not a fault -- dpkg owns those files. Use an environment instead.
eng                                 activate the shared /opt/eng-venv (a shell alias; dev + EMI)
python3 -m venv ~/venv              make your own
source ~/venv/bin/activate          enter it -- the prompt shows its name. `deactivate` leaves.
pip install <pkg>                   safe now: it lands in the venv, not in the OS
sudo apt install python3-<pkg>      the packaged version, when one exists. Preferred offline.
NEVER  sudo pip install --break-system-packages ...
   It overwrites dpkg-managed files and breaks apt later, on a box you cannot casually rebuild.
Offline: on a connected box   pip download -d wheels <pkg>
         carry the wheels/ folder, then
         pip install --no-index --find-links wheels <pkg>

## snap -- the snap store, which apt does not manage
snap list                           installed snaps and their versions
sudo snap refresh                   update them. Needs the internet -- there is no local mirror.
snap changes                        recent snap activity
Air-gapped boxes never update snaps. Firefox and the GNOME platform are snaps.

## after -- what apt alone does not finish
ls /var/run/reboot-required         if it exists, a reboot is pending (kernel, libc, systemd)
cat /var/run/reboot-required.pkgs   which packages asked for it
uname -r                            the kernel you are RUNNING, which is not the newest installed
pro status                          Ubuntu Pro / ESM entitlement
sudo it-checklist                   the org checklist -- run it after anything significant
HOWTO
}

cmd_howto() {
  local want="${1:-}" topics
  # The key is the first word after "## ". Do NOT require a space and a subtitle
  # after it: a section headed just "## remove" then vanishes from the topic
  # list and `howto remove` answers "no such topic".
  topics=$(howto_text | sed -n 's/^## \([a-z]*\).*/\1/p' | tr '\n' ' ')

  if [ -n "$want" ]; then
    case " $topics " in
      *" $want "*) ;;
      *) die "no such topic: $want
Topics: $topics" ;;
    esac
    howto_text | awk -v t="$want" '/^## / { show = ($2 == t) } show { print }'
  else
    howto_text
  fi | awk -v b="$B" -v r="$R" '
    /^## / { sub(/^## /, ""); printf "\n%s%s%s\n", b, $0, r; next }
    { print }'

  [ -n "$want" ] || printf '\n%sOne section at a time: it-repo howto <%s>%s\n' \
    "$DIM" "$(printf '%s' "$topics" | sed 's/ $//; s/ /|/g')" "$R"
  echo
}

# ---- dispatch ---------------------------------------------------------------

ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY=1 ;;
    --yes|-y)   ASSUME_YES=1 ;;
    --prune)    PRUNE=1 ;;
    --suite)    SUITE_OVERRIDE="${2:-}"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
set -- "${ARGS[@]:-}"

# --suite is parsed after the globals were computed, so redo the ones that
# depend on it.
if [ -n "$SUITE_OVERRIDE" ]; then
  SUITE="$SUITE_OVERRIDE"
  TREE="$REPO_DIR/ubuntu/$SUITE"
  RELEASE="$TREE/dists/$SUITE/Release"
fi
valid_suite "$SUITE" || die "not a usable release codename: '$SUITE'"

case "${1:-status}" in
  status|check|"") cmd_status ;;
  scan|media)      cmd_scan ;;
  load|mirror)     shift; cmd_load "${1:-}" ;;
  enable)          cmd_enable ;;
  disable)         cmd_disable ;;
  verify)          cmd_verify ;;
  howto|cheat|ref) shift; cmd_howto "${1:-}" ;;
  *)               usage; exit 1 ;;
esac
