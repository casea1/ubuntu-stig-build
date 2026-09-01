#!/usr/bin/env bash
# First-boot bootstrap for imaging an Ubuntu 24.04 STIG box.
# Run once, while the machine has internet.
#
#   DEVELOPMENT (default) -- engineering workstation with a GNOME desktop reached
#   over RDP (xrdp). Works on a headless server base (it installs the GUI):
#     curl -fsSL https://git.asplab.com/ASPLAB/ubuntu-stig-build/raw/branch/main/bootstrap.sh | sudo bash
#
#   AI -- Ubuntu Pro AI server (host prep: Docker + NVIDIA + USG hardening +
#   firewall). Your prebuilt images + compose files deploy the AI tools:
#     curl -fsSL .../bootstrap.sh | sudo PROFILE=ai bash
#
#   BASELINE -- an ALREADY-BUILT box (software already installed). Org accounts/
#   groups/ACL'd folders + USB->dta, Cockpit, USG hardening, and the GUI-preserving
#   fixups only. Installs NO app set and NO RDP:
#     curl -fsSL .../bootstrap.sh | sudo PROFILE=baseline bash
#
#   EMI -- a local-GUI, STIG-hardened Dell imaging/field workstation (dev app set
#   minus RDP, + VPN/recon/CJK-IME, imaging-service firewall, camera/mic lockoff):
#     curl -fsSL .../bootstrap.sh | sudo PROFILE=emi bash          # classified-capable (FIPS+LUKS)
#     curl -fsSL .../bootstrap.sh | sudo PROFILE=emi-unclass bash  # unclassified-only (no FIPS/LUKS)
#
# Recognised environment variables:
#   PROFILE=development|ai|baseline|emi|emi-unclass  which build  (default: development)
#                           (aliases: desktop->development, server->ai, emi-unclass->emi variant)
#   PRO_TOKEN=<token>       Ubuntu Pro token for USG hardening (BOTH profiles use
#                           USG; else you're prompted). Enter to skip = POA&M.
#   HARDEN=0                install but SKIP the disruptive `usg fix` (both
#                           profiles; audit-only -- validate before hardening)
#
# NOTE (ai profile): Ansible does HOST PREP only (Docker + NVIDIA + firewall).
# Your prebuilt images + compose files deploy the AI tools -- there is no TOOLS or
# HF_TOKEN to pass anymore.
#
# It also prompts (hidden) for the disk encryption password to enable TPM
# auto-unlock (either profile). Press Enter at any prompt to skip.
# REPO_URL/BRANCH are environment-overridable, so a mirror needs no edit:
#     curl -fsSL https://git.example.com/ASPLAB/ubuntu-stig-build/raw/branch/main/bootstrap.sh \
#       | sudo REPO_URL=https://git.example.com/ASPLAB/ubuntu-stig-build.git PROFILE=emi bash
# If the server uses an internal CA, install it first (or pass CA_CERT=/path/ca.crt).

set -euo pipefail

# Overridable from the environment so the same script works against another
# mirror, or back at GitHub during a transition, without editing it:
#   sudo REPO_URL=https://git.example.com/ASPLAB/ubuntu-stig-build.git PROFILE=emi bash
REPO_URL="${REPO_URL:-https://git.asplab.com/ASPLAB/ubuntu-stig-build.git}"
BRANCH="${BRANCH:-main}"
PROFILE="${PROFILE:-development}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

# Back-compat aliases from the first release.
case "${PROFILE}" in
  desktop) PROFILE="development" ;;
  server)  PROFILE="ai" ;;
esac

case "${PROFILE}" in
  development|ai|baseline|emi|emi-unclass) : ;;
  *) echo "PROFILE must be development|ai|baseline|emi|emi-unclass (got '${PROFILE}')." >&2; exit 1 ;;
esac

echo "[*] Deployment profile: ${PROFILE}"

# --- Extra vars passed to ansible-pull (built up below) ----------------------
EXTRA_ARGS=(-e "deployment_profile=${PROFILE}")

# --- Ubuntu Pro token (secret, out-of-band) -- BOTH profiles harden with USG ---
# USG needs the box Pro-attached. Collect the token HERE (interactively) and drop
# it where the usg_harden role reads it. Skipped if already present, already
# attached, or supplied via PRO_TOKEN. The token is NEVER placed in the repo.
PRO_TOKEN_FILE="/etc/ubuntu-advantage/pro-token"
ALREADY_ATTACHED="no"
if command -v pro >/dev/null 2>&1 && pro status --format json 2>/dev/null | grep -q '"attached": *true'; then
  ALREADY_ATTACHED="yes"
fi
if [[ -n "${PRO_TOKEN:-}" ]]; then
  install -d -m 700 /etc/ubuntu-advantage
  printf '%s' "${PRO_TOKEN}" > "${PRO_TOKEN_FILE}"
  chmod 600 "${PRO_TOKEN_FILE}"
  echo "[*] Ubuntu Pro token saved from PRO_TOKEN."
  unset PRO_TOKEN
elif [[ "${ALREADY_ATTACHED}" == "no" && ! -s "${PRO_TOKEN_FILE}" && -r /dev/tty ]]; then
  printf '\n[?] Ubuntu Pro token (required for USG DISA-STIG hardening).\n' > /dev/tty
  printf '    Paste your Pro token (hidden), or press Enter to skip hardening: ' > /dev/tty
  PRO_TOKEN_INPUT=""
  read -rs PRO_TOKEN_INPUT < /dev/tty || true
  printf '\n' > /dev/tty
  if [[ -n "${PRO_TOKEN_INPUT}" ]]; then
    install -d -m 700 /etc/ubuntu-advantage
    printf '%s' "${PRO_TOKEN_INPUT}" > "${PRO_TOKEN_FILE}"
    chmod 600 "${PRO_TOKEN_FILE}"
    echo "[*] Token saved — the build will Pro-attach and run USG."
  else
    echo "[*] No token — USG hardening will be SKIPPED (POA&M). Attach later and re-run."
  fi
  unset PRO_TOKEN_INPUT
elif [[ "${ALREADY_ATTACHED}" == "yes" ]]; then
  echo "[*] Box is already Ubuntu Pro-attached; USG will use the existing attach."
fi

# HARDEN=0 -> install everything but don't run the disruptive `usg fix` (both profiles).
if [[ "${HARDEN:-1}" == "0" ]]; then
  EXTRA_ARGS+=(-e "usg_fix_enabled=false")
  echo "[*] HARDEN=0 -> USG will AUDIT only (no fix)."
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
    echo "[*] Skipping TPM auto-unlock (enable later per docs/reference.md)."
  fi
  unset LUKS_PASS
fi

# PERSIST THE PROFILE before the first run. Nothing else does: ansible-pull is
# given -e deployment_profile=<x> below, and group_vars defaults to
# `development` -- so ANY later ansible-pull without that -e rebuilds the box
# under the wrong profile. On an EMI laptop that silently turns off USB storage,
# the dta carve-out and the camera/mic lockdown, and it is not obvious from the
# outside that it happened. local.yml loads /opt/it/site.yml above group_vars,
# so a value written here is what every later run uses, typed flag or not.
install -d -m 0755 /opt/it
touch /opt/it/site.yml
if grep -qE '^deployment_profile[[:space:]]*:' /opt/it/site.yml; then
  sed -i -E "s|^deployment_profile[[:space:]]*:.*|deployment_profile: ${PROFILE}|" /opt/it/site.yml
else
  printf '\n# Written by bootstrap.sh. Which profile this box is. local.yml loads this\n# above group_vars, so ANY ansible-pull builds it the same way.\ndeployment_profile: %s\n' \
    "${PROFILE}" >> /opt/it/site.yml
fi
echo "[*] Profile '${PROFILE}' persisted to /opt/it/site.yml."

echo "[*] Installing Ansible + git + curl..."
apt-get update
apt-get install -y ansible git curl ca-certificates

# Internal CA (private Forgejo/GitLab, TLS-inspecting proxy). Point CA_CERT at a
# PEM file already on the box; it is installed into the system trust store so
# git, curl and apt all trust it. Needed BEFORE the clone below.
if [ -n "${CA_CERT:-}" ]; then
  if [ -f "$CA_CERT" ]; then
    install -m 0644 "$CA_CERT" "/usr/local/share/ca-certificates/$(basename "${CA_CERT%.*}").crt"
    update-ca-certificates >/dev/null
    echo "[*] Installed CA into the system trust store: $CA_CERT"
  else
    echo "ERROR: CA_CERT=$CA_CERT not found." >&2; exit 1
  fi
fi

echo "[*] Installing roles + collections from requirements.yml..."
# Fetched with GIT, not a raw-file URL. Every forge spells raw URLs differently
# (GitHub raw.githubusercontent.com vs Forgejo/Gitea /raw/branch/<b>/ vs GitLab
# /-/raw/<b>/), and hardcoding one of them meant a mirror silently pulled its
# requirements from the ORIGINAL host -- or failed outright on an internal-only
# network. Cloning uses the same URL, auth and TLS trust as the ansible-pull below.
TMP_CLONE="$(mktemp -d)"
git clone --quiet --depth 1 --branch "$BRANCH" "$REPO_URL" "$TMP_CLONE" || {
  echo "ERROR: could not clone $REPO_URL (branch $BRANCH)." >&2
  echo "  TLS 'unable to get local issuer certificate' => the box does not trust" >&2
  echo "  the server's CA. Install it first (see docs/procedures.md §1):" >&2
  echo "    sudo cp your-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates" >&2
  exit 1
}
if [ -f "$TMP_CLONE/requirements.yml" ]; then
  ansible-galaxy install -r "$TMP_CLONE/requirements.yml"
else
  echo "[!] no requirements.yml in the repo -- skipping galaxy install"
fi
rm -rf "$TMP_CLONE"

# Run the build DETACHED as a transient systemd service. On desktop the hardening
# restarts GDM mid-run; a foreground process launched from the GUI session (e.g.
# this curl|bash in a terminal) would be killed by that restart, leaving the box
# half-hardened. systemd-run decouples it so the build survives regardless of
# profile.
echo "[*] Starting provision + harden + scan as systemd unit 'stig-build'..."
systemctl reset-failed stig-build 2>/dev/null || true
systemd-run --unit=stig-build --collect \
  ansible-pull -U "$REPO_URL" -C "$BRANCH" -i localhost, local.yml "${EXTRA_ARGS[@]}"

echo
echo "[✓] Build started in the background as systemd unit 'stig-build'."
echo "    Watch it:     sudo journalctl -u stig-build -f"
echo "    Result:       systemctl status stig-build   (active(exited) = success)"
if [[ "${PROFILE}" == "ai" ]]; then
  echo "    Reports:      /var/log/stig-scan/  — 'usg audit' output (collect BEFORE air-gapping)."
  echo "    Host is prepped (Docker + NVIDIA + firewall). Deploy your prebuilt AI"
  echo "    compose stack (docker compose up -d) — Ansible does not manage the containers."
  echo "    Then REBOOT to apply USG hardening (and load the NVIDIA driver, if installed)."
elif [[ "${PROFILE}" == "baseline" ]]; then
  echo "    Reports:      /var/log/stig-scan/  — 'usg audit' output (collect BEFORE air-gapping)."
  echo "    Provisioned org accounts/groups/folders + USB->dta and hardened with USG"
  echo "    (no app installs, no RDP). Set each new account's password: sudo passwd <user>."
  echo "    Then REBOOT to apply USG hardening; the box comes up to GDM with the DCSA banner."
elif [[ "${PROFILE}" == "emi" || "${PROFILE}" == "emi-unclass" ]]; then
  echo "    Reports:      /var/log/stig-scan/  — 'usg audit' output (collect BEFORE air-gapping)."
  if [[ "${PROFILE}" == "emi-unclass" ]]; then
    echo "    Variant:      UNCLASSIFIED-only — FIPS + LUKS/TPM OFF, and 'usg fix' SKIPPED"
    echo "                  (USG audit report still written; ufw/dconf/banner hardening still applied)."
  else
    echo "    Variant:      classified-CAPABLE — FIPS on + LUKS/TPM auto-unlock."
    echo "                  (Select full-disk encryption at the Ubuntu install for LUKS.)"
  fi
  echo "    Camera + microphone are disabled in software — also disable them in BIOS."
  echo "    Imaging services (TFTP/DHCP/dnsmasq/OpenVPN) are installed but DISABLED;"
  echo "    their firewall ports are open — configure + enable a service to use it."
  echo "    Set each account's password (sudo passwd <user>), then REBOOT to apply USG."
else
  echo "    Reports:      /var/log/stig-scan/  — 'usg audit' output (collect BEFORE air-gapping)."
  echo "    RDP:          connect an RDP client to this host:3389 (TLS) and log in as a local user."
  echo "    Then REBOOT to apply USG hardening; the box comes up to GDM with the DCSA banner."
fi

echo
echo "    AFTER this first build, updates are one command -- no curl, no flags:"
echo "      sudo it-pull            light: config + scripts, no apt, no scan, no container touched"
echo "      sudo it-pull full       + packages and a fresh usg audit / SCAP scan"
echo "      sudo it-pull status     is this box behind the repo?"
