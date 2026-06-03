#!/usr/bin/env bash
# First-boot bootstrap for imaging an Ubuntu 24.04 Desktop STIG box.
# Run once, while the machine has internet:
#   curl -fsSL https://raw.githubusercontent.com/casea1/ubuntu-stig-build/main/bootstrap.sh | sudo bash
#
# Edit REPO_URL before baking into your image.

set -euo pipefail

REPO_URL="https://github.com/casea1/ubuntu-stig-build.git"
BRANCH="main"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

echo "[*] Installing Ansible + git + curl..."
apt-get update
apt-get install -y ansible git curl

echo "[*] Installing the UBUNTU24-STIG role from requirements.yml..."
TMP_REQ="$(mktemp)"
curl -fsSL "https://raw.githubusercontent.com/casea1/ubuntu-stig-build/${BRANCH}/requirements.yml" -o "$TMP_REQ"
ansible-galaxy install -r "$TMP_REQ"
rm -f "$TMP_REQ"

# Run the build DETACHED as a transient systemd service. The hardening restarts
# GDM mid-run; a foreground process launched from the GUI session (e.g. this
# curl|bash in a terminal) would be killed by that restart, leaving the box
# half-hardened. systemd-run decouples it so the build survives.
echo "[*] Starting provision + harden + scan as systemd unit 'stig-build'..."
systemctl reset-failed stig-build 2>/dev/null || true
systemd-run --unit=stig-build --collect \
  ansible-pull -U "$REPO_URL" -C "$BRANCH" -i localhost, local.yml

echo
echo "[✓] Build started in the background as systemd unit 'stig-build'."
echo "    Watch it:     journalctl -u stig-build -f"
echo "    Result:       systemctl status stig-build   (active(exited) = success)"
echo "    Reports:      /var/log/stig-scan/  — collect BEFORE air-gapping."
echo "    Then reboot to apply hardening and reach the graphical login banner."
