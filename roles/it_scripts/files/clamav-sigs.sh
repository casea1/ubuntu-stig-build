#!/usr/bin/env bash
# it-clamav -- install ClamAV signature archives by hand, and prove they took.
#
# For air-gapped boxes: freshclam cannot reach anything, so signatures arrive as
# a tar.gz carried in on media. Drop it in /opt/it/clamavsigs and run `install`.
#
# Usage:
#   it-clamav                    what is installed, how old, is the daemon serving it
#   it-clamav check              ...the same thing
#   it-clamav list               archives waiting in /opt/it/clamavsigs
#   it-clamav install [ARCHIVE]  install the newest archive (or the one named)
#   it-clamav rollback           put the previous signature set back
#   --force                      install even if it is not newer than what is on disk
#   --no-test                    skip the EICAR detection test
set -uo pipefail

SIG_SRC="${CLAMAV_SIG_SRC:-/opt/it/clamavsigs}"
DB_DIR=/var/lib/clamav
BACKUP_ROOT=/var/backups/clamav
LOG=/var/log/clamav-sig-install.log
FORCE=0
DO_TEST=1

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

# ---- signature-file helpers -------------------------------------------------
# `sigtool --info` does more than read a header: a CVD carries a digital
# signature from the ClamAV project, and sigtool verifies it. That is the whole
# reason to use it instead of `ls` -- it proves the archive was not altered on
# the media it travelled on.
sig_field() {  # file field -> value
  sigtool --info "$1" 2>/dev/null | awk -F': ' -v k="$2" '$1==k {print $2; exit}'
}
sig_verified() { sigtool --info "$1" 2>/dev/null | grep -q '^Verification OK'; }

db_files() {  # the signature files currently installed
  find "$DB_DIR" -maxdepth 1 -type f \( -name '*.cvd' -o -name '*.cld' \) 2>/dev/null | sort
}

installed_version() {  # base (daily|main|bytecode) -> version number, or empty
  local f
  for f in "$DB_DIR/$1.cvd" "$DB_DIR/$1.cld"; do
    [ -f "$f" ] && { sig_field "$f" Version; return; }
  done
}

daemon_db_version() {  # what the RUNNING daemon reports, not what is on disk
  clamdscan --version 2>/dev/null | awk -F/ '{print $2; exit}'
}

age_days() { echo $(( ( $(date +%s) - $(stat -c %Y "$1") ) / 86400 )); }

# ---- check ------------------------------------------------------------------
cmd_check() {
  head2 "Installed signature databases  ($DB_DIR)"
  local any=0 f v b a
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    any=1
    v=$(sig_field "$f" Version); b=$(sig_field "$f" 'Build time'); a=$(age_days "$f")
    printf '  %-16s version %-8s %s\n' "$(basename "$f")" "${v:-?}" "${b:-unknown build time}"
    if [ "$a" -gt 30 ];  then bad  "    $a days old -- well past the point of being useful"
    elif [ "$a" -gt 7 ]; then warn "    $a days old"
    else                      ok   "    $a days old"
    fi
    sig_verified "$f" && ok "    digital signature verified" \
                      || bad "    DIGITAL SIGNATURE DID NOT VERIFY"
  done < <(db_files)
  [ "$any" = 1 ] || bad "  No signature database installed at all."

  head2 "Engine"
  say "  $(clamscan --version 2>/dev/null || echo 'clamscan not installed')"

  head2 "Services"
  local dstate fstate
  dstate=$(systemctl is-active clamav-daemon 2>/dev/null || echo unknown)
  fstate=$(systemctl is-active clamav-freshclam 2>/dev/null || echo unknown)
  printf '  clamav-daemon    : %s\n' "$dstate"
  printf '  clamav-freshclam : %s\n' "$fstate"

  if [ "$dstate" = active ]; then
    local dv iv
    dv=$(daemon_db_version); iv=$(installed_version daily)
    printf '  daemon is serving: daily version %s\n' "${dv:-?}"
    if [ -n "$dv" ] && [ -n "$iv" ] && [ "$dv" != "$iv" ]; then
      warn "  Daemon is serving $dv but $iv is on disk -- it has not reloaded."
      warn "  Fix with: systemctl restart clamav-daemon"
    fi
  else
    warn "  clamav-daemon is not running, so scans fall back to standalone clamscan (slow)."
  fi

  if [ "$fstate" = active ]; then
    warn "  freshclam is running. On an air-gapped box it cannot reach anything;"
    warn "  on a connected one it will overwrite manually installed signatures."
  fi

  head2 "Scanner socket (can a non-admin DTA use the daemon?)"
  local sock mode
  sock=$(awk '/^LocalSocket[[:space:]]/{print $2; exit}' /etc/clamav/clamd.conf 2>/dev/null)
  sock="${sock:-/run/clamav/clamd.ctl}"
  if [ -S "$sock" ]; then
    printf '  %s  %s\n' "$sock" "$(stat -c '%A %U:%G' "$sock")"
    mode=$(stat -c %a "$sock")
    # `dta-log` uses clamdscan --fdpass, which opens the file as the DTA and
    # hands the daemon the descriptor -- so the DTA's own read rights are what
    # matter, not the clamav user's. All the DTA needs is to WRITE to this
    # socket. Debian/Ubuntu ship LocalSocketMode 666, which allows exactly that.
    if [ "${mode: -1}" -ge 6 ]; then
      ok "world-writable -- any local account can submit a scan"
      ok "dta-log will use the daemon (fast); --fdpass keeps the DTA's read rights"
    else
      warn "not world-writable -- a dta account cannot reach the daemon"
      warn "dta-log falls back to standalone clamscan (works, just slow)"
      warn "to use the daemon instead, set LocalSocketMode 666 (or LocalSocketGroup dta)"
      warn "in /etc/clamav/clamd.conf and restart clamav-daemon"
    fi
  else
    warn "  $sock does not exist -- the daemon is not running."
  fi

  head2 "Archives available"
  cmd_list quiet
  say ""
}

cmd_list() {
  local quiet="${1:-}" n=0 f
  if [ ! -d "$SIG_SRC" ]; then
    warn "  $SIG_SRC does not exist."
    return
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n + 1))
    printf '  %s  %s  %s\n' \
      "$(date -r "$f" '+%Y-%m-%d %H:%M')" "$(du -h "$f" | cut -f1)" "$f"
  done < <(find "$SIG_SRC" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.tgz' \) \
             -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-)
  [ "$n" -gt 0 ] || warn "  No *.tar.gz in $SIG_SRC"
  [ "$quiet" = quiet ] || say ""
}

# ---- install ----------------------------------------------------------------
cmd_install() {
  local archive="${1:-}"
  command -v sigtool >/dev/null 2>&1 || die "sigtool not found (install the 'clamav' package)."

  if [ -z "$archive" ]; then
    archive=$(find "$SIG_SRC" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.tgz' \) \
                -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2-)
    [ -n "$archive" ] || die "No *.tar.gz found in $SIG_SRC. Copy the signature archive there first."
  fi
  [ -f "$archive" ] || die "No such archive: $archive"

  head2 "Archive"
  say "  $archive"
  say "  ${DIM}$(date -r "$archive" '+%Y-%m-%d %H:%M')  $(du -h "$archive" | cut -f1)${R}"
  logline "install: starting from $archive"

  # Extract and validate BEFORE touching the live database. The old procedure
  # deleted the working signatures first and extracted second, which turns a
  # truncated archive into a box with no antivirus at all.
  local tmp; tmp=$(mktemp -d /tmp/clamav-sigs.XXXXXX) || die "mktemp failed"
  trap 'rm -rf "$tmp"' EXIT
  tar xzf "$archive" -C "$tmp" 2>/dev/null || die "Could not extract $archive (corrupt or not a gzip tar?)."

  mapfile -t NEW < <(find "$tmp" -type f \( -name '*.cvd' -o -name '*.cld' \) | sort)
  [ "${#NEW[@]}" -gt 0 ] || die "The archive holds no .cvd/.cld files. Is this a ClamAV signature archive?"

  head2 "Validating ${#NEW[@]} signature file(s)"
  local f base v newer=0
  for f in "${NEW[@]}"; do
    base=$(basename "$f"); base="${base%.*}"
    v=$(sig_field "$f" Version)
    if ! sig_verified "$f"; then
      bad "$(basename "$f"): digital signature DID NOT VERIFY -- refusing to install."
      die "Archive rejected. Re-download it; do not use this copy."
    fi
    local cur; cur=$(installed_version "$base")
    printf '  %-16s version %-8s %s\n' "$(basename "$f")" "${v:-?}" "$(sig_field "$f" 'Build time')"
    ok "    signature verified"
    if [ -n "$cur" ] && [ -n "$v" ]; then
      if [ "$v" -gt "$cur" ] 2>/dev/null; then
        ok "    newer than installed ($cur -> $v)"; newer=1
      elif [ "$v" -eq "$cur" ] 2>/dev/null; then
        warn "    same as installed ($cur)"
      else
        warn "    OLDER than installed ($cur -> $v)"
      fi
    else
      newer=1
    fi
  done

  if [ "$newer" = 0 ] && [ "$FORCE" = 0 ]; then
    warn ""
    warn "Nothing in this archive is newer than what is already installed."
    warn "Use --force to install it anyway."
    exit 0
  fi

  # ---- back up ----
  local ts backup; ts=$(date +%Y%m%d-%H%M%S); backup="$BACKUP_ROOT/$ts"
  mkdir -p "$backup"; chmod 0700 "$BACKUP_ROOT"
  local had=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    cp -a "$f" "$backup/" && had=1
  done < <(db_files)
  head2 "Backup"
  if [ "$had" = 1 ]; then ok "previous signatures -> $backup"
  else warn "nothing to back up (no signatures were installed)"; fi

  # ---- stop services, remembering what was running ----
  local was_daemon=0 was_fresh=0
  systemctl is-active --quiet clamav-freshclam 2>/dev/null && { was_fresh=1; systemctl stop clamav-freshclam; }
  systemctl is-active --quiet clamav-daemon    2>/dev/null && { was_daemon=1; systemctl stop clamav-daemon; }

  # ---- install ----
  head2 "Installing"
  for f in "${NEW[@]}"; do
    base=$(basename "$f")
    # A .cvd and a .cld of the same database must never both be present -- clamd
    # loads one of them and it is not necessarily the newer one.
    rm -f "$DB_DIR/${base%.*}.cvd" "$DB_DIR/${base%.*}.cld"
    install -o clamav -g clamav -m 0644 "$f" "$DB_DIR/$base" \
      && ok "$base" || bad "$base FAILED"
  done
  logline "install: placed ${#NEW[@]} file(s) from $archive"

  # ---- restart and confirm ----
  head2 "Confirming"
  if [ "$was_daemon" = 1 ] || systemctl is-enabled --quiet clamav-daemon 2>/dev/null; then
    systemctl start clamav-daemon
    local i=0
    while [ $i -lt 60 ]; do
      clamdscan --ping 1 >/dev/null 2>&1 && break
      i=$((i + 1)); sleep 1
    done
    if clamdscan --ping 1 >/dev/null 2>&1; then
      ok "clamav-daemon restarted and answering (${i}s)"
    else
      bad "clamav-daemon did not come back within 60s."
      bad "Roll back with: it-clamav rollback"
      exit 1
    fi
    local dv iv; dv=$(daemon_db_version); iv=$(installed_version daily)
    if [ -n "$dv" ] && [ "$dv" = "$iv" ]; then
      ok "daemon is serving daily version $dv -- matches what was just installed"
    else
      bad "daemon reports '$dv' but '$iv' is on disk. The reload did not take."
      exit 1
    fi
  else
    warn "clamav-daemon is not enabled; nothing to reload."
  fi
  [ "$was_fresh" = 1 ] && systemctl start clamav-freshclam

  # ---- functional test ----
  # Proof the engine actually detects with the new database. The test string is
  # assembled at runtime: written out whole, this file would itself trip every
  # AV product that scanned the repo.
  if [ "$DO_TEST" = 1 ]; then
    local td; td=$(mktemp -d /tmp/clamav-test.XXXXXX)
    printf '%s%s' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR' '-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' \
      > "$td/testfile"
    local out rc
    if clamdscan --ping 1 >/dev/null 2>&1; then
      out=$(clamdscan --fdpass --no-summary "$td/testfile" 2>&1); rc=$?
    else
      out=$(clamscan --no-summary "$td/testfile" 2>&1); rc=$?
    fi
    rm -rf "$td"
    if [ "$rc" -eq 1 ]; then
      ok "detection test passed -- the engine flagged the EICAR test file"
    else
      bad "detection test FAILED (exit $rc): $out"
      bad "The database loaded but the engine is not detecting. Roll back and investigate."
      exit 1
    fi
  fi

  head2 "Done"
  ok "Signatures installed from $(basename "$archive")"
  say "  ${DIM}Backup: $backup    Log: $LOG${R}"
  logline "install: OK, daemon serving $(daemon_db_version)"
  say ""
}

# ---- rollback ---------------------------------------------------------------
cmd_rollback() {
  local backup
  backup=$(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1)
  [ -n "$backup" ] || die "No backup found under $BACKUP_ROOT."
  head2 "Rolling back to $backup"
  systemctl stop clamav-daemon 2>/dev/null
  rm -f "$DB_DIR"/*.cvd "$DB_DIR"/*.cld
  local f
  for f in "$backup"/*; do
    [ -f "$f" ] || continue
    install -o clamav -g clamav -m 0644 "$f" "$DB_DIR/$(basename "$f")" && ok "$(basename "$f")"
  done
  systemctl start clamav-daemon 2>/dev/null
  logline "rollback: restored $backup"
  ok "Restored. Verify with: it-clamav check"
  say ""
}

# ---- dispatch ---------------------------------------------------------------
CMD=""; ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --force)   FORCE=1; shift ;;
    --no-test) DO_TEST=0; shift ;;
    check|list|install|rollback) CMD="$1"; shift ;;
    -*) die "unknown option: $1  (try --help)" ;;
    *)  [ -z "$CMD" ] && die "unknown command: $1  (try --help)"; ARG="$1"; shift ;;
  esac
done

case "${CMD:-check}" in
  check)    cmd_check ;;
  list)     head2 "Archives in $SIG_SRC"; cmd_list ;;
  install)  cmd_install "$ARG" ;;
  rollback) cmd_rollback ;;
esac
