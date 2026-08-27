#!/usr/bin/env bash
# it-checklist -- run the org Linux checklist against THIS box and print a
# pass/fail line per item. Companion to docs/compliance.md (same numbering).
#
# Usage: it-checklist [--fail-only] [--out FILE]
# Exit:  0 = no FAILs, 1 = at least one FAIL.
#
# MAN = human/hardware step, N/A = not used in this environment. Neither counts
# as a failure. This is a quick indicator, NOT a substitute for `usg audit`.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

FAIL_ONLY=0; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fail-only) FAIL_ONLY=1; shift ;;
    --out) OUT="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$OUT" ] && exec > >(tee "$OUT")

P=0; F=0; N=0; M=0
have(){ command -v "$1" >/dev/null 2>&1; }
active(){ systemctl is-active --quiet "$1" 2>/dev/null; }
row(){ # $1=status $2=id $3=name $4=detail
  case "$1" in PASS) P=$((P+1));; FAIL) F=$((F+1));; "N/A") N=$((N+1));; MAN) M=$((M+1));; esac
  [ "$FAIL_ONLY" = 1 ] && [ "$1" != FAIL ] && return 0
  printf '[%-4s] %-2s %-28s %s\n' "$1" "$2" "$3" "$4"
}
yn(){ [ "$1" = 0 ] && echo PASS || echo FAIL; }

# Which profile this box was built as. it_scripts writes it; fall back to
# inferring from the EMI-only tooling if an older box has no marker yet.
PROFILE=""
if [ -r /etc/stig-build/profile ]; then
  PROFILE=$(awk -F= '/^deployment_profile=/{print $2; exit}' /etc/stig-build/profile)
fi
[ -z "$PROFILE" ] && have it-vulnscan && PROFILE=emi
is_emi(){ case "$PROFILE" in emi|emi-unclass) return 0 ;; *) return 1 ;; esac; }

REV=""
[ -r /etc/stig-build/profile ] && REV=$(awk -F= '/^baseline_revision=/{print $2; exit}' /etc/stig-build/profile)
echo "Linux checklist -- $(hostname) -- $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "baseline ${REV:-unknown}${PROFILE:+  profile $PROFILE}"
echo

# 1 AD/SSSD -- this fleet uses local accounts by design (documented deviation)
row "N/A" 1 "AD integration (SSSD)" "local accounts by design; SSSD STIG rules de-selected"

# 2 no root over SSH -- the ROOT ACCOUNT specifically. This does not restrict
# an admin from logging in as themselves and elevating with sudo, which is the
# required path (and is what makes the audit trail attributable).
v=$(sshd -T 2>/dev/null | awk '/^permitrootlogin/{print $2}')
rk=0; [ -r /root/.ssh/authorized_keys ] && rk=$(wc -l < /root/.ssh/authorized_keys)
if [ "$v" = no ]; then
  if [ "${rk:-0}" -gt 0 ] 2>/dev/null; then
    row PASS 2 "No root SSH login" "PermitRootLogin no (note: /root/.ssh/authorized_keys has $rk key(s), inert while this holds)"
  else
    row PASS 2 "No root SSH login" "PermitRootLogin no; admins log in as themselves and sudo"
  fi
else
  row FAIL 2 "No root SSH login" "PermitRootLogin=${v:-unknown} -- must be no"
fi

# 3 banners + last login
b=$(sshd -T 2>/dev/null | awk '/^banner/{print $2}')
l=$(sshd -T 2>/dev/null | awk '/^printlastlog/{print $2}')
if [ -s /etc/issue.net ] && [ "$b" != none ] && [ -n "$b" ]; then
  row PASS 3 "Banners + last login" "banner=$b printlastlog=${l:-?}"
else row FAIL 3 "Banners + last login" "issue.net or sshd Banner missing (banner=${b:-none})"; fi

# 4 anti-virus: does it actually DETECT, plus signature freshness.
# NOT "is clamav-daemon running" -- on a FIPS box that daemon runs happily and
# detects nothing (clamav#1786), and where the containerised engine took over it
# is masked on purpose. it-clamav test settles it either way.
if have it-clamav; then
  dbdir=/var/lib/clamav
  [ -d /var/lib/clamav-container ] && [ -r /etc/clamav/clamd-container.conf ] \
    && dbdir=/var/lib/clamav-container
  d=$(find "$dbdir" -name '*.c[vl]d' -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
  age=$([ -n "$d" ] && echo $(( ( $(date +%s) - ${d%.*} ) / 86400 )) || echo "?")
  if ! it-clamav test >/dev/null 2>&1; then
    row FAIL 4 "Anti-virus" "engine does NOT detect the EICAR test file -- a clean scan means nothing"
  elif [ "$age" != "?" ] && [ "$age" -le 30 ] 2>/dev/null; then
    row PASS 4 "Anti-virus" "detects; signatures ${age}d old"
  else
    row FAIL 4 "Anti-virus" "detects, but signatures ${age}d old (>30d / unknown) -- it-clamav install"
  fi
else row FAIL 4 "Anti-virus" "it-clamav not installed"; fi

# 5 password policy -- USG owns this; report the evidence source
[ -f /etc/security/pwquality.conf ] && [ -f /etc/security/faillock.conf ] \
  && row PASS 5 "Password policy" "pwquality+faillock present (authoritative: usg audit)" \
  || row FAIL 5 "Password policy" "pwquality/faillock config missing"

# 6 auditd -- rules LOADED IN THE KERNEL, compared against what is on disk.
# "more than zero" is not a STIG audit posture: USG writes ~90 rules across
# /etc/audit/rules.d, and a box showing a handful loaded has rules that never
# reached the kernel. That happens for a specific, easy-to-miss reason: the
# STIG sets `-e 2` (immutable), after which the kernel REFUSES new rules until
# a reboot -- so a pull that adds audit rules leaves them on disk and inert,
# and every file-based OVAL still passes. Compare the two numbers.
if active auditd; then
  loaded=$(auditctl -l 2>/dev/null | grep -cvE '^(No rules|)$' || true); loaded=${loaded:-0}
  ondisk=$(cat /etc/audit/rules.d/*.rules 2>/dev/null \
             | grep -cvE '^\s*(#|$)' || true); ondisk=${ondisk:-0}
  imm=$(auditctl -s 2>/dev/null | awk '/^enabled/{print $2}')
  immnote=""
  [ "$imm" = 2 ] && immnote=" (immutable: -e 2, needs a REBOOT to load)"
  if [ "$loaded" -eq 0 ]; then
    row FAIL 6 "Audit rules" "auditd active but NO rules loaded; $ondisk on disk$immnote"
  elif [ "$ondisk" -gt 0 ] && [ "$loaded" -lt $(( ondisk / 2 )) ]; then
    row FAIL 6 "Audit rules" "only $loaded of $ondisk rules reached the kernel$immnote -- run: augenrules --load, or reboot"
  elif [ "$loaded" -lt 20 ]; then
    row FAIL 6 "Audit rules" "$loaded rules loaded -- far below a STIG ruleset ($ondisk on disk)$immnote"
  else
    row PASS 6 "Audit rules" "auditd active, $loaded rules loaded of $ondisk on disk"
  fi
else row FAIL 6 "Audit rules" "auditd not active"; fi

# 7 BIOS. Two of the three parts ARE machine-readable:
#   Secure Boot  -- mokutil, or the EFI variable directly
#   Admin password -- the vendor firmware-attributes driver (dell-wmi-sysman,
#                  think-lmi, hp-wmi-sysman) exposes authentication/Admin/is_enabled.
# The rest of "BIOS hardened" (boot order, disabled ports/radios) is not, so a
# box where the password cannot be read stays MANUAL rather than being called
# passing on half the evidence.
sb=unknown
if have mokutil; then
  case "$(mokutil --sb-state 2>/dev/null)" in
    *"enabled"*)  sb=enabled ;;
    *"disabled"*) sb=disabled ;;
  esac
fi
if [ "$sb" = unknown ] && [ -d /sys/firmware/efi ]; then
  # Last byte of the SecureBoot EFI variable: 1 = on. The first 4 bytes are the
  # variable's attributes, which is why this reads the tail and not the head.
  e=$(find /sys/firmware/efi/efivars -maxdepth 1 -name 'SecureBoot-*' 2>/dev/null | head -1)
  if [ -n "$e" ]; then
    b=$(od -An -tu1 -j4 -N1 "$e" 2>/dev/null | tr -d ' ')
    [ "$b" = 1 ] && sb=enabled
    [ "$b" = 0 ] && sb=disabled
  fi
fi

bp=unknown; bpsrc=""
for a in /sys/class/firmware-attributes/*/authentication/Admin/is_enabled; do
  [ -r "$a" ] || continue
  bpsrc=$(basename "$(dirname "$(dirname "$(dirname "$a")")")")
  case "$(cat "$a" 2>/dev/null)" in
    1) bp=set ;;
    0) bp=unset ;;
  esac
  break
done

if [ "$sb" = disabled ]; then
  row FAIL 7 "BIOS hardened + password" "Secure Boot DISABLED; admin password ${bp}${bpsrc:+ ($bpsrc)}"
elif [ "$bp" = unset ]; then
  row FAIL 7 "BIOS hardened + password" "no BIOS admin password set ($bpsrc); Secure Boot $sb"
elif [ "$sb" = enabled ] && [ "$bp" = set ]; then
  row MAN 7 "BIOS hardened + password" "Secure Boot on, admin password set ($bpsrc) -- boot order/ports still manual"
else
  row MAN 7 "BIOS hardened + password" "Secure Boot $sb, admin password $bp -- verify at POST"
fi

# 8 vendor supported release
row PASS 8 "Vendor supported release" "$(lsb_release -ds 2>/dev/null || echo Ubuntu) $(pro status --format=json 2>/dev/null | grep -o '\"attached\": *[a-z]*' | head -1)"

# 9 FIPS (OS) + 10 DARE
f=$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo 0)
[ "$f" = 1 ] && row PASS 9 "FIPS crypto (OS)" "fips_enabled=1" \
             || row FAIL 9 "FIPS crypto (OS)" "fips_enabled=$f (reboot after enabling?)"
if lsblk -o TYPE 2>/dev/null | grep -q crypt; then
  c=$(lsblk -o NAME,TYPE 2>/dev/null | awk '$2=="crypt"{print $1; exit}')
  row PASS 10 "DARE (disk encryption)" "LUKS active ($c)"
else row FAIL 10 "DARE (disk encryption)" "no crypt device found"; fi

# 11 GRUB password -- credential AND every entry --unrestricted
G=/boot/grub/grub.cfg
if grep -q '^\s*password_pbkdf2' "$G" 2>/dev/null && grep -q '^\s*set superusers=' "$G" 2>/dev/null; then
  t=$(grep -cE '^\s*menuentry ' "$G" 2>/dev/null || true); t=${t:-0}
  r=$(grep -E '^\s*menuentry ' "$G" 2>/dev/null | grep -cv -- '--unrestricted' || true); r=${r:-0}
  [ "$r" -eq 0 ] && row PASS 11 "GRUB2 password" "set, all $t entries --unrestricted" \
                 || row FAIL 11 "GRUB2 password" "set BUT $r/$t entries restricted -> every boot prompts"
else row FAIL 11 "GRUB2 password" "not configured (see: it-grub status)"; fi

# 12 MAC -- Ubuntu uses AppArmor, not SELinux
if have aa-status && aa-status --enabled 2>/dev/null; then
  row PASS 12 "MAC (AppArmor)" "enabled, $(aa-status 2>/dev/null | awk '/profiles are in enforce/{print $1}') enforcing (SELinux N/A on Ubuntu)"
else row FAIL 12 "MAC (AppArmor)" "AppArmor not enabled"; fi

# 13 local accounts inventory (informational -- always PASS, prints the list)
u=$(awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd | paste -sd, -)
row PASS 13 "Local accounts" "${u:-none}"

# 14 CUPS must not run
if active cups || active cups-browsed; then
  row FAIL 14 "CUPS disabled" "cups/cups-browsed is running"
else row PASS 14 "CUPS disabled" "not active"; fi

# 15 filesystems / partitions -- N/A. XFS and the separate-mount list are the
# org checklist's RHEL heritage, not an Ubuntu STIG requirement. Still print
# what this box actually has, because an assessor will ask.
fs=$(findmnt -no FSTYPE / 2>/dev/null)
sep=""
for m in /var /var/log /var/log/audit /home /tmp; do
  findmnt -no TARGET "$m" >/dev/null 2>&1 && sep="$sep $m"
done
row "N/A" 15 "Filesystems / partitions" "org (RHEL-derived), not an Ubuntu STIG rule; root=$fs, separate:${sep:- none}"

# 16 port/process capture
i=$(ls -1t /opt/it/inventory-*.txt 2>/dev/null | head -1)
[ -n "$i" ] && grep -q "Listening ports" "$i" 2>/dev/null \
  && row PASS 16 "Port/process capture" "$(basename "$i") ($(date -r "$i" +%Y-%m-%d))" \
  || row FAIL 16 "Port/process capture" "no inventory with a ports section -- run: it-inventory"

# 17 time sync
if active chrony || active chronyd; then
  row PASS 17 "Chrony/NTP" "$(chronyc -n sources 2>/dev/null | tail -n +3 | wc -l) source(s)"
else row FAIL 17 "Chrony/NTP" "chrony not active"; fi

# 18 USBGuard
if active usbguard; then
  n=$(grep -cvE '^\s*(#|$)' /etc/usbguard/rules.conf 2>/dev/null || true); n=${n:-0}
  row PASS 18 "USBGuard" "active, $n allow-rules (manage: it-usb)"
else row FAIL 18 "USBGuard" "not active"; fi

row "N/A" 19 "Solarwinds" "not used in this environment"

# 20 firewall -- org checklist says DISABLED; this build enables ufw. Flag the conflict.
if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
  row MAN 20 "Local firewall" "ufw ACTIVE -- org checklist asks for disabled; confirm intent"
else row PASS 20 "Local firewall" "ufw not active (matches checklist)"; fi

row "N/A" 21 "Splunk agent" "not used in this environment"
row MAN 22 "DNS records (COMPASS)" "org infrastructure -- verify externally"

# 23 backup -- two different answers by profile.
#   EMI: standalone and air-gapped, so there is no file server to push to.
#        Backup is a manual offline SSD duplication, and it is logged ON PAPER.
#        Nothing on the box can see it; MANUAL is the honest answer, not a
#        check pretending to have evidence.
#   everything else: nothing kept locally, the file servers are backed up.
if is_emi; then
  row MAN 23 "Backup + restore" "manual SSD duplication, logged on paper -- verify against the paper record"
else
  row "N/A" 23 "Backup + restore" "org: file servers backed up; endpoints hold no primary data by policy"
fi

# 24 scheduled OSCAP
if systemctl list-timers 2>/dev/null | grep -q oscap-scan; then
  row PASS 24 "Scheduled OSCAP job" "oscap-scan.timer active"
elif [ -f /etc/cron.d/oscap-scan ]; then
  row PASS 24 "Scheduled OSCAP job" "/etc/cron.d/oscap-scan"
else row FAIL 24 "Scheduled OSCAP job" "no timer or cron entry"; fi

row MAN 25 "iDRAC / OME" "server hardware -- verify out-of-band"

# 26 latest scan result. Search the tree, not the top level: it-oscap writes
# into build/ scheduled/ manual/ (one directory per writer), so a glob rooted at
# /opt/ia/oscap matches nothing and this always reported FAIL.
l=$(find /opt/ia/oscap -name 'stig-report-*.html' -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | head -1 | cut -d' ' -f2-)
if [ -n "$l" ]; then
  d=$(( ( $(date +%s) - $(stat -c %Y "$l") ) / 86400 ))
  [ "$d" -le 45 ] && row PASS 26 "Recent compliance scan" "$(basename "$l") (${d}d ago)" \
                  || row FAIL 26 "Recent compliance scan" "newest is ${d}d old -- run: it-oscap"
else
  row FAIL 26 "Recent compliance scan" "no report under /opt/ia/oscap -- run: it-oscap"
fi

# 27 STIG content version
d=$(ls -1 /usr/share/xml/scap/ssg/content/ssg-ubuntu24*-ds*.xml 2>/dev/null | head -1)
uv=$(dpkg-query -W -f='${Version}' usg 2>/dev/null || echo n/a)
if [ -n "$d" ]; then row PASS 27 "STIG content present" "usg=$uv ssg=$(basename "$d")"
else row FAIL 27 "STIG content present" "usg=$uv, no SSG datastream -- run the scap_scan role"; fi

# 28 nmap vulnerability scan -- the org's MUSA_Vuln_Scan process. Only the EMI
# boxes carry it (nmap is installed there and it-vulnscan is placed there).
if have it-vulnscan; then
  v=$(find /opt/ia/vulnscans -name '*-vuln-scan-*.txt' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-)
  if [ -n "$v" ]; then
    d=$(( ( $(date +%s) - $(stat -c %Y "$v") ) / 86400 ))
    h=$(grep -cE '^\|.*(VULNERABLE|CVE-[0-9]{4}-[0-9]+)' "$v" 2>/dev/null || true); h=${h:-0}
    # A scanner that did not run must never read as a clean result. it-vulnscan
    # stamps NMAP-FAULT / ENGINE-FAULT into the report when that happens.
    if grep -qE 'NMAP-FAULT|ENGINE-FAULT|Anti-virus +: +(ERROR|INFECTED)' "$v" 2>/dev/null; then
      row FAIL 28 "nmap vulnerability scan" "$(basename "$v") (${d}d ago) -- a scanner FAULTED; the report is not evidence"
    elif [ "$h" -gt 0 ]; then
      row FAIL 28 "nmap vulnerability scan" "$(basename "$v") (${d}d ago) -- $h finding(s) to review"
    elif [ "$d" -le 45 ]; then
      row PASS 28 "nmap vulnerability scan" "$(basename "$v") (${d}d ago), nothing flagged"
    else
      row FAIL 28 "nmap vulnerability scan" "newest is ${d}d old -- run: it-vulnscan"
    fi
  else
    row FAIL 28 "nmap vulnerability scan" "never run -- run: it-vulnscan"
  fi
fi

echo
printf 'PASS=%d  FAIL=%d  N/A=%d  MANUAL=%d\n' "$P" "$F" "$N" "$M"
echo 'Authoritative evidence is `usg audit disa_stig` / it-oscap, not this script.'
[ "$F" -eq 0 ]
