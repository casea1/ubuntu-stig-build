# ubuntu-stig-build

Ansible-pull project that turns a **fresh Ubuntu 24.04 LTS Desktop (GNOME)** install into a
**DoD-STIG-hardened engineering workstation** in a single run: it installs the tooling, applies
the DISA STIG (CAT I + II) via [ansible-lockdown/UBUNTU24-STIG](https://github.com/ansible-lockdown/UBUNTU24-STIG),
and produces an OpenSCAP compliance report — all while the machine still has internet, before it
is moved to an air-gapped network.

You install Ubuntu, run one command, reboot, and collect the report.

---

## What it does

The work is split into Ansible roles that run in a **deliberate order** —
install → configure → dev tools → harden → scan. Order matters: hardening tightens `umask`, sets
`noexec` on `/tmp`, and locks down PAM, which breaks package/pip installs if it runs first; and the
compliance content must be downloaded while the box is still online.

| Stage | Role | What it does |
|-------|------|--------------|
| 1. Install | `base_packages` | Core tooling (below) |
| 2. Configure | `app_config` | Service config + access controls |
| 3. Accounts | `local_accounts` | Org users/groups, ACL'd shared folders, USB→`dta` policy |
| 4. Dev tools | `dev_tools` | Compilers, Python env, VS Code extensions |
| 5. Harden | `stig_harden` | DISA STIG remediation + SSG gap-fixes + GNOME fixups |
| 6. Branding | `desktop_branding` | System-wide wallpaper (desktop + lock screen) |
| 7. Scan | `scap_scan` | OpenSCAP evaluation → reports |

### 1. `base_packages` — core tooling
- **Security/scan:** ClamAV (daemon + freshclam), OpenSCAP (`oscap`), OpenSSH client
- **Network/analysis:** Wireshark + `tshark`, PuTTY (GUI) + `putty-tools` (`plink`/`pscp`/`psftp`)
- **Languages/editors:** Python 3.12, your editor (VS Code by default; `vim`/`neovim` selectable), Git
- **PowerShell 7.4.16 LTS** (`pwsh`) — required by the PowerStrux auditing tool; pinned `.deb`
- **Network provisioning services** — `tftpd-hpa`, `isc-dhcp-server`, `dnsmasq`, installed but
  left **disabled + stopped** (enable deliberately once configured for your network)

### 2. `app_config` — service config + access controls
- Starts the ClamAV daemon + freshclam definition updates + a weekly scan timer
- Restricts packet capture to a `wireshark` group and locks down `dumpcap` (STIG requirement)

### 3. `local_accounts` — org users, groups & access control
- Creates the access groups **`dta`** (USB storage), **`audit`** (owns `/opt/_AuditFiles`),
  **`sentry`** (owns `/home/shared`) and the standing user accounts (defined in `group_vars`),
  each created with a **locked password** — set per-machine at deploy with `sudo passwd <user>`
- Group-shared folders use setgid **+ POSIX default ACLs** so group sharing survives the STIG
  `umask 077` (which would otherwise make new files `0600`)
- **Restricts USB storage to the `dta` group** (udisks2 polkit + udev rule) — out of the box USB
  was only de-auto-mounted, not access-controlled. See
  [OPERATIONS.md](OPERATIONS.md#local-accounts-access-groups--branding)

### 4. `dev_tools` — engineering workstation layer
- **Toolchains:** `build-essential` (gcc/g++/make), `gdb`, `cmake`, GNAT (Ada), .NET SDK 8.0,
  Docker engine, Doxygen/Graphviz, a JRE (for UMLet)
- **Shared Python environment** at `/opt/eng-venv` with ~140 libraries (data science +
  network automation: NumPy/Pandas/SciPy/JupyterLab/Flask, NAPALM/Netmiko/Scapy/ncclient/
  junos-eznc, …). Exposed as a system-wide Jupyter kernel **"Eng (Python 3.12)"** and an
  `eng` shell command. Users don't need to know the path — VS Code and Jupyter are pre-wired.
- **26 VS Code extensions** (C/C++, C#/.NET, CMake, Python/Pylance, Ada & SPARK, GitLens,
  Docker, Remote-SSH, …) installed and seeded into `/etc/skel` so any account inherits them
- Adds the primary user to the `docker` group

### 5. `stig_harden` — hardening
- Imports the **UBUNTU24-STIG** Lockdown role (pinned to **v1.3.0**), applying **CAT I + II**
  (CAT III off by default; `disruption_high` off so the most breaking controls are skipped)
- Adds the GNOME/GDM pieces the *server* STIG omits: the **DCSA login banner**, idle screen lock,
  screensaver concealment, and disabling the Ctrl-Alt-Del logout key
- **Closes the SSG/ComplianceAsCode `stig`-profile findings the Lockdown role skips** with a
  set of idempotent, desktop-safe gap-remediation task files (`tasks/audit|pam|sessions|gnome|
  ssh|services|filesystem|grub.yml`): full auditd rule set, PAM faillock, session limits, GNOME
  dconf locks, sshd, chrony/ufw/AIDE, file/journal perms, and the GRUB2 bootloader password.
  See [STIG gap remediation](OPERATIONS.md#stig-gap-remediation-ssg-scan-findings) for the
  coverage table and the **POA&M list** (FIPS, smartcard, disk encryption, …).
- Works around three upstream bugs in the role's GNOME dconf controls (see
  [Known issues & exceptions](#known-issues--exceptions))

### 6. `desktop_branding` — system-wide wallpaper
- Deploys `SHB_Background.jpg` to `/usr/share/backgrounds/` and sets it **locked, system-wide** on
  the desktop background and the **session lock screen** — the lock-screen part overrides the STIG
  blank-screensaver control (documented deviation). GDM login background is best-effort (Ubuntu's
  greeter usually ignores it).

### 7. `scap_scan` — compliance report
- Fetches the **Ubuntu 24.04 SCAP Security Guide datastream** from SSG release **v0.1.81**
  (checksum-verified) — the distro's `ssg-debderived` package only ships content through 22.04
- Runs `oscap` against the DISA STIG profile and writes, to `/var/log/stig-scan/`:
  - `stig-report-<date>.html` — human-readable report
  - `stig-viewer-<date>.xml` — importable into DISA STIG Viewer
  - `stig-arf-<date>.xml` — full ARF results

---

## Quick start

**Prerequisites:** a freshly installed Ubuntu 24.04.4 Desktop with internet access, and a local
account whose name matches `dev_tools_user`/`wireshark_users` in `group_vars/all.yml`
(default `austin_case_adm`).

On the target machine, run:

```bash
curl -fsSL https://raw.githubusercontent.com/casea1/ubuntu-stig-build/main/bootstrap.sh | sudo bash
```

This installs Ansible + the Lockdown role, then runs the full pipeline as a detached systemd
unit named `stig-build` (detached so the GDM restart during hardening can't kill it). Watch it:

```bash
journalctl -u stig-build -f
systemctl status stig-build        # active (exited) = success
```

When it finishes, **collect the reports from `/var/log/stig-scan/` while still online**, then
reboot. The machine comes up to a graphical login showing the DCSA banner.

**New to this?** Start with the **[Imaging Guide](docs/imaging-guide.md)** — the complete end-to-end
runbook (Ubuntu install → setup → run → post-install checklist → troubleshooting). See
**[OPERATIONS.md](OPERATIONS.md)** for subsystem deep-dives and gotchas.

---

## Configuration

Everything is toggled from **[`group_vars/all.yml`](group_vars/all.yml)**:

- `wireshark_users` — local accounts allowed to capture packets
- `editor_choice` — `vscode` | `vim` | `neovim`
- `ubtu24stig_cat1` / `cat2` / `cat3` — which STIG severity tiers to apply
- `ubtu24stig_disruption_high` — apply the high-impact controls (off until validated)
- `dcsa_gui_banner` — the login banner text (DCSA Authorized Warning Banner)
- **`STIG GAP-REMEDIATION TUNABLES`** section — lockout counts, session/screensaver timeouts,
  auditd retention, firewall ports, etc. for the `tasks/*.yml` gap files (STIG-safe defaults)
- **`grub_password_pbkdf2`** — vaulted GRUB bootloader-password hash. Ships as a `CHANGEME`
  placeholder; the GRUB task self-skips until you set a real hash (see OPERATIONS.md). **Set
  this** to close the two GRUB findings.
- `dev_tools_user`, `eng_venv_path`, `powershell_version` — dev-tooling settings
- `scap_profile`, `ssg_content_version` — which compliance content to scan against

Package and VS Code extension lists live in `roles/dev_tools/defaults/main.yml`. The dev-tooling
layer is documented in [docs/dev-tools-design.md](docs/dev-tools-design.md).

### Classification banner

A persistent **top + bottom on-screen classification banner** is included (default
**UNCLASSIFIED**). This is *not* a STIG control — it's a classified-system / accreditation
requirement. **To change the level, edit `group_vars/all.yml`:**

- `classification_banner_level` — `UNCLASSIFIED` | `CUI` | `FOUO` | `CONFIDENTIAL` | `SECRET` |
  `"TOP SECRET"` | `SCI`. The level text and DoD-standard colors are defined in
  `roles/classification_banner/files/classification-banner.conf` (add your own section there for
  custom markings).
- `classification_banner_enabled` — set `false` to omit the banner entirely.
- `classification_banner_force_xorg` — the docked banner needs an **Xorg** session; `true` (default)
  forces GDM to Xorg, since Wayland ignores the dock/strut hints.

Change the value, commit/push, and re-run the build on the machine (it's idempotent — see Notes).

---

## Known issues & exceptions

This box is a **GNOME Desktop** running a STIG written for **Ubuntu Server**, plus an engineering
toolchain — so some findings are expected and documented as mission-need exceptions:

- **Desktop vs. Server:** DISA only publishes a *Server* 24.04 STIG. GNOME/GDM/graphical-target
  controls are handled or accepted as exceptions; triage the HTML report after the first scan.
- **Developer workstation:** compilers (`gcc`/`g++`/GNAT), Docker engine, and `docker`-group
  membership are required for development and are documented exceptions.
- **Network services:** `tftpd-hpa`/`isc-dhcp-server`/`dnsmasq` are installed (disabled) for
  provisioning use and will appear as scan findings.
- **Upstream role bugs (worked around):** the Lockdown v1.3.0 GNOME controls `UBTU-24-200650`
  (banner), `UBTU-24-200043` (`picture-uri`), and `UBTU-24-300025` (`logout`) write malformed
  dconf that breaks GDM; they are disabled and re-implemented correctly in `stig_harden`.

A pristine single-partition install will also flag the separate-mount controls (`/tmp`, `/var`,
`/var/log`, `/var/log/audit`, `/home`); partition manually at install time to satisfy them.

---

## Repo layout

```
ubuntu-stig-build/
├── README.md              # this file
├── OPERATIONS.md          # imaging runbook + gotchas
├── bootstrap.sh           # one-command first-boot runner (detached)
├── local.yml              # ansible-pull entrypoint (role run order)
├── requirements.yml       # pulls ansible-lockdown/UBUNTU24-STIG @ 1.3.0
├── group_vars/all.yml     # all toggles
├── docs/                  # design + implementation notes
└── roles/
    ├── base_packages/     # apt installs + PowerShell + provisioning services
    ├── app_config/        # clamav services, wireshark group
    ├── dev_tools/         # toolchains, /opt/eng-venv, VS Code extensions
    ├── stig_harden/       # Lockdown role import + GNOME fixups
    └── scap_scan/         # SSG datastream fetch + oscap eval → reports
```

---

## Notes

- **Run while online, then air-gap.** The build needs internet (apt, the SSG datastream, remote
  OVAL). Collect the reports before disconnecting; `oscap` can re-scan offline afterward.
- **Reboot after hardening** for all controls (PAM, mounts, GRUB, banner) to take effect, then
  re-run the scan for accurate post-reboot results.
- Validate on a throwaway VM before imaging production hardware — the Lockdown role can make
  breaking changes.
- **Re-running is safe and idempotent.** After changing a setting or adding software, push and
  re-run the same `stig-build` command on the machine — Ansible applies only the *delta*
  (tasks already in the desired state report `ok` and do nothing; only changed/new tasks act).
  Use the detached run method (hardening restarts GDM), and reboot afterward for settings that
  need it (mounts, PAM, GRUB, the Xorg/Wayland switch).
