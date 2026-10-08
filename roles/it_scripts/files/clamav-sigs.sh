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
#   it-clamav scan PATH...       scan a file or folder ON DEMAND (proves the
#                                engine first, then scans; use after bringing
#                                files on from removable media)
#   it-clamav test               does the engine actually DETECT? (EICAR)
#   it-clamav image-save <dir>   AIR-GAP: save the scanner image to a USB
#   it-clamav image-load <dir>   AIR-GAP: load it on the fielded box
#   it-clamav sync               copy freshclam's host database to the scanner
#   it-clamav revert [--purge]   hand scanning back to the host engine once
#                                a fixed clamav is installed (clamav#1786)
#   it-clamav rollback           put the previous signature set back
#   --force                      install even if it is not newer than what is on disk
#   --no-test                    skip the EICAR detection test
set -uo pipefail

SIG_SRC="${CLAMAV_SIG_SRC:-/opt/it/clamavsigs}"
# Where the ACTIVE engine reads its signatures. The containerised engine keeps
# its own copy (the image's entrypoint chowns the directory to its own clamav
# user, so it cannot share the host's), and installing into the wrong one is a
# silent no-op. CLAMAV_DB_DIR overrides the choice outright (testing, or a
# non-standard layout); without it the container auto-detect decides.
if [ -n "${CLAMAV_DB_DIR:-}" ]; then
  DB_DIR=$CLAMAV_DB_DIR
else
  DB_DIR=/var/lib/clamav
  [ -d /var/lib/clamav-container ] && [ -r /etc/clamav/clamd-container.conf ] \
    && DB_DIR=/var/lib/clamav-container
fi
CLAMD_CONF=/etc/clamav/clamd.conf
FRESHCLAM_CONF=/etc/clamav/freshclam.conf
conf_value() {  # key -> its value in freshclam.conf, else clamd.conf; fails if unset
  local c v
  for c in "$FRESHCLAM_CONF" "$CLAMD_CONF"; do
    v=$(awk -v k="$1" '$1==k {gsub(/"/, "", $2); print $2; exit}' "$c" 2>/dev/null)
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  done
  return 1
}
# ClamAV 1.5 verifies each .cvd against a detached <db>-<version>.cvd.sign with
# this certificate. Without it a 1.5 engine cannot verify anything. The
# directory is CVDCertsDirectory when the config sets one; a package built with
# another default would otherwise get a false "missing" here.
CVD_CERT="$(conf_value CVDCertsDirectory || echo /etc/clamav/certs)/clamav.crt"
BACKUP_ROOT=/var/backups/clamav
LOG=/var/log/clamav-sig-install.log
FORCE=0
DO_TEST=1
PURGE=0

[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

# On a FIPS host OpenSSL refuses to initialise MD5, which ClamAV -- and sigtool,
# which verifies the CVD signatures -- depend on. The clamav_fips role writes
# this config after proving it works; on Ubuntu FIPS it cannot, and the file is
# absent. Use it wherever it does exist.
if [ -r /etc/clamav/openssl-clamav.cnf ]; then
  export OPENSSL_CONF=/etc/clamav/openssl-clamav.cnf
fi

# Where the containerised engine lives, when clamav_container has stood one up.
CTR_CONF=/etc/clamav/clamd-container.conf
CTR_IMAGE=""
[ -r /etc/clamav/container-image ] && CTR_IMAGE=$(cat /etc/clamav/container-image)

# sigtool verifies a CVD's digital signature, which needs MD5. Where the host
# cannot do MD5 but a container image is staged, run sigtool in there instead --
# otherwise every archive would be rejected as unverifiable.
SIGTOOL_MODE=native
if ! openssl md5 /dev/null >/dev/null 2>&1 && [ -n "$CTR_IMAGE" ]; then
  SIGTOOL_MODE=container
fi

# `clamdscan --ping 1` returns 0 even when it cannot connect (seen on ASP-2, where
# it reported the HOST socket missing and still succeeded), so check the socket
# exists and use the = form.
ctr_alive() {
  local sock
  sock=$(awk '/^LocalSocket[[:space:]]/{print $2; exit}' "$CTR_CONF" 2>/dev/null)
  [ -n "$sock" ] && [ -S "$sock" ] || return 1
  clamdscan -c "$CTR_CONF" --ping=1 >/dev/null 2>&1
}

sigtool_info() {  # file -> `sigtool --info` output
  if [ "$SIGTOOL_MODE" = container ]; then
    # --user 0:0: the extracted files are root-only (0700/0600). Without it an
    # image that gained a USER, or a remapped docker, would report every archive
    # as "did not verify" -- failing closed, but with the wrong diagnosis.
    docker run --rm --network none --security-opt no-new-privileges --user 0:0 \
      -v "$(cd "$(dirname "$1")" && pwd):/w:ro" "$CTR_IMAGE" \
      sigtool --info "/w/$(basename "$1")" 2>/dev/null
  else
    sigtool --info "$1" 2>/dev/null
  fi
}

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
  sigtool_info "$1" | awk -F': ' -v k="$2" '$1==k {print $2; exit}'
}
sig_verified() { sigtool_info "$1" | grep -q '^Verification OK'; }

db_files() {  # the signature databases currently installed (.cvd/.cld)
  find "$DB_DIR" -maxdepth 1 -type f \( -name '*.cvd' -o -name '*.cld' \) 2>/dev/null | sort
}

# The whole installed set: databases AND their detached .cvd.sign files. This is
# what a backup must hold and a rollback must restore -- on a 1.5 engine a .cvd
# put back without its .sign is a .cvd clamd refuses to load.
db_set_files() {
  find "$DB_DIR" -maxdepth 1 -type f \
    \( -name '*.cvd' -o -name '*.cld' -o -name '*.cvd.sign' \) 2>/dev/null | sort
}

# ---- ClamAV 1.5 detached signatures -----------------------------------------
# From 1.5 a .cvd is verified against <db>-<version>.cvd.sign beside it. When
# MD5 verification is disabled (FIPSCryptoHashLimits, or a FIPS OpenSSL) a .cvd
# WITHOUT its .sign is rejected outright -- "unable to verify CVD with detached
# signature file and MD5 verification is disabled" -- and clamd will not start.
# 1.4 ignores .sign files, so carrying them is harmless there.
sign_name() {  # db-file version -> the .sign file name that belongs to it
  local b; b=$(basename "$1"); printf '%s-%s.cvd.sign' "${b%.*}" "$2"
}

sign_for() {  # db-file -> path of its matching .sign in the same directory, or fail
  local v s
  v=$(sig_field "$1" Version); [ -n "$v" ] || return 1
  s="$(dirname "$1")/$(sign_name "$1" "$v")"
  [ -f "$s" ] && printf '%s' "$s"
}

ver_ge_15() {  # "major minor" -> 0 if >= 1.5
  local maj min; read -r maj min <<<"$1"
  [ -n "$maj" ] && [ -n "$min" ] || return 1
  [ "$maj" -gt 1 ] || { [ "$maj" -eq 1 ] && [ "$min" -ge 5 ]; }
}

host_engine_ver() {  # -> "major minor" of the host clamscan, or empty
  clamscan --version 2>/dev/null \
    | sed -n 's/^ClamAV \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p' | head -1
}

# Can the engine reading a database directory fall back to the legacy MD5
# check of a .cvd? Not when OpenSSL refuses MD5 (FIPS, checked under the
# OPENSSL_CONF this script exported) or FIPSCryptoHashLimits is on. The
# containerised engine's OpenSSL is a stock build -- the reason it exists -- so
# for it only the configuration can switch MD5 off.
FIPS_LIMITS_RE='^[[:space:]]*FIPSCryptoHashLimits[[:space:]]+(yes|true|1)([[:space:]]|$)'
md5_verification_off() {  # dir -> 0 if off
  local c
  for c in "$CLAMD_CONF" "$FRESHCLAM_CONF"; do
    grep -qiE "$FIPS_LIMITS_RE" "$c" 2>/dev/null && return 0
  done
  if [ "$1" = /var/lib/clamav-container ]; then
    grep -qiE "$FIPS_LIMITS_RE" "$CTR_CONF" 2>/dev/null
    return
  fi
  ! openssl md5 /dev/null >/dev/null 2>&1
}

# What the engine that READS a database directory needs from .cvd.sign files:
#   required     1.5+ with MD5 verification off: a .cvd without its .sign is
#                rejected and clamd does not start
#   recommended  1.5+ with MD5 available: such a .cvd still loads, by MD5
#   none         1.4 and older ignore .sign files
# "1.5+" answers yes when in doubt -- an unreadable host version, or an image
# tag that is not a number (latest, stable: today's release, which is 1.5+).
# The containerised engine's version is its image tag (clamav/clamav:1.4.3).
sign_policy() {  # [dir] -> sets SIGN_POLICY and ENGINE_VER_DESC
  local dir="${1:-$DB_DIR}" hv tag tv is15=1
  hv=$(host_engine_ver)
  if [ -n "$hv" ]; then
    ENGINE_VER_DESC="host clamscan ${hv/ /.}"
    ver_ge_15 "$hv" || is15=0
  else
    ENGINE_VER_DESC="host clamscan version unreadable (assuming 1.5+)"
  fi
  if [ "$dir" = /var/lib/clamav-container ]; then
    tag="${CTR_IMAGE##*:}"
    [ "$tag" = "$CTR_IMAGE" ] && tag=""   # no tag at all = latest
    ENGINE_VER_DESC="$ENGINE_VER_DESC; scanner image ${CTR_IMAGE:-unknown}"
    tv=$(printf '%s' "$tag" | sed -n 's/^\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p')
    if [ -z "$tv" ] || ver_ge_15 "$tv"; then is15=1; fi
  fi
  if [ "$is15" = 0 ]; then
    SIGN_POLICY=none
  elif md5_verification_off "$dir"; then
    SIGN_POLICY=required; ENGINE_VER_DESC="$ENGINE_VER_DESC; MD5 verification off"
  else
    SIGN_POLICY=recommended; ENGINE_VER_DESC="$ENGINE_VER_DESC; MD5 verification available"
  fi
}

sign_policy_line() {  # one line for the report
  case "$SIGN_POLICY" in
    required)    printf '.cvd.sign REQUIRED' ;;
    recommended) printf '.cvd.sign recommended (a .cvd without one still loads by MD5)' ;;
    *)           printf '.cvd.sign not used by this engine' ;;
  esac
}

installed_version() {  # base (daily|main|bytecode) -> version number, or empty
  local f
  for f in "$DB_DIR/$1.cvd" "$DB_DIR/$1.cld"; do
    [ -f "$f" ] && { sig_field "$f" Version; return; }
  done
}

daemon_db_version() {  # what the RUNNING daemon reports, or empty
  # clamd can have the VERSION command disabled, in which case clamdscan falls
  # back to printing the LOCAL version -- which says nothing about what the
  # daemon loaded. Detect that and report nothing rather than something wrong.
  local out
  out=$(clamdscan --version 2>&1) || return 1
  printf '%s' "$out" | grep -qi 'VERSION command disabled' && return 1
  printf '%s' "$out" | awk -F/ 'NF>1 {print $2; exit}'
}

# The authoritative check: does the engine actually DETECT? A FIPS host is the
# reason this exists -- OpenSSL there refuses to initialise MD5, which is what
# ClamAV hashes with, so the engine loads every signature and then scans zero
# bytes, reporting every file OK. Assembled at runtime so this file does not
# itself trip an AV scan of the repo.
engine_selftest() {  # -> 0 detects, 1 does not.  Sets SELFTEST_ENGINE/SELFTEST_OUT
  local td rc
  td=$(mktemp -d /tmp/clamav-test.XXXXXX) || return 1
  printf '%s%s' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR' '-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' \
    > "$td/canary"
  # Same order of preference as dta-log, so the test reflects what a transfer
  # would actually use.
  if [ -r "$CTR_CONF" ] && ctr_alive; then
    SELFTEST_ENGINE="containerised clamd"
    SELFTEST_OUT=$(clamdscan -c "$CTR_CONF" --fdpass "$td/canary" 2>&1); rc=$?
  elif clamdscan --ping=1 >/dev/null 2>&1; then
    SELFTEST_ENGINE="clamdscan (host daemon)"
    SELFTEST_OUT=$(clamdscan --fdpass "$td/canary" 2>&1); rc=$?
  else
    SELFTEST_ENGINE="clamscan (standalone)"
    SELFTEST_OUT=$(clamscan "$td/canary" 2>&1); rc=$?
  fi
  rm -rf "$td"
  [ "$rc" -eq 1 ]
}

# clamd binds its socket only AFTER loading the signature set, so "up but not
# answering" is NORMAL for the first minute or so. It is also exactly what a
# WEDGED container looks like, and the only thing separating the two is TIME.
#
# This used to have no time bound, so a container that had been hung for nine
# days still reported "still starting -- re-run in a minute" (ASP-2,
# 2026-09-23). The advice was unfollowable and the box had had no working AV
# since the container stopped logging. Both checks below are bounded now.
CTR_START_GRACE=300        # 60-90s is typical for ~3.6M signatures; be generous
CTR_LOG_STALE=3600         # clamd SelfChecks every ~10 min; an hour of silence is wedged

# Seconds since the container started. Fails if it is not running at all.
ctr_uptime() {
  local started t
  started=$(docker inspect -f '{{.State.StartedAt}}' clamav-container 2>/dev/null) || return 1
  [ -n "$started" ] || return 1
  t=$(date -d "$started" +%s 2>/dev/null) || return 1
  echo $(( $(date +%s) - t ))
}

# Seconds since its newest log line. clamd logs a SelfCheck every ~10 minutes,
# so this is a liveness signal independent of the socket -- a container can be
# "Up 9 days" to docker and have stopped doing anything a week ago.
ctr_log_age() {
  local last t
  last=$(docker logs --tail 1 --timestamps clamav-container 2>/dev/null | awk '{print $1}')
  [ -n "$last" ] || return 1
  t=$(date -d "$last" +%s 2>/dev/null) || return 1
  echo $(( $(date +%s) - t ))
}

ctr_running() {
  [ "$(systemctl is-active clamav-container 2>/dev/null)" = active ] || return 1
  docker ps --filter name=clamav-container --format '{{.Names}}' 2>/dev/null \
    | grep -q clamav-container
}

ctr_starting() {
  ctr_running || return 1
  local up; up=$(ctr_uptime) || return 1
  [ "$up" -lt "$CTR_START_GRACE" ]
}

# Up, past the grace, and still not answering: not starting. Broken.
ctr_wedged() {
  ctr_running || return 1
  ctr_alive && return 1
  local up; up=$(ctr_uptime) || return 1
  [ "$up" -ge "$CTR_START_GRACE" ]
}

human_secs() {   # $1 = seconds -> "9d 2h" / "14m"
  local s="${1:-0}"
  if   [ "$s" -ge 86400 ]; then printf '%dd %dh' $(( s / 86400 )) $(( (s % 86400) / 3600 ))
  elif [ "$s" -ge 3600 ];  then printf '%dh %dm' $(( s / 3600 ))  $(( (s % 3600) / 60 ))
  else printf '%dm' $(( s / 60 )); fi
}

# When the containerised daemon is configured but not answering, the useful
# information is in the container's own log and in the unit state -- not in
# anything the host tools can infer. Print it here rather than sending the
# operator away for another round trip.
container_postmortem() {
  local state
  state=$(systemctl is-active clamav-container 2>/dev/null || echo unknown)
  printf '\n  %sclamav-container unit : %s%s\n' "$DIM" "$state" "$R"
  say "  ${DIM}--- docker ps -a ---${R}"
  docker ps -a --filter name=clamav-container \
    --format '  {{.Names}}  {{.Status}}  {{.Image}}' 2>&1 | sed 's/^/  /' | head -5
  say "  ${DIM}--- docker logs (last 30) ---${R}"
  docker logs --tail 30 clamav-container 2>&1 | sed 's/^/  /' | head -40
  say "  ${DIM}--- socket directory ---${R}"
  ls -la "$(dirname "$(awk '/^LocalSocket[[:space:]]/{print $2; exit}' "$CTR_CONF" 2>/dev/null)")" 2>&1 \
    | sed 's/^/  /' | head -8
  say "  ${DIM}--- systemctl status (last 15) ---${R}"
  systemctl --no-pager --lines=15 status clamav-container 2>&1 | sed 's/^/  /' | head -25
  say ""
}

# Which engine this box actually scans with, and why. `it-clamav test` failing
# means one of these is not what it should be, and guessing which wastes a round
# trip -- so print all of it.
engine_report() {
  head2 "Scanning engine"
  printf '  kernel FIPS mode    : %s\n' "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo '?')"

  if openssl md5 /dev/null >/dev/null 2>&1; then
    ok "host OpenSSL MD5    : available"
  else
    warn "host OpenSSL MD5    : REFUSED (FIPS). The host ClamAV cannot hash file"
    warn "                      content, so it detects nothing -- clamav#1786."
  fi

  if [ -r "$CTR_CONF" ]; then
    ok "containerised clamd : configured (${CTR_IMAGE:-image unknown})"
    if ctr_alive; then
      ok "                      socket answering"
    elif ctr_starting; then
      warn "                      still starting -- clamd loads the signature set"
      warn "                      before it binds the socket (allow ~60-90s after a"
      warn "                      restart, and it has been $(human_secs "$(ctr_uptime)"))."
      warn "                      Re-run this in a minute."
      say "  ${DIM}--- docker logs (last 10) ---${R}"
      docker logs --tail 10 clamav-container 2>&1 | sed 's/^/  /' | head -12
    elif ctr_wedged; then
      local _up _la
      _up=$(ctr_uptime 2>/dev/null || echo 0); _la=$(ctr_log_age 2>/dev/null || echo "")
      bad "                      WEDGED -- up $(human_secs "$_up") and the socket has"
      bad "                      never answered. This is NOT 'still starting'."
      if [ -n "$_la" ] && [ "$_la" -ge "$CTR_LOG_STALE" ]; then
        bad "                      Last log line was $(human_secs "$_la") ago; clamd"
        bad "                      SelfChecks every ~10 min, so it stopped working then."
        bad "                      THIS BOX HAS HAD NO WORKING AV SINCE."
      fi
      bad "                      Restart it: systemctl restart clamav-container"
      container_postmortem
    else
      bad "                      socket NOT answering"
      container_postmortem
    fi
  elif [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" = 1 ]; then
    bad "containerised clamd : NOT configured, and this box needs it"
    bad "                      The clamav_container role stands it up on a pull."
    bad "                      Air-gapped? Stage the image: it-clamav image-load <dir>"
  fi

  printf '  sigtool runs        : %s\n' "$SIGTOOL_MODE"
  printf '  live database       : %s\n' "$DB_DIR"
}

# ---- host -> container database sync ----------------------------------------
# freshclam keeps /var/lib/clamav current while a box still has a network. The
# containerised engine reads its own copy, so without this the host looks
# up-to-date and the thing that actually scans quietly falls behind.
cmd_sync() {
  [ "$DB_DIR" = /var/lib/clamav-container ] \
    || { say "No containerised engine on this box; nothing to sync."; exit 0; }
  [ -d /var/lib/clamav ] || die "/var/lib/clamav does not exist."

  head2 "Syncing host database -> scanner"
  local n=0 f s
  for f in /var/lib/clamav/*.cvd /var/lib/clamav/*.cld; do
    [ -f "$f" ] || continue
    # Never let a .cvd and a .cld of the same database coexist: clamd loads one
    # of them and not necessarily the newer. The same goes for an old-version
    # .cvd.sign: replace the database's whole set, signature files included.
    local base; base=$(basename "$f"); base="${base%.*}"
    s=$(sign_for "$f")
    if [ "$f" -nt "$DB_DIR/$(basename "$f")" ] || [ ! -f "$DB_DIR/$(basename "$f")" ] \
       || { [ -n "$s" ] && [ ! -f "$DB_DIR/$(basename "$s")" ]; }; then
      rm -f "$DB_DIR/$base.cvd" "$DB_DIR/$base.cld" "$DB_DIR/$base"-*.cvd.sign
      install -o clamav -g clamav -m 0644 "$f" "$DB_DIR/$(basename "$f")" \
        && { ok "$(basename "$f")  -> $(sig_field "$f" Version)"; n=$((n+1)); }
      [ -n "$s" ] && install -o clamav -g clamav -m 0644 "$s" "$DB_DIR/$(basename "$s")" \
        && ok "$(basename "$s")"
    fi
  done
  if [ "$n" = 0 ]; then say "  already in step; nothing copied"; say ""; exit 0; fi

  if ctr_alive; then
    clamdscan -c "$CTR_CONF" --reload >/dev/null 2>&1 \
      && ok "scanner reloaded" || warn "reload failed -- systemctl restart clamav-container"
  fi
  logline "sync: copied $n file(s) from /var/lib/clamav"
  say ""
}

# ---- go back to the host engine ---------------------------------------------
# The containerised engine exists only because the host one cannot hash under
# FIPS (clamav#1786). When that is fixed -- a patched clamav lands, or the box
# stops being FIPS -- this hands scanning back. An ansible-pull does the same
# thing automatically; this is for doing it now, on an air-gapped box, right
# after installing a .deb by hand.
cmd_revert() {
  [ -r "$CTR_CONF" ] || { say "No containerised engine on this box; nothing to revert."; exit 0; }

  head2 "Checking the host engine before handing anything back"
  local td rc
  td=$(mktemp -d /tmp/clamav-revert.XXXXXX)
  printf '%s%s' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR' '-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > "$td/canary"
  clamscan --no-summary "$td/canary" >/dev/null 2>&1; rc=$?
  rm -rf "$td"
  if [ "$rc" -ne 1 ]; then
    bad "The HOST clamscan still does not detect the EICAR test file (exit $rc)."
    bad "Reverting now would leave this box with no working antivirus."
    say ""
    say "  Install a fixed clamav first, then re-run this. On an air-gapped box:"
    say "    sudo apt install ./clamav_<version>_amd64.deb ./libclamav*.deb"
    say "    sudo it-clamav revert"
    exit 1
  fi
  ok "host clamscan detects the EICAR test file"

  # The container has had the signature updates, so its database is the current
  # one. Hand it back before the host daemon starts on whatever it was left with.
  # A 1.5 host with MD5 verification off will not load a .cvd without its
  # .sign, and a database the old it-clamav installed into the scanner has
  # none. Handing that back and then removing the container would leave the
  # box with no engine that starts. Check before anything is copied or removed.
  sign_policy /var/lib/clamav
  if [ "$SIGN_POLICY" = required ]; then
    local cf nos=()
    for cf in "$DB_DIR"/*.cvd; do
      [ -f "$cf" ] || continue
      sign_for "$cf" >/dev/null || nos+=("$(basename "$cf")")
    done
    if [ "${#nos[@]}" -gt 0 ]; then
      bad "The host engine needs a .cvd.sign beside every .cvd ($ENGINE_VER_DESC),"
      bad "and the scanner's database has none for: ${nos[*]}"
      bad "Handing it back would leave clamd unable to start. Nothing was changed."
      say ""
      say "  Install a current signature archive first, then re-run this:"
      say "    sudo it-clamav install && sudo it-clamav revert"
      exit 1
    fi
  fi

  head2 "Handing the current database back to the host"
  local f b base s n=0
  for f in "$DB_DIR"/*.cvd "$DB_DIR"/*.cld; do
    [ -f "$f" ] || continue
    b=$(basename "$f"); base="${b%.*}"
    # The host engine being handed back to is, by definition here, a newer
    # clamav -- likely 1.5, which will not load a .cvd without its .sign.
    s=$(sign_for "$f")
    if [ "$f" -nt "/var/lib/clamav/$b" ] || [ ! -f "/var/lib/clamav/$b" ] \
       || { [ -n "$s" ] && [ ! -f "/var/lib/clamav/$(basename "$s")" ]; }; then
      rm -f "/var/lib/clamav/$base.cvd" "/var/lib/clamav/$base.cld" \
            "/var/lib/clamav/$base"-*.cvd.sign
      install -o clamav -g clamav -m 0644 "$f" "/var/lib/clamav/$b" \
        && { ok "$b"; n=$((n + 1)); }
      [ -n "$s" ] && install -o clamav -g clamav -m 0644 "$s" "/var/lib/clamav/$(basename "$s")" \
        && ok "$(basename "$s")"
    fi
  done
  [ "$n" = 0 ] && say "  host database already current"

  head2 "Removing the containerised engine"
  systemctl disable --now clamav-container-sync.path >/dev/null 2>&1
  systemctl disable --now clamav-container >/dev/null 2>&1
  rm -f /etc/systemd/system/clamav-container.service \
        /etc/systemd/system/clamav-container-sync.service \
        /etc/systemd/system/clamav-container-sync.path \
        "$CTR_CONF"
  systemctl daemon-reload
  ok "units and client config removed"

  systemctl unmask clamav-daemon >/dev/null 2>&1
  systemctl enable --now clamav-daemon >/dev/null 2>&1
  ok "clamav-daemon unmasked and started"

  head2 "Confirming the host engine is doing the work"
  local i=0
  while [ $i -lt 90 ]; do clamdscan --ping=1 >/dev/null 2>&1 && break; i=$((i + 1)); sleep 1; done
  # CTR_CONF is gone now, so engine_selftest picks the host daemon on its own.
  if engine_selftest; then
    ok "PASS -- $SELFTEST_ENGINE detected the EICAR test file"
  else
    bad "FAIL -- $SELFTEST_ENGINE did NOT detect it. The box has no working antivirus."
    bad "Put the container back with an ansible-pull, or investigate before relying on scans."
    exit 1
  fi

  if [ "$PURGE" = 1 ]; then
    head2 "Purging"
    [ -n "$CTR_IMAGE" ] && { docker rmi "$CTR_IMAGE" >/dev/null 2>&1 && ok "image $CTR_IMAGE removed"; }
    rm -f /etc/clamav/container-image
    rm -rf /var/lib/clamav-container && ok "/var/lib/clamav-container removed"
  else
    say ""
    say "  ${DIM}The image and /var/lib/clamav-container are still on disk."
    say "  Remove them with: it-clamav revert --purge${R}"
  fi
  logline "revert: handed scanning back to the host engine"
  say ""
}

# ---- air-gap image staging --------------------------------------------------
cmd_image_save() {
  local dir="${1:?usage: it-clamav image-save <dir>}"
  [ -n "$CTR_IMAGE" ] || CTR_IMAGE="clamav/clamav:1.4.3"
  command -v docker >/dev/null 2>&1 || die "docker is not installed."
  mkdir -p "$dir" || die "cannot write to $dir"
  head2 "Saving $CTR_IMAGE"
  docker image inspect "$CTR_IMAGE" >/dev/null 2>&1 || {
    say "  not on this box; pulling"
    docker pull "$CTR_IMAGE" || die "pull failed"
  }
  local out="$dir/clamav-image.tar"
  docker save "$CTR_IMAGE" -o "$out" || die "docker save failed"
  printf '%s\n' "$CTR_IMAGE" > "$dir/clamav-image.txt"
  ok "$out  ($(du -h "$out" | cut -f1))"
  ok "$dir/clamav-image.txt  ($CTR_IMAGE)"
  say ""
  say "  Carry both to the fielded box and run: it-clamav image-load $dir"
  say ""
}

cmd_image_load() {
  local dir="${1:?usage: it-clamav image-load <dir>}"
  local tar="$dir/clamav-image.tar"
  command -v docker >/dev/null 2>&1 || die "docker is not installed."
  [ -f "$tar" ] || die "no clamav-image.tar in $dir"
  head2 "Loading $(cat "$dir/clamav-image.txt" 2>/dev/null || echo 'the image')"
  docker load -i "$tar" || die "docker load failed"
  ok "loaded"
  say ""
  say "  Now run an ansible-pull so clamav_container starts the daemon,"
  say "  then confirm with: it-clamav test"
  say ""
}

cmd_test() {
  head2 "Engine detection test"
  if ! command -v clamscan >/dev/null 2>&1; then bad "clamav is not installed."; exit 1; fi
  if engine_selftest; then
    ok "PASS -- $SELFTEST_ENGINE detected the EICAR test file."
    say ""
    return 0
  fi
  if [ -r "$CTR_CONF" ] && ctr_starting; then
    warn "The containerised engine is still starting -- clamd loads the signature"
    warn "set before it binds its socket (~60-90s after a restart). This test used"
    warn "$SELFTEST_ENGINE instead, which is not the engine that will do the work."
    warn "Re-run it in a minute."
    say ""
  elif [ -r "$CTR_CONF" ] && ctr_wedged; then
    # The important distinction, and the one this tool used to get wrong: a
    # container that is UP but has never answered is not starting, and telling
    # someone to re-run in a minute hides an outage for as long as they believe
    # it. What ran instead was the host engine, which on FIPS detects nothing.
    local _la
    _la=$(ctr_log_age 2>/dev/null || echo "")
    bad "THE CONTAINERISED ENGINE IS WEDGED, NOT STARTING."
    bad "It has been up $(human_secs "$(ctr_uptime)") and its socket has never answered."
    if [ -n "$_la" ] && [ "$_la" -ge "$CTR_LOG_STALE" ]; then
      bad "Its last log line was $(human_secs "$_la") ago -- clamd SelfChecks every"
      bad "~10 minutes, so it stopped doing anything then. THIS BOX HAS HAD NO"
      bad "WORKING ANTI-VIRUS SINCE, and every scan in that window reported OK"
      bad "because it silently fell back to the host engine, which cannot detect."
    fi
    bad "Restart it, wait 90s, then re-run this:"
    bad "  sudo systemctl restart clamav-container && sleep 90 && sudo it-clamav test"
    say ""
  fi
  bad "FAIL -- $SELFTEST_ENGINE did NOT detect the EICAR test file."
  say ""
  printf '%s\n' "$SELFTEST_OUT" | sed 's/^/    /'

  # Separate "the daemon is misconfigured" from "the engine cannot scan at all".
  # Only the daemon path was tried above; clamscan hashes in its own process.
  if [ "$SELFTEST_ENGINE" = "clamdscan (daemon)" ]; then
    head2 "Second opinion: standalone clamscan (hashes in its own process)"
    local td rc
    td=$(mktemp -d /tmp/clamav-test2.XXXXXX)
    printf '%s%s' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR' '-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > "$td/canary"
    clamscan --no-summary "$td/canary" >/dev/null 2>&1; rc=$?
    rm -rf "$td"
    if [ "$rc" -eq 1 ]; then
      ok "clamscan DOES detect. The engine is fine -- it is the DAEMON that is not"
      ok "picking up the carve-out. Restart it: systemctl restart clamav-daemon"
    else
      bad "clamscan does not detect either. The engine itself cannot scan."
    fi
  fi

  engine_report
  say ""
  # Leave a canary behind so the operator can re-run the check by hand.
  CANARY_HINT=/run/clamav-canary
  printf '%s%s' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR' '-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' \
    > "$CANARY_HINT" 2>/dev/null || CANARY_HINT=/path/to/an/eicar/file
  # The single most likely cause on these boxes, and it is silent: the scan
  # reports OK for everything instead of erroring out.
  if printf '%s' "$SELFTEST_OUT" | grep -qiE 'error initializing|hash context' \
     || [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" = 1 ]; then
    bad "This host is in FIPS mode. MD5 is not FIPS-approved and it is what ClamAV"
    bad "hashes file content with, so the engine loads every signature and then"
    bad "cannot evaluate any of the MD5-based ones. The EICAR test file is NOT"
    bad "detected. DO NOT TREAT A CLEAN RESULT FROM THIS BOX AS MEANINGFUL."
    say ""
    bad "This is upstream bug Cisco-Talos/clamav#1786 -- open, no fix. It is not"
    bad "something this repo can configure around: Ubuntu's FIPS OpenSSL takes FIPS"
    bad "from the kernel flag, so even OPENSSL_CONF=/dev/null cannot restore MD5"
    bad "(verified on ASP-2). --fips-limits and FIPSCryptoHashLimits do not help"
    bad "either. See the POA&M in docs/compliance.md for the options."
    say ""
    say "  THE FIX on this fleet is the containerised engine (clamav_container):"
    say "  clamd runs in a container whose OpenSSL is a stock build, so MD5 works,"
    say "  and the host kernel stays in FIPS mode. Scans go over its socket with"
    say "  clamdscan --fdpass, so nothing is mounted into it and a DTA needs no"
    say "  docker access. An ansible-pull stands it up."
    say ""
    say "  Air-gapped, so the pull cannot fetch the image? On an online box:"
    say "    sudo it-clamav image-save /mnt/usb"
    say "  then here:"
    say "    sudo it-clamav image-load /mnt/usb && sudo ansible-pull ... && sudo it-clamav test"
  fi
  exit 1
}

age_days() { echo $(( ( $(date +%s) - $(stat -c %Y "$1") ) / 86400 )); }

# ---- check ------------------------------------------------------------------
cmd_check() {
  head2 "Installed signature databases  ($DB_DIR)"
  local any=0 f v b base age s
  sign_policy
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    any=1
    base=$(basename "$f"); base="${base%.*}"
    v=$(sig_field "$f" Version); b=$(sig_field "$f" 'Build time')
    # Age from the CVD's OWN build time, not the file mtime -- mtime is when the
    # file happened to be written here, which says nothing about the signatures.
    age=""
    [ -n "$b" ] && age=$(( ( $(date +%s) - $(date -d "$b" +%s 2>/dev/null || echo 0) ) / 86400 ))
    printf '  %-16s version %-8s %s\n' "$(basename "$f")" "${v:-?}" "${b:-unknown build time}"
    case "$base" in
      daily)
        # daily is published several times a DAY; this is the one that carries
        # new detections and the only one whose age means anything.
        if   [ -z "$age" ];      then warn "    build time unreadable"
        elif [ "$age" -gt 30 ];  then bad  "    $age days old -- well past useful"
        elif [ "$age" -gt 7 ];   then warn "    $age days old"
        else                          ok   "    $age days old"
        fi ;;
      *)
        # main and bytecode are published a couple of times a YEAR. An old build
        # date here is normal and is NOT a finding -- freshclam would have
        # replaced them if newer ones existed.
        ok "    ${age:-?} days since publication (normal -- $base is published rarely)" ;;
    esac
    sig_verified "$f" && ok "    digital signature verified" \
                      || bad "    DIGITAL SIGNATURE DID NOT VERIFY"
    # Detached .sign files for this database. Only the one whose version matches
    # belongs; any other is left over from an older set and makes a 1.5 engine
    # warn about duplicates or fail to load.
    local have_match=0
    for s in "$DB_DIR/$base"-*.cvd.sign; do
      [ -f "$s" ] || continue
      if [ -z "$v" ]; then
        warn "    $(basename "$s") -- cannot judge (database version unreadable)"
      elif [ "$(basename "$s")" = "$(sign_name "$f" "$v")" ]; then
        ok "    $(basename "$s") present"; have_match=1
      else
        warn "    $(basename "$s") is STALE (does not match version ${v:-?}) -- remove it"
      fi
    done
    if [ "$have_match" = 0 ] && [ "${f##*.}" = cvd ]; then
      case "$SIGN_POLICY" in
        required)
          bad "    NO $(sign_name "$f" "${v:-<version>}") -- a 1.5 engine with MD5 verification"
          bad "    disabled refuses this .cvd and clamd will not start. Install a"
          bad "    current archive (it carries the .sign files): it-clamav install" ;;
        recommended)
          warn "    no $(sign_name "$f" "${v:-<version>}") -- loads by MD5 today; would not"
          warn "    if MD5 were switched off. A current archive carries it." ;;
        *)
          say "  ${DIM}    no .cvd.sign (not used by this engine; 1.5+ uses it)${R}" ;;
      esac
    fi
  done < <(db_files)
  [ "$any" = 1 ] || bad "  No signature database installed at all."
  printf '  %sengine: %s -- %s%s\n' "$DIM" "$ENGINE_VER_DESC" "$(sign_policy_line)" "$R"
  if [ "$SIGN_POLICY" != none ] && [ "$DB_DIR" != /var/lib/clamav-container ] && [ ! -f "$CVD_CERT" ]; then
    warn "  $CVD_CERT is missing -- a 1.5 engine verifies .sign files with it."
    warn "  Reinstall the clamav package to restore it."
  fi

  # The live database must be clamav's and writable by nobody else: whoever can
  # write here chooses what the scanner believes is clean. A plain
  # `tar xzf -C /var/lib/clamav` of a grabber archive, whose ./ entry is mode
  # 777, leaves exactly that behind. The containerised engine's directory is
  # chowned to the IMAGE's clamav uid by its entrypoint, which need not be the
  # host's clamav -- so there only the write bits are judged.
  if [ -d "$DB_DIR" ]; then
    local downer dmode owner_bad=0
    downer=$(stat -c %U "$DB_DIR" 2>/dev/null); dmode=$(stat -c %a "$DB_DIR" 2>/dev/null)
    [ "$DB_DIR" != /var/lib/clamav-container ] && [ "$downer" != clamav ] && owner_bad=1
    if [ "$owner_bad" = 1 ] || [ $(( 8#${dmode:-0} & 8#022 )) -ne 0 ]; then
      bad "  $DB_DIR is $(stat -c '%A %U:%G' "$DB_DIR" 2>/dev/null) -- it must be owned by"
      bad "  clamav and not group/world-writable. Fix it with:"
      if [ "$DB_DIR" = /var/lib/clamav-container ]; then
        bad "    sudo chmod go-w $DB_DIR $DB_DIR/*"
      else
        bad "    sudo chown clamav:clamav $DB_DIR && sudo chmod 0755 $DB_DIR"
        bad "    sudo chmod go-w $DB_DIR/*"
      fi
    else
      ok "  $DB_DIR is $(stat -c '%A %U:%G' "$DB_DIR" 2>/dev/null)"
    fi
  fi

  # freshclam writes to the HOST database. The containerised engine reads its own
  # copy. Left alone they diverge silently, with the host looking current and the
  # thing that actually scans falling behind.
  if [ "$DB_DIR" = /var/lib/clamav-container ] && [ -d /var/lib/clamav ]; then
    local hv cv
    hv=$(sig_field /var/lib/clamav/daily.cld Version 2>/dev/null)
    [ -n "$hv" ] || hv=$(sig_field /var/lib/clamav/daily.cvd Version 2>/dev/null)
    cv=$(installed_version daily)
    if [ -n "$hv" ] && [ -n "$cv" ] && [ "$hv" != "$cv" ]; then
      bad "  Host database is at daily $hv but the SCANNER is at $cv."
      bad "  Sync with: it-clamav sync"
    elif [ -n "$hv" ]; then
      ok "  Scanner matches the host database (daily $cv)"
    fi
  fi

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

  head2 "Engine detection test"
  if command -v clamscan >/dev/null 2>&1; then
    if engine_selftest; then
      ok "PASS -- $SELFTEST_ENGINE detected the EICAR test file"
    else
      bad "FAIL -- $SELFTEST_ENGINE did NOT detect the EICAR test file"
      bad "The engine is loaded but scanning nothing. Run: it-clamav test"
    fi
  else
    bad "clamav is not installed"
  fi

  head2 "Scanner socket (can a non-admin DTA use the daemon?)"
  # Read the config of whichever engine is ACTUALLY serving. This used to read
  # /etc/clamav/clamd.conf unconditionally, so on every containerised box it
  # reported the host socket missing and "the daemon is not running" -- true of
  # the host daemon, which is masked on purpose there, and wrong about the DTA
  # path, which is the question being asked.
  local sock mode conf=/etc/clamav/clamd.conf
  [ -r "$CTR_CONF" ] && conf="$CTR_CONF"
  sock=$(awk '/^LocalSocket[[:space:]]/{print $2; exit}' "$conf" 2>/dev/null)
  sock="${sock:-/run/clamav/clamd.ctl}"
  printf '  %sfrom %s%s\n' "$DIM" "$conf" "$R"
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
  elif [ "$conf" = "$CTR_CONF" ]; then
    warn "  $sock does not exist -- the containerised scanner is not serving."
    warn "  dta-log falls back to standalone clamscan, which on a FIPS box"
    warn "  DETECTS NOTHING. Fix it: systemctl restart clamav-container"
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
  #
  # The grabber's archives are built under WSL: every entry, ./ included, is
  # owned by the build user with mode 777. tar run as root restores both by
  # default, so extracting ./ over the mktemp directory made it world-writable
  # -- and any local user could swap a file between sigtool verifying it and
  # install copying it. Never take owner or modes from the archive, and keep the
  # directory 0700 whatever ./ says. (A global, not a local: the EXIT trap runs
  # after this function has returned.)
  CLAMAV_TMP=$(mktemp -d /tmp/clamav-sigs.XXXXXX) || die "mktemp failed"
  trap 'rm -rf "$CLAMAV_TMP"' EXIT
  local tmp="$CLAMAV_TMP"
  # freshclam.dat is the BUILD machine's freshclam state (its UUID, mirror
  # back-off). Installed here it would hand this box another machine's identity.
  ( umask 077
    tar xzf "$archive" -C "$tmp" --no-same-owner --no-same-permissions \
        --exclude='freshclam.dat' 2>/dev/null ) \
    || die "Could not extract $archive (corrupt or not a gzip tar?)."
  chmod 0700 "$tmp"

  mapfile -t NEW < <(find "$tmp" -type f \( -name '*.cvd' -o -name '*.cld' \) | sort)
  [ "${#NEW[@]}" -gt 0 ] || die "The archive holds no .cvd/.cld files. Is this a ClamAV signature archive?"

  head2 "Validating ${#NEW[@]} signature file(s)"
  sign_policy
  say "  ${DIM}engine: $ENGINE_VER_DESC -- $(sign_policy_line)${R}"
  if [ "$SIGN_POLICY" != none ] && [ "$DB_DIR" != /var/lib/clamav-container ] && [ ! -f "$CVD_CERT" ]; then
    warn "$CVD_CERT is missing -- a 1.5 engine verifies .sign files with it."
    warn "Installing anyway; reinstall the clamav package if clamd will not load them."
  fi
  # SIGN[db] = the archive's .sign for that database's .cvd, version-matched.
  declare -A SIGN=()
  local f base v s newer=0 missing=()
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
    # The .sign must name the SAME version sigtool read from the .cvd: a 1.5
    # engine looks for exactly <db>-<version>.cvd.sign and nothing else. Only a
    # .cvd is paired -- 1.5 never consults a .sign for a .cld, and pairing one
    # could put another version's .sign beside a .cvd of the same database.
    if [ "${f##*.}" = cvd ]; then
      s=""
      [ -n "$v" ] && s="$(dirname "$f")/$(sign_name "$f" "$v")"
      if [ -n "$s" ] && [ -f "$s" ]; then
        SIGN[$base]=$s; ok "    $(basename "$s")"
      else
        unset 'SIGN[$base]'
        missing+=("$(basename "$f") (wants $(sign_name "$f" "${v:-<version>}"))")
        case "$SIGN_POLICY" in
          required)    bad  "    NO $(sign_name "$f" "${v:-<version>}")" ;;
          recommended) warn "    no $(sign_name "$f" "${v:-<version>}") (loads by MD5 here)" ;;
          *)           warn "    no .cvd.sign (fine for this engine)" ;;
        esac
      fi
    fi
    if [ -n "$cur" ] && [ -n "$v" ]; then
      if [ "$v" -gt "$cur" ] 2>/dev/null; then
        ok "    newer than installed ($cur -> $v)"; newer=1
      elif [ "$v" -eq "$cur" ] 2>/dev/null; then
        warn "    same as installed ($cur)"
        # Same version, but the installed copy is missing the .sign this one
        # carries -- the state a pre-1.5-aware install left behind, and the one
        # that stops a 1.5 clamd. Installing it is the repair, not a no-op.
        if [ -n "${SIGN[$base]:-}" ] && [ ! -f "$DB_DIR/$(basename "${SIGN[$base]}")" ]; then
          ok "    ...but the installed copy lacks $(basename "${SIGN[$base]}") -- installing"; newer=1
        fi
      else
        warn "    OLDER than installed ($cur -> $v)"
      fi
    else
      newer=1
    fi
  done

  # .sign files that match no .cvd in the archive belong to some other set.
  # They are not installed: beside the new set they only cause load errors.
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    local sb; sb=$(basename "$s")
    # A name starting with "-" has no database part; an empty subscript is a
    # bash error, so test for that first.
    if [ -z "${sb%%-*}" ] || [ "${SIGN[${sb%%-*}]:-}" != "$s" ]; then
      warn "  ignoring $sb (matches no .cvd version in this archive)"
    fi
  done < <(find "$tmp" -type f -name '*.cvd.sign' | sort)

  # Refuse BEFORE the live database is touched. Installing a .cvd a 1.5 engine
  # cannot verify does not degrade the box, it stops clamd starting at all.
  # --force overrides (the restart and EICAR test below still catch a clamd
  # that will not start); with MD5 available such a .cvd loads, so only warn.
  if [ "${#missing[@]}" -gt 0 ] && [ "$SIGN_POLICY" = required ]; then
    bad ""
    bad "This engine is ClamAV 1.5+ ($ENGINE_VER_DESC). It verifies every .cvd"
    bad "against <db>-<version>.cvd.sign, and with MD5 verification disabled (FIPS)"
    bad "a .cvd without one is rejected and clamd will not start. Missing:"
    for s in "${missing[@]}"; do bad "  $s"; done
    if [ "$FORCE" = 0 ]; then
      die "Archive rejected; nothing was changed. Use a signature archive built for ClamAV 1.5 (it carries the .cvd.sign files)."
    fi
    bad ""
    bad "!!! --force: INSTALLING ANYWAY. Expect clamd to refuse these databases and"
    bad "!!! not start. If it does not come back: it-clamav rollback"
    bad ""
    logline "install: --force past missing .cvd.sign on a 1.5 MD5-off engine: ${missing[*]}"
  elif [ "${#missing[@]}" -gt 0 ] && [ "$SIGN_POLICY" = recommended ]; then
    warn ""
    warn "Installing without .cvd.sign for: ${missing[*]}"
    warn "This 1.5 engine still verifies them by MD5. A box with MD5 switched off"
    warn "(FIPS) would refuse them -- prefer an archive built for ClamAV 1.5."
  fi

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
  done < <(db_set_files)
  head2 "Backup"
  if [ "$had" = 1 ]; then ok "previous signatures -> $backup"
  else warn "nothing to back up (no signatures were installed)"; fi

  # ---- stop services, remembering what was running ----
  local was_daemon=0 was_fresh=0
  if [ "$DB_DIR" != /var/lib/clamav-container ]; then
    systemctl is-active --quiet clamav-freshclam 2>/dev/null && { was_fresh=1; systemctl stop clamav-freshclam; }
    systemctl is-active --quiet clamav-daemon    2>/dev/null && { was_daemon=1; systemctl stop clamav-daemon; }
  fi

  # ---- install ----
  head2 "Installing"
  for f in "${NEW[@]}"; do
    base=$(basename "$f")
    # A .cvd and a .cld of the same database must never both be present -- clamd
    # loads one of them and it is not necessarily the newer one. Old-version
    # .cvd.sign files go too: the database's set is replaced as a whole, or a
    # 1.5 engine finds a stale .sign beside the new .cvd.
    rm -f "$DB_DIR/${base%.*}.cvd" "$DB_DIR/${base%.*}.cld" "$DB_DIR/${base%.*}"-*.cvd.sign
    install -o clamav -g clamav -m 0644 "$f" "$DB_DIR/$base" \
      && ok "$base" || bad "$base FAILED"
    s="${SIGN[${base%.*}]:-}"
    if [ -n "$s" ]; then
      if install -o clamav -g clamav -m 0644 "$s" "$DB_DIR/$(basename "$s")"; then
        ok "$(basename "$s")"
      else
        bad "$(basename "$s") FAILED"
      fi
    fi
  done
  logline "install: placed ${#NEW[@]} file(s) from $archive"

  # ---- restart and confirm ----
  head2 "Confirming"
  if [ "$DB_DIR" = /var/lib/clamav-container ]; then
    say "  restarting the containerised daemon to re-read the database"
    systemctl restart clamav-container 2>/dev/null || warn "could not restart clamav-container"
    local i=0
    while [ $i -lt 120 ]; do ctr_alive && break; i=$((i + 1)); sleep 1; done
    if ctr_alive; then ok "containerised clamd answering (${i}s)"
    else bad "containerised clamd did not come back: systemctl status clamav-container"; exit 1; fi
  elif [ "$was_daemon" = 1 ] || systemctl is-enabled --quiet clamav-daemon 2>/dev/null; then
    systemctl start clamav-daemon
    local i=0
    while [ $i -lt 60 ]; do
      clamdscan --ping=1 >/dev/null 2>&1 && break
      i=$((i + 1)); sleep 1
    done
    if clamdscan --ping=1 >/dev/null 2>&1; then
      ok "clamav-daemon restarted and answering (${i}s)"
    else
      bad "clamav-daemon did not come back within 60s."
      bad "Roll back with: it-clamav rollback"
      exit 1
    fi
    local dv iv; dv=$(daemon_db_version); iv=$(installed_version daily)
    if [ -z "$dv" ]; then
      warn "the daemon will not report its database version (VERSION command disabled)."
      warn "the detection test below is what confirms the reload."
    elif [ "$dv" = "$iv" ]; then
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
    if engine_selftest; then
      ok "detection test passed -- $SELFTEST_ENGINE flagged the EICAR test file"
    else
      bad "detection test FAILED -- the database loaded but the engine detects nothing."
      bad "Run 'it-clamav test' for the likely cause. Roll back with: it-clamav rollback"
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
  # install makes the backup directory even when there was nothing to back up.
  # Restoring that would delete the live set and put back nothing.
  find "$backup" -maxdepth 1 -type f \( -name '*.cvd' -o -name '*.cld' \) | grep -q . \
    || die "$backup holds no signature database (nothing was installed when it was taken). Nothing was changed."
  head2 "Rolling back to $backup"
  # Backups taken before .cvd.sign files were carried have none. On an engine
  # that cannot fall back to MD5 such a .cvd will not load -- say so now, not
  # after clamd fails to start.
  sign_policy
  if [ "$SIGN_POLICY" = required ]; then
    local bf
    for bf in "$backup"/*.cvd; do
      [ -f "$bf" ] || continue
      sign_for "$bf" >/dev/null \
        || warn "$(basename "$bf") in this backup has no .cvd.sign -- this 1.5 engine (MD5 verification off) will refuse it"
    done
  fi
  systemctl stop clamav-daemon 2>/dev/null
  # The .sign files go with their databases: the backup carries its own, and a
  # newer .sign left beside a restored older .cvd is a mismatch on 1.5.
  rm -f "$DB_DIR"/*.cvd "$DB_DIR"/*.cld "$DB_DIR"/*.cvd.sign
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

# ---- on-demand scan ---------------------------------------------------------
# Why this exists: `dta-log` scans a transfer as part of RECORDING it, but only
# on profiles with a dta group and only inside that workflow. The weekly job
# scans the whole box. Neither covers "I just copied a folder on, is it clean?"
#
# PROVE THE ENGINE FIRST, every time. On a FIPS host ClamAV loads every
# signature and then scans zero bytes, reporting every file OK -- so a CLEAN
# verdict from an unverified engine is worse than no scan at all. If the canary
# is not detected this refuses to scan rather than hand back a false CLEAN.
SCAN_LOG=/var/log/clamav-scan.log

cmd_scan() {
  [ "$#" -gt 0 ] || die "scan needs at least one file or directory"
  local p
  for p in "$@"; do
    [ -e "$p" ] || die "no such file or directory: $p"
  done

  command -v clamscan >/dev/null 2>&1 || { bad "clamav is not installed."; exit 2; }

  if [ "$DO_TEST" -eq 1 ]; then
    head2 "Proving the engine detects before trusting a verdict"
    if engine_selftest; then
      ok "$SELFTEST_ENGINE detects the EICAR test file"
    else
      bad "$SELFTEST_ENGINE did NOT detect the EICAR test file -- REFUSING to scan."
      say "A CLEAN result from this engine would be meaningless. Fix it first:"
      say "  sudo it-clamav test        # the same check, with detail"
      say "  sudo it-clamav check       # signature age / daemon state"
      exit 2
    fi
  else
    engine_selftest >/dev/null 2>&1 || true
    warn "--no-test given: the engine was NOT proved. A CLEAN verdict here means little."
  fi

  head2 "Scanning"
  for p in "$@"; do say "  $p"; done

  # Same engine the selftest just used, so the verdict comes from the engine we
  # proved. clamdscan recurses into directories on its own; clamscan needs -r.
  local out rc
  if [ -r "$CTR_CONF" ] && ctr_alive; then
    out=$(clamdscan -c "$CTR_CONF" --fdpass "$@" 2>&1); rc=$?
  elif clamdscan --ping=1 >/dev/null 2>&1; then
    out=$(clamdscan --fdpass "$@" 2>&1); rc=$?
  else
    out=$(clamscan -r "$@" 2>&1); rc=$?
  fi

  printf '%s\n' "$out" | sed 's/^/  /'

  # Judge by the SUMMARY, not the exit code. clamdscan exits non-zero for an
  # unreadable path as well as for a detection, and a targeted scan of a
  # transfer folder hits neither often -- but conflating them would turn a
  # permission problem into a virus alert.
  local infected found errs
  infected=$(printf '%s\n' "$out" | sed -n 's/^Infected files: *\([0-9][0-9]*\).*/\1/p' | tail -1)
  infected=${infected:-}
  found=$(printf '%s\n' "$out" | grep -cE ' FOUND$' || true); found=${found:-0}
  # A file the scanner could not READ is a file that was not checked. On a
  # whole-system sweep those are benign noise (sockets, /proc); here you named
  # the path deliberately, so an unreadable one has to be reported, not folded
  # into "0 infected". Same rule as everywhere else in this repo: a check that
  # did not run is never a pass.
  errs=$(printf '%s\n' "$out" | grep -cE '(: Access denied|: Can.t open file or directory|ERROR)' || true)
  errs=${errs:-0}
  local terr; terr=$(printf '%s\n' "$out" | sed -n 's/^Total errors: *\([0-9][0-9]*\).*/\1/p' | tail -1)
  [ -n "${terr:-}" ] && [ "$terr" -gt "$errs" ] && errs=$terr

  local who; who="${SUDO_USER:-$(id -un)}"
  head2 "Result"
  if [ -z "$infected" ]; then
    bad "The scanner produced no summary -- treat this as NOT SCANNED (exit $rc)."
    printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$who" "$*" "ENGINE-FAULT" >> "$SCAN_LOG" 2>/dev/null
    chmod 0640 "$SCAN_LOG" 2>/dev/null || true
    exit 2
  elif [ "$infected" -gt 0 ] || [ "$found" -gt 0 ]; then
    bad "INFECTED -- $infected file(s) flagged. Do NOT move this data."
    printf '%s\n' "$out" | grep -E ' FOUND$' | sed 's/^/    /'
    say ""
    say "Isolate the media and report it per the incident procedure."
    printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$who" "$*" "INFECTED:$infected" >> "$SCAN_LOG" 2>/dev/null
    chmod 0640 "$SCAN_LOG" 2>/dev/null || true
    exit 1
  elif [ "$errs" -gt 0 ]; then
    warn "PARTIAL -- 0 infected, but $errs path(s) could NOT be read and were not scanned."
    printf '%s\n' "$out" | grep -E '(: Access denied|: Can.t open file or directory|ERROR)' \
      | head -10 | sed 's/^/    /'
    say ""
    say "Re-run as root, or fix the permissions, before calling this data clean."
    printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$who" "$*" "PARTIAL:$errs-unread" >> "$SCAN_LOG" 2>/dev/null
    chmod 0640 "$SCAN_LOG" 2>/dev/null || true
    exit 2
  else
    ok "CLEAN -- 0 infected, verified against $SELFTEST_ENGINE."
    printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$who" "$*" "CLEAN" >> "$SCAN_LOG" 2>/dev/null
    chmod 0640 "$SCAN_LOG" 2>/dev/null || true
  fi
  say ""
  say "Recorded in $SCAN_LOG"
  say "For a transfer that needs a signed RECORD (who/what/when + hashes), use dta-log."
}

# ---- dispatch ---------------------------------------------------------------
CMD=""; ARG=""; SCAN_PATHS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --force)   FORCE=1; shift ;;
    --no-test) DO_TEST=0; shift ;;
    --purge)   PURGE=1; shift ;;
    check|list|install|rollback|test|sync|revert|image-save|image-load) CMD="$1"; shift ;;
    # scan takes MANY paths, so it swallows the rest of the line rather than
    # the single ARG the other verbs use.
    scan) CMD=scan; shift; SCAN_PATHS=("$@"); break ;;
    -*) die "unknown option: $1  (try --help)" ;;
    *)  [ -z "$CMD" ] && die "unknown command: $1  (try --help)"; ARG="$1"; shift ;;
  esac
done

case "${CMD:-check}" in
  check)    cmd_check ;;
  list)     head2 "Archives in $SIG_SRC"; cmd_list ;;
  install)  cmd_install "$ARG" ;;
  rollback)   cmd_rollback ;;
  sync)       cmd_sync ;;
  revert)     cmd_revert ;;
  test)       cmd_test ;;
  scan)       cmd_scan "${SCAN_PATHS[@]}" ;;
  image-save) cmd_image_save "$ARG" ;;
  image-load) cmd_image_load "$ARG" ;;
esac
