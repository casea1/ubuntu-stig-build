#!/usr/bin/env bash
# it-repair -- find and fix the faults that make a hardened box slow, or that
# stop a desktop session starting at all. One command, because these were four
# separate hand-run remedies and the boxes that need them most are the ones a
# new baseline cannot reach.
#
# Usage: it-repair [check|fix] [--only a,b,c] [--list]
#   check   (default) report everything, change NOTHING
#   fix     apply the repairs
#   --only  restrict to named checks (see --list)
# Exit:  0 = nothing left to fix, 1 = something still needs attention.
#
# SELF-CONTAINED ON PURPOSE. It calls nothing from this repo and reads no
# config, so it can be copied to a fielded box on its own -- WinSCP it to
# /usr/local/sbin/it-repair, chmod 0755, run it. A box that cannot take a whole
# baseline can still take this.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

MODE=check; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    check|--check) MODE=check; shift ;;
    fix|--fix)     MODE=fix;   shift ;;
    --only) ONLY="${2:?--only needs a list}"; shift 2 ;;
    --list) printf '%s\n' home net codeserver rdp tiles units crash sshclient identity slow boot disk creds audit; exit 0 ;;
    # Print the header block, however long it grows -- a line count here goes
    # stale the moment anyone edits the comment above.
    -h|--help)
      awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"
      # The checks themselves, not just a pointer to --list. A check nobody
      # knows about is a check nobody runs.
      printf '\nChecks:\n'
      printf '  %-11s %s\n' \
        home       "root-owned files in a home (black screen, stalled session)" \
        net        "systemd-networkd-wait-online waiting for links it does not own" \
        codeserver "leftover code-server system units that start at boot" \
        rdp        "orphaned RDP sessions" \
        tiles      "duplicate FPGA app-grid entries" \
        units      "failed systemd units" \
        crash      "queued apport reports, whoopsie" \
        sshclient  "ssh_config.d drop-ins only root can read" \
        identity   "sssd/nss stalling every user lookup on the box" \
        slow       "desktop latency, MEASURED: DNS, portal, session environment" \
        boot       "slowest units last boot (read-only)" \
        disk       "filesystem usage (read-only)" \
        creds      "were the imaging LUKS/GRUB credentials rotated? (read-only)" \\
        audit      "kernel audit-rule count (read-only)"
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then
  B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'; RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'
else
  B=""; DIM=""; R=""; RED=""; GRN=""; YEL=""
fi
say()  { printf '%s\n' "$*"; }
head2(){ printf '\n%s== %s%s\n' "$B" "$*" "$R"; }
ok()   { printf '  %sOK%s   %s\n'   "$GRN" "$R" "$*"; }
warn() { printf '  %sWARN%s %s\n'   "$YEL" "$R" "$*"; }
bad()  { printf '  %sFAIL%s %s\n'   "$RED" "$R" "$*"; }
did()  { printf '  %sFIXED%s %s\n'  "$GRN" "$R" "$*"; }
note() { printf '       %s%s%s\n'   "$DIM" "$*" "$R"; }

OUTSTANDING=0
flag(){ OUTSTANDING=$((OUTSTANDING + 1)); }
want(){ # $1 = check name
  [ -z "$ONLY" ] && return 0
  case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}
fixing(){ [ "$MODE" = fix ]; }
have(){ command -v "$1" >/dev/null 2>&1; }

# Real login accounts with a home under /home. Locked accounts still get
# repaired: the damage outlives the lock, and an account unlocked later would
# hit the same black screen.
human_homes() {
  awk -F: '$3 >= 1000 && $3 < 65000 && $6 ~ /^\/home\// {print $1":"$6}' /etc/passwd
}

# ---------------------------------------------------------------------------
# 1. HOME OWNERSHIP -- the black screen, and "the session takes forever".
#
# A root-run helper that creates a directory inside someone's home leaves it
# root-owned, because `install -d a/b/c` applies -o only to the LEAF and every
# parent gets the caller's identity (reference.md trap 44). GNOME then cannot
# write its own state: ibus, dconf and the session manager each fail, the
# session sits on a black screen with an X cursor, and apport puts up a
# PermissionError dialog naming whichever one lost first.
#
# Nothing in a user's home is legitimately owned by root on this baseline, so
# the sweep is the check. The named paths are listed first because they are the
# ones that break the SESSION rather than an application.
# ---------------------------------------------------------------------------
CRITICAL_PATHS=".Xauthority .ICEauthority .config .config/dconf .cache .local
.local/share .local/share/code-server .dbus .vscode .gnupg .ssh"

check_home() {
  head2 "Desktop session ownership"
  local entry u h g n_bad total=0 clean=1
  while IFS=: read -r u h; do
    [ -d "$h" ] || continue
    g="$(id -gn "$u" 2>/dev/null)" || continue

    # The home directory itself. If this is wrong nothing else can be right.
    if [ "$(stat -c %U "$h" 2>/dev/null)" != "$u" ]; then
      clean=0
      if fixing; then chown -h "$u:$g" "$h" && did "$h -> $u"; else bad "$h is owned by $(stat -c %U "$h")"; flag; fi
    fi

    for entry in $CRITICAL_PATHS; do
      [ -e "$h/$entry" ] || continue
      [ "$(stat -c %U "$h/$entry" 2>/dev/null)" = "$u" ] && continue
      clean=0
      if fixing; then
        chown -h "$u:$g" "$h/$entry" && did "$u: $entry"
      else
        bad "$u: ~/$entry is owned by root -- this is what stalls the session"
        flag
      fi
    done

    # Everything else. Counted rather than listed: a broken .cache can hold
    # thousands and the number is the useful part.
    n_bad=$(find "$h" -xdev ! -user "$u" -printf . 2>/dev/null | wc -c)
    if [ "${n_bad:-0}" -gt 0 ]; then
      clean=0
      if fixing; then
        find "$h" -xdev ! -user "$u" -exec chown -h "$u:$g" {} + 2>/dev/null
        did "$u: $n_bad further file(s) returned to $u"
      else
        warn "$u: $n_bad file(s) under $h not owned by $u"
        note "see them: sudo find $h -xdev ! -user $u | head"
        flag
      fi
    fi
    total=$((total + 1))
  done <<EOT
$(human_homes)
EOT
  [ "$total" = 0 ] && { note "no login accounts with a home under /home"; return 0; }
  [ "$clean" = 1 ] && ok "$total home(s) -- every file owned by its user"
  return 0
}

# ---------------------------------------------------------------------------
# 2. systemd-networkd-wait-online -- ~2 minutes of every boot.
#
# NetworkManager is the netplan renderer on the desktop profiles, so
# systemd-networkd manages nothing -- but its wait-online is enabled, waits for
# links it does not own and times out at the default 120s on EVERY boot.
# NetworkManager-wait-online has already satisfied network-online.target
# seconds in.
#
# NOT unconditional. Real units order behind network-online.target here (the
# SMB offloads, the FlexLM daemon), and on an `ai` node running Ubuntu Server
# networkd IS the renderer -- masking it there breaks the target outright. So
# both conditions are read from the box.
# ---------------------------------------------------------------------------
check_net() {
  head2 "Boot: systemd-networkd-wait-online"
  have networkctl || { note "networkctl not present -- skipped"; return 0; }
  local managed nm masked
  managed=$(networkctl list --no-legend 2>/dev/null | awk '$5 != "unmanaged" && $5 != "pending"' | wc -l)
  nm=$(systemctl is-enabled NetworkManager-wait-online.service 2>/dev/null)
  masked=$(systemctl is-enabled systemd-networkd-wait-online.service 2>/dev/null)

  if [ "${managed:-1}" -eq 0 ] && { [ "$nm" = enabled ] || [ "$nm" = enabled-runtime ]; }; then
    if [ "$masked" = masked ]; then
      ok "already masked -- networkd manages 0 links, NetworkManager provides the target"
      return 0
    fi
    if fixing; then
      systemctl disable --now systemd-networkd-wait-online.service >/dev/null 2>&1
      systemctl mask systemd-networkd-wait-online.service >/dev/null 2>&1 \
        && did "masked systemd-networkd-wait-online -- ~2 min off every boot"
    else
      bad "enabled, but networkd manages 0 links -- it waits 120s for nothing"
      note "NetworkManager-wait-online is $nm and already provides network-online.target"
      flag
    fi
  else
    if [ "$masked" = masked ]; then
      # Self-correcting: a box rebuilt onto networkd loses its only provider of
      # network-online.target, and every unit ordered behind it hangs instead.
      if fixing; then
        systemctl unmask systemd-networkd-wait-online.service >/dev/null 2>&1 \
          && did "unmasked it -- networkd now manages $managed link(s) and the target needs it"
      else
        bad "masked, but networkd manages $managed link(s) -- network-online.target has no provider"
        flag
      fi
    else
      ok "correct: networkd manages ${managed:-?} link(s), leaving it enabled"
    fi
  fi
}

# ---------------------------------------------------------------------------
# 3. Leftover code-server SYSTEM units. The instance is a systemd USER service
# now, started by its owner and gone when they log out. Any surviving
# code-server@<user> system unit is the old model: it starts at boot, for
# everybody, and races the user's own copy for the same port. Removing it is
# the migration, and it is safe -- the user service replaces it entirely.
# ---------------------------------------------------------------------------
check_codeserver() {
  head2 "code-server instances"
  local f n=0 u
  for f in /etc/systemd/system/*.wants/code-server@*.service; do
    [ -e "$f" ] || continue
    u="$(basename "$f")"; u="${u#code-server@}"; u="${u%.service}"
    n=$((n + 1))
    if fixing; then
      systemctl disable --now "code-server@$u.service" >/dev/null 2>&1
      systemctl reset-failed "code-server@$u.service" >/dev/null 2>&1
      did "$u: old system unit retired (they start their own: it-codeserver mine start)"
    else
      warn "$u: old system unit still starts at boot"
      flag
    fi
  done
  [ "$n" = 0 ] && ok "no system units left -- instances are per-user services"
  [ "$n" -gt 0 ] && [ "$MODE" = check ] && \
    note "$n leftover unit(s). The config and password are untouched; only the"
  [ "$n" -gt 0 ] && [ "$MODE" = check ] && \
    note "boot-start goes, and the engineer starts their own without sudo."
  return 0
}

# ---------------------------------------------------------------------------
# 4. Orphaned RDP sessions. Never restart xrdp-sesman to clear these: every
# session it manages is orphaned by the restart and the next login by those
# users dies a second after authentication ("Session manager already running!").
# it-rdp sweep is the safe path.
# ---------------------------------------------------------------------------
check_rdp() {
  head2 "RDP sessions"
  have it-rdp || { note "it-rdp not installed -- skipped"; return 0; }
  if fixing; then
    it-rdp sweep 2>&1 | sed 's/^/  /'
    did "swept orphaned sessions"
  else
    it-rdp status 2>&1 | sed 's/^/  /'
    note "stale entries: sudo it-repair fix --only rdp   (never restart xrdp-sesman)"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 5. Duplicate FPGA app-grid tiles -- the pull's generic tile, the vendor's
# copy in its tree, and the vendor's copy in the installing user's home can all
# point at one binary. it-fpga desktop reconciles them.
# ---------------------------------------------------------------------------
check_tiles() {
  head2 "FPGA app-grid tiles"
  have it-fpga || { note "it-fpga not installed -- skipped"; return 0; }
  # Only files whose Exec points into a vendor tree. Counting every per-user
  # .desktop would flag someone's own launcher, which `it-fpga desktop` will
  # never remove -- so the check could not be satisfied by the fix.
  local private
  private=$(grep -lE '^Exec=.*(/tools/Xilinx|/opt/microchip)' \
              /home/*/.local/share/applications/*.desktop 2>/dev/null | wc -l)
  if [ "${private:-0}" -gt 0 ]; then
    if fixing; then
      it-fpga desktop >/dev/null 2>&1 && did "tiles rebuilt, duplicates removed"
    else
      warn "$private per-user .desktop file(s) -- these show beside the system-wide tiles"
      note "sudo it-fpga desktop   (imports one tile per program, clears the copies)"
      flag
    fi
  else
    ok "no per-user vendor tiles left to duplicate"
  fi
}

# ---------------------------------------------------------------------------
# 6. Failed units. code-server@<locked user> failing is known noise and is
# cleared; anything else is reported and left alone, because a unit that failed
# for a real reason should not be quietly reset.
# ---------------------------------------------------------------------------
check_units() {
  head2 "Failed units"
  local failed n
  failed=$(systemctl list-units --failed --plain --no-legend 2>/dev/null | awk '{print $1}')
  n=$(printf '%s' "$failed" | grep -c . || true)
  [ "${n:-0}" = 0 ] && { ok "none"; return 0; }
  printf '%s\n' "$failed" | sed 's/^/       /'
  if fixing; then
    printf '%s\n' "$failed" | grep '^code-server@' | while read -r u; do
      systemctl reset-failed "$u" >/dev/null 2>&1 && did "reset $u"
    done
    printf '%s\n' "$failed" | grep -qv '^code-server@' && { flag; warn "the rest need looking at -- not reset automatically"; }
  else
    warn "$n failed unit(s)"
    flag
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 7. Crash dialogs. apport catches the PermissionError from a root-owned home
# and puts a dialog in front of the user at login. Fixing the ownership removes
# the cause; this removes the report queue and the dialog.
# ---------------------------------------------------------------------------
check_crash() {
  head2 "Crash reporting"
  local n; n=$(ls -1 /var/crash/ 2>/dev/null | wc -l)
  local en=0
  systemctl is-enabled apport.service    >/dev/null 2>&1 && en=1
  systemctl is-enabled whoopsie.service  >/dev/null 2>&1 && en=1
  if [ "${n:-0}" = 0 ] && [ "$en" = 0 ]; then ok "no queued reports, apport/whoopsie off"; return 0; fi
  if fixing; then
    rm -f /var/crash/* 2>/dev/null && did "cleared $n queued report(s)"
    # whoopsie phones Canonical, which a hardened box should not do. apport is
    # disabled with it: on this fleet its only visible output has been a dialog
    # about a fault this script has already repaired.
    local u
    for u in apport.service whoopsie.service whoopsie.path; do
      systemctl is-enabled "$u" >/dev/null 2>&1 || continue
      systemctl disable --now "$u" >/dev/null 2>&1 && did "disabled $u"
    done
    [ -f /etc/default/apport ] && sed -i 's/^enabled=.*/enabled=0/' /etc/default/apport
  else
    [ "${n:-0}" -gt 0 ] && { warn "$n queued crash report(s) -- the login dialog"; flag; }
    [ "$en" = 1 ] && { warn "apport/whoopsie enabled (whoopsie reports to Canonical)"; flag; }
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 8. SSH CLIENT config a normal user cannot read.
#
# ssh reads /etc/ssh/ssh_config.d/*.conf AS THE CALLING USER. `usg fix` writes
# the STIG's client ciphers there and nothing asserted a mode, so under the
# STIG's umask 077 the file lands 0600 root:root: ssh works for an admin and
# fails for everyone else, naming the drop-in -- which reads as a broken cipher
# list rather than a permissions problem.
#
# 0644 is right, not a relaxation: algorithm lists, no secrets, and stock
# /etc/ssh/ssh_config is 0644. sshd_config.d is deliberately left alone.
# ---------------------------------------------------------------------------
check_sshclient() {
  head2 "SSH client config"
  local d=/etc/ssh/ssh_config.d f n=0 mode
  [ -d "$d" ] || { ok "no drop-in directory"; return 0; }
  for f in "$d"/*.conf; do
    [ -e "$f" ] || continue
    mode="$(stat -c %a "$f" 2>/dev/null)"
    case "$mode" in
      *4|*5|*6|*7) continue ;;          # world-readable already
    esac
    n=$((n + 1))
    if fixing; then
      chmod 0644 "$f" && chown root:root "$f" && did "$(basename "$f") -> 0644"
    else
      bad "$(basename "$f") is $mode -- only root can read it, so ssh fails for everyone else"
      flag
    fi
  done
  [ "$n" = 0 ] && ok "every drop-in is readable"
  [ "$n" -gt 0 ] && [ "$MODE" = check ] && \
    note "test as a normal user:  ssh -G localhost >/dev/null"
  return 0
}

# ---------------------------------------------------------------------------
# 9. WHY THE DESKTOP IS SLOW. On a deployed box the usual answer is not load,
# it is WAITING: for a DNS server that will not answer, or for a D-Bus service
# that cannot start. Both present identically -- an app that opens after a long
# pause -- so this MEASURES rather than guesses, and prints the number.
# ---------------------------------------------------------------------------
ms_for() {   # $@ = command -> elapsed milliseconds, output discarded
  local a b
  a=$(date +%s%N)
  "$@" >/dev/null 2>&1
  b=$(date +%s%N)
  echo $(( (b - a) / 1000000 ))
}

check_slow() {
  head2 "Desktop latency"
  local t host

  # 1. The box's own name. Every gethostbyname() for it -- sudo, GNOME, D-Bus,
  # X -- takes this path, and off-network an unanswered lookup costs seconds
  # EACH TIME, uncached.
  host="$(hostname)"
  t=$(ms_for getent hosts "$host")
  if [ "$t" -gt 100 ]; then
    bad "resolving this box's own name took ${t}ms -- it is going to DNS"
    if fixing; then
      if ! grep -qE "^127\.0\.1\.1[[:space:]]" /etc/hosts; then
        printf '127.0.1.1 %s\n' "$host" >> /etc/hosts
        did "added 127.0.1.1 $host to /etc/hosts"
      else
        sed -i -E "s|^127\.0\.1\.1[[:space:]].*|127.0.1.1 $host|" /etc/hosts
        did "corrected the 127.0.1.1 line in /etc/hosts"
      fi
    else
      note "no /etc/hosts entry for it. Every lookup waits for the resolver."
      flag
    fi
  else
    ok "own hostname resolves in ${t}ms"
  fi

  # 2. A name that cannot exist. Off-network this SHOULD fail instantly; if it
  # takes seconds, a configured DNS server is not answering and every lookup on
  # the box pays that.
  t=$(ms_for getent hosts does-not-exist.invalid)
  if [ "$t" -gt 1000 ]; then
    bad "a failed DNS lookup took ${t}ms -- a configured resolver is not answering"
    note "every name lookup on this box pays this. Check: resolvectl status"
    note "point it at a resolver that exists, or none: sudo it-net dns"
    flag
  else
    ok "failed lookups return in ${t}ms"
  fi

  # 3. NetworkManager's connectivity probe: off-network it can only time out.
  if [ -e /usr/sbin/NetworkManager ]; then
    if [ -e /etc/NetworkManager/conf.d/20-no-connectivity-check.conf ]; then
      ok "NetworkManager connectivity check is off"
    elif fixing; then
      install -d -m 0755 /etc/NetworkManager/conf.d
      printf '[connectivity]\nenabled=false\nuri=\ninterval=0\n' \
        > /etc/NetworkManager/conf.d/20-no-connectivity-check.conf
      nmcli general reload >/dev/null 2>&1 || true
      did "turned off the NetworkManager connectivity check"
    else
      warn "NetworkManager still probes connectivity.ubuntu.com -- it can only time out here"
      flag
    fi
  fi

  # 4. The user services an RDP session needs. Asked of each logged-in user's
  # own manager, because that is where they run.
  local u seen=0
  for u in $(loginctl list-users --no-legend 2>/dev/null | awk '$2 != "root" {print $2}'); do
    seen=1
    local portal env_ok
    portal="$(sctl_user "$u" is-active xdg-desktop-portal.service)"
    env_ok="$(systemctl --user --machine="$u@.host" show-environment 2>/dev/null \
              | grep -c '^XDG_CURRENT_DESKTOP=' || true)"
    if [ "$portal" = active ] && [ "${env_ok:-0}" -gt 0 ]; then
      ok "$u: desktop portal active, session environment present"
    else
      bad "$u: portal is '$portal', XDG_CURRENT_DESKTOP $([ "${env_ok:-0}" -gt 0 ] && echo present || echo MISSING)"
      note "every GTK app waits out a ~25s portal timeout before it opens."
      note "the pull ships /etc/X11/Xsession.d/56it-session-env to fix this;"
      note "it applies at the NEXT full RDP login, not to this session."
      flag
    fi
  done
  [ "$seen" = 0 ] && note "no non-root user logged in, so the session services cannot be checked"
  return 0
}

sctl_user() {   # $1 = user, rest = systemctl args -> one word
  local out
  out="$(systemctl --user --machine="$1@.host" "${@:2}" 2>/dev/null | head -1)"
  printf '%s' "${out:-unknown}"
}

# ---------------------------------------------------------------------------
# 10. IDENTITY LOOKUPS. The one that makes a box slow BEFORE anyone logs in.
#
# libnss-sss puts `sss` into the passwd/group/shadow lines of nsswitch.conf, so
# every getpwnam() on the box asks sssd. With sssd dead -- installed for a
# domain join that has not happened, or half-configured -- those lookups wait
# instead of failing, and the cost lands on everything: the login banner, PAM,
# sudo, GDM, the session.
#
# The give-away is WHERE the delay is. A slow desktop portal cannot slow down a
# banner that is printed before authentication; a stalled NSS lookup can.
#
# This build deliberately does NOT install sssd (group_vars says why: libpam-sss
# regenerates common-auth and that is how ASP-2 became unloggable). If it is
# here, `it-domain stage` or a join put it here.
# ---------------------------------------------------------------------------
check_identity() {
  head2 "Identity lookups (nsswitch / sssd)"
  local nss active t

  nss="$(grep -E '^(passwd|group|shadow):' /etc/nsswitch.conf 2>/dev/null | grep -c 'sss' || true)"
  if [ "${nss:-0}" -eq 0 ]; then
    ok "nsswitch does not consult sssd"
  else
    active="$(systemctl is-active sssd.service 2>/dev/null | head -1)"
    if [ "$active" = active ]; then
      ok "nsswitch uses sssd and sssd is running"
    else
      bad "nsswitch asks sssd on $nss line(s), but sssd is '$active'"
      note "every user/group lookup on this box goes to a daemon that is not there --"
      note "which is why the login banner is slow, not just the desktop."
      if fixing; then
        cp -a /etc/nsswitch.conf "/etc/nsswitch.conf.before-it-repair.$(date +%s)"
        sed -i -E '/^(passwd|group|shadow):/ s/[[:space:]]+sss\b//g' /etc/nsswitch.conf
        did "removed sss from nsswitch.conf (backup kept alongside it)"
        note "libpam-sss is deliberately NOT touched: rewriting the auth stack is"
        note "how a box becomes unloggable. Remove it only with it-domain."
      else
        flag
      fi
    fi
  fi

  # Measure it either way -- the number is what tells you if this is THE cause.
  t=$(ms_for getent passwd root)
  if [ "$t" -gt 200 ]; then
    bad "a local user lookup took ${t}ms -- that is paid by every login and every sudo"
    flag
  else
    ok "user lookups return in ${t}ms"
  fi
  return 0
}

# ---- read-only context -----------------------------------------------------
check_boot() {
  head2 "Slowest units last boot"
  have systemd-analyze || return 0
  systemd-analyze blame 2>/dev/null | head -6 | sed 's/^/       /'
  note "read-only -- nothing here is changed by fix"
}

check_disk() {
  head2 "Disk"
  local line use mnt
  df -h -x tmpfs -x devtmpfs --output=pcent,avail,target 2>/dev/null | tail -n +2 |
  while read -r line; do
    use=$(printf '%s' "$line" | awk '{gsub("%","",$1); print $1}')
    mnt=$(printf '%s' "$line" | awk '{print $3}')
    if [ "${use:-0}" -ge 90 ]; then bad "$mnt is ${use}% full -- nothing here repairs that"
    elif [ "${use:-0}" -ge 80 ]; then warn "$mnt is ${use}% full"
    fi
  done
  df -h / /var 2>/dev/null | tail -n +2 | sed 's/^/       /'
}

# Read-only. Answers "were the imaging credentials rotated after deployment?"
# from what the box recorded at the time -- see the note in the output for why
# it cannot be reconstructed afterwards.
check_creds() {
  head2 "Credential changes since imaging"
  local log=/etc/stig-build/credential-changes.log
  if [ -s "$log" ]; then
    sed 's/^/       /' "$log"
  else
    warn "nothing recorded"
    note "either nothing has been rotated on this box, or it was rotated with"
    note "cryptsetup/grub-mkpasswd directly instead of it-luks-passwd / it-grub set."
  fi
  # What CAN be read from the system itself, as a cross-check.
  local g=/etc/grub.d/01_superusers
  if [ -e "$g" ]; then
    if grep -q CHANGEME "$g" 2>/dev/null; then
      bad "GRUB password is still the CHANGEME sentinel -- it is NOT set"
      flag
    else
      ok "GRUB password set; drop-in last written $(stat -c %y "$g" 2>/dev/null | cut -d. -f1)"
    fi
  else
    warn "no GRUB password drop-in on this box"
    flag
  fi
  [ -e /etc/luks/initial-passphrase ] \
    && { bad "the IMAGING LUKS passphrase is still staged at /etc/luks/initial-passphrase"; flag; } \
    || ok "no staged imaging passphrase left on disk"
  note "a LUKS2 header stores no per-keyslot timestamp, so a passphrase change"
  note "cannot be dated after the fact -- only recorded as it happens."
  return 0
}

check_audit() {
  head2 "Audit rules"
  have auditctl || { note "auditctl not present -- skipped"; return 0; }
  local n; n=$(auditctl -l 2>/dev/null | grep -c . || true)
  if [ "${n:-0}" -le 1 ]; then
    bad "$n rule(s) loaded -- auditctl stops at the first rule it cannot apply"
    note "one bad syscall name or a watch on a missing path leaves the rest unloaded"
    note "diagnose: sudo it-checklist   (item 6 names both faults)"
    flag
  else
    ok "$n rules loaded"
  fi
  note "read-only -- this one is not repaired here"
}

# ---------------------------------------------------------------------------
say "${B}it-repair${R} -- $(hostname) -- $(date '+%Y-%m-%d %H:%M:%S %Z')"
[ "$MODE" = check ] && note "reporting only. Apply with: sudo it-repair fix"

for c in home net codeserver rdp tiles units crash sshclient identity slow boot disk creds audit; do
  want "$c" && "check_$c"
done

head2 "Summary"
if fixing; then
  if [ "$OUTSTANDING" = 0 ]; then
    ok "repairs applied"
  else
    warn "$OUTSTANDING item(s) still need a human -- see above"
  fi
  note "a reboot confirms the boot-time change; log out and back in for the session ones"
  # daemon-reload so a masked/disabled unit is not still live in this boot.
  systemctl daemon-reload >/dev/null 2>&1 || true
else
  if [ "$OUTSTANDING" = 0 ]; then
    ok "nothing to repair"
  else
    warn "$OUTSTANDING item(s) to repair -- sudo it-repair fix"
  fi
fi
say ""
[ "$OUTSTANDING" = 0 ] || exit 1
exit 0
