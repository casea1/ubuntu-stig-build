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
# silent no-op.
DB_DIR=/var/lib/clamav
[ -d /var/lib/clamav-container ] && [ -r /etc/clamav/clamd-container.conf ] \
  && DB_DIR=/var/lib/clamav-container
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
    docker run --rm --network none --security-opt no-new-privileges \
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

db_files() {  # the signature files currently installed
  find "$DB_DIR" -maxdepth 1 -type f \( -name '*.cvd' -o -name '*.cld' \) 2>/dev/null | sort
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

# Up but not listening yet: the unit is running and the container has not
# exited. clamd is loading signatures.
ctr_starting() {
  [ "$(systemctl is-active clamav-container 2>/dev/null)" = active ] || return 1
  docker ps --filter name=clamav-container --format '{{.Names}}' 2>/dev/null \
    | grep -q clamav-container
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
      # clamd binds its socket only AFTER loading the signature set -- roughly a
      # minute for 3.6M signatures. Restart-then-test-immediately looks exactly
      # like a broken container otherwise.
      warn "                      still starting -- clamd loads the signature set"
      warn "                      before it binds the socket (allow ~60-90s after a"
      warn "                      restart). Re-run this in a minute."
      say "  ${DIM}--- docker logs (last 10) ---${R}"
      docker logs --tail 10 clamav-container 2>&1 | sed 's/^/  /' | head -12
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
  local n=0 f
  for f in /var/lib/clamav/*.cvd /var/lib/clamav/*.cld; do
    [ -f "$f" ] || continue
    # Never let a .cvd and a .cld of the same database coexist: clamd loads one
    # of them and not necessarily the newer.
    local base; base=$(basename "$f"); base="${base%.*}"
    if [ "$f" -nt "$DB_DIR/$(basename "$f")" ] || [ ! -f "$DB_DIR/$(basename "$f")" ]; then
      rm -f "$DB_DIR/$base.cvd" "$DB_DIR/$base.cld"
      install -o clamav -g clamav -m 0644 "$f" "$DB_DIR/$(basename "$f")" \
        && { ok "$(basename "$f")  -> $(sig_field "$f" Version)"; n=$((n+1)); }
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
  head2 "Handing the current database back to the host"
  local f b base n=0
  for f in "$DB_DIR"/*.cvd "$DB_DIR"/*.cld; do
    [ -f "$f" ] || continue
    b=$(basename "$f"); base="${b%.*}"
    if [ "$f" -nt "/var/lib/clamav/$b" ] || [ ! -f "/var/lib/clamav/$b" ]; then
      rm -f "/var/lib/clamav/$base.cvd" "/var/lib/clamav/$base.cld"
      install -o clamav -g clamav -m 0644 "$f" "/var/lib/clamav/$b" \
        && { ok "$b"; n=$((n + 1)); }
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
  if [ -r "$CTR_CONF" ] && ctr_starting && ! ctr_alive; then
    warn "The containerised engine is still starting -- clamd loads the signature"
    warn "set before it binds its socket (~60-90s after a restart). This test used"
    warn "$SELFTEST_ENGINE instead, which is not the engine that will do the work."
    warn "Re-run it in a minute."
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
  local any=0 f v b base age
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
  done < <(db_files)
  [ "$any" = 1 ] || bad "  No signature database installed at all."

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
  if [ "$DB_DIR" != /var/lib/clamav-container ]; then
    systemctl is-active --quiet clamav-freshclam 2>/dev/null && { was_fresh=1; systemctl stop clamav-freshclam; }
    systemctl is-active --quiet clamav-daemon    2>/dev/null && { was_daemon=1; systemctl stop clamav-daemon; }
  fi

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
      bad "Run `it-clamav test` for the likely cause. Roll back with: it-clamav rollback"
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
