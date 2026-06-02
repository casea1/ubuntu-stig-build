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

echo "[*] Installing Ansible + git..."
apt-get update
apt-get install -y ansible git

echo "[*] Installing the UBUNTU24-STIG role from requirements.yml..."
TMP_REQ="$(mktemp)"
curl -fsSL "https://raw.githubusercontent.com/casea1/ubuntu-stig-build/${BRANCH}/requirements.yml" -o "$TMP_REQ"
ansible-galaxy install -r "$TMP_REQ"
rm -f "$TMP_REQ"

echo "[*] Running ansible-pull (provision + harden + scan)..."
ansible-pull -U "$REPO_URL" -C "$BRANCH" -i localhost, local.yml

echo
echo "[✓] Done. Compliance reports are in /var/log/stig-scan/"
echo "    Collect them BEFORE moving this machine to the air-gapped network."
