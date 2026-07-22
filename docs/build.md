# Build & Imaging Guide

Runbook for building a box from bare metal through hardening and post-install. Two tracks:

- **Track A:** development workstation (Ubuntu 24.04 LTS Desktop).
- **Track B:** two-node AI server pair (`dev-ai1` / `dev-ai2`).

Follow the one track that matches your profile. [README.md](../README.md) is the overview; [operate.md](operate.md) is the subsystem reference.

> **Workstation model:** install Ubuntu, run one command (installs tooling, hardens to the DISA STIG,
> sets the DCSA banner, scans), collect the report, run the post-install checklist, reboot.

---

## Contents

- [Track A: Development Workstation](#track-a-development-workstation)
  - [1. Overview: what this build produces](#1-overview-what-this-build-produces)
  - [2. Before you start: prerequisites & decisions](#2-before-you-start-prerequisites--decisions)
  - [3. Phase 1: Install Ubuntu 24.04 LTS Desktop](#3-phase-1-install-ubuntu-2404-lts-desktop)
  - [4. One-time repo setup](#4-one-time-repo-setup)
  - [5. Phase 2: Run the build](#5-phase-2-run-the-build)
  - [6. What runs, in order (and why it's load-bearing)](#6-what-runs-in-order-and-why-its-load-bearing)
  - [7. Watch & confirm](#7-watch--confirm)
  - [8. Collect the SCAP reports: **before air-gapping**](#8-collect-the-scap-reports-before-air-gapping)
  - [9. Phase 3: After the build (in order)](#9-phase-3-after-the-build-in-order)
  - [10. POA&M & accepted deviations: the assessor checklist](#10-poam--accepted-deviations-the-assessor-checklist)
  - [11. Configuration reference (`group_vars/all.yml`)](#11-configuration-reference-group_varsallyml)
  - [12. Troubleshooting & quick reference](#12-troubleshooting--quick-reference)
- [Track B: AI Servers (two-node)](#track-b-ai-servers-two-node)
  - [Before you start](#before-you-start)
  - [Step 1: Install Ubuntu 24.04](#step-1-install-ubuntu-2404)
  - [Step 2: Per-node config (site.yml, only if needed)](#step-2-per-node-config-siteyml-only-if-needed)
  - [Step 3: Run the build](#step-3-run-the-build)
  - [Step 4: Fetch models & start the stack](#step-4-fetch-models--start-the-stack)
  - [Step 5: Connect & verify](#step-5-connect--verify)
  - [Step 6: Optional oikb knowledge sync](#step-6-optional-oikb-knowledge-sync)
  - [Switching the System 1 chat model](#switching-the-system-1-chat-model)
  - [Collect the compliance report](#collect-the-compliance-report)
  - [Troubleshooting](#troubleshooting)

---

## Track A: Development Workstation

DISA-STIG-hardened Ubuntu 24.04 LTS Desktop workstation. Three phases: install (manual), run (one command), afterward (a checklist).

### 1. Overview: what this build produces

DISA-STIG-hardened Ubuntu 24.04 LTS Desktop (GNOME) workstation with the DCSA Authorized Warning Banner, an OpenSCAP compliance report, org user/group accounts, USB locked to a data-transfer group, and optional TPM-bound auto-unlock for the encrypted disk. Runs as Ansible roles in a deliberate order:

| Stage | Role | What it does |
|------|------|--------------|
| 1 | `base_packages` | ClamAV, Wireshark, Python, PuTTY, OpenSCAP, editor, PowerShell, provisioning services |
| 2 | `app_config` | ClamAV daemon + scans, Wireshark capture group |
| 3 | `local_accounts` | org groups (`dta`/`audit`/`sentry`), locked user accounts, ACL'd shared folders, USB→`dta` |
| 4 | `dev_tools` | compilers, `/opt/eng-venv`, VS Code extensions, Docker |
| 5 | `classification_banner` | *optional:* persistent top/bottom classification bars |
| 6 | `stig_harden` | DISA STIG (lockdown role **v1.3.0**) + SSG gap-remediation + GNOME/GDM fixups + DCSA banner |
| 7 | `desktop_branding` | system-wide wallpaper (desktop + lock screen) |
| 8 | `tpm_luks_unlock` | *opt-in:* bind LUKS to the TPM for passphrase-free boot |
| 9 | `scap_scan` | OpenSCAP evaluation → HTML + STIG-Viewer + ARF reports |

Phases: install (manual), run (one command), afterward (a checklist).

---

### 2. Before you start: prerequisites & decisions

Decide these before install. Several are irreversible.

- [ ] **UEFI mode; decide Secure Boot now.** TPM auto-unlock (§9.4) requires **Secure Boot ON**. It's a
  firmware setting and PCR-7 sealing is meaningless without it. Can't be made meaningful retroactively.
- [ ] **Internet for the whole build.** apt (incl. Microsoft's VS Code repo), the pinned PowerShell `.deb`
  from GitHub, the ~175 MB SSG datastream, and `oscap --fetch-remote-resources` all need the network.
  Air-gap only after collecting reports. (`editor_choice: vim`/`neovim` instead of the default `vscode` is
  the only thing that drops an internet dependency.)
- [ ] **Repo must be public and reachable.** The install command pulls `bootstrap.sh` + `requirements.yml`
  from `raw.githubusercontent.com`; `ansible-pull` clones over unauthenticated HTTPS. Private/unreachable
  fails immediately.
- [ ] **Forked/renamed the repo:** update the `casea1` URL everywhere (§12) and push public.
- [ ] **Operator account name** must match `dev_tools_user` and `wireshark_users` in `group_vars/all.yml`
  (default **`austin_case_adm`**). See §3.4.
- [ ] **Build host uses the full `ansible` package, not `ansible-core`.** Gap-remediation tasks use
  `community.general` (pamd/pam_limits/ufw/ini_file) and `ansible.posix` (ACLs), which ship with `ansible`
  but not `ansible-core`. `bootstrap.sh` installs `ansible`; relevant only if you run manually.

---

### 3. Phase 1: Install Ubuntu 24.04 LTS Desktop

Manual installer work. None automated; some choices can't be fixed later.

**Order:** firmware (UEFI + Secure Boot), partition layout, encrypt, create `austin_case_adm`, hostname, clock.

#### 3.1 Media & firmware
- Install **Ubuntu 24.04.x LTS Desktop (GNOME)** in **UEFI** mode.
- Set **Secure Boot = ON** if TPM auto-unlock is planned (§9.4). Decide now.
- Connect to the **internet**.

#### 3.2 Disk encryption (LUKS): install-time only
In the installer choose **"Erase disk and use LVM"** and tick **"Encrypt the new Ubuntu installation for security."** Set a strong **LUKS passphrase**.

- **Record it and keep it forever.** It's the disk's recovery key and what TPM auto-unlock needs (supplied
  **out-of-band** via `luks_passphrase_file`, never in this public repo, §9.4). TPM auto-unlock *keeps* it as
  the recovery keyslot (never replaces it). Lose it, lose your only recovery.
- Encryption **cannot** be added after install. For unattended/fleet installs, bake LUKS into an Ubuntu
  autoinstall seed (see *Full-disk encryption at install time* in [operate.md](operate.md)). That seed is
  separate from this repo and the passphrase must be vaulted, never committed.

#### 3.3 STIG partition layout (recommended, install-time only)
DISA STIG wants **separate partitions** for `/home`, `/var`, `/var/log`, `/var/log/audit`, `/tmp`, `/var/tmp` with `nodev`/`nosuid`/`noexec` where applicable.

- **This repo does not create partitions or set mount options.** `filesystem.yml` only fixes ownership/permissions/sysctl on existing paths.
- Single-partition installs leave the separate-mount controls as **open findings** (track as POA&M).
- Lay these out now in the installer's manual partitioning. Can't be retrofitted cleanly.

#### 3.4 Create the operator account: **name must match the playbook**
Create the primary admin account named **exactly `austin_case_adm`** (default value of both `dev_tools_user` and the single `wireshark_users` entry in `group_vars/all.yml`).

- **Hand-created in the installer.** The playbook does **not** create it (deliberately excluded from
  `local_users`, which holds the other, locked org accounts).
- **If the name doesn't match:** the playbook still runs, but `app_config`/`dev_tools` use
  `ansible.builtin.user`, which **creates a new locked account** with the configured name and grants *it*
  the `wireshark`/`docker`/VS-Code memberships. The perks land on a stray account, not your login. For a
  different login name, edit `dev_tools_user` **and** `wireshark_users` in `group_vars/all.yml` before pushing.

#### 3.5 Other install settings
- **Hostname:** set a unique hostname (not the default `ubuntu`). It's tied to log/audit identity.
- **Clock/UTC:** hardening sets the RTC to UTC and swaps `systemd-timesyncd` for `chrony`. Install with a UTC-aligned clock.

**Phase 1 exit criteria:** fresh, UEFI, LUKS-encrypted, (ideally) STIG-partitioned Ubuntu 24.04.x Desktop, online, with `austin_case_adm` created.

---

### 4. One-time repo setup

Before the first run, review **`group_vars/all.yml`** (full reference §11):
- `wireshark_users`, `dev_tools_user`: match your operator account (§3.4).
- `editor_choice`: `vscode` (default) | `vim` | `neovim`.
- `ubtu24stig_cat3`: leave `false` until low-severity controls are validated.
- `stig_skip_tags`: add controls you must skip on Desktop (document each as a POA&M).
- *(optional, can wait until after the first clean run)* `grub_password_pbkdf2`, `tpm_luks_enabled`/`luks_passphrase`.

Forked repo: update the URLs (§12) and **push to a public repo**.

---

### 5. Phase 2: Run the build

On the target box, online:

```bash
curl -fsSL https://raw.githubusercontent.com/casea1/ubuntu-stig-build/main/bootstrap.sh | sudo bash
```

It prompts (hidden) for the disk encryption password to enable TPM auto-unlock: type it and press Enter, or press Enter to skip. (Auto-skips on a non-encrypted disk, an already-bound box, or a headless run.) Then `bootstrap.sh`, in order: installs `ansible git curl`; downloads `requirements.yml` and runs `ansible-galaxy install -r` (installs both the pinned `UBUNTU24-STIG` role **v1.3.0** and the `community.general` + `ansible.posix` collections); launches the build **detached** as transient systemd unit `stig-build` via `systemd-run`.

Detached because hardening restarts GDM mid-run, which would kill a foreground job from the GUI session. `systemd-run` decouples it. The `curl | bash` returns immediately; the build runs in the background.

**Manual alternative** (same effect): `sudo apt install -y ansible git curl`, then `sudo ansible-galaxy install -r requirements.yml` **(before `ansible-pull`, or the gap tasks fail mid-run)**, then `sudo systemd-run --unit=stig-build --collect ansible-pull -U <repo> -C main -i localhost, local.yml`.

---

### 6. What runs, in order (and why it's load-bearing)

`base_packages → app_config → local_accounts → dev_tools → classification_banner` *(if enabled)* `→ stig_harden → desktop_branding → tpm_luks_unlock` *(if `tpm_luks_enabled`)* `→ scap_scan`

Don't reorder. Hardening sets `noexec /tmp`, tightens `umask`, and locks down PAM; running it before the installs breaks apt/pip and group-sharing. `scap_scan` is **last** because it needs the internet (`--fetch-remote-resources`) before you air-gap.

---

### 7. Watch & confirm

```bash
sudo journalctl -u stig-build -f          # live log
systemctl status stig-build          # "active (exited)" = success
```

- Long run (dozens of installs, the ~140-lib `/opt/eng-venv`, the SSG bundle, a full oscap eval). No fixed
  duration; watch the log, don't assume a hang.
- **`oscap` exit code 2 is NOT a failure.** It means "scan ran, some rules failed," which is expected.
- **Findings are normal.** Triage into your POA&M (§10): Desktop-vs-Server STIG gaps, the dev
  toolchain/Docker, the disabled provisioning services, GRUB until you set the hash, AIDE on the first scan
  (§9.5), and the documented deviations.

---

### 8. Collect the SCAP reports: **before air-gapping**

Three artifacts land in **`/var/log/stig-scan/`**:
- `stig-report-<date>.html`: human-readable
- `stig-viewer-<date>.xml`: import into DISA STIG Viewer
- `stig-arf-<date>.xml`: full ARF results

Copy them off while still online. Air-gap last, after artifacts are collected and the post-install checklist is done. Re-scan later offline: run `oscap` without `--fetch-remote-resources` against the on-box `ssg-ubuntu2404-ds.xml`.

---

### 9. Phase 3: After the build (in order)

> **Ordering:** verify auth before the final reboot, with your current admin/root session still open.
> Collect reports before air-gap. Do GRUB/TPM as edit, push, re-run, reboot loops.

#### 9.1 Verify auth BEFORE you reboot
`pam.yml` applied account-lockout (faillock). With your **current session still open**, open a **new** terminal / fresh login and confirm:
```bash
sudo -v                              # confirm sudo still works
# optional: fail 3 logins to confirm lockout engages, then recover:
sudo faillock --user <name> --reset
```
`unlock_time=0` means only an admin reset clears a lockout. A broken PAM stack discovered *after* reboot with no session open can leave no recovery path. Don't skip this gate.

#### 9.2 Set passwords for the locked org accounts (at deploy, per machine)
Standing accounts are created **locked** (they exist but can't log in). On the fielded box:
```bash
sudo passwd overlord
sudo passwd austin_case_dta
sudo passwd adam_kabat_adm   # ...and _aud, _dta
sudo passwd pj_bates_adm     # ...and _aud
sudo passwd zac_mccamant_adm # ...and _aud, _dta
```
(10 accounts total, from `local_users`.) Deploy-time, per machine. Never baked into a gold image.

#### 9.3 GRUB bootloader password (closes 2 high findings)
Self-skips on the `CHANGEME` placeholder. To enable:
```bash
grub-mkpasswd-pbkdf2         # type the password twice; copy the grub.pbkdf2.sha512... token
ansible-vault encrypt_string 'grub.pbkdf2.sha512.10000.<salt>.<hash>' --name 'grub_password_pbkdf2'
```
Paste the `!vault` block over `grub_password_pbkdf2` in `group_vars/all.yml`, **push**, **re-run** the build, **then reboot**.

- Normal boot stays password-free (menuentries are `--unrestricted`); the password is required only to *edit* an entry.
- Keep `grub_superuser` to letters/underscores only.
- Test the hash on a throwaway VM before a gold image.

#### 9.4 TPM2 LUKS auto-unlock (on by default, per machine)
Passphrase-free boot via the TPM. **Secure Boot must be ON** (§3.1). `tpm_luks_enabled: true` by default; it binds only once it can read the install passphrase (never in this public repo). Two ways to supply it:

- **Interactive / manual install (easiest):** `bootstrap.sh` (§5) prompts for the disk password up front,
  hidden. Type it. It writes it to the file below for the build, which binds the TPM then deletes it.
- **Automated / autoinstall install:** have your **private autoinstall seed** write the passphrase to the
  same root-only file the role reads (`luks_passphrase_file`, default `/etc/luks/initial-passphrase`):
```yaml
# autoinstall user-data (PRIVATE install media, not this repo):
late-commands:
  - install -d -m 700 /target/etc/luks
  - printf '%s' 'YOUR-INSTALL-PASSPHRASE' > /target/etc/luks/initial-passphrase
  - chmod 600 /target/etc/luks/initial-passphrase
```
- With that file present, the build binds a **new** keyslot to **PCR 7** via `clevis` and **keeps your install passphrase as recovery** (never replaces it, §3.2).
- Without it, the build skips the bind (no failure).
- Test on one box first (manual: `sudo clevis luks bind -d /dev/<part> tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'` then `sudo update-initramfs -u -k all`).
- A firmware/Secure-Boot/shim change that alters the PCRs falls back to the passphrase prompt (not a brick). Re-bind if needed.
- TPM-only / no-PIN auto-unlock is a deliberate data-at-rest deviation (§10).
- Each box uses its **own** passphrase; the role **auto-deletes** `luks_passphrase_file` after a successful bind (`luks_passphrase_purge_after_bind: true`). Re-drop it only to re-bind.

#### 9.5 AIDE builds itself after the first boot
AIDE's database is **no longer built during the run** (hashing the whole disk would stall the build). A one-shot timer builds it **~5 minutes after the first boot**, at idle priority, in the background. Confirm later:
```bash
systemctl list-timers aide-init.timer
systemctl status aide-init.service
ls -l /var/lib/aide/aide.db          # exists once built
```
So the build-time scan's *"Build and Test AIDE Database"* rule is a **finding on the first scan**. Re-scan offline (§8) after the DB builds and it passes.

#### 9.6 Confirm state & final reboot
- **USB storage** works only for `dta`-group members; everyone else (incl. admins) uses `sudo mount`.
- **Wallpaper** is set system-wide on desktop + lock screen (set `branding_lockscreen_wallpaper: false` for
  the STIG blank lock screen).
- **Classification banner** level is `classification_banner_level` (default `UNCLASSIFIED`).
- **Reboot** to apply hardening. You should reach a GDM login showing the **DCSA banner**. (A hang at the
  boot splash is the known upstream `UBTU-24-200650` GDM bug, already worked around here.)

---

### 10. POA&M & accepted deviations: the assessor checklist

Hand these to your assessor as documented exceptions:

- **Disk encryption:** done at install time (LUKS), not by the playbook.
- **Separate mount partitions** (`/var`, `/var/log`, `/var/log/audit`, `/tmp`, `/home`): install-time; open findings if not partitioned (§3.3).
- **FIPS mode:** requires an Ubuntu Pro token; not enabled.
- **Smartcard / CAC + SSSD:** image is password-login only by decision; smartcard controls POA&M'd (the harmless GNOME lock-on-removal *is* set).
- **GUI login-banner TEXT:** the SSG OVAL pins the *DoD* Standard Mandatory Notice; this image shows the **DCSA** banner by requirement, so the text rule stays failing as an **approved deviation** (banner-enable passes).
- **Last-logon PAM notification:** `pam_lastlog` removed in 24.04, `pam_lastlog2` not in `noble`; POA&M.
- **Audit-log offload** (remote server / external media): disabled by default; set `stig_audit_remote_server` to enable au-remote.
- **GRUB password:** failing until you complete §9.3.
- **AIDE database:** first-scan finding; passes after the post-boot build (§9.5).
- **Blank screensaver overridden:** lock screen shows the wallpaper instead of blank (§9.6).
- **USB → `dta` group:** controlled-group access instead of blanket USB disable.
- **TPM-only LUKS auto-unlock** (if enabled): no-PIN auto-unlock is a data-at-rest deviation, mitigated only by Secure Boot (§9.4).
- **TFTP / DHCP / DNS:** installed but disabled (mission-need provisioning services).

---

### 11. Configuration reference (`group_vars/all.yml`)

All operator-facing knobs. Values with a **cap** fail the scan if exceeded.

**Tooling & users**
- `editor_choice: vscode`: `vscode` (needs internet) | `vim` | `neovim`.
- `wireshark_users: [austin_case_adm]`, `dev_tools_user: austin_case_adm`: **must match your operator account** (§3.4).
- `clamav_run_daemon`, `clamav_freshclam_*`: antivirus daemon + update cadence.

**STIG engine toggles**
- `ubtu24stig_cat1/cat2/cat3`: severity tiers (cat3 off by default).
- `ubtu24stig_disruption_high: false`: leave off until validated (the gap-remediation files cover what it skips).
- `dcsa_gui_banner`: the DCSA Authorized Warning Banner text (single-quoted, literal `\n`).

**STIG gap-remediation tunables**
- `pam_faillock_deny: 3`, `pam_faillock_unlock_time: 0`, `pam_faillock_fail_interval: 900`: account lockout.
- `stig_session_timeout: 900` *(cap ≤ 900)*, `stig_max_concurrent_sessions: 10`: session limits.
- `gnome_idle_delay_seconds: 600` *(cap: > 0 and ≤ 600)*, `gnome_lock_delay_seconds: 0`: screensaver lock.
- `stig_audit_space_left_action`, `stig_audit_admin_space_left_action`, `stig_audit_remote_server: ""`: auditd retention/offload.
- `stig_var_log_group: syslog` *(must be syslog)*, `stig_journal_dir_mode: "2640"` *(must be 2640, not 2750)*, `stig_journalctl_mode: "0740"`, `stig_kernel_dmesg_restrict: 1`.
- `stig_firewall_limit_ports`: ufw rate-limited inbound (default: ssh).

**Secrets (never commit to a public repo)** 🔒
- `grub_password_pbkdf2`: GRUB hash (opt-in; self-skips on `CHANGEME`). `grub_superuser` must be `[a-zA-Z_]+` (no digits/hyphens). Vault it.
- `luks_passphrase`: leave **empty** in this public repo. TPM auto-unlock (`tpm_luks_enabled: true` by default) reads the install passphrase **out-of-band** from `luks_passphrase_file` (default `/etc/luks/initial-passphrase`, written by your private autoinstall seed). See §9.4.

**Accounts / access / branding**
- `local_groups`, `local_users`, `local_shared_dirs`, `usb_access_group: dta`.
- `branding_wallpaper_dest`, `branding_lockscreen_wallpaper: true`.
- `classification_banner_enabled`, `classification_banner_level: UNCLASSIFIED`.

**Scan**
- `scap_profile`, `ssg_content_version: "0.1.81"`: compliance content (pinned).

---

### 12. Troubleshooting & quick reference

**Command cheat-sheet**
```bash
# Run / watch
curl -fsSL https://raw.githubusercontent.com/casea1/ubuntu-stig-build/main/bootstrap.sh | sudo bash
sudo journalctl -u stig-build -f ; systemctl status stig-build
sudo systemctl stop stig-build           # abort a run (then re-run; it's idempotent)

# Recover a locked-out account
sudo faillock --user <name> --reset

# Secrets
grub-mkpasswd-pbkdf2
ansible-vault encrypt_string '<value>' --name '<var>'

# TPM auto-unlock (manual equivalent). clevis-tpm2 is a SEPARATE package on 24.04
# (without it: "tpm2 is not a valid pin").
sudo apt install -y clevis clevis-luks clevis-initramfs clevis-tpm2 tpm2-tools
sudo clevis luks bind -d /dev/<part> tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'
sudo update-initramfs -u -k all

# Rotate the LUKS passphrase (independent of TPM unlock; re-vault luks_passphrase after).
# Full notes: operate.md -> "Rotating the LUKS passphrase".
sudo cryptsetup luksChangeKey /dev/<part>      # current passphrase, then new one twice

# Re-scan offline (after air-gap)
sudo oscap xccdf eval --profile <profile> --report report.html <on-box ssg-ubuntu2404-ds.xml>
```

**Symptoms**
- **Build "hangs" at `aideinit`:** fixed, AIDE now builds post-boot via `aide-init.timer` (§9.5). On an older
  revision, `sudo systemctl stop stig-build` and re-run after pulling the fix.
- **Boot hangs at the splash / GDM won't start:** the upstream `UBTU-24-200650` banner bug (the role writes
  the banner one-char-per-line). Worked around here (`ubtu24stig_200650: false`).
- **Lockout after hardening:** see faillock reset above; this is why §9.1 is a mandatory pre-reboot gate.
- **Re-running is safe:** every role is idempotent and the run is detached; re-run any time to converge, or
  after editing `grub_password_pbkdf2` / `luks_passphrase` / `tpm_luks_enabled` to apply them.

**Forked-repo URL checklist** (update every `casea1` reference, then push **public**):
- `bootstrap.sh`: `REPO_URL=` and the `curl` URL in its header comment
- `README.md`: the Quick-start `curl` one-liner
- `docs/operate.md`: the run block (the `curl` line and the `ansible-pull -U` line)
- `docs/build.md`: this guide's `curl` URLs (§5 and §12)

---

## Track B: AI Servers (two-node)

Build and configure the two AI servers from bare metal to a working chat system. Assumes the `ubuntu-stig-build` repo. Subsystem detail: [operate.md](operate.md).

### Before you start

- **Hardware:** 2× Dell Precision 7960. System 1 (`dev-ai1`) = 2× RTX 6000 Ada (48 GB). System 2 (`dev-ai2`) = 1 GPU.
- **Network:** the two boxes must reach each other; know their IPs (e.g. `192.168.1.102` / `.106`). An Ubuntu Pro token (for USG/FIPS). Internet during the build (or an internal mirror).
- **Hostname sets the role:** name the box **`dev-ai1`** or **`dev-ai2`**; everything else auto-derives.

### Step 1: Install Ubuntu 24.04

- Install **Ubuntu 24.04 LTS Server** with the standard **LVM + LUKS full-disk encryption** option.
- Set the hostname to `dev-ai1` or `dev-ai2`.
- Create the operator/admin account (e.g. `austin_case_adm`).
- Reboot into the OS.

Recommended, patch the base first:
```bash
sudo apt update && sudo apt full-upgrade -y && sudo reboot
```

### Step 2: Per-node config (site.yml, only if needed)

A correctly-named box usually needs **nothing** here. Add `/etc/stig-build/site.yml` only for exceptions: IPs (if hostnames don't resolve between the boxes), an existing DB password, oikb secrets, model fetch/deploy.

```bash
sudo install -d -m 0755 /etc/stig-build
sudo tee /etc/stig-build/site.yml >/dev/null <<'EOF'
# --- System 1 example ---
ai_system2_addr: "192.168.1.106"     # if dev-ai2 doesn't resolve by name
ai_pgvector_password: "gelab_24"     # ONLY if reusing an already-initialised DB
ai_model_fetch: true                 # download the models during the build
ai_compose_deploy: true              # start the stack during the build
# firewall: open the ports this node serves (see docs/site.yml.example)
EOF
```
Full reference: [`site.yml.example`](site.yml.example). On **System 2**, set the cross-node firewall + oikb secrets there.

### Step 3: Run the build

```bash
curl -fsSL https://raw.githubusercontent.com/casea1/ubuntu-stig-build/main/bootstrap.sh | PROFILE=ai bash
```
Grows the disk, installs Docker + NVIDIA + hardens Docker, attaches Ubuntu Pro and STIG-hardens with FIPS (**FIPS needs a reboot**; the build flags it), bakes the node's compose into `/opt/it/docker`, builds the custom images (System 2), and (if the toggles are set) fetches models and starts the stack. Watch: `sudo journalctl -u stig-build -f`. **Reboot** when it finishes.

### Step 4: Fetch models & start the stack

If you didn't set `ai_model_fetch`/`ai_compose_deploy` in `site.yml`, do it now on each box:

```bash
cd /opt/it/docker
# (models auto-fetch on the build if ai_model_fetch: true; otherwise the build placed the empty volumes)
sudo docker compose up -d          # start the node's services
sudo ./switch-model.sh gpt-oss     # System 1 only: load the default chat model
```
gpt-oss-120B is ~200 GB; the first fetch is long. System 2's embedding/vision models are small.

### Step 5: Connect & verify

- **System 2 first** (System 1 depends on it): `docker compose ps`, embed/vision/docling/tika/lgtm/oikb healthy.
- **System 1:** `docker compose ps`, vllm/open-webui/redis/pgvector healthy; `curl -s http://localhost:8000/v1/models` lists the chat model.
- **Browse:** Open WebUI at `http://dev-ai1:3000`. Create the first (admin) account. The chat model appears in the dropdown; embeddings/vision/Docling are wired to System 2 via env (or set them in **Admin → Settings → Connections/Documents** if you blanked the env).
- **Monitoring:** Grafana at `http://dev-ai2:3001` (admins).

### Step 6: Optional oikb knowledge sync

oikb (System 2) syncs data sources into Open WebUI knowledge bases. To enable: create an **API key** in Open WebUI (Settings → Account), put it + your GitLab URL/token in System 2's `site.yml` (`ai_oikb_openwebui_api_key`, `ai_oikb_gitlab_url`, `ai_oikb_gitlab_token`), edit `/opt/it/docker/.oikb.yaml` to map sources → KBs, re-run the build (or `docker compose up -d`), then `docker compose restart oikb`.

### Switching the System 1 chat model

gpt-oss-120B and Granite-4.1-30B are **alternates** (only one fits in VRAM):
```bash
cd /opt/it/docker
sudo ./switch-model.sh granite    # or gpt-oss ; or status
```
Don't run a bare `docker compose up -d` while on Granite; it would also start gpt-oss and OOM the GPUs.

### Collect the compliance report

- After the build, the USG/SCAP report is in **`/opt/ia/`** (`usg-report-*.html` + XCCDF `.xml`).
- Grab it while online.
- Re-run on demand: `sudo usg audit --tailoring-file /etc/usg/managed-tailoring.xml`.
- Full detail: [operate.md](operate.md) → "Running a USG / SCAP compliance scan."

### Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Disk fills mid-build | `disk_expand` grows root automatically; if it didn't, check it's LVM (`docs` note). |
| A vLLM container crash-loops on `fips.so` / `FIPS SELFTEST` | Host FIPS vs the image's OpenSSL; the `fips_off` mount handles it; ensure it's present (`grep fips_off docker-compose.yaml`). |
| Model loads but no model in Open WebUI | tiktoken/harmony encodings missing (auto-fetched now) **and/or** add the `http://chat-llm:8000/v1` connection. |
| vLLM `Up` seconds then restarts | still loading (120B takes minutes) or OOM; check `docker logs vllm-server` + `nvidia-smi`. |
| Open WebUI can't reach System 2 (embed/vision/Docling) | set `ai_system2_addr` to dev-ai2's **IP** in `site.yml` (containers use their own DNS, not the host's `/etc/hosts`). With an IP set, the build auto-maps the name in the host `/etc/hosts` **and** the containers' `extra_hosts` (no manual editing). Also confirm the System 2 firewall opened 8002/8003/5001 from System 1. |

More detail for every subsystem: [operate.md](operate.md).
