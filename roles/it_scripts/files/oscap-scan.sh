#!/usr/bin/env bash
# it-oscap -- run the OpenSCAP DISA-STIG evaluation and drop the results in the
# IA collection point. Run by hand any time, and on a schedule by the
# oscap-scan.timer / cron.d entry the scap_scan role installs.
#
# Usage:  sudo it-oscap [--dir DIR] [--profile PROFILE] [--keep N] [--content FILE]
#   --dir      output dir (default /opt/ia/oscap)
#   --profile  XCCDF profile id (default: the SSG STIG profile, or the sole
#              profile in --content when that datastream has exactly one)
#   --keep     how many result SETS to retain (default 12; 0 = keep everything)
#   --content  SCAP datastream to evaluate against (default: the ComplianceAsCode
#              SSG content the scap_scan role stages)
#
# WHICH CONTENT: the default SSG datastream automates MORE rules, but its rule
# ids are SSG ids, so building a checklist means mapping them onto DISA's V-IDs.
# DISA publishes its OWN SCAP benchmark for this STIG, whose ids match the manual
# STIG exactly -- feed that in with --content and `it-ckl` maps 1:1 instead of by
# inference:
#   sudo it-oscap --content /opt/ia/stig/U_CAN_Ubuntu_24-04_LTS_STIG_V1R5_STIG_SCAP_1-3_Benchmark.xml
# Note DISA ships the SCAP benchmark a release behind the manual STIG at times;
# rules the older benchmark does not contain simply stay Not_Reviewed.
#
# Produces three files per run, timestamped:
#   stig-report-<ts>.html   human-readable
#   stig-arf-<ts>.xml       full ARF results
#   stig-viewer-<ts>.xml    importable into DISA STIG Viewer
# Exit: 0 = all rules passed, 2 = some rules failed (still a successful scan),
# anything else = the scan itself failed.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

DIR="/opt/ia/oscap"
PROFILE="xccdf_org.ssgproject.content_profile_stig"
KEEP=12
DS_ARG=""
PROFILE_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)     DIR="${2:?}"; shift 2 ;;
    --profile) PROFILE="${2:?}"; PROFILE_SET=1; shift 2 ;;
    --keep)    KEEP="${2:?}"; shift 2 ;;
    --content) DS_ARG="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v oscap >/dev/null 2>&1 || { echo "oscap not installed (apt install openscap-scanner)" >&2; exit 1; }

# Locate the datastream: an explicit --content wins, else the one scap_scan staged.
DS=""
if [ -n "$DS_ARG" ]; then
  [ -f "$DS_ARG" ] || { echo "no such content file: $DS_ARG" >&2; exit 1; }
  DS="$DS_ARG"
else
  for c in /usr/share/xml/scap/ssg/content/ssg-ubuntu24*-ds*.xml \
           /usr/local/share/scap/ssg-ubuntu24*-ds*.xml; do
    [ -f "$c" ] && DS="$c" && break
  done
fi
[ -n "$DS" ] || { echo "no Ubuntu 24.04 SCAP datastream found -- run the scap_scan role" >&2; exit 1; }

# The default profile id is SSG's. Any other datastream (DISA's benchmark, for
# one) uses different ids, so a stale default would fail with an unhelpful
# error. Resolve it against the content actually being evaluated.
avail=$(oscap info "$DS" 2>/dev/null | sed -n 's/^[[:space:]]*Id:[[:space:]]*\(xccdf_[^[:space:]]*profile[^[:space:]]*\)$/\1/p')
if [ -n "$avail" ] && ! printf '%s\n' "$avail" | grep -qx -- "$PROFILE"; then
  if [ "$PROFILE_SET" = 1 ]; then
    echo "profile '$PROFILE' is not in $DS. Available:" >&2
    printf '  %s\n' $avail >&2
    exit 1
  fi
  n=$(printf '%s\n' $avail | wc -l)
  if [ "$n" = 1 ]; then
    PROFILE="$avail"
    echo "Using the only profile in this content: $PROFILE"
  else
    echo "This content does not carry the default SSG profile. Pick one with --profile:" >&2
    printf '  %s\n' $avail >&2
    exit 1
  fi
fi
echo "Content : $DS"
echo "Profile : $PROFILE"

mkdir -p "$DIR" && chmod 0750 "$DIR"
TS="$(date +%Y%m%d-%H%M%S)"

# --fetch-remote-resources is deliberately NOT used: these boxes are air-gapped
# or heading there, and it would stall the scan waiting on a network fetch.
oscap xccdf eval \
  --profile "$PROFILE" \
  --results-arf "$DIR/stig-arf-$TS.xml" \
  --report      "$DIR/stig-report-$TS.html" \
  --stig-viewer "$DIR/stig-viewer-$TS.xml" \
  "$DS"
rc=$?

chmod 0640 "$DIR"/stig-*-"$TS".* 2>/dev/null || true

# Retention: keep the newest N of each result type.
if [ "$KEEP" -gt 0 ] 2>/dev/null; then
  for kind in stig-report stig-arf stig-viewer; do
    ls -1t "$DIR/$kind-"* 2>/dev/null | tail -n +$((KEEP+1)) | while read -r old; do rm -f "$old"; done
  done
fi

case "$rc" in
  0) echo "SCAN OK  -- all rules passed.  $DIR/stig-report-$TS.html" ;;
  2) echo "SCAN OK  -- some rules FAILED (expected; review the report).  $DIR/stig-report-$TS.html" ;;
  *) echo "SCAN ERROR (oscap rc=$rc)" >&2 ;;
esac
# 0 and 2 both mean the scan ran; only other codes are a real failure.
[ "$rc" = 0 ] || [ "$rc" = 2 ] && exit 0
exit "$rc"
