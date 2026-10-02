#!/usr/bin/env bash
# First run of the `legacy` profile on an Ubuntu 22.04 VM. Fully offline: the
# baseline comes from the SSD, the packages from the box's own apt mirror.
#
# On the VM, with baseline.git.tar.gz copied to your home directory:
#   sudo apt-get install -y git
#   sudo install -d -m 0700 /opt/it/baseline-stage
#   sudo tar xzf ~/baseline.git.tar.gz -C /opt/it/baseline-stage
#   sudo git --git-dir=/opt/it/baseline-stage/baseline.git show main:tools/legacy/bootstrap.sh | sudo bash
#
# What it does, once: installs ansible + auditd + libopenscap8 from the apt
# mirror, keeps the baseline on the box (/srv/baseline.git, exactly as
# `it-pull load` does), records the profile as `legacy`, and runs the first
# pull. After that the box is updated like the 24.04 fleet:
#   sudo it-pull load      (new archive from the SSD)
#   sudo it-pull
set -euo pipefail
# Run as `... | sudo bash`, the script IS bash's stdin: anything below that read
# stdin (apt, dpkg, ansible) would swallow the rest of it. Every such command
# reads /dev/null instead.

STAGE="${STAGE:-/opt/it/baseline-stage/baseline.git}"
MIRROR=/srv/baseline.git
BRANCH="${BRANCH:-main}"

[ "$EUID" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
[ "${VERSION_ID:-}" = "22.04" ] || { echo "This is the 22.04 legacy bootstrap; this box is ${PRETTY_NAME:-unknown}." >&2; exit 1; }
[ -d "$STAGE" ] || { echo "No baseline at $STAGE -- unpack baseline.git.tar.gz there first." >&2; exit 1; }

echo "[1/4] Packages from the apt mirror (ansible, auditd, libopenscap8, git)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq </dev/null || echo "    (apt-get update reported a problem -- trying the install anyway)"
apt-get install -y -qq ansible auditd libopenscap8 git xz-utils </dev/null >/dev/null

echo "[2/4] Keeping the baseline on the box ($MIRROR)..."
# Is it really this baseline? Checked by content: the legacy playbook and the
# shared scripts must both be there, or the pull below runs something else.
git --git-dir="$STAGE" cat-file -e "refs/heads/$BRANCH:legacy.yml" 2>/dev/null \
  && git --git-dir="$STAGE" cat-file -e "refs/heads/$BRANCH:roles/it_scripts" 2>/dev/null \
  || { echo "$STAGE has no legacy.yml on $BRANCH -- an older or a different repository." >&2; exit 1; }
tmp="$MIRROR.new.$$"
rm -rf "$tmp"
git clone --quiet --mirror "$STAGE" "$tmp" </dev/null
rm -rf "$MIRROR.old"; [ -d "$MIRROR" ] && mv "$MIRROR" "$MIRROR.old"
mv "$tmp" "$MIRROR"; rm -rf "$MIRROR.old"
chown -R root:root "$MIRROR"; chmod -R go-w "$MIRROR"
git -C "$MIRROR" symbolic-ref HEAD "refs/heads/$BRANCH"
install -d -m 0700 /etc/stig-build
printf '# Written by tools/legacy/bootstrap.sh. This box pulls from carried media.\nREPO_URL=%s\n' "$MIRROR" > /etc/stig-build/pull.conf
chmod 0600 /etc/stig-build/pull.conf

echo "[3/4] Recording the profile (legacy)..."
install -d -m 2770 -o root -g sudo /opt/it
touch /opt/it/site.yml
if grep -qE '^deployment_profile[[:space:]]*:' /opt/it/site.yml; then
  sed -i -E 's|^deployment_profile[[:space:]]*:.*|deployment_profile: legacy|' /opt/it/site.yml
else
  printf '# Written by tools/legacy/bootstrap.sh. legacy.yml loads this.\ndeployment_profile: legacy\n' >> /opt/it/site.yml
fi

echo "[4/4] First pull (a few minutes)..."
log=/var/log/stig-build-legacy-bootstrap.log
# The same checkout path it-pull uses, so `it-pull status` finds it.
set +e
ansible-pull -U "$MIRROR" -C "$BRANCH" -d "/root/.ansible/pull/$(hostname -s)" \
  -i localhost, legacy.yml -e deployment_profile=legacy </dev/null 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
set -e
echo
if [ "$rc" = 0 ]; then
  echo "[OK] Done. From now on:  sudo it-pull    sudo it-audit    sudo it-oscap    sudo it-checklist"
else
  echo "[FAIL] The first pull failed -- the full output is in $log" >&2
fi
exit "$rc"
