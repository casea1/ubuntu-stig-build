#!/usr/bin/env bash
# dta-log -- record a data transfer and scan the payload before it moves.
#
# Runs as the DTA, NOT as root: the whole point is that the record names the
# person who did the transfer. /opt/dta/logs is 3770 root:dta -- group-writable
# so a DTA can add a record, sticky so nobody can delete somebody else's.
#
# Usage:
#   dta-log                 walk through a transfer and write the record
#   dta-log list [N]        the last N records (default 15)
#   dta-log show <id|last>  print one record in full
#   dta-log where           print the paths and exit
#   --no-hash               skip the per-file sha256 (large transfers)
#   --dir PATH              skip the folder prompt and use PATH
set -uo pipefail

DTA_DIR="${DTA_DIR:-/opt/dta}"
LOG_DIR="$DTA_DIR/logs"
INDEX="$LOG_DIR/transfers.tsv"
RECENT_DAYS="${DTA_RECENT_DAYS:-14}"
DO_HASH=1
FORCED_DIR=""


# On a FIPS host OpenSSL refuses to initialise MD5, which ClamAV -- and sigtool,
# which verifies the CVD signatures -- depend on. The clamav_fips role writes
# this config (default provider only) after proving it works; use it if present.
if [ -r /etc/clamav/openssl-clamav.cnf ]; then
  export OPENSSL_CONF=/etc/clamav/openssl-clamav.cnf
fi

# Records must be readable by the rest of the dta group and by nobody else.
# The STIG umask is 077, which would make each record private to its author.
umask 007

# ---- presentation -----------------------------------------------------------
if [ -t 1 ]; then
  B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'
else
  B=""; DIM=""; R=""; RED=""; GRN=""; YEL=""; CYN=""
fi
say()  { printf '%s\n' "$*"; }
head2(){ printf '\n%s%s%s\n' "$B" "$*" "$R"; }
warn() { printf '%s%s%s\n' "$YEL" "$*" "$R" >&2; }
die()  { printf '%s%s%s\n' "$RED" "$*" "$R" >&2; exit 1; }

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; }

# ---- helpers ----------------------------------------------------------------
human() {  # bytes -> human
  local b=${1:-0}
  numfmt --to=iec --suffix=B "$b" 2>/dev/null || echo "${b}B"
}

dir_stats() {  # dir -> "count<TAB>bytes<TAB>newest_epoch"
  local d="$1" c=0 b=0 n=0
  while IFS=$'\t' read -r size mtime; do
    c=$((c + 1)); b=$((b + size))
    [ "${mtime%.*}" -gt "$n" ] && n=${mtime%.*}
  done < <(find "$d" -type f -printf '%s\t%T@\n' 2>/dev/null)
  printf '%s\t%s\t%s\n' "$c" "$b" "$n"
}

newest_subdir() {  # root -> the dir holding the most recently modified file
  local root="$1"
  [ -d "$root" ] || return 1
  find "$root" -type f -newermt "-${RECENT_DAYS} days" -printf '%T@\t%h\n' 2>/dev/null \
    | sort -rn | head -1 | cut -f2-
}

describe() {  # dir -> one padded line for the menu
  local d="$1" c b n
  IFS=$'\t' read -r c b n < <(dir_stats "$d")
  if [ "$c" -eq 0 ]; then
    printf '%s  %s(empty)%s\n' "$d" "$DIM" "$R"
  else
    printf '%s\n      %s%s files, %s, newest %s%s\n' \
      "$d" "$DIM" "$c" "$(human "$b")" "$(date -d "@$n" '+%Y-%m-%d %H:%M')" "$R"
  fi
}

classification() {
  local a=/etc/xdg/autostart/classification-banner.desktop
  [ -f "$a" ] && grep -oP '^Exec=.*classification-banner\s+"?\K[^"]+' "$a" 2>/dev/null && return
  echo "NOT RECORDED"
}

sig_age() {  # -> "daily.cld 2026-08-20 (6 days old)" | "NO SIGNATURE DATABASE"
  local newest="" f age
  for f in /var/lib/clamav/daily.cvd /var/lib/clamav/daily.cld; do
    [ -f "$f" ] || continue
    [ -z "$newest" ] || [ "$f" -nt "$newest" ] && newest="$f"
  done
  [ -n "$newest" ] || { echo "NO SIGNATURE DATABASE"; return 1; }
  age=$(( ( $(date +%s) - $(stat -c %Y "$newest") ) / 86400 ))
  printf '%s %s (%s days old)\n' "$(basename "$newest")" \
    "$(date -r "$newest" '+%Y-%m-%d')" "$age"
  [ "$age" -le 7 ]
}

# The engine can load every signature and still scan NOTHING. On a FIPS host,
# OpenSSL refuses to initialise MD5 -- which is what ClamAV hashes with -- so
# every file comes back OK with "Data scanned: 0 B". A record that says CLEAN
# because the scanner was broken is worse than no record, so prove the engine
# detects before trusting what it says about the payload.
# The test string is assembled at runtime: written out whole, this file would
# itself be flagged by every AV product that scanned the repo.
engine_selftest() {  # engine name -> 0 detects, 1 does not
  local td out rc
  td=$(mktemp -d /tmp/dta-canary.XXXXXX) || return 1
  printf '%s%s' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR' '-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' \
    > "$td/canary"
  out=$(scan_with "$1" --no-summary "$td/canary" 2>&1); rc=$?
  rm -rf "$td"
  SELFTEST_OUT="$out"
  [ "$rc" -eq 1 ]
}

# Which engine to use, in order of preference. On a FIPS host the host engine
# cannot initialise MD5 and detects nothing, so clamav_container runs clamd in a
# container whose OpenSSL is a stock build; its socket lands on the host and we
# talk to it with the ordinary clamdscan client. --fdpass hands over a file
# DESCRIPTOR, so the file never has to exist inside the container and the daemon
# reads with this user's rights -- which is also why a DTA needs no docker access.
CTR_CONF=/etc/clamav/clamd-container.conf
# `clamdscan --ping 1` returns 0 even when it cannot connect (seen on ASP-2, where
# it reported the HOST socket missing and still succeeded), so check the socket
# exists and use the = form.
ctr_alive() {
  local sock
  sock=$(awk '/^LocalSocket[[:space:]]/{print $2; exit}' "$CTR_CONF" 2>/dev/null)
  [ -n "$sock" ] && [ -S "$sock" ] || return 1
  clamdscan -c "$CTR_CONF" --ping=1 >/dev/null 2>&1
}

pick_engine() {
  if [ -r "$CTR_CONF" ] && ctr_alive; then
    echo container
  elif command -v clamdscan >/dev/null 2>&1 && systemctl is-active --quiet clamav-daemon 2>/dev/null; then
    echo clamd
  elif command -v clamscan >/dev/null 2>&1; then
    echo clamscan
  fi
}

scan_with() {  # engine, then clamscan-style args
  local eng="$1"; shift
  case "$eng" in
    container) clamdscan -c "$CTR_CONF" --fdpass "$@" ;;
    clamd)     clamdscan --fdpass "$@" ;;
    clamscan)  clamscan -r "$@" ;;
    *)         return 99 ;;
  esac
}

engine_label() {
  case "$1" in
    container) echo "clamdscan -> containerised clamd (host engine cannot scan under FIPS)" ;;
    clamd)     echo "clamdscan (host clamav-daemon)" ;;
    clamscan)  echo "clamscan (standalone -- loads signatures itself, slower)" ;;
    *)         echo "NONE -- clamav is not available" ;;
  esac
}

ask_yn() {  # prompt default(Y|N) -> 0 yes / 1 no
  local p="$1" d="${2:-Y}" a hint="[Y/n]"
  [ "$d" = "N" ] && hint="[y/N]"
  while true; do
    read -r -p "$p $hint " a </dev/tty || die "aborted"
    a="${a:-$d}"
    case "${a,,}" in y|yes) return 0 ;; n|no) return 1 ;; esac
    warn "  Answer y or n."
  done
}

# ---- subcommands ------------------------------------------------------------
cmd_where() {
  say "records   : $LOG_DIR"
  say "index     : $INDEX"
  say "incoming  : $DTA_DIR/incoming"
  say "outgoing  : $DTA_DIR/outgoing"
  exit 0
}

cmd_list() {
  local n="${1:-15}"
  [ -s "$INDEX" ] || { say "No transfers recorded yet."; exit 0; }
  printf '%s%-20s %-16s %-5s %-4s %-8s %s%s\n' "$B" \
    "WHEN (UTC)" "OPERATOR" "TYPE" "APPR" "SCAN" "SOURCE" "$R"
  tail -n "$n" "$INDEX" | while IFS=$'\t' read -r when host user name typ appr src cnt sz verdict inf rec; do
    local col="$GRN"
    case "$verdict" in INFECTED) col="$RED" ;; ERROR|SKIPPED) col="$YEL" ;; esac
    printf '%-20s %-16s %-5s %-4s %s%-8s%s %s\n' \
      "$when" "$user" "$typ" "$appr" "$col" "$verdict" "$R" "$src"
  done
  exit 0
}

cmd_show() {
  local id="${1:-last}" f
  if [ "$id" = "last" ]; then
    f=$(ls -1t "$LOG_DIR"/*.log 2>/dev/null | head -1)
  else
    f="$LOG_DIR/$id"; [ -f "$f" ] || f="$LOG_DIR/$id.log"
  fi
  [ -n "${f:-}" ] && [ -f "$f" ] || die "no such record: $id"
  cat "$f"
  exit 0
}

# ---- argument parsing -------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --no-hash) DO_HASH=0; shift ;;
    --dir)     FORCED_DIR="${2:?--dir needs a path}"; shift 2 ;;
    where)     cmd_where ;;
    list)      shift; cmd_list "${1:-15}" ;;
    show)      shift; cmd_show "${1:-last}" ;;
    -*)        die "unknown option: $1  (try --help)" ;;
    *)         die "unknown command: $1  (try --help)" ;;
  esac
done

# ---- preflight --------------------------------------------------------------
[ "$(id -u)" -ne 0 ] || warn "Running as root. The record will name 'root', not a DTA."
[ -d "$LOG_DIR" ] || die "$LOG_DIR does not exist. Run an ansible-pull on this box first."
[ -w "$LOG_DIR" ] || die "You cannot write to $LOG_DIR. Membership of the 'dta' group is required (you are in: $(id -nG))."

STARTED_EPOCH=$(date +%s)
REC_ID="$(date -u -d "@$STARTED_EPOCH" +%Y%m%dT%H%M%SZ)-$(id -un)"
REC="$LOG_DIR/$REC_ID.log"

head2 "DATA TRANSFER RECORD"
say "${DIM}Record  : $REC_ID"
say "Host    : $(hostname)   Classification: $(classification)"
say "Operator: $(id -un) (uid $(id -u))${R}"

# ---- Q1: approval -----------------------------------------------------------
head2 "1. Approval"
say "Has the low-side transfer form been approved by the AO and the ISSM/ISSO?"
if ask_yn "  Approved?" Y; then
  Q_APPROVED="YES"
else
  Q_APPROVED="NO"
  warn ""
  warn "  Not approved. The transfer must not proceed."
  warn "  An ABORTED record is being written so the attempt is still on file."
  {
    printf '=== DATA TRANSFER RECORD (ABORTED) ===\n'
    printf 'Record ID        : %s\n' "$REC_ID"
    printf 'Host             : %s\n' "$(hostname)"
    printf 'Classification   : %s\n' "$(classification)"
    printf 'Operator         : %s (uid %s)\n' "$(id -un)" "$(id -u)"
    printf 'Started          : %s\n' "$(date -u -d "@$STARTED_EPOCH" '+%Y-%m-%d %H:%M:%S UTC')"
    printf 'Local time       : %s\n' "$(date -d "@$STARTED_EPOCH" '+%Y-%m-%d %H:%M:%S %Z')"
    printf '\n1. AO / ISSM-ISSO approval : NO\n'
    printf '\nOutcome          : ABORTED -- no approval on file. Nothing was scanned or moved.\n'
  } > "$REC"
  chmod 0660 "$REC" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u -d "@$STARTED_EPOCH" +%Y-%m-%dT%H:%M:%SZ)" "$(hostname)" "$(id -un)" \
    "-" "-" "NO" "-" "0" "0" "ABORTED" "0" "$REC_ID.log" >> "$INDEX"
  say ""
  say "Record: $REC"
  exit 1
fi

# ---- Q2: who ----------------------------------------------------------------
head2 "2. Data transfer agent"
GECOS=$(getent passwd "$(id -un)" | cut -d: -f5 | cut -d, -f1)
read -r -p "  Name of DTA${GECOS:+ [$GECOS]}: " Q_NAME </dev/tty || die "aborted"
Q_NAME="${Q_NAME:-$GECOS}"
[ -n "$Q_NAME" ] || die "A name is required for the record."

# ---- Q3: direction ----------------------------------------------------------
head2 "3. Transfer type"
say "  1) L2H  -- low to high"
say "  2) H2H  -- high to high"
while true; do
  read -r -p "  Select [1]: " a </dev/tty || die "aborted"
  case "${a:-1}" in
    1|l2h|L2H) Q_TYPE="L2H"; Q_TYPE_LONG="L2H (low to high)"; break ;;
    2|h2h|H2H) Q_TYPE="H2H"; Q_TYPE_LONG="H2H (high to high)"; break ;;
    *) warn "  Enter 1 or 2." ;;
  esac
done

# ---- Q4: what -----------------------------------------------------------
head2 "4. Location of files"
SRC=""; HOW=""
if [ -n "$FORCED_DIR" ]; then
  SRC="$FORCED_DIR"; HOW="given on the command line (--dir)"
else
  CANDS=()
  for root in "$DTA_DIR/incoming" "$DTA_DIR/outgoing"; do
    d=$(newest_subdir "$root") || true
    [ -n "${d:-}" ] && CANDS+=("$d")
  done
  # dedupe, preserving order
  UNIQ=(); for d in "${CANDS[@]:-}"; do
    [ -n "$d" ] || continue
    for u in "${UNIQ[@]:-}"; do [ "$u" = "$d" ] && continue 2; done
    UNIQ+=("$d")
  done

  if [ "${#UNIQ[@]}" -eq 0 ]; then
    warn "  Nothing modified in $DTA_DIR/incoming or /outgoing in the last $RECENT_DAYS days."
  elif [ "${#UNIQ[@]}" -eq 1 ]; then
    say "  Most recent activity:"
    printf '    '; describe "${UNIQ[0]}"
    if ask_yn "  Is this the data being transferred?" Y; then
      SRC="${UNIQ[0]}"; HOW="auto-detected, confirmed by the operator"
    fi
  else
    say "  Most recent activity:"
    i=1; for d in "${UNIQ[@]}"; do printf '   %s) ' "$i"; describe "$d"; i=$((i + 1)); done
    say "   o) other -- type a path"
    read -r -p "  Select [1]: " a </dev/tty || die "aborted"
    a="${a:-1}"
    if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le "${#UNIQ[@]}" ]; then
      SRC="${UNIQ[$((a - 1))]}"; HOW="auto-detected, selected by the operator"
    fi
  fi

  if [ -z "$SRC" ]; then
    read -r -p "  Path to the data: " SRC </dev/tty || die "aborted"
    HOW="typed in by the operator"
  fi
fi

SRC="${SRC%/}"
[ -d "$SRC" ] || die "Not a directory: $SRC"
SRC=$(readlink -f "$SRC")
IFS=$'\t' read -r F_COUNT F_BYTES F_NEWEST < <(dir_stats "$SRC")
[ "$F_COUNT" -gt 0 ] || die "$SRC holds no files. Nothing to transfer."

say ""
say "  Confirmed source: ${B}$SRC${R}"
say "  ${DIM}$F_COUNT files, $(human "$F_BYTES"), newest $(date -d "@$F_NEWEST" '+%Y-%m-%d %H:%M:%S')${R}"

# ---- Q5: scan ---------------------------------------------------------------
head2 "5. Malware scan"
SIG=$(sig_age) || SIG_STALE=1
say "  Signatures: $SIG"
[ "${SIG_STALE:-0}" = 1 ] && warn "  Signatures are stale or missing. Record it on the transfer form."

SCAN_START=$(date +%s)
ENGINE="NONE -- clamav is not available"; SCAN_OUT="no usable scanner"; SCAN_RC=99
SELFTEST="NOT RUN"; SELFTEST_OUT=""

ENG=$(pick_engine)
if [ -n "$ENG" ]; then
  ENGINE=$(engine_label "$ENG")
  # Prove the engine detects anything at all before it is asked about the payload.
  if engine_selftest "$ENG"; then
    SELFTEST="PASS -- engine detected the EICAR test file"
  else
    SELFTEST="FAIL -- engine did NOT detect the EICAR test file"
  fi
fi

if [ "$SELFTEST" != "${SELFTEST#FAIL}" ]; then
  ENGINE="$ENGINE -- SELF-TEST FAILED, payload NOT scanned"
  SCAN_OUT="$SELFTEST_OUT"
  SCAN_RC=98
elif [ -n "$ENG" ]; then
  [ "$ENG" = clamscan ] && say "  ${DIM}Loading signatures. This takes a minute.${R}"
  SCAN_OUT=$(scan_with "$ENG" --infected "$SRC" 2>&1); SCAN_RC=$?
fi
SCAN_END=$(date +%s)

INFECTED=$(printf '%s\n' "$SCAN_OUT" | grep -oP '^Infected files:\s*\K[0-9]+' | tail -1)
INFECTED="${INFECTED:-0}"
case "$SCAN_RC" in
  0)  VERDICT="CLEAN" ;;
  1)  VERDICT="INFECTED" ;;
  98) VERDICT="ENGINE-FAULT" ;;
  99) VERDICT="SKIPPED" ;;
  *)  VERDICT="ERROR" ;;
esac
# Belt and braces: a clean result that scanned no bytes, or that logged a hash
# failure, is not a clean result.
if [ "$VERDICT" = CLEAN ]; then
  if printf '%s' "$SCAN_OUT" | grep -qiE 'error initializing|hash context'; then
    VERDICT="ENGINE-FAULT"; SCAN_RC=98
  elif printf '%s' "$SCAN_OUT" | grep -qE '^Data scanned: 0 '; then
    VERDICT="ENGINE-FAULT"; SCAN_RC=98
  fi
fi

say ""
printf '%s\n' "$SCAN_OUT" | sed 's/^/  /'
say ""
case "$VERDICT" in
  CLEAN)    say "  ${GRN}${B}CLEAN${R} -- 0 infected files." ;;
  INFECTED) say "  ${RED}${B}INFECTED${R} -- $INFECTED file(s). ${RED}Do not transfer. Notify the ISSO.${R}" ;;
  ENGINE-FAULT)

            say "  ${RED}${B}ENGINE FAULT${R} -- ClamAV is loaded but is not detecting anything."
            say "  ${RED}The payload was NOT scanned. Do not transfer. Tell an admin to run"
            say "  \`sudo it-clamav test\` on this box.${R}" ;;
  SKIPPED)  warn "  NOT SCANNED -- clamav is not available on this box." ;;
  *)        warn "  SCANNER ERROR (exit $SCAN_RC). Treat as unscanned." ;;
esac

# ---- write the record -------------------------------------------------------
FIN_EPOCH=$(date +%s)
{
  printf '================================================================\n'
  printf ' DATA TRANSFER RECORD\n'
  printf '================================================================\n'
  printf 'Record ID        : %s\n' "$REC_ID"
  printf 'Host             : %s\n' "$(hostname)"
  printf 'Classification   : %s\n' "$(classification)"
  printf 'Operator account : %s (uid %s)\n' "$(id -un)" "$(id -u)"
  printf 'Started          : %s\n' "$(date -u -d "@$STARTED_EPOCH" '+%Y-%m-%d %H:%M:%S UTC')"
  printf 'Local time       : %s\n' "$(date -d "@$STARTED_EPOCH" '+%Y-%m-%d %H:%M:%S %Z')"
  printf '\n'
  printf '1. AO / ISSM-ISSO approval : %s\n' "$Q_APPROVED"
  printf '2. Name of DTA             : %s\n' "$Q_NAME"
  printf '3. Transfer type           : %s\n' "$Q_TYPE_LONG"
  printf '4. Source folder           : %s\n' "$SRC"
  printf '   Selected by             : %s\n' "$HOW"
  printf '   Contents                : %s files, %s\n' "$F_COUNT" "$(human "$F_BYTES")"
  printf '   Newest file             : %s\n' "$(date -d "@$F_NEWEST" '+%Y-%m-%d %H:%M:%S %Z')"
  printf '\n'
  printf '5. Malware scan\n'
  printf '   Engine                  : %s\n' "$ENGINE"
  printf '   Signatures              : %s\n' "$SIG"
  printf '   Started                 : %s\n' "$(date -u -d "@$SCAN_START" '+%Y-%m-%d %H:%M:%S UTC')"
  printf '   Finished                : %s (%ss)\n' \
    "$(date -u -d "@$SCAN_END" '+%Y-%m-%d %H:%M:%S UTC')" "$((SCAN_END - SCAN_START))"
  printf '   Engine self-test        : %s\n' "$SELFTEST"
  printf '   Result                  : %s (%s infected, scanner exit %s)\n' "$VERDICT" "$INFECTED" "$SCAN_RC"
  printf '   ---- scanner output ----\n'
  printf '%s\n' "$SCAN_OUT" | sed 's/^/   /'
  printf '\n'
  printf 'Finished         : %s\n' "$(date -u -d "@$FIN_EPOCH" '+%Y-%m-%d %H:%M:%S UTC')"
  case "$VERDICT" in
    CLEAN)    printf 'Outcome          : APPROVED TO TRANSFER -- scan clean.\n' ;;
    INFECTED) printf 'Outcome          : BLOCKED -- malware detected. Do not transfer; notify the ISSO.\n' ;;
    ENGINE-FAULT)
              printf 'Outcome          : BLOCKED -- the scanner failed its own detection test, so it\n'
              printf '                   cannot vouch for this payload. NOT scanned. Do not transfer.\n' ;;
    *)        printf 'Outcome          : INCOMPLETE -- payload was not scanned successfully.\n' ;;
  esac
  printf '\n'
  printf '================================================================\n'
  if [ "$DO_HASH" = 1 ]; then
    printf ' FILE MANIFEST (sha256  bytes  path relative to the source folder)\n'
    printf '================================================================\n'
    ( cd "$SRC" && find . -type f -print0 | sort -z \
        | xargs -0 -r sha256sum 2>/dev/null \
        | while read -r h p; do printf '%s  %10s  %s\n' "$h" "$(stat -c %s "$p" 2>/dev/null)" "$p"; done )
  else
    printf ' FILE MANIFEST (--no-hash: listing only)\n'
    printf '================================================================\n'
    ( cd "$SRC" && find . -type f -printf '%10s  %p\n' | sort -k2 )
  fi
} > "$REC"
chmod 0660 "$REC" 2>/dev/null || true

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(date -u -d "@$STARTED_EPOCH" +%Y-%m-%dT%H:%M:%SZ)" "$(hostname)" "$(id -un)" \
  "$Q_NAME" "$Q_TYPE" "$Q_APPROVED" "$SRC" "$F_COUNT" "$F_BYTES" \
  "$VERDICT" "$INFECTED" "$REC_ID.log" >> "$INDEX"
chmod 0660 "$INDEX" 2>/dev/null || true

head2 "Recorded"
say "  $REC"
say "  ${DIM}Review with: dta-log show last   |   dta-log list${R}"
say ""

[ "$VERDICT" = "CLEAN" ] || exit 1
