#!/usr/bin/env bash
# First-boot bootstrap for imaging an Ubuntu 24.04 Desktop STIG box.
# Run once, while the machine has internet:
#   curl -fsSL https://raw.githubusercontent.com/casea1/ubuntu-stig-build/main/bootstrap.sh | sudo bash
#
# It prompts (hidden) for the disk encryption password to enable TPM auto-unlock,
# then launches the harden+scan build in the background. Press Enter at the prompt
# to skip TPM unlock. Edit REPO_URL before baking into your image.

set -euo pipefail

REPO_URL="https://github.com/casea1/ubuntu-stig-build.git"
BRANCH="main"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

# --- TPM auto-unlock: ask for the disk passphrase ONCE, up front --------------
# The build runs detached (below) and can't prompt, so we collect the LUKS
# passphrase HERE -- interactively, in your terminal -- and drop it where the
# tpm_luks_unlock role reads it. The role uses it once to bind the TPM, then
# deletes it. Auto-skipped if: there is no encrypted disk, the file already
# exists (e.g. written by an autoinstall seed), the disk is already TPM-bound, or
# there's no terminal to prompt on (headless). Press Enter to skip.
LUKS_DEV="$(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null | head -1 || true)"
LUKS_PASS_FILE="/etc/luks/initial-passphrase"
if [[ -n "${LUKS_DEV}" && ! -s "${LUKS_PASS_FILE}" && -r /dev/tty ]] \
   && ! cryptsetup luksDump "${LUKS_DEV}" 2>/dev/null | grep -qi clevis; then
  printf '\n[?] Enable TPM auto-unlock so the disk opens at boot with NO password?\n' > /dev/tty
  printf '    Type this box'\''s disk encryption password (hidden), or press Enter to skip: ' > /dev/tty
  LUKS_PASS=""
  read -rs LUKS_PASS < /dev/tty || true
  printf '\n' > /dev/tty
  if [[ -n "${LUKS_PASS}" ]]; then
    install -d -m 700 /etc/luks
    printf '%s' "${LUKS_PASS}" > "${LUKS_PASS_FILE}"
    chmod 600 "${LUKS_PASS_FILE}"
    echo "[*] Passphrase saved — the build will bind the TPM, then delete the file."
  else
    echo "[*] Skipping TPM auto-unlock (enable later per OPERATIONS.md)."
  fi
  unset LUKS_PASS
fi

echo "[*] Installing Ansible + git + curl..."
apt-get update
apt-get install -y ansible git curl

echo "[*] Installing the UBUNTU24-STIG role from requirements.yml..."
TMP_REQ="$(mktemp --suffix=.yml)"   # ansible-galaxy requires a .yml/.yaml extension
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
