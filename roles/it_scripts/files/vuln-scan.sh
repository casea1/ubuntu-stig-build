#!/usr/bin/env bash
# it-vulnscan -- local vulnerability scan, EMI profile. The Linux counterpart to
# the org's MUSA_Vuln_Scan Windows job: nmap service/version detection with the
# `vuln` NSE category against this host, then a full anti-virus scan.
#
# It scans THIS box (loopback by default), which is the point -- it is evidence
# that the host's own listening services are not vulnerable, not a network sweep.
# Scanning anything you have not been authorised to scan is a different activity
# with different rules; --target exists for a deliberate, authorised scope.
#
# Usage:
#   it-vulnscan                  nmap vuln scan + AV scan -> /opt/ia/vulnscans
#   it-vulnscan --quick          nmap only, skip the AV scan (minutes, not hours)
#   it-vulnscan --no-av          same thing, said the other way
#   it-vulnscan --target HOST    scan something else (authorised scope only)
#   it-vulnscan --ports SPEC     nmap port spec (default: the top 1000 + open)
#   it-vulnscan --list           past scans, newest first
#   it-vulnscan --show [FILE]    print the newest scan (or the one named)
#   it-vulnscan --keep N         how many scans to retain (default 12; 0 = all)
#   it-vulnscan --no-container   do not fall back to the containerised nmap
#   it-vulnscan image-save DIR   AIR-GAP: save the nmap image to removable media
#   it-vulnscan image-load DIR   AIR-GAP: load it on the fielded box
set -uo pipefail

OUT_DIR="${VULNSCAN_DIR:-/opt/ia/vulnscans}"
TARGET=127.0.0.1
PORTS=""
DO_AV=1
KEEP=12
ACTION=scan
SHOW_FILE=""
IMG_DIR=""
USE_CONTAINER=1

# Written by the nmap_container role, and only after it has PROVEN the image can
# scan. Absent means there is no working containerised nmap -- never guess one.
NMAP_IMG_MARKER=/etc/stig-build/nmap-image
FIPS_OFF=/etc/stig-build/fips_off

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
usage(){ awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --quick|--no-av) DO_AV=0; shift ;;
    --target) TARGET="${2:?--target needs a host}"; shift 2 ;;
    --ports)  PORTS="${2:?--ports needs a spec}"; shift 2 ;;
    --keep)   KEEP="${2:?--keep needs a number}"; shift 2 ;;
    --no-container) USE_CONTAINER=0; shift ;;
    image-save) ACTION=image-save; IMG_DIR="${2:?image-save needs a directory}"; shift 2 ;;
    image-load) ACTION=image-load; IMG_DIR="${2:?image-load needs a directory}"; shift 2 ;;
    --list)   ACTION=list; shift ;;
    --show)   ACTION=show; SHOW_FILE="${2:-}"; [ -n "$SHOW_FILE" ] && shift; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ---- containerised nmap -----------------------------------------------------
# The host nmap cannot start under FIPS. nmap_container builds an image whose
# OpenSSL is a stock build and records it here ONLY after proving it can scan.

ctr_image() { [ -r "$NMAP_IMG_MARKER" ] && cat "$NMAP_IMG_MARKER" || true; }

ctr_nmap() {   # args -> nmap args. --network host so loopback means the host's.
  local img; img=$(ctr_image)
  [ -n "$img" ] || return 127
  local mnt=()
  [ -r "$FIPS_OFF" ] && mnt=(-v "$FIPS_OFF:/proc/sys/crypto/fips_enabled:ro")
  # --ulimit: dockerd runs with LimitNOFILE=infinity and containers inherit it.
  # nmap sizes its socket tables from the fd limit, so an unbounded one makes it
  # allocate for a billion descriptors. Bound it the same way the image build does.
  docker run --rm --network host --ulimit nofile="${NMAP_CTR_NOFILE:-1024:65536}" \
    "${mnt[@]}" "$img" "$@"
}

cmd_image_save() {
  local img; img=$(ctr_image)
  [ -n "$img" ] || die "no containerised nmap on this box (nothing to save)"
  [ -d "$IMG_DIR" ] || die "no such directory: $IMG_DIR"
  command -v docker >/dev/null 2>&1 || die "docker is not installed"
  head2 "Saving $img"
  docker save "$img" -o "$IMG_DIR/nmap-image.tar" || die "docker save failed"
  printf '%s\n' "$img" > "$IMG_DIR/nmap-image.txt"
  chmod 0644 "$IMG_DIR/nmap-image.tar" "$IMG_DIR/nmap-image.txt"
  ok "$(du -h "$IMG_DIR/nmap-image.tar" | cut -f1) -> $IMG_DIR/nmap-image.tar"
  say "  ${DIM}On the fielded box: sudo it-vulnscan image-load $IMG_DIR${R}"
}

cmd_image_load() {
  [ -r "$IMG_DIR/nmap-image.tar" ] || die "no nmap-image.tar in $IMG_DIR"
  command -v docker >/dev/null 2>&1 || die "docker is not installed"
  head2 "Loading"
  docker load -i "$IMG_DIR/nmap-image.tar" || die "docker load failed"
  local img=""
  [ -r "$IMG_DIR/nmap-image.txt" ] && img=$(cat "$IMG_DIR/nmap-image.txt")
  [ -n "$img" ] || die "no nmap-image.txt beside the tar -- cannot tell which tag to record"

  # Prove it before recording it, exactly as the role does.
  install -d -m 0700 /etc/stig-build
  [ -r "$FIPS_OFF" ] || printf '0\n' > "$FIPS_OFF"
  local mnt=(-v "$FIPS_OFF:/proc/sys/crypto/fips_enabled:ro")
  # -sV, not -sn: nmap only initialises OpenSSL when it needs TLS, so a ping
  # scan succeeds even on a box where the real scan cannot start.
  if docker run --rm --network host "${mnt[@]}" "$img" -sV -n -p 22 127.0.0.1 >/dev/null 2>&1; then
    printf '%s\n' "$img" > "$NMAP_IMG_MARKER"; chmod 0644 "$NMAP_IMG_MARKER"
    ok "loaded and verified: $img"
  else
    rm -f "$NMAP_IMG_MARKER"
    die "the image loaded but could not scan -- not recording it"
  fi
}

# ---- list / show ------------------------------------------------------------

newest() { ls -1t "$OUT_DIR"/*-vuln-scan-*.txt 2>/dev/null | head -1; }

case "$ACTION" in
  image-save) cmd_image_save; exit 0 ;;
  image-load) cmd_image_load; exit 0 ;;
esac

if [ "$ACTION" = list ]; then
  head2 "Scans in $OUT_DIR"
  f=$(ls -1t "$OUT_DIR"/*-vuln-scan-*.txt 2>/dev/null)
  [ -z "$f" ] && { warn "none yet -- run: it-vulnscan"; exit 0; }
  printf '%s\n' "$f" | while read -r x; do
    printf '  %s  %s  %s\n' "$(date -r "$x" '+%Y-%m-%d %H:%M')" \
      "$(du -h "$x" | cut -f1)" "$x"
  done
  exit 0
fi

if [ "$ACTION" = show ]; then
  f="${SHOW_FILE:-$(newest)}"
  [ -n "$f" ] && [ -r "$f" ] || die "no scan to show (run it-vulnscan first)"
  exec less -R -- "$f"
fi

# ---- scan -------------------------------------------------------------------

command -v nmap >/dev/null 2>&1 || die "nmap is not installed (base_packages installs it on the emi profile)"

install -d -o root -g "$(stat -c %G /opt/ia 2>/dev/null || echo sudo)" -m 2770 "$OUT_DIR"

STAMP=$(date '+%m-%d-%Y')
LOG="$OUT_DIR/$(hostname)-vuln-scan-$STAMP.txt"

# Appending, like the Windows job: two runs on the same day land in one dated
# file rather than one silently replacing the other.
log() { printf '%s\n' "$*" | tee -a "$LOG"; }

log "===================================================================="
log " Vulnerability scan -- $(hostname)"
log " Started : $(date '+%Y-%m-%d %H:%M:%S %Z')"
log " Operator: ${SUDO_USER:-root}"
log " Baseline: $(awk -F= '/^baseline_revision=/{print $2; exit}' /etc/stig-build/profile 2>/dev/null || echo unknown)"
log " Target  : $TARGET"
log "===================================================================="

head2 "nmap service + vulnerability scan"
say_target=$TARGET
[ "$TARGET" = 127.0.0.1 ] && say_target="127.0.0.1 (this host)"
printf '  target %s\n' "$say_target"
printf '  %sthis takes several minutes -- the vuln scripts probe every service found%s\n' "$DIM" "$R"

NMAP_ARGS=(-sV --script vuln)
[ -n "$PORTS" ] && NMAP_ARGS+=(-p "$PORTS")

log ""
log "-------------------------------------------------------------------- "
log " nmap $(nmap --version 2>/dev/null | awk '/^Nmap version/{print $3}')  --  nmap ${NMAP_ARGS[*]} $TARGET"
log "-------------------------------------------------------------------- "
nmap_out=$(nmap "${NMAP_ARGS[@]}" "$TARGET" 2>&1)
nmap_rc=$?
nmap_via=host

# The host nmap cannot start under FIPS. When nmap_container has proven an
# image can, use it rather than filing a report that scanned nothing. Only
# after the host has actually failed -- the host binary stays the default.
if [ "$nmap_rc" -ne 0 ] && [ "$USE_CONTAINER" -eq 1 ] && [ -n "$(ctr_image)" ]; then
  warn "host nmap failed -- retrying in the containerised nmap ($(ctr_image))"
  log "*** host nmap exited $nmap_rc; retrying via container $(ctr_image) ***"
  ctr_out=$(ctr_nmap "${NMAP_ARGS[@]}" "$TARGET" 2>&1)
  ctr_rc=$?
  if [ "$ctr_rc" -eq 0 ]; then
    nmap_out="$ctr_out"; nmap_rc=0; nmap_via=container
  else
    # Keep the HOST failure as the reported one -- it is the root cause, and a
    # container that also fails is a second fact, not a replacement for it.
    nmap_out="$nmap_out
--- containerised nmap also failed (rc=$ctr_rc) ---
$ctr_out"
  fi
fi

printf '%s\n' "$nmap_out" | tee -a "$LOG"
[ "$nmap_via" = container ] && log "nmap ran in the container: $(ctr_image)"

nmap_verdict=OK
if [ "$nmap_rc" -ne 0 ]; then
  nmap_verdict=FAULT
  bad "nmap exited $nmap_rc -- NOTHING WAS SCANNED"
  log "*** NMAP-FAULT: nmap exited $nmap_rc. No ports were probed. ***"
  # The known one on these boxes. nmap initialises OpenSSL at startup and the
  # FIPS provider offers it no usable cipher suite, so it quits before probing
  # anything -- the same class of failure as ClamAV (clamav#1786). Say so,
  # because the output otherwise reads exactly like a clean scan.
  if printf '%s' "$nmap_out" | grep -q 'library has no ciphers'; then
    bad "cause: OpenSSL in FIPS mode gives nmap no usable ciphers, so it quit at startup"
    log "*** cause: FIPS OpenSSL -- 'SSL routines::library has no ciphers'. ***"
    say "  ${DIM}nmap links the host OpenSSL and cannot be configured out of FIPS mode.${R}"
    if [ -n "$(ctr_image)" ]; then
      say "  ${DIM}The containerised nmap was tried and also failed. See docs/procedures.md 3.3.${R}"
    else
      say "  ${DIM}No containerised nmap on this box. Re-run the build to have nmap_container${R}"
      say "  ${DIM}build one, or carry it in: it-vulnscan image-load <dir>. docs/procedures.md 3.3.${R}"
    fi
  fi
else
  ok "nmap complete (via $nmap_via)"
fi

# What an operator actually wants off the top: did any vuln script report
# something, and what is listening. nmap's own output buries both.
#
# Count from THIS run's output, not the whole log -- the log is appended, so
# grepping it would fold in every earlier scan of the same day.
hits=$(printf '%s\n' "$nmap_out" | grep -cE '^\|.*(VULNERABLE|CVE-[0-9]{4}-[0-9]+)' || true)
hits=${hits:-0}

# SPLIT THE HITS, because the two kinds mean very different things and lumping
# them makes the number useless.
#
#   confirmed -- a script probed the service and said VULNERABLE. Real until
#                disproved. "NOT VULNERABLE" is a PASS and must not count.
#   listed    -- the `vulners` script matched the BANNER VERSION STRING against
#                its CVE database. On Ubuntu that is mostly noise: security
#                fixes are BACKPORTED without bumping the upstream version, so
#                a fully patched sshd still announces "OpenSSH 9.6p1" and
#                collects every CVE ever filed against 9.6p1. ASP-2 reported
#                CVE-2024-6387 (regreSSHion) while running
#                9.6p1-3ubuntu13.18 -- fixed upstream of that in 13.3.
confirmed=$(printf '%s\n' "$nmap_out" | grep -E '^\|' | grep -vi 'NOT VULNERABLE' \
              | grep -c 'VULNERABLE' || true); confirmed=${confirmed:-0}
listed=$(printf '%s\n' "$nmap_out" | grep -cE '^\|.*CVE-[0-9]{4}-[0-9]+' || true)
listed=${listed:-0}

# DID THE CVE-LISTING HALF RUN AT ALL?
# `vulners` is the only script here that needs the INTERNET -- it posts the
# detected service versions to vulners.com. Air-gapped it returns nothing, in
# silence, and the scan then reads "nmap flagged nothing as vulnerable" when
# what actually happened is that the check did not run. Same failure shape as
# NMAP-FAULT, and it gets reported the same way: a check that did not run is
# not a pass. Every OTHER vuln script probes the target directly and is
# unaffected offline.
vulners_ran=0
printf '%s\n' "$nmap_out" | grep -q '^| *vulners:' && vulners_ran=1
open=$(printf '%s\n' "$nmap_out" | grep -cE '^[0-9]+/(tcp|udp)[[:space:]]+open' || true)
open=${open:-0}

# ---- anti-virus -------------------------------------------------------------
# The Windows job runs a Defender full scan here. The equivalent, and the same
# engine-selection every other tool in this repo uses: the containerised clamd
# first (the host engine cannot detect on a FIPS box -- clamav#1786), then the
# host daemon, then standalone clamscan.

av_verdict="SKIPPED"
if [ "$DO_AV" -eq 1 ]; then
  head2 "Anti-virus scan"
  log ""
  log "-------------------------------------------------------------------- "
  log " Anti-virus full scan"
  log "-------------------------------------------------------------------- "

  # A scanner that cannot detect EICAR reports every file clean and exits 0.
  # Prove it works before recording a clean result as evidence.
  if command -v it-clamav >/dev/null 2>&1 && ! it-clamav test >/dev/null 2>&1; then
    bad "the AV engine does NOT detect the EICAR test file -- a clean scan proves nothing"
    log "*** ENGINE-FAULT: EICAR self-test failed. See: it-clamav test ***"
    av_verdict="ENGINE-FAULT"
  else
    CTR_CONF=/etc/clamav/clamd-container.conf
    sock=""
    [ -r "$CTR_CONF" ] && sock=$(awk '/^LocalSocket[[:space:]]/{print $2; exit}' "$CTR_CONF" 2>/dev/null)

    # NEVER hand the engine "/". clamdscan has no --exclude-dir (that is a
    # clamscan-only flag), so a "/" scan walks /proc and /sys, spends minutes
    # printing "Failed to open file" for every task's mem/pagemap, and then
    # grinds through /var/lib/docker. Scan the places writable content actually
    # lives instead. Override with VULNSCAN_AV_PATHS="/a /b".
    read -r -a AV_PATHS <<< "${VULNSCAN_AV_PATHS:-/home /root /opt /srv /etc /usr/local /tmp /var/tmp /media /mnt}"
    TARGETS=()
    for d in "${AV_PATHS[@]}"; do [ -d "$d" ] && TARGETS+=("$d"); done
    log "Scanned paths: ${TARGETS[*]}"
    printf '  %spaths: %s%s\n' "$DIM" "${TARGETS[*]}" "$R"

    AV_CMD=()
    if [ -n "$sock" ] && [ -S "$sock" ] && clamdscan -c "$CTR_CONF" --ping=1 >/dev/null 2>&1; then
      printf '  %sengine: containerised clamd%s\n' "$DIM" "$R"
      AV_CMD=(clamdscan -c "$CTR_CONF" --fdpass --multiscan --infected)
    elif systemctl is-active --quiet clamav-daemon 2>/dev/null; then
      printf '  %sengine: host clamav-daemon%s\n' "$DIM" "$R"
      AV_CMD=(clamdscan --fdpass --multiscan --infected)
    elif command -v clamscan >/dev/null 2>&1; then
      printf '  %sengine: standalone clamscan (slow)%s\n' "$DIM" "$R"
      AV_CMD=(clamscan -r --infected)
    fi

    if [ "${#AV_CMD[@]}" -eq 0 ]; then
      warn "no ClamAV engine available -- skipping"
      log "*** no AV engine available ***"
      av_verdict="SKIPPED"
    else
      av_out=$("${AV_CMD[@]}" "${TARGETS[@]}" 2>&1)
      av_rc=$?
      # Full fidelity into the report -- it is the evidence artifact.
      printf '%s\n' "$av_out" >> "$LOG"

      # A live desktop has hundreds of sockets and FIFOs (X11, ICE, dbus,
      # code-server) that no scanner can read. clamd counts each one in
      # "Total errors" and then exits 2, so the EXIT CODE alone says "error"
      # on a perfectly good scan. Judge by the summary instead, and only treat
      # errors as real when they are not the known-unscannable kinds.
      BENIGN='Not supported file type|cli_realpath: Invalid arguments|Can.t open file or directory|Access denied'
      printf '%s\n' "$av_out" | grep -vE "$BENIGN" | grep -vE '^\s*$' | sed 's/^/    /'

      infected=$(printf '%s\n' "$av_out" | sed -n 's/^Infected files: *\([0-9][0-9]*\).*/\1/p' | tail -1)
      errors=$(printf '%s\n'   "$av_out" | sed -n 's/^Total errors: *\([0-9][0-9]*\).*/\1/p'   | tail -1)
      # Anything that looks like a problem and is NOT one of the benign kinds.
      odd=$(printf '%s\n' "$av_out" | grep -E '^(WARNING|ERROR|LibClamAV (Error|Warning))' \
              | grep -cvE "$BENIGN" || true)
      odd=${odd:-0}

      if [ -z "$infected" ]; then
        # No summary line at all -- the scan did not complete.
        av_verdict="ENGINE-FAULT"
        bad "the AV scan did not complete (rc=$av_rc, no summary) -- see $LOG"
        log "*** ENGINE-FAULT: AV scan produced no summary (rc=$av_rc). ***"
      elif [ "$infected" -gt 0 ]; then
        av_verdict="INFECTED"
        bad "INFECTED FILES FOUND ($infected) -- see $LOG"
      elif [ "$odd" -gt 0 ]; then
        av_verdict="ERROR"
        bad "scan completed with $odd unexplained error(s) -- see $LOG"
      else
        av_verdict="CLEAN"
        if [ "${errors:-0}" -gt 0 ]; then
          ok "no infected files (${errors} unscannable sockets/FIFOs skipped -- normal on a desktop)"
          log "Note: ${errors} unscannable special files (sockets/FIFOs). Not a fault."
        else
          ok "no infected files"
        fi
      fi
    fi
  fi
else
  log ""
  log "Anti-virus scan: skipped (--quick)"
fi

# ---- summary ----------------------------------------------------------------

log ""
log "===================================================================="
log " SCAN COMPLETE -- $(date '+%Y-%m-%d %H:%M:%S %Z')"
log " nmap                    : $nmap_verdict (via $nmap_via)"
log " Open ports found        : $open"
log " nmap vuln script hits   : $hits"
log " Anti-virus              : $av_verdict"
log "===================================================================="

chmod 0640 "$LOG"

head2 "Summary"
if [ "$nmap_verdict" = FAULT ]; then
  bad "nmap FAULTED -- no ports were probed. This report is not evidence of anything."
else
  printf '  %-24s %s\n' "open ports" "$open"
fi
if [ "$nmap_verdict" = FAULT ]; then
  :
elif [ "$hits" -gt 0 ]; then
  if [ "$confirmed" -gt 0 ]; then
    bad "$confirmed line(s) CONFIRMED VULNERABLE by a probe -- treat as real"
    grep -E '^\|' "$LOG" | grep -vi 'NOT VULNERABLE' | grep 'VULNERABLE' \
      | head -10 | sed 's/^/    /'
  else
    ok "no script probed a service and found it vulnerable"
  fi
  if [ "$listed" -eq 0 ] && [ "$vulners_ran" -eq 0 ] && [ "$open" -gt 0 ]; then
    warn "vulners produced NO output -- the CVE-listing half of this scan did not run"
    printf '    %sIt is the one script here that needs the internet (it posts service\n' "$DIM"
    printf '    versions to vulners.com). Air-gapped it returns nothing, in silence.\n'
    printf '    The local probe scripts above DID run. Do NOT read this as "no CVEs"\n'
    printf '    -- judge patch state from the box itself:%s\n' "$R"
    printf '      sudo pro security-status        # local apt data, works OFFLINE\n'
    printf '      apt list --upgradable\n'
  fi
  if [ "$listed" -gt 0 ]; then
    warn "$listed CVE(s) LISTED by vulners from the banner version -- NOT confirmed"
    grep -E '^\|.*CVE-[0-9]{4}-[0-9]+' "$LOG" | head -5 | sed 's/^/    /'
    [ "$listed" -gt 5 ] && printf '    %s... %d more in the log%s\n' "$DIM" "$((listed-5))" "$R"
    printf '    %svulners matches the VERSION STRING, and Ubuntu BACKPORTS fixes without\n' "$DIM"
    printf '    bumping it -- a patched sshd still announces "OpenSSH 9.6p1". Most of\n'
    printf '    these are false positives. Confirm before filing any of them:%s\n' "$R"
    printf '      sudo pro fix --dry-run CVE-2024-6387   # authoritative; NEEDS INTERNET\n'
    printf '      sudo pro security-status               # local apt data, works OFFLINE\n'
    printf '      apt list --upgradable | grep -i openssh\n'
  fi
else
  ok "nmap flagged nothing as vulnerable"
fi
printf '  %-24s %s\n' "anti-virus" "$av_verdict"
printf '\n  report: %s\n' "$LOG"
printf '  %sReview it and file the result -- an unread scan is not evidence.%s\n' "$DIM" "$R"

# Retention. Only ever prunes files this script wrote.
if [ "$KEEP" -gt 0 ]; then
  ls -1t "$OUT_DIR"/*-vuln-scan-*.txt 2>/dev/null | tail -n +$((KEEP+1)) | while read -r old; do
    rm -f -- "$old"
  done
fi

# Exit non-zero when something needs a human. A faulted scanner counts: a scan
# that did not run must never read as a clean result.
[ "$nmap_verdict" = OK ] \
  && [ "$hits" -eq 0 ] \
  && [ "$av_verdict" != INFECTED ] \
  && [ "$av_verdict" != ENGINE-FAULT ] \
  && [ "$av_verdict" != ERROR ]
