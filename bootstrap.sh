#!/usr/bin/env bash
# First-boot bootstrap for imaging an Ubuntu 24.04 STIG box.
# Run once, while the machine has internet.
#
#   DEVELOPMENT (default) -- engineering workstation with a GNOME desktop reached
#   over RDP (xrdp). Works on a headless server base (it installs the GUI):
#     curl -fsSL https://raw.githubusercontent.com/casea1/ubuntu-stig-build/main/bootstrap.sh | sudo bash
#
#   AI -- Ubuntu Pro AI server (USG DISA-STIG + selectable AI stack). Pass options
#   as environment variables (piped bash can't take flags):
#     curl -fsSL .../bootstrap.sh | sudo PROFILE=ai TOOLS=docker,vllm,open_webui,pgvector,docling bash
#
# Recognised environment variables:
#   PROFILE=development|ai   which build to run                 (default: development)
#                           (aliases: desktop->development, server->ai)
#   TOOLS=a,b,c             ai only: which AI tools to install
#                           (docker,vllm,open_webui,pgvector,docling; default: all)
#   PRO_TOKEN=<token>       ai only: Ubuntu Pro token (else you're prompted)
#   HF_TOKEN=<token>        ai only: Hugging Face token for gated models (optional)
#   HARDEN=0                ai only: install the stack but SKIP `usg fix`
#                           (audit-only; flip to validate before hardening)
#
# It also prompts (hidden) for the disk encryption password to enable TPM
# auto-unlock (either profile). Press Enter at any prompt to skip.
# Edit REPO_URL before baking into your image.

set -euo pipefail

REPO_URL="https://github.com/casea1/ubuntu-stig-build.git"
BRANCH="main"
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

if [[ "${PROFILE}" != "development" && "${PROFILE}" != "ai" ]]; then
  echo "PROFILE must be 'development' or 'ai' (got '${PROFILE}')." >&2
  exit 1
fi

echo "[*] Deployment profile: ${PROFILE}"

# --- Extra vars passed to ansible-pull (built up below) ----------------------
EXTRA_ARGS=(-e "deployment_profile=${PROFILE}")

# --- AI: Ubuntu Pro token (secret, out-of-band) ------------------------------
# USG needs the box Pro-attached. Collect the token HERE (interactively) and drop
# it where the usg_harden role reads it. Skipped if already present, already
# attached, or supplied via PRO_TOKEN. The token is NEVER placed in the repo.
if [[ "${PROFILE}" == "ai" ]]; then
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

  # Optional Hugging Face token for gated model downloads (vLLM).
  if [[ -n "${HF_TOKEN:-}" ]]; then
    install -d -m 700 /etc/ai-stack
    printf '%s' "${HF_TOKEN}" > /etc/ai-stack/hf_token
    chmod 600 /etc/ai-stack/hf_token
    echo "[*] Hugging Face token saved for gated model downloads."
    unset HF_TOKEN
  fi

  # Tool selection -> JSON list extra-var.
  if [[ -n "${TOOLS:-}" ]]; then
    JSON_TOOLS=""
    IFS=',' read -ra _tool_arr <<< "${TOOLS}"
    for t in "${_tool_arr[@]}"; do
      t="$(echo "$t" | tr -d '[:space:]')"
      [[ -z "$t" ]] && continue
      JSON_TOOLS="${JSON_TOOLS:+${JSON_TOOLS},}\"${t}\""
    done
    EXTRA_ARGS+=(-e "{\"server_tools\": [${JSON_TOOLS}]}")
    echo "[*] AI tools selected: ${TOOLS}"
  fi

  # HARDEN=0 -> install everything but don't run the disruptive `usg fix`.
  if [[ "${HARDEN:-1}" == "0" ]]; then
    EXTRA_ARGS+=(-e "usg_fix_enabled=false")
    echo "[*] HARDEN=0 -> USG will AUDIT only (no fix)."
  fi
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

echo "[*] Installing roles + collections from requirements.yml..."
TMP_REQ="$(mktemp --suffix=.yml)"   # ansible-galaxy requires a .yml/.yaml extension
curl -fsSL "https://raw.githubusercontent.com/casea1/ubuntu-stig-build/${BRANCH}/requirements.yml" -o "$TMP_REQ"
ansible-galaxy install -r "$TMP_REQ"
rm -f "$TMP_REQ"

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
echo "    Watch it:     journalctl -u stig-build -f"
echo "    Result:       systemctl status stig-build   (active(exited) = success)"
if [[ "${PROFILE}" == "ai" ]]; then
  echo "    Reports:      /var/log/stig-scan/  — 'usg audit' output (collect BEFORE air-gapping)."
  echo "    AI stack:     cd /opt/ai-stack && docker compose ps   (once images finish pulling)."
  echo "    Then REBOOT to apply USG hardening (and load the NVIDIA driver, if installed)."
else
  echo "    Reports:      /var/log/stig-scan/  — collect BEFORE air-gapping."
  echo "    RDP:          connect an RDP client to this host:3389 (TLS) and log in as a local user."
  echo "    Then reboot to apply hardening; the box comes up to GDM with the DCSA banner."
fi
