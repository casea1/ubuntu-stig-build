#!/usr/bin/env bash
# it-stig -- one command for the whole STIG evidence cycle: scan, then build the
# checklist. Wraps it-oscap and it-ckl so the two stay in step and the
# prerequisites are checked before anything runs rather than failing halfway.
#
#   it-stig status      what is staged, what is missing, when it last ran
#   it-stig run         scan + checklist (the default)
#   it-stig scan        scan only        (it-oscap)
#   it-stig checklist   checklist only   (it-ckl, reusing the newest scan)
#   it-stig archive     tar the current evidence set for hand-off
#
# Options are passed through:
#   --content FILE     scan against DISA's SCAP benchmark instead of SSG content
#   --no-tailoring     scan the untailored benchmark on purpose
#   --format cklb|ckl|both      checklist format (default both)
#   --keep N           how many scan result sets to retain
#
# The one thing this cannot fetch for you is DISA's manual STIG XCCDF; `status`
# says so and where to put it. See docs/compliance.md.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

OSCAP_DIR="${OSCAP_DIR:-/opt/ia/oscap}"
STIG_DIR="${STIG_DIR:-/opt/ia/stig}"
TAILORING="/etc/usg/managed-tailoring.xml"
FORMAT="both"
PASS_SCAN=()
PASS_CKL=()

ok(){ printf '  \033[32mOK\033[0m   %s\n' "$1"; }
no(){ printf '  \033[31mMISS\033[0m %s\n' "$1"; }
wa(){ printf '  \033[33mWARN\033[0m %s\n' "$1"; }

CMD="run"
case "${1:-}" in
  status|run|scan|checklist|archive) CMD="$1"; shift ;;
  help|-h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --content)      PASS_SCAN+=(--content "${2:?}"); shift 2 ;;
    --no-tailoring) PASS_SCAN+=(--no-tailoring); shift ;;
    --keep)         PASS_SCAN+=(--keep "${2:?}"); shift 2 ;;
    --format)       FORMAT="${2:?}"; shift 2 ;;
    --summary)      PASS_CKL+=(--summary); shift ;;
    --map)          PASS_CKL+=(--map "${2:?}"); shift 2 ;;
    *) echo "unknown option: $1  (try: it-stig help)" >&2; exit 2 ;;
  esac
done

newest() { ls -1t $1 2>/dev/null | head -1; }

manual_xccdf() { newest "$STIG_DIR/*Manual-xccdf.xml"; }
last_scan()    { newest "$OSCAP_DIR/stig-viewer-*.xml"; }
last_ckl()     { newest "$STIG_DIR/*.cklb"; }

status() {
  echo "STIG evidence status  ($(hostname))"
  echo
  local rc=0 f
  command -v oscap >/dev/null 2>&1 && ok "oscap installed" || { no "oscap not installed (apt install openscap-scanner)"; rc=1; }

  f=$(newest "/usr/share/xml/scap/ssg/content/ssg-ubuntu24*-ds*.xml")
  [ -n "$f" ] && ok "SSG content: $(basename "$f")" || { no "no SSG datastream -- the scap_scan role stages it (needs internet once)"; rc=1; }

  f=$(manual_xccdf)
  if [ -n "$f" ]; then ok "manual STIG: $(basename "$f")"
  else
    no "no manual STIG XCCDF in $STIG_DIR"
    echo "         Download 'Canonical Ubuntu 24.04 LTS STIG' from"
    echo "         https://public.cyber.mil/stigs/downloads/ , unzip, and copy the"
    echo "         *Manual-xccdf.xml into $STIG_DIR/ . Unclassified -- USB is fine."
    rc=1
  fi

  [ -s "$STIG_DIR/answers.yml" ] \
    && ok "adjudications: $(grep -cE '^[A-Za-z]' "$STIG_DIR/answers.yml" 2>/dev/null || echo 0) entries in answers.yml" \
    || wa "no answers.yml -- run an ansible-pull so the scap_scan role renders it"

  [ -f "$TAILORING" ] && ok "USG tailoring: $TAILORING (smartcard/SSSD de-selected)" \
                      || wa "no $TAILORING -- scans will include rules the baseline de-scopes"

  f=$(last_scan)
  [ -n "$f" ] && ok "last scan: $(basename "$f")  ($(date -r "$f" '+%Y-%m-%d %H:%M'))" \
              || wa "no scan results yet -- run: it-stig scan"

  f=$(last_ckl)
  [ -n "$f" ] && ok "last checklist: $(basename "$f")  ($(date -r "$f" '+%Y-%m-%d %H:%M'))" \
              || wa "no checklist yet -- run: it-stig run"

  echo
  [ "$rc" = 0 ] && echo "RESULT: ready. Run 'it-stig run'." \
                || echo "RESULT: not ready -- see MISS lines above."
  return "$rc"
}

do_scan() {
  echo "== SCAN =="
  it-oscap ${PASS_SCAN[@]+"${PASS_SCAN[@]}"}
  local rc=$?
  # 0 = everything passed, 2 = some rules failed. Both are successful scans;
  # only anything else means the scanner itself broke.
  case "$rc" in
    0|2) return 0 ;;
    *) echo "scan failed (rc=$rc)" >&2; return "$rc" ;;
  esac
}

do_checklist() {
  echo
  echo "== CHECKLIST =="
  if [ -z "$(manual_xccdf)" ]; then
    echo "No manual STIG XCCDF staged -- cannot build a checklist." >&2
    echo "Run 'it-stig status' for where to put it." >&2
    return 1
  fi
  [ -n "$(last_scan)" ] || { echo "No scan results -- run 'it-stig scan' first." >&2; return 1; }
  it-ckl --format "$FORMAT" ${PASS_CKL[@]+"${PASS_CKL[@]}"}
}

case "$CMD" in
  status)    status ;;
  scan)      do_scan ;;
  checklist) do_checklist ;;
  run)
    status >/dev/null || { echo "Prerequisites missing:"; status; exit 1; }
    do_scan && do_checklist
    ;;
  archive)
    ts=$(date +%Y%m%d-%H%M%S); out="$STIG_DIR/stig-evidence-$(hostname -s)-$ts.tar.gz"
    # A manifest instead of the XCCDF itself: DISA's manual STIG is ~40 MB of
    # public content, so shipping it in every evidence bundle wastes the media.
    # Recording WHICH release was used is the part that matters for the audit.
    man="$STIG_DIR/.manifest.txt"
    {
      echo "host      : $(hostname -f 2>/dev/null || hostname)"
      echo "collected : $(date -Is)"
      echo "manual STIG: $(basename "$(manual_xccdf)" 2>/dev/null || echo 'none staged')"
      echo "last scan : $(basename "$(last_scan)" 2>/dev/null || echo none)"
      echo "checklist : $(basename "$(last_ckl)" 2>/dev/null || echo none)"
    } > "$man"
    tar -czf "$out" -C / --exclude='*.tar.gz' --exclude='*Manual-xccdf.xml' \
      --exclude='*-ds.xml' \
      "${OSCAP_DIR#/}" "${STIG_DIR#/}" 2>/dev/null
    rm -f "$man"
    chmod 0640 "$out"
    echo "Wrote $out"
    echo "Scan results, generated checklists, answers.yml and a manifest naming"
    echo "the STIG release used. DISA's XCCDF is excluded (public, and large)."
    ;;
esac
