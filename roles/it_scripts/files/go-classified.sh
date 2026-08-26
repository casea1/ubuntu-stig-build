#!/usr/bin/env bash
# it-goclassified -- the pre-classification gate for a box about to hold
# classified data. Everything that can be checked from the OS is checked;
# everything that cannot (firmware, physical, "did you actually rotate it")
# is put to the operator as an attestation and recorded with their name.
#
# The record lands in /opt/ia/goclassified/ and is the artefact you hand the
# ISSM. It is not a substitute for the SSP -- it is evidence the steps were
# done on THIS box, on a date, by a named person.
#
# Usage:
#   it-goclassified            walk the gate, prompting for attestations
#   it-goclassified --report   machine checks only, no prompts, nothing written
#   it-goclassified --out FILE also write the record here
# Exit: 0 = ready, 1 = something failed or was not attested.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

RECORD_DIR=/opt/ia/goclassified
REPORT_ONLY=0; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --report) REPORT_ONLY=1; shift ;;
    --out) OUT="${2:?}"; shift 2 ;;
    -h|--help) awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then
  B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'
else B=""; DIM=""; R=""; RED=""; GRN=""; YEL=""; CYN=""; fi

P=0; F=0; A=0; U=0        # pass / fail / attested / unattested
LINES=()

have(){ command -v "$1" >/dev/null 2>&1; }
active(){ systemctl is-active --quiet "$1" 2>/dev/null; }

# Install date, used to spot secrets that have never been changed since imaging.
INSTALL_DATE=$(date -r /etc/machine-id '+%Y-%m-%d' 2>/dev/null || echo "unknown")

row(){ # status  id  name  detail
  local st="$1" id="$2" name="$3" detail="$4" col=""
  case "$st" in
    PASS)   P=$((P+1)); col="$GRN" ;;
    FAIL)   F=$((F+1)); col="$RED" ;;
    ATTEST) A=$((A+1)); col="$CYN" ;;
    OPEN)   U=$((U+1)); col="$YEL" ;;
  esac
  printf '%s[%-6s]%s %-3s %-34s %s\n' "$col" "$st" "$R" "$id" "$name" "$detail"
  LINES+=("[$st] $id $name -- $detail")
}

# A step the OS cannot verify. Records the answer against the operator's name;
# "no" is an OPEN item, not a silent pass.
ask(){ # id  name  question  [context]
  local id="$1" name="$2" q="$3" ctx="${4:-}" a
  if [ "$REPORT_ONLY" = 1 ]; then
    row OPEN "$id" "$name" "needs attestation${ctx:+ -- $ctx}"
    return
  fi
  [ -n "$ctx" ] && printf '       %s%s%s\n' "$DIM" "$ctx" "$R"
  while true; do
    read -r -p "       $q [y/N/s=skip] " a </dev/tty || a=n
    case "${a,,}" in
      y|yes) row ATTEST "$id" "$name" "attested by $OPERATOR on $(date '+%Y-%m-%d %H:%M %Z')"; return ;;
      n|no|"") row OPEN "$id" "$name" "NOT done / not confirmed"; return ;;
      s|skip) row OPEN "$id" "$name" "skipped -- still outstanding"; return ;;
    esac
  done
}

sec(){ printf '\n%s%s%s\n' "$B" "$*" "$R"; LINES+=("" "== $* =="); }

# ---------------------------------------------------------------------------
echo "${B}GO-CLASSIFIED GATE -- $(hostname)${R}"
echo "${DIM}$(date '+%Y-%m-%d %H:%M:%S %Z')   imaged $INSTALL_DATE${R}"
OPERATOR="(report only)"
if [ "$REPORT_ONLY" = 0 ]; then
  read -r -p "Your name (goes in the record): " OPERATOR </dev/tty || exit 1
  [ -n "$OPERATOR" ] || { echo "A name is required." >&2; exit 1; }
fi

# --- Firmware and physical -------------------------------------------------
sec "1. Firmware and physical"

if have mokutil; then
  sb=$(mokutil --sb-state 2>/dev/null | head -1)
  case "$sb" in
    *enabled*) row PASS 1.1 "Secure Boot" "$sb" ;;
    *) row FAIL 1.1 "Secure Boot" "${sb:-could not read state}" ;;
  esac
else row OPEN 1.1 "Secure Boot" "mokutil not installed"; fi

[ -e /sys/class/tpm/tpm0 ] \
  && row PASS 1.2 "TPM present" "$(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null | sed 's/^/TPM /')" \
  || row FAIL 1.2 "TPM present" "no /sys/class/tpm/tpm0"

ask 1.3 "BIOS/UEFI admin password" "Is a BIOS/UEFI admin password set on this box?" \
    "Cannot be read from the OS. Without it the boot order and Secure Boot can be changed by anyone with the lid open."
ask 1.4 "Boot order locked" "Are USB and network boot disabled, and the boot order locked in firmware?" \
    "The GRUB password does not help if the box will boot someone else's USB first."

# --- Boot chain ------------------------------------------------------------
sec "2. Boot chain"

fips=$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo 0)
[ "$fips" = 1 ] && row PASS 2.1 "FIPS mode" "fips_enabled=1" \
                || row FAIL 2.1 "FIPS mode" "fips_enabled=$fips (classified profile expects 1)"

if grep -q '^password_pbkdf2' /boot/grub/grub.cfg 2>/dev/null; then
  entries=$(grep -c '^menuentry\|^\s*menuentry' /boot/grub/grub.cfg 2>/dev/null || echo 0)
  unrest=$(grep -c 'menuentry.*--unrestricted' /boot/grub/grub.cfg 2>/dev/null || echo 0)
  if [ "$entries" -gt 0 ] && [ "$entries" = "$unrest" ]; then
    row PASS 2.2 "GRUB password" "set; all $entries entries --unrestricted (boot free, edit locked)"
  else
    row FAIL 2.2 "GRUB password" "set, but $((entries - unrest)) of $entries entries are restricted -- run it-grub status"
  fi
else row FAIL 2.2 "GRUB password" "no password_pbkdf2 in grub.cfg -- run it-grub set"; fi

root_src=$(findmnt -no SOURCE / 2>/dev/null)
if lsblk -no TYPE "$root_src" 2>/dev/null | grep -q crypt \
   || cryptsetup status "$(basename "$root_src")" >/dev/null 2>&1 \
   || lsblk 2>/dev/null | grep -q crypt; then
  row PASS 2.3 "Root filesystem encrypted" "LUKS in the stack under $root_src"
else row FAIL 2.3 "Root filesystem encrypted" "no LUKS device found under $root_src"; fi

luksdev=$(lsblk -rno NAME,TYPE 2>/dev/null | awk '$2=="part"{print "/dev/"$1}' \
          | while read -r d; do cryptsetup isLuks "$d" 2>/dev/null && { echo "$d"; break; }; done)
slots=""
[ -n "$luksdev" ] && slots=$(cryptsetup luksDump "$luksdev" 2>/dev/null | grep -c '^\s*[0-9]*: luks2\|^Key Slot [0-9]*: ENABLED')
ask 2.4 "LUKS passphrase rotated" "Has the LUKS passphrase been changed from the one used at imaging?" \
    "Cannot be verified -- a passphrase leaves no trace of when it changed.${luksdev:+ Device $luksdev, ${slots:-?} keyslot(s) in use.}"

if have clevis && clevis luks list -d "${luksdev:-/dev/null}" >/dev/null 2>&1; then
  row PASS 2.5 "TPM auto-unlock bound" "$(clevis luks list -d "$luksdev" 2>/dev/null | head -1)"
else row OPEN 2.5 "TPM auto-unlock bound" "no clevis binding found -- run it-luks"; fi

ask 2.6 "TPM re-sealed after firmware changes" "If the BIOS/firmware was changed today, was the TPM binding re-sealed (it-luks-rebind)?" \
    "PCR 7 changes with Secure Boot state. A stale binding means the box falls back to the passphrase prompt."

# --- Accounts and secrets --------------------------------------------------
sec "3. Accounts and secrets"

stale=""; checked=0
while IFS=: read -r u _ uid _ _ _ sh; do
  [ "$uid" -ge 1000 ] 2>/dev/null || continue
  case "$sh" in */nologin|*/false) continue ;; esac
  checked=$((checked+1))
  lc=$(chage -l "$u" 2>/dev/null | awk -F': ' '/Last password change/{print $2}')
  [ -z "$lc" ] && continue
  d=$(date -d "$lc" '+%Y-%m-%d' 2>/dev/null) || continue
  [ "$d" = "$INSTALL_DATE" ] && stale="$stale $u"
done < /etc/passwd
if [ -n "$stale" ]; then
  row FAIL 3.1 "Interactive passwords changed" "still on the imaging-day password:$stale"
else
  row PASS 3.1 "Interactive passwords changed" "$checked interactive account(s), none dated $INSTALL_DATE"
fi

leftover=""
for u in vagrant ubuntu packer; do id "$u" >/dev/null 2>&1 && leftover="$leftover $u"; done
[ -z "$leftover" ] && row PASS 3.2 "Base-image accounts purged" "none of vagrant/ubuntu/packer present" \
                   || row FAIL 3.2 "Base-image accounts purged" "still present:$leftover"

pw_stale=$(find /etc/stig-build -name '*.pw' -newermt "$INSTALL_DATE" 2>/dev/null | wc -l)
pw_total=$(find /etc/stig-build -name '*.pw' 2>/dev/null | wc -l)
if [ "$pw_total" = 0 ]; then
  row OPEN 3.3 "Generated service secrets" "no /etc/stig-build/*.pw on this box"
elif [ "$pw_stale" -gt 0 ]; then
  row PASS 3.3 "Generated service secrets" "$pw_stale of $pw_total regenerated since imaging"
else
  row OPEN 3.3 "Generated service secrets" "all $pw_total date from imaging -- rotate if the image was ever shared"
fi

# --- Radios and peripherals ------------------------------------------------
sec "4. Radios and peripherals"

if have rfkill; then
  unblocked=$(rfkill list 2>/dev/null | grep -c 'Soft blocked: no')
  [ "$unblocked" = 0 ] && row PASS 4.1 "Radios disabled" "no unblocked wireless/bluetooth device" \
                       || row FAIL 4.1 "Radios disabled" "$unblocked radio(s) not blocked -- rfkill list"
else row OPEN 4.1 "Radios disabled" "rfkill not installed"; fi

blk=$(cat /etc/modprobe.d/*.conf 2>/dev/null | grep -c '^blacklist \(uvcvideo\|btusb\|bluetooth\)')
[ "$blk" -ge 1 ] && row PASS 4.2 "Camera/Bluetooth modules blacklisted" "$blk blacklist line(s) in modprobe.d" \
                 || row FAIL 4.2 "Camera/Bluetooth modules blacklisted" "no uvcvideo/btusb/bluetooth blacklist found"

if active usbguard; then
  pol=$(date -r /etc/usbguard/rules.conf '+%Y-%m-%d' 2>/dev/null || echo unknown)
  rules=$(wc -l < /etc/usbguard/rules.conf 2>/dev/null || echo 0)
  row PASS 4.3 "USBGuard active" "$rules rule(s), policy dated $pol"
  ask 4.4 "USBGuard policy matches the fielded kit" "Does the USB allow-list cover exactly the peripherals this box will have in the field?" \
      "Policy generated $pol. Peripherals added later need `it-usb enroll`; anything left in it that is not going with the box should come out."
else row FAIL 4.3 "USBGuard active" "usbguard is not running"; fi

# --- Detection and monitoring ----------------------------------------------
sec "5. Detection and monitoring"

# Deliberately runs the real detection test, not a service-is-running check:
# on a FIPS box the host engine loads every signature and detects nothing.
if have it-clamav; then
  if it-clamav test >/dev/null 2>&1; then
    row PASS 5.1 "Antivirus detects" "it-clamav test PASSED (EICAR detected)"
  else
    row FAIL 5.1 "Antivirus detects" "it-clamav test FAILED -- a clean scan from this box means nothing"
  fi
else row OPEN 5.1 "Antivirus detects" "it-clamav not installed"; fi

active auditd && row PASS 5.2 "Audit daemon" "auditd running" \
              || row FAIL 5.2 "Audit daemon" "auditd not running"

[ -x /etc/cron.weekly/audit-offload ] \
  && row PASS 5.3 "Audit log offload" "/etc/cron.weekly/audit-offload present" \
  || row OPEN 5.3 "Audit log offload" "no weekly offload job -- logs stay on the box only"

banner=$(grep -oP '^Exec=.*classification-banner\s+"?\K[^"]+' \
         /etc/xdg/autostart/classification-banner.desktop 2>/dev/null || echo "NOT SET")
ask 5.4 "Classification banner level" "Is the on-screen banner set to the level this box will actually hold?" \
    "Currently: $banner. Change with it-set-classification."

# --- Evidence and hygiene --------------------------------------------------
sec "6. Evidence and hygiene"

recent=$(find /opt/ia/oscap -name '*.xml' -o -name '*.html' 2>/dev/null \
         | head -1)
newest=$(find /opt/ia/oscap -type f \( -name '*.xml' -o -name '*.html' \) -printf '%T@ %p\n' 2>/dev/null \
         | sort -rn | head -1)
if [ -n "$newest" ]; then
  age=$(( ( $(date +%s) - ${newest%% *} ) / 86400 ))
  age=${age%%.*}
  [ "$age" -le 30 ] && row PASS 6.1 "OpenSCAP evidence" "newest result ${age}d old" \
                    || row FAIL 6.1 "OpenSCAP evidence" "newest result ${age}d old -- re-run it-oscap before hand-off"
else row FAIL 6.1 "OpenSCAP evidence" "no results under /opt/ia/oscap -- run it-stig run"; fi

ckl=$(find /opt/ia -name '*.cklb' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1)
[ -n "$ckl" ] && row PASS 6.2 "STIG checklist generated" "$(basename "${ckl#* }")" \
              || row OPEN 6.2 "STIG checklist generated" "no .cklb found -- run it-stig checklist"

inst=$(find /opt/it/installers -type f 2>/dev/null | wc -l)
[ "$inst" = 0 ] && row PASS 6.3 "Build staging cleared" "/opt/it/installers empty" \
                || row OPEN 6.3 "Build staging cleared" "$inst file(s) left in /opt/it/installers"

if active stig-build.timer || systemctl is-enabled --quiet stig-build.timer 2>/dev/null; then
  url=$(grep -ho 'https\?://[^ ]*' /etc/systemd/system/stig-build.service 2>/dev/null | head -1)
  ask 6.4 "Provisioning pull repointed" "Is the ansible-pull source reachable and appropriate for the classified network?" \
      "stig-build.timer is enabled and pulls from ${url:-an unknown URL}. On an isolated network it will fail every run; decide whether to disable it."
else row PASS 6.4 "Provisioning pull repointed" "stig-build.timer not enabled"; fi

ask 6.5 "Media and notes removed" "Have build media, notes and any written-down passwords been removed from the box and the bench?" \
    "Nothing here can check this. It is the step people skip."

# ---------------------------------------------------------------------------
printf '\n%s%s%s\n' "$B" "RESULT" "$R"
printf '  %spassed %s%s   %sattested %s%s   %sopen %s%s   %sfailed %s%s\n' \
  "$GRN" "$P" "$R" "$CYN" "$A" "$R" "$YEL" "$U" "$R" "$RED" "$F" "$R"

verdict="NOT READY"
if [ "$F" -eq 0 ] && [ "$U" -eq 0 ]; then
  verdict="READY"
  printf '  %sEvery machine check passed and every manual step is attested.%s\n' "$GRN" "$R"
else
  printf '  %s%s FAILED and %s item(s) open. This box is not ready to go classified.%s\n' \
    "$RED" "$F" "$U" "$R"
fi

if [ "$REPORT_ONLY" = 0 ]; then
  mkdir -p "$RECORD_DIR"; chmod 0750 "$RECORD_DIR"
  rec="$RECORD_DIR/$(hostname)-$(date -u +%Y%m%dT%H%M%SZ).txt"
  {
    echo "GO-CLASSIFIED RECORD"
    echo "Host      : $(hostname)"
    echo "Imaged    : $INSTALL_DATE"
    echo "Run by    : $OPERATOR"
    echo "Run at    : $(date -u '+%Y-%m-%d %H:%M:%S UTC') / $(date '+%H:%M:%S %Z')"
    echo "Verdict   : $verdict  (passed $P, attested $A, open $U, failed $F)"
    echo
    printf '%s\n' "${LINES[@]}"
  } > "$rec"
  chmod 0640 "$rec"
  printf '  %sRecord: %s%s\n' "$DIM" "$rec" "$R"
fi
echo

[ "$F" -eq 0 ] && [ "$U" -eq 0 ]
