#!/usr/bin/env bash
# collect-diag.sh -- one read-only sweep for the three open questions on the
# deployed boxes: the RDP first-app stall, DNS, and the FIPS enable.
#
# Carried to a box on media (like tools/usb-serial-enable.sh) rather than
# shipped by the pull, because the boxes that need it are air-gapped and cannot
# pull. Writes ONE file and prints its path.
#
#   sudo bash collect-diag.sh
#
# READ-ONLY. Changes nothing, starts nothing, stops nothing. Secrets are named
# but never read: passwords, tokens and keys are reported by existence and mode
# only, the same rule it-baseline follows.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

OUT="/tmp/$(hostname)-diag-$(date +%Y%m%d-%H%M%S).txt"
# fd 3 keeps the real terminal; everything else goes to the file. NOT
# `tee` through a process substitution: that races the script's own exit and
# can lose the tail, which is the half you most want.
exec 3>&1
exec >"$OUT" 2>&1

sec() { printf '\n\n===== %s =====\n' "$*"; }
run() { printf '\n--- $ %s\n' "$*"; eval "$@" 2>&1 | head -60; }

printf 'collect-diag  %s  %s\n' "$(hostname)" "$(date -Is)"

# ---------------------------------------------------------------------------
sec "BOX"
run 'uname -r'
run 'lsb_release -ds'
run 'cat /opt/it/site.yml 2>/dev/null | grep -v -i "pass\|token\|secret\|key"'
run 'git -C /opt/it/baseline rev-parse --short HEAD 2>/dev/null || echo "(no /opt/it/baseline)"'
[ -x /usr/local/sbin/it-pull ] && run 'it-pull status'

# ---------------------------------------------------------------------------
# 1. DNS. The question is which resolver stack is in play, because that decides
#    where `options` can durably live -- netplan cannot express them.
sec "DNS"
run 'ls -l /etc/resolv.conf'
run 'cat /etc/resolv.conf'
run 'systemctl is-active systemd-resolved NetworkManager systemd-networkd'
run 'resolvectl status 2>/dev/null | head -40'
run 'ls -l /etc/netplan/'
run 'cat /etc/netplan/*.yaml'
run 'ls /etc/systemd/resolved.conf.d/ 2>/dev/null'
run 'cat /etc/systemd/resolved.conf.d/*.conf 2>/dev/null'
run 'nmcli -t -f NAME,DEVICE,TYPE connection show --active 2>/dev/null'
run 'nmcli -t -f ipv4.dns,ipv4.dns-search,ipv4.dns-options,ipv4.method connection show "$(nmcli -t -f NAME connection show --active 2>/dev/null | head -1)" 2>/dev/null'
run 'cat /etc/NetworkManager/conf.d/*.conf 2>/dev/null'

# ---------------------------------------------------------------------------
# 2. The RDP first-app stall. A box whose own hostname does not resolve stalls
#    anything that looks itself up at startup, and nothing in this baseline
#    manages /etc/hosts -- so time these rather than assume.
sec "NAME RESOLUTION TIMING  (anything over ~0.05s real is a finding)"
run 'hostname; hostname -f 2>&1'
run 'cat /etc/hosts'
run 'grep -E "^(hosts|passwd|group):" /etc/nsswitch.conf'
for n in "$(hostname)" localhost _gateway; do
  printf '\n--- $ time getent hosts %s\n' "$n"
  { time getent hosts "$n"; } 2>&1 | head -8
done

sec "SESSION SERVICES  (portal activation is the usual first-app stall)"
run 'loginctl list-sessions --no-legend'
run 'systemctl list-units --failed --no-legend --no-pager'
# Per-user session state, for whoever is actually logged in right now.
for u in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | sort -u); do
  uid=$(id -u "$u" 2>/dev/null) || continue
  [ -d "/run/user/$uid" ] || continue
  printf '\n--- user session: %s (uid %s)\n' "$u" "$uid"
  runuser -u "$u" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
    systemctl --user list-units --failed --no-legend --no-pager 2>&1 | head -20
  runuser -u "$u" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
    systemctl --user status xdg-desktop-portal xdg-desktop-portal-gnome xdg-desktop-portal-gtk \
    --no-pager 2>&1 | grep -E 'Loaded:|Active:|●' | head -20
  runuser -u "$u" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
    systemd-analyze --user blame 2>/dev/null | head -12
done

sec "SERVICES THAT REACH OUT  (each one is a timeout candidate air-gapped)"
run 'systemctl is-enabled NetworkManager-wait-online fwupd-refresh.timer snapd.snap-repair.timer whoopsie apport packagekit 2>&1'
run 'nmcli general permissions 2>/dev/null | head -3; nmcli -f connectivity general status 2>/dev/null'
run 'journalctl -b -p warning --no-pager | grep -iE "timed out|timeout|resolve|unreachable|refused|dbus" | tail -40'

# ---------------------------------------------------------------------------
# 3. FIPS. The one open question is which ubuntu-fips-userspace these boxes
#    got, because that is what would confirm the suite regressed under us.
sec "FIPS"
run 'pro status --all 2>&1 | head -30'
run 'dpkg -l | grep -iE "fips|ubuntu-fips" | head -30'
run 'dpkg -l ubuntu-fips ubuntu-fips-userspace 2>&1 | tail -5'
run 'dpkg --print-foreign-architectures'
run 'dpkg -l | grep -c ":i386"'
run 'apt-cache policy libgcrypt20 libgnutls30t64 libgnutls30'
run 'apt-mark showhold'
run 'ls /etc/apt/sources.list.d/'

sec "USG"
run 'command -v usg || echo "(usg not installed)"'
run 'ls -l /var/lib/usg-harden/ 2>/dev/null'

printf '\n\nWROTE: %s\n' "$OUT"
exec 1>&3 3>&-
printf '\nDone. Bring this back:\n  %s\n\n' "$OUT"
ls -l "$OUT"
