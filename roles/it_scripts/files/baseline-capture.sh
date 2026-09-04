#!/usr/bin/env bash
# it-baseline -- capture what this box actually IS, so the repo can be checked
# against it.
#
# The question this answers is not "is the box compliant" -- it-checklist and
# it-stig do that. It is: **if this machine were rebuilt from an ansible-pull
# tomorrow, what would be missing?** Everything a person did by hand lives in
# the gap between those two, and nothing else on the box reports it.
#
# So the sections that matter most are the ones about what is NOT managed:
# manually installed packages, modified conffiles, unit files and /usr/local
# entries the baseline never wrote, hand-edited sysctl/udev/modprobe drop-ins.
#
#   it-baseline               write the capture, print a summary
#   it-baseline --stdout      write it to standard output instead of a file
#   it-baseline --brief       skip the long inventories (packages, files)
#
# READ-ONLY. It runs no fix, starts nothing, changes nothing.
#
# SECRETS ARE NEVER INCLUDED. Credential files, *.pw, *.cred, .env, keytabs and
# tokens are listed by NAME, MODE and SIZE only -- never contents. The capture
# is meant to be sent to someone off the box, so that rule is absolute.
set -uo pipefail

OUT_DIR="${IT_BASELINE_DIR:-/opt/it}"
HOST="$(hostname -s 2>/dev/null || hostname)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$OUT_DIR/baseline-$HOST-$STAMP.txt"
BRIEF=0
TO_STDOUT=0

for a in "$@"; do
  case "$a" in
    --stdout) TO_STDOUT=1 ;;
    --brief)  BRIEF=1 ;;
    -h|--help|help)
      awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$a" >&2; exit 1 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

# --------------------------------------------------------------------------
# helpers. Every section is bounded: a capture nobody can read gets skimmed,
# and the thing that mattered is in the part that was skimmed.
# --------------------------------------------------------------------------
sec()  { printf '\n\n===== %s =====\n' "$*"; }
sub()  { printf '\n--- %s\n' "$*"; }
run()  { printf '$ %s\n' "$*"; eval "$@" 2>&1 | head -"${LIMIT:-60}"; }
note() { printf '%s\n' "$*"; }

# A file's shape, never its contents. Used for anything that might hold a
# secret -- the whole capture is meant to leave the box.
shape() {
  local f
  for f in "$@"; do
    [ -e "$f" ] || continue
    printf '  %-52s %s %s %s bytes\n' "$f" \
      "$(stat -c '%a' "$f")" "$(stat -c '%U:%G' "$f")" "$(stat -c '%s' "$f")"
  done
}

capture() {

printf 'it-baseline  %s  %s\n' "$HOST" "$(date -Is)"
printf 'Read-only capture. Secrets are listed by name and mode only.\n'

# ---------------------------------------------------------------------------
sec "IDENTITY AND BASELINE"
run "cat /etc/os-release | head -3"
run "uname -r"
printf '$ fips_enabled\n%s\n' "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo 'n/a')"
run "cat /etc/stig-build/profile 2>/dev/null || echo '(no profile file)'"
sub "the baseline this box is running"
LIMIT=25 run "it-pull status 2>&1"
sub "persisted site.yml (this is repo INPUT -- differences here are intentional config)"
LIMIT=80 run "cat /opt/it/site.yml 2>/dev/null || echo '(none)'"

# ---------------------------------------------------------------------------
sec "SUBSCRIPTION AND HARDENING STATE"
LIMIT=30 run "pro status 2>&1"
sub "USG"
run "usg version 2>&1 || echo '(usg not installed)'"
LIMIT=20 run "ls -lt /opt/ia/*.html /opt/ia/*.xml 2>/dev/null | head -8 || echo '(no USG/oscap reports)'"

# ---------------------------------------------------------------------------
# The single most common silent failure on this fleet: one bad rule name and
# auditctl stops, leaving 1 of 68 loaded while every file-based check passes.
sec "AUDIT RULES (the fleet-wide gap)"
printf '$ auditctl -l | wc -l\n%s\n' "$(auditctl -l 2>/dev/null | wc -l)"
printf '$ auditctl -s | grep -E "^enabled"\n%s\n' "$(auditctl -s 2>/dev/null | grep -E '^enabled' || echo '?')"
LIMIT=15 run "augenrules --check 2>&1 || true"
sub "why a load failed, if it did -- from the journal, NOT by re-running it"
# `augenrules --load` would answer this directly and it CHANGES STATE: it
# applies rules to a running box. This command promises read-only, so the same
# information comes from what the last load already recorded.
LIMIT=15 run "journalctl -b -u auditd --no-pager 2>/dev/null | grep -iE 'unknown|error in line|syscall name' | tail -8 || echo '(nothing logged)'"
shape /var/log/sudo.log

# ---------------------------------------------------------------------------
sec "ACCOUNTS, GROUPS, SUDO"
LIMIT=40 run "it-users --all 2>/dev/null || getent passwd | awk -F: '\$3>=1000 && \$3<65000'"
sub "group membership that matters"
for g in sudo sentry audit dta dialout plugdev; do
  printf '  %-10s %s\n' "$g" "$(getent group "$g" | cut -d: -f4)"
done
sub "sudoers drop-ins (names only)"
LIMIT=30 run "ls -l /etc/sudoers.d/ 2>/dev/null"

# ---------------------------------------------------------------------------
sec "PASSWORD AND LOCKOUT POLICY"
LIMIT=30 run "grep -vE '^\s*(#|$)' /etc/security/pwquality.conf 2>/dev/null"
LIMIT=20 run "grep -vE '^\s*(#|$)' /etc/security/faillock.conf 2>/dev/null"
LIMIT=10 run "grep -E '^(PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE|UMASK)' /etc/login.defs"

# ---------------------------------------------------------------------------
sec "DISK, BOOT, TPM"
LIMIT=20 run "lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,TYPE"
run "cryptsetup luksDump \$(blkid -t TYPE=crypto_LUKS -o device | head -1) 2>/dev/null | grep -E 'Version|Keyslots:|^  [0-9]:|Tokens:|clevis|systemd-tpm2' | head -12 || echo '(no LUKS device)'"
sub "GRUB superuser -- CHANGEME here means physical access is root access"
run "grep -rlE '^\s*password_pbkdf2' /etc/grub.d/ /boot/grub/grub.cfg 2>/dev/null || echo '(NO GRUB PASSWORD SET)'"
run "df -h / /home /opt 2>/dev/null"

# ---------------------------------------------------------------------------
sec "NETWORK EXPOSURE"
LIMIT=40 run "ss -tulpnH | awk '{print \$1, \$5, \$7}' | sort -u"
LIMIT=40 run "ufw status numbered 2>/dev/null"

# ---------------------------------------------------------------------------
sec "SERVICES"
LIMIT=15 run "systemctl --failed --no-pager --no-legend"
sub "timers"
LIMIT=25 run "systemctl list-timers --all --no-pager --no-legend"
sub "unit files in /etc/systemd/system -- anything the repo did not write is drift"
LIMIT=60 run "ls -1 /etc/systemd/system/*.service /etc/systemd/system/*.timer /etc/systemd/system/*.mount /etc/systemd/system/*.automount 2>/dev/null | xargs -r -n1 basename"

# ---------------------------------------------------------------------------
sec "DEVELOPMENT PROFILE: THE TOOLCHAINS"
LIMIT=60 run "it-fpga status 2>&1"
sub "vendor app tiles"
LIMIT=20 run "ls -1 /usr/share/applications/fpga-*.desktop /usr/local/bin/fpga-vendor-* 2>/dev/null"
sub "RDP"
LIMIT=40 run "it-rdp status 2>&1"
sub "code-server + shared extensions"
LIMIT=25 run "it-codeserver status 2>&1"
LIMIT=10 run "it-vscode status 2>&1"
sub "USB"
LIMIT=30 run "it-usb status 2>&1"
sub "serial adapters"
LIMIT=25 run "it-serial status 2>&1"

# ---------------------------------------------------------------------------
sec "EVIDENCE PIPELINE"
LIMIT=30 run "it-offload status 2>&1"
LIMIT=40 run "it-powerstrux offload status 2>&1"
LIMIT=25 run "it-smb 2>&1"

# ---------------------------------------------------------------------------
# Contents are NEVER printed for these.
sec "SECRET-BEARING FILES (name, mode, size only)"
shape /etc/stig-build/*.pw /etc/stig-build/*.cred /etc/stig-build/smb/*.cred \
      /etc/ubuntu-advantage/pro-token /etc/krb5.keytab /opt/it/docker/*/.env \
      /etc/stig-build/fpga/License.dat
note "  (contents deliberately omitted -- this capture is meant to leave the box)"

[ "$BRIEF" -eq 1 ] && { printf '\n\n(--brief: package and file inventories skipped)\n'; return 0; }

# ---------------------------------------------------------------------------
# THE POINT OF THE WHOLE CAPTURE.
#
# apt-mark showmanual is everything someone chose to install. Diffed against
# what the repo installs, the remainder is exactly what a rebuild would lose.
sec "MANUALLY INSTALLED PACKAGES (diff this against the repo's lists)"
LIMIT=500 run "apt-mark showmanual | sort"

# ---------------------------------------------------------------------------
sec "MODIFIED PACKAGE FILES (dpkg says these differ from the package)"
LIMIT=120 run "dpkg --verify 2>/dev/null | grep -vE '^\?\?5?\?\?\?\?\?\s+c ' | head -100"

# ---------------------------------------------------------------------------
sec "LOCAL BINARIES AND DROP-INS"
sub "/usr/local -- the it-* commands plus anything hand-placed"
LIMIT=80 run "ls -l /usr/local/bin /usr/local/sbin 2>/dev/null"
sub "sysctl / modprobe / udev drop-ins"
LIMIT=60 run "ls -1 /etc/sysctl.d/ /etc/modprobe.d/ /etc/udev/rules.d/ 2>/dev/null"
sub "apt sources"
LIMIT=40 run "grep -rhE '^[^#]' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | sort -u"
sub "cron"
LIMIT=40 run "ls -1 /etc/cron.d /etc/cron.daily /etc/cron.weekly 2>/dev/null; for u in \$(getent passwd | awk -F: '\$3>=1000 && \$3<65000 {print \$1}'); do c=\$(crontab -l -u \"\$u\" 2>/dev/null | grep -cvE '^\s*(#|$)'); [ \"\${c:-0}\" -gt 0 ] && echo \"crontab: \$u has \$c entries\"; done"

# ---------------------------------------------------------------------------
sec "HOME DIRECTORIES (shape only, no contents)"
LIMIT=30 run "ls -ld /home/* /opt/_AuditFiles /home/shared 2>/dev/null"

printf '\n\n===== END =====\n'
}

if [ "$TO_STDOUT" -eq 1 ]; then
  capture
  exit 0
fi

install -d -m 0750 "$OUT_DIR"
capture > "$OUT" 2>&1
chmod 0640 "$OUT"

printf '\nBaseline captured: %s  (%s lines, %s)\n' \
  "$OUT" "$(wc -l < "$OUT")" "$(du -h "$OUT" | cut -f1)"
printf '\nHeadlines:\n'
printf '  %-26s %s\n' "profile" "$(cat /etc/stig-build/profile 2>/dev/null || echo '?')"
printf '  %-26s %s\n' "baseline" "$(git -C "/root/.ansible/pull/$HOST" rev-parse --short HEAD 2>/dev/null || echo '?')"
printf '  %-26s %s\n' "FIPS" "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo '?')"
printf '  %-26s %s\n' "Pro attached" "$(pro status --format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("attached"))' 2>/dev/null || echo '?')"
printf '  %-26s %s\n' "audit rules loaded" "$(auditctl -l 2>/dev/null | wc -l)"
printf '  %-26s %s\n' "manual packages" "$(apt-mark showmanual 2>/dev/null | wc -l)"
printf '  %-26s %s\n' "GRUB password" "$(grep -rlE '^\s*password_pbkdf2' /etc/grub.d/ 2>/dev/null >/dev/null && echo set || echo 'NOT SET')"
printf '\nSend that file. It contains no secrets -- credential files are listed\nby name and mode only.\n\n'
