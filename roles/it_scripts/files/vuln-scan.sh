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
set -uo pipefail

OUT_DIR="${VULNSCAN_DIR:-/opt/ia/vulnscans}"
TARGET=127.0.0.1
PORTS=""
DO_AV=1
KEEP=12
ACTION=scan
SHOW_FILE=""

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
    --list)   ACTION=list; shift ;;
    --show)   ACTION=show; SHOW_FILE="${2:-}"; [ -n "$SHOW_FILE" ] && shift; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ---- list / show ------------------------------------------------------------

newest() { ls -1t "$OUT_DIR"/*-vuln-scan-*.txt 2>/dev/null | head -1; }

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
printf '%s\n' "$nmap_out" | tee -a "$LOG"

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
    say "  ${DIM}nmap is linked against the host OpenSSL and cannot be configured out of${R}"
    say "  ${DIM}FIPS mode. Run it from a container, or from a non-FIPS box on the same${R}"
    say "  ${DIM}segment, and file that output instead. See docs/procedures.md 3.3.${R}"
  fi
else
  ok "nmap complete"
fi

# What an operator actually wants off the top: did any vuln script report
# something, and what is listening. nmap's own output buries both.
#
# Count from THIS run's output, not the whole log -- the log is appended, so
# grepping it would fold in every earlier scan of the same day.
hits=$(printf '%s\n' "$nmap_out" | grep -cE '^\|.*(VULNERABLE|CVE-[0-9]{4}-[0-9]+)' || true)
hits=${hits:-0}
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
log " nmap                    : $nmap_verdict"
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
  bad "nmap flagged $hits line(s) as VULNERABLE / CVE -- review them"
  grep -E '^\|.*(VULNERABLE|CVE-[0-9]{4}-[0-9]+)' "$LOG" | head -10 | sed 's/^/    /'
  [ "$hits" -gt 10 ] && printf '    %s... %d more in the log%s\n' "$DIM" "$((hits-10))" "$R"
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
