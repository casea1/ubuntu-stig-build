# ubuntu-stig-build

One-command imaging / config tool for Ubuntu 24.04 LTS. Run it on a fresh install while it still has internet, before air-gap. It:

- Installs the software for the machine's role.
- DoD-STIG-hardens with Canonical USG (`usg fix disa_stig`).
- Writes the compliance report.

Pick a profile, run one `curl | sudo bash`, reboot, collect the report from `/opt/ia`.

## Contents

- [Profiles](#profiles)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Documentation](#documentation)
- [Configuration](#configuration)
- [Repo layout](#repo-layout)
- [Notes](#notes)

## Documentation

This README is orientation. Detail lives under [`docs/`](docs/).

**By profile** (what it builds + its software list):

| Profile | Page |
|---|---|
| `development` workstation | **[Development Workstation](docs/dev-workstation.md)** |
| `ai` server | **[AI Server Profile](docs/ai-stack.md)** |

**Shared references** (both profiles):

| Guide | What's in it |
|---|---|
| **[Build & Imaging Guide](docs/build.md)** | Bare-metal build steps: **Track A** (dev workstation), **Track B** (two-node AI servers). |
| **[Operations & Reference](docs/operate.md)** | Operator manual: run steps, gotchas, STIG-gap remediation, accounts, TPM/LUKS, RDP, AI-stack quick reference + deep ops, USG/SCAP scans. |
| **[Security & Compliance](docs/compliance.md)** | For IA / DCSA: hardening posture, NIST 800-53 mapping, POA&M, "why no Docker STIG." |

Per-node config template: **[`docs/site.yml.example`](docs/site.yml.example)**.

## Profiles

Pick one with `deployment_profile` (or `PROFILE=` on `bootstrap.sh`). Default: **`development`**.

| Profile | For | What it builds |
|---|---|---|
| **`development`** | Engineering **workstation** | Dev toolchain + **GNOME desktop over RDP** (installs the GUI, so a server base works too) + browser VS Code (code-server) + Cockpit. |
| **`ai`** | Local-AI **inference server** | **Host prep only**: Docker + NVIDIA GPU stack + Cockpit + Portainer, with container inbound ports opened. Deploy the AI tools (vLLM / Open WebUI / pgvector / Docling) from your own prebuilt images + compose files. |

Both profiles harden with USG (both need an **Ubuntu Pro** token), create the org accounts/groups and the `/opt/ia` + `/opt/it` admin folders, and drop the USG report in **`/opt/ia`**. `desktop`/`server` are aliases for `development`/`ai`.

## Quick start

**1. Prerequisites.** Fresh Ubuntu 24.04 install with internet:

- **`development`**: Ubuntu **Desktop** (or Server), plus a local account whose name matches `dev_tools_user` in `group_vars/all.yml` (default `austin_case_adm`).
- **`ai`**: Ubuntu **Server**, with **Ubuntu Pro** selected during install.
- **Both** need an **Ubuntu Pro token**. `bootstrap.sh` prompts for it (hidden), or drop it in `/etc/ubuntu-advantage/pro-token` beforehand.

**2. Run one command** on the target:

```bash
# Development workstation (default profile):
curl -fsSL https://raw.githubusercontent.com/casea1/ubuntu-stig-build/main/bootstrap.sh | sudo bash

# AI server:
curl -fsSL https://raw.githubusercontent.com/casea1/ubuntu-stig-build/main/bootstrap.sh | sudo PROFILE=ai bash

# AI server, audit-only first pass (installs USG + writes the report, but does NOT apply `usg fix` yet):
curl -fsSL https://raw.githubusercontent.com/casea1/ubuntu-stig-build/main/bootstrap.sh | sudo PROFILE=ai HARDEN=0 bash
```

Pipeline runs as detached systemd unit `stig-build`. The `development` run also prompts (hidden) for the disk-encryption password to enable TPM auto-unlock (Enter to skip).

**3. Watch it, then collect the report:**

```bash
sudo journalctl -u stig-build -f
systemctl status stig-build        # active (exited) = success
```

On finish, grab the USG report from **`/opt/ia/`** (admin-readable) **while still online**, then **reboot** to apply USG (and load the GPU driver on `ai`). The `development` box boots to a graphical login with the DCSA banner; on `ai`, deploy your prebuilt compose stack.

> New to this? Start with the **[Build & Imaging Guide](docs/build.md)**.

## How it works

Ansible roles run in a deliberate order: install → configure → dev tools → harden → scan. Order matters: hardening tightens `umask`, sets `noexec` on `/tmp`, and locks down PAM (breaks package/pip installs if it runs first), and compliance content must download while online.

| Stage | Role | What it does |
|-------|------|--------------|
| 1. Install | `base_packages` | Core tooling (ClamAV, OpenSCAP, Wireshark, Python, PowerShell, provisioning services) |
| 2. Configure | `app_config` | Service config + access controls (ClamAV, Wireshark capture group) |
| 3. Accounts | `local_accounts` | Org users/groups, ACL'd shared folders, USB→`dta` policy |
| 4. Dev tools | `dev_tools` *(development)* | Compilers, `/opt/eng-venv`, VS Code extensions, Docker |
| 4. Host prep | `ai_stack` *(ai)* | Docker + NVIDIA GPU stack + Portainer |
| 5. Harden | `usg_harden` → `desktop_hardening`/`ai_firewall` → `usg_remediate` | `usg fix disa_stig` + FIPS, then GUI/USB/firewall re-assert, then idempotent residual fixes |
| 6. Report | `usg audit` (re-run by `usg_remediate`) | Compliance report → `/opt/ia` |

Full role-by-role detail, the STIG-gap coverage table, and every documented deviation/POA&M are in **[Operations & Reference](docs/operate.md)** and **[Security & Compliance](docs/compliance.md)**.

## Configuration

Toggle everything from **[`group_vars/all.yml`](group_vars/all.yml)**: profile selection, editor choice, STIG tunables (lockout counts, timeouts, audit retention), DCSA banner text, USG options (`usg_profile`, `usg_fix_enabled`, `usg_enable_fips`), NTP servers (`usg_chrony_servers`), Cockpit, and AI-server settings (`nvidia_*`, `portainer_enabled`, `ai_firewall_allow_ports`).

Per-node / per-site overrides (internal IPs, existing DB password, oikb secrets, firewall port openings) go in **`/etc/stig-build/site.yml`** on the box, see **[`docs/site.yml.example`](docs/site.yml.example)**. Package and VS Code extension lists live in `roles/dev_tools/defaults/main.yml`. Full config reference: **[Build Guide](docs/build.md)** and **[Operations & Reference](docs/operate.md)**.

## Repo layout

```
ubuntu-stig-build/
├── README.md              # this file (orientation)
├── bootstrap.sh           # one-command first-boot runner (detached)
├── local.yml              # ansible-pull entrypoint (role run order)
├── requirements.yml       # pinned external roles
├── group_vars/all.yml     # all toggles
├── docs/                  # build, operations & compliance guides + site.yml.example
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

- **Run while online, then air-gap.** Build needs internet (apt, USG content). Collect reports before disconnecting.
- **Reboot after hardening** so all controls (PAM, mounts, GRUB, banner, FIPS) take effect, then re-run the audit for accurate post-reboot results.
- **Validate on a throwaway VM** before imaging production hardware. USG's DISA profile can make breaking changes; confirm you can still log in / RDP after `usg fix` + reboot.
- **Re-running is safe and idempotent.** After changing a setting or adding software, push and re-run the same `stig-build` command; Ansible applies only the *delta*. Use the detached run method (hardening restarts GDM), and reboot afterward for settings that need it.
