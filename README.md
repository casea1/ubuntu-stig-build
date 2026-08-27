# ubuntu-stig-build

One-command imaging / config tool for Ubuntu 24.04 LTS. Run it on a fresh install while it still has internet, before air-gap. It:

- Installs the software for the machine's role.
- DoD-STIG-hardens with Canonical USG (`usg fix disa_stig`).
- Writes the compliance report.

Pick a profile, run one `curl | sudo bash`, reboot, collect the report from `/opt/ia`.

## Contents

- [Documentation](#documentation)
- [Profiles](#profiles)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Configuration](#configuration)
- [Repo layout](#repo-layout)

## Documentation

This README is orientation. Everything else is one of three documents:

| Document | For |
|---|---|
| **[Procedures](docs/procedures.md)** | **Start here.** Every task as numbered steps — build, deploy, patch, scan, recover. |
| **[Reference](docs/reference.md)** | Lookup: the traps that have cost us a box, every `it-*` command, paths, config variables, AI-stack ports and volumes, software inventory. |
| **[Security & Compliance](docs/compliance.md)** | For IA / DCSA: hardening posture, the org checklist, NIST 800-53 mapping, POA&M, why there is no Docker STIG. |

Per-node config template: **[`docs/site.yml.example`](docs/site.yml.example)**.

## Profiles

Pick one with `deployment_profile` (or `PROFILE=` on `bootstrap.sh`). Default: **`development`**.

| Profile | For | What it builds |
|---|---|---|
| **`development`** | Engineering **workstation** | Dev toolchain + **GNOME desktop over RDP** (installs the GUI, so a server base works too) + browser VS Code (code-server) + Cockpit. |
| **`ai`** | Local-AI **inference server** | Docker + NVIDIA GPU stack + Cockpit + Dockge, with container ports opened, plus the AI compose stacks (vLLM / Open WebUI / pgvector / Docling / MLflow / …) written to `/opt/stacks/`. Two nodes; the hostname picks the role. |
| **`baseline`** | An **already-built** box (software already installed) | **Provision + harden only, no app installs, no RDP**: org accounts/groups/ACL'd folders + USB→`dta`, `/opt/ia` + `/opt/it`, Cockpit, USG, and the GUI-preserving fixups (graphical target, GDM banner, GNOME dconf, USB re-enable). For a hand-built Ubuntu **Desktop** endpoint logged into locally. |
| **`emi`** / **`emi-unclass`** | Local-GUI imaging/**field workstation** | The `development` app set + `dev_tools` **minus RDP**, plus VPN/recon/CJK-IME extras, an imaging-service firewall (DHCP/TFTP/DNS/OpenVPN), and a **camera + microphone lockdown**. Local desktop only, with wallpaper + classification banner. Two variants: **`emi`** is classified-capable (FIPS + LUKS/TPM on, full `usg fix`); **`emi-unclass`** is unclassified-only (FIPS/LUKS off and the disruptive `usg fix` skipped — USG audit + ufw/dconf/banner hardening still apply). |

All profiles harden with USG (all need an **Ubuntu Pro** token), create the org accounts/groups and the `/opt/ia` + `/opt/it` admin folders, and drop the USG report in **`/opt/ia`**. `desktop`/`server` are aliases for `development`/`ai`; `emi-unclass` is the unclassified variant of `emi`.

## Quick start

**1. Prerequisites.** Fresh Ubuntu 24.04 install with internet:

- **`development`**: Ubuntu **Desktop** (or Server), plus a local account whose name matches `dev_tools_user` in `group_vars/all.yml` (default `austin_case_adm`).
- **`ai`**: Ubuntu **Server**, with **Ubuntu Pro** selected during install.
- **`baseline`**: an already-configured Ubuntu **Desktop** with your software already installed — the build adds only org provisioning + USG hardening.
- **All** need an **Ubuntu Pro token**. `bootstrap.sh` prompts for it (hidden), or drop it in `/etc/ubuntu-advantage/pro-token` beforehand.

**2. Trust the lab CA.** The forge uses an internal CA, so a fresh machine must
trust it before it can fetch anything over HTTPS. Once per target:

```bash
sudo curl -fsSLo /usr/local/share/ca-certificates/lab-root-ca.crt \
  http://git.asplab.com/lab-root-ca.crt
sudo update-ca-certificates
```

Verify you got the real one before trusting it -- the SHA-1 fingerprint must be
`03:DD:DD:55:C6:34:F5:8F:2D:1B:6B:25:D2:ED:73:93:54:A8:AE:F9`:

```bash
openssl x509 -in /usr/local/share/ca-certificates/lab-root-ca.crt -noout -fingerprint -sha1
```

**3. Run one command** on the target:

```bash
# Development workstation (default profile):
curl -fsSL https://git.asplab.com/ASPLAB/ubuntu-stig-build/raw/branch/main/bootstrap.sh | sudo bash

# AI server:
curl -fsSL https://git.asplab.com/ASPLAB/ubuntu-stig-build/raw/branch/main/bootstrap.sh | sudo PROFILE=ai bash

# Baseline: harden + provision an already-built box (no app installs, no RDP):
curl -fsSL https://git.asplab.com/ASPLAB/ubuntu-stig-build/raw/branch/main/bootstrap.sh | sudo PROFILE=baseline bash

# EMI imaging/field workstation (classified-capable / unclassified-only):
curl -fsSL https://git.asplab.com/ASPLAB/ubuntu-stig-build/raw/branch/main/bootstrap.sh | sudo PROFILE=emi bash
curl -fsSL https://git.asplab.com/ASPLAB/ubuntu-stig-build/raw/branch/main/bootstrap.sh | sudo PROFILE=emi-unclass bash

# AI server, audit-only first pass (installs USG + writes the report, but does NOT apply `usg fix` yet):
curl -fsSL https://git.asplab.com/ASPLAB/ubuntu-stig-build/raw/branch/main/bootstrap.sh | sudo PROFILE=ai HARDEN=0 bash
```

Pipeline runs as detached systemd unit `stig-build`. The `development` run also prompts (hidden) for the disk-encryption password to enable TPM auto-unlock (Enter to skip).

**4. Watch it, then collect the report:**

```bash
sudo journalctl -u stig-build -f
systemctl status stig-build        # active (exited) = success
```

On finish, grab the USG report from **`/opt/ia/`** (admin-readable) **while still online**, then **reboot** to apply USG (and load the GPU driver on `ai`). The `development` box boots to a graphical login with the DCSA banner; on `ai`, fetch the models and run `sudo it-ai up`.

> Full step-by-step, including what to decide before you install: **[Procedures §1](docs/procedures.md#1-build-a-box)**.

## How it works

Ansible roles run in a deliberate order: install → configure → dev tools → harden → scan. Order matters: hardening tightens `umask`, sets `noexec` on `/tmp`, and locks down PAM (breaks package/pip installs if it runs first), and compliance content must download while online.

| Stage | Role | What it does |
|-------|------|--------------|
| 1. Install | `base_packages` | Core tooling (ClamAV, OpenSCAP, Wireshark, Python, PowerShell, provisioning services) |
| 2. Configure | `app_config` | Service config + access controls (ClamAV, Wireshark capture group) |
| 3. Accounts | `local_accounts` | Org users/groups, ACL'd shared folders, USB→`dta` policy |
| 4. Dev tools | `dev_tools` *(development)* | Compilers, `/opt/eng-venv`, VS Code extensions, Docker |
| 4. Host prep | `ai_stack` *(ai)* | Docker + NVIDIA GPU stack + Dockge |
| 5. Harden | `usg_harden` → `desktop_hardening`/`ai_firewall` → `usg_remediate` | `usg fix disa_stig` + FIPS, then GUI/USB/firewall re-assert, then idempotent residual fixes |
| 6. Report | `usg audit` (re-run by `usg_remediate`) | Compliance report → `/opt/ia` |

Every documented deviation and POA&M is in **[Security & Compliance](docs/compliance.md)**.

## Configuration

Toggle everything from **[`group_vars/all.yml`](group_vars/all.yml)**: profile selection, editor choice, STIG tunables (lockout counts, timeouts, audit retention), DCSA banner text, USG options (`usg_profile`, `usg_fix_enabled`, `usg_enable_fips`), NTP servers (`usg_chrony_servers`), Cockpit, and AI-server settings (`nvidia_*`, `dockge_enabled`, `ai_firewall_allow_ports`).

Per-node / per-site overrides (internal IPs, existing DB password, oikb secrets, firewall port openings) go in **`/opt/it/site.yml`** on the box (the build drops an editable template there; legacy `/etc/stig-build/site.yml` still works), see **[`docs/site.yml.example`](docs/site.yml.example)**. Package and VS Code extension lists live in `roles/dev_tools/defaults/main.yml`. The variables worth knowing are summarised in **[Reference](docs/reference.md#configuration)**.

## Repo layout

```
ubuntu-stig-build/
├── README.md              # this file (orientation)
├── bootstrap.sh           # one-command first-boot runner (detached)
├── local.yml              # ansible-pull entrypoint (role run order)
├── requirements.yml       # pinned external roles
├── group_vars/all.yml     # all toggles
├── docs/                  # procedures, reference, compliance + site.yml.example
└── roles/
    ├── base_packages/     # apt installs + PowerShell + provisioning services
    ├── app_config/        # clamav services, wireshark group
    ├── local_accounts/    # org users/groups, ACL'd shares, USB→dta
    ├── dev_tools/         # toolchains, /opt/eng-venv, VS Code, code-server
    ├── remote_desktop/    # GNOME + xrdp (development profile)
    ├── ai_stack/          # Docker + NVIDIA host prep (ai profile)
    ├── ai_firewall/       # opens container ports after USG (ai profile)
    ├── ai_compose/        # bakes the AI compose stack into /opt/it/docker (ai profile)
    ├── usg_harden/        # Ubuntu Pro attach + `usg fix disa_stig` + FIPS
    ├── usg_remediate/     # idempotent residual STIG fixes + re-audit
    ├── desktop_hardening/ # GNOME/GDM/USB carve-outs after USG (development)
    └── …                  # branding, managed_dirs, tpm_luks_unlock, gpu_fips_module, …
```

## Notes

- **Run while online, then air-gap.** The build needs internet (apt, USG content, the SCAP datastream). Collect reports before disconnecting.
- **Reboot after hardening**, then re-run the audit — PAM, mounts, GRUB, banner and FIPS only take effect after it.
- **Verify auth before that reboot** ([Procedures §1.6](docs/procedures.md#16-verify-auth-before-you-reboot)). A broken PAM stack found afterwards, with no session open, needs a live USB.
- **Validate on a throwaway VM** before imaging production hardware.
- **Re-running is safe and idempotent** — Ansible applies only the delta.
