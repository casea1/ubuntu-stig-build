# Imaging Guide — Ubuntu 24.04 STIG Workstation

End-to-end runbook: from a blank machine, through the Ubuntu install, the hardening run, and
everything you do afterward. This is the single source of truth for building one of these boxes;
[README.md](../README.md) is the overview and [OPERATIONS.md](../OPERATIONS.md) holds the deep-dive
reference for individual subsystems.

> **The one-line model:** install Ubuntu → run one command → it installs tooling, hardens to the
> DISA STIG, sets the DCSA banner, and scans → you collect the report, do a short post-install
> checklist, and reboot.

---

## 1. Overview — what this build produces

A **DISA-STIG-hardened Ubuntu 24.04 LTS Desktop (GNOME)** engineering workstation with the **DCSA
Authorized Warning Banner**, an OpenSCAP compliance report, org user/group accounts, USB locked to a
data-transfer group, and an optional TPM-bound auto-unlock for the encrypted disk. It runs as a set
of Ansible roles in a deliberate order:

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

The three phases below are **install (manual) → run (one command) → afterward (a checklist)**.

---

## 2. Before you start — prerequisites & decisions

Decide these *before* you install, because several are irreversible:

- [ ] **Hardware/firmware: UEFI mode, and decide Secure Boot now.** If you will ever use the TPM
  auto-unlock (§9.4), **Secure Boot must be ON** — it is a firmware setting and PCR-7 sealing is
  meaningless without it. You can't make a TPM-only unlock meaningful retroactively.
- [ ] **Internet for the *whole* build.** apt (incl. Microsoft's VS Code repo), the pinned PowerShell
  `.deb` from GitHub, the ~175 MB SSG datastream, and `oscap --fetch-remote-resources` all need the
  network. **Only air-gap *after* you've collected the reports.** (Choosing `editor_choice: vim`/`neovim`
  instead of the default `vscode` is the only thing that removes an internet dependency.)
- [ ] **The repo must be public and reachable.** The install command pulls `bootstrap.sh` +
  `requirements.yml` from `raw.githubusercontent.com` and `ansible-pull` clones over **unauthenticated
  HTTPS**. A private/unreachable repo fails immediately.
- [ ] **If you forked/renamed the repo**, update the `casea1` URL **everywhere it appears** and push
  public — see the checklist in §12.
- [ ] **Operator account name.** The admin account you create in the installer **must match**
  `dev_tools_user` and `wireshark_users` in `group_vars/all.yml` (default **`austin_case_adm`**). See §3.4.
- [ ] **Build host uses the full `ansible` package, not `ansible-core`.** The gap-remediation tasks use
  `community.general` (pamd/pam_limits/ufw/ini_file) and `ansible.posix` (ACLs), which ship with `ansible`
  but **not** `ansible-core`. `bootstrap.sh` installs `ansible` for you; only relevant if you run manually.

---

## 3. Phase 1 — Install Ubuntu 24.04 LTS Desktop

All manual installer work. None of it is automated, and a few choices can't be fixed later.

**Order:** firmware (UEFI + Secure Boot) → partition layout → encrypt → create `austin_case_adm` →
hostname → clock.

### 3.1 Media & firmware
- Install **Ubuntu 24.04.x LTS Desktop (GNOME)**, booted in **UEFI** mode.
- In firmware, set **Secure Boot = ON** if TPM auto-unlock is in your plans (§9.4). Decide now.
- Connect to the **internet**.

### 3.2 Disk encryption (LUKS) — install-time only
In the installer choose **"Erase disk and use LVM"** and tick **"Encrypt the new Ubuntu installation
for security."** Set a strong **LUKS passphrase**.

- **Record this passphrase and keep it forever.** It is the disk's recovery key. It is also the exact
  secret you later vault as `luks_passphrase` if you enable TPM auto-unlock — and that feature *keeps*
  this passphrase as the recovery keyslot (it never replaces it). Losing it = losing your only recovery.
- Encryption **cannot** be added after install. (For unattended/fleet installs, bake LUKS into an Ubuntu
  autoinstall seed — see *Full-disk encryption at install time* in [OPERATIONS.md](../OPERATIONS.md);
  that seed is separate from this repo and the passphrase must be vaulted, never committed.)

### 3.3 STIG partition layout (recommended, install-time only)
DISA STIG wants **separate partitions** for `/home`, `/var`, `/var/log`, `/var/log/audit`, `/tmp`,
`/var/tmp` with `nodev`/`nosuid`/`noexec` where applicable. **This repo does not create partitions or
set mount options** — `filesystem.yml` only fixes ownership/permissions/sysctl on existing paths. If you
install to a single partition, the separate-mount controls remain **open findings** (track as POA&M).
Use the installer's manual partitioning to lay these out now; it can't be retrofitted cleanly.

### 3.4 Create the operator account — **name must match the playbook**
Create the primary admin account named **exactly `austin_case_adm`** (the default value of both
`dev_tools_user` and the single `wireshark_users` entry in `group_vars/all.yml`).

- This account is **hand-created in the installer** — the playbook does **not** create it (it is
  deliberately excluded from the `local_users` list, which holds the *other*, locked org accounts).
- **If the name doesn't match:** the playbook still runs, but `app_config`/`dev_tools` use
  `ansible.builtin.user`, which will **create a new locked account** with the configured name and grant
  *it* the `wireshark`/`docker`/VS-Code memberships — so the perks land on a stray account, not your real
  login. If you want a different login name, edit `dev_tools_user` **and** `wireshark_users` in
  `group_vars/all.yml` before pushing.

### 3.5 Other install settings
- **Hostname:** set a sane, unique hostname (don't leave the default `ubuntu`) — it's tied to log/audit identity.
- **Clock/UTC:** the hardening sets the RTC to UTC and swaps `systemd-timesyncd` for `chrony`; install with a UTC-aligned clock to avoid surprises.

**Phase 1 exit criteria:** a fresh, UEFI, LUKS-encrypted, (ideally) STIG-partitioned Ubuntu 24.04.x
Desktop, online, with `austin_case_adm` created. Ready to run.

---

## 4. One-time repo setup

Before the first run, review **`group_vars/all.yml`** (full reference in §11):
- `wireshark_users`, `dev_tools_user` — match your operator account (§3.4).
- `editor_choice` — `vscode` (default) | `vim` | `neovim`.
- `ubtu24stig_cat3` — leave `false` until you've validated low-severity controls.
- `stig_skip_tags` — add any controls you must skip on Desktop (document each as a POA&M).
- *(optional, can wait until after the first clean run)* `grub_password_pbkdf2`, `tpm_luks_enabled`/`luks_passphrase`.

If you forked the repo, update the URLs (§12) and **push to a public repo**.

---

## 5. Phase 2 — Run the build

On the target box, online:

```bash
curl -fsSL https://raw.githubusercontent.com/casea1/ubuntu-stig-build/main/bootstrap.sh | sudo bash
```

`bootstrap.sh`, in order: installs `ansible git curl`; downloads `requirements.yml` and runs
`ansible-galaxy install -r` (which installs **both** the pinned `UBUNTU24-STIG` role **v1.3.0** **and** the
`community.general` + `ansible.posix` collections); then launches the build **detached** as a transient
systemd unit `stig-build` via `systemd-run`.

> **Why detached:** hardening restarts GDM mid-run, which would kill a foreground job launched from the
> GUI session. `systemd-run` decouples it so the build survives. The `curl | bash` returns immediately —
> that's expected; the build runs in the background.

**Manual alternative** (same effect): `sudo apt install -y ansible git curl`, then
`sudo ansible-galaxy install -r requirements.yml` **(do this before `ansible-pull`, or the gap tasks
fail mid-run)**, then `sudo systemd-run --unit=stig-build --collect ansible-pull -U <repo> -C main -i localhost, local.yml`.

---

## 6. What runs, in order (and why it's load-bearing)

`base_packages → app_config → local_accounts → dev_tools → classification_banner` *(if enabled)* `→
stig_harden → desktop_branding → tpm_luks_unlock` *(if `tpm_luks_enabled`)* `→ scap_scan`

Do **not** reorder: hardening sets `noexec /tmp`, tightens `umask`, and locks down PAM — running it
before the installs would break apt/pip and group-sharing. `scap_scan` is **last** because it needs the
internet (`--fetch-remote-resources`) before you air-gap.

---

## 7. Watch & confirm

```bash
journalctl -u stig-build -f          # live log
systemctl status stig-build          # "active (exited)" = success
```

- The run is **long** (dozens of installs, the ~140-lib `/opt/eng-venv`, the SSG bundle, a full oscap
  eval). There's no fixed duration; watch the log, don't assume a hang.
- **`oscap` exit code 2 is NOT a failure** — it means "scan ran, some rules failed," which is expected.
- **Findings are normal** and must be triaged into your POA&M (§10): Desktop-vs-Server STIG gaps, the dev
  toolchain/Docker, the disabled provisioning services, GRUB until you set the hash, AIDE on the first
  scan (§9.5), and the documented deviations.

---

## 8. Collect the SCAP reports — **before air-gapping**

Three artifacts land in **`/var/log/stig-scan/`**:
- `stig-report-<date>.html` — human-readable
- `stig-viewer-<date>.xml` — import into DISA STIG Viewer
- `stig-arf-<date>.xml` — full ARF results

Copy them off the box **while still online**. Air-gapping is the very last step, after artifacts are
collected and the post-install checklist is done. To **re-scan later offline**, run `oscap` without
`--fetch-remote-resources` against the on-box `ssg-ubuntu2404-ds.xml`.

---

## 9. Phase 3 — After the build (in order)

> **Critical ordering:** verify auth **before** the final reboot, with your current admin/root session
> still open. Collect reports before air-gap. Do GRUB/TPM as *edit → push → re-run → reboot* loops.

### 9.1 Verify auth BEFORE you reboot
`pam.yml` applied account-lockout (faillock). While your **current session stays open**, open a **new**
terminal / fresh login and confirm:
```bash
sudo -v                              # confirm sudo still works
# optional: fail 3 logins to confirm lockout engages, then recover:
sudo faillock --user <name> --reset
```
`unlock_time=0` means only an admin reset clears a lockout — discovering a broken PAM stack *after*
reboot, with no session open, can leave no recovery path. Don't skip this gate.

### 9.2 Set passwords for the locked org accounts (at deploy, per machine)
The standing accounts are created **locked** (they exist but can't log in). On the fielded box:
```bash
sudo passwd overlord
sudo passwd austin_case_dta
sudo passwd adam_kabat_adm   # ...and _aud, _dta
sudo passwd pj_bates_adm     # ...and _aud
sudo passwd zac_mccamant_adm # ...and _aud, _dta
```
(10 accounts total, from `local_users`.) This is **deploy-time, per machine** — never baked into a gold image.

### 9.3 GRUB bootloader password (closes 2 high findings)
Self-skips on the `CHANGEME` placeholder. To enable:
```bash
grub-mkpasswd-pbkdf2         # type the password twice; copy the grub.pbkdf2.sha512... token
ansible-vault encrypt_string 'grub.pbkdf2.sha512.10000.<salt>.<hash>' --name 'grub_password_pbkdf2'
```
Paste the `!vault` block over `grub_password_pbkdf2` in `group_vars/all.yml`, **push**, **re-run** the
build, **then reboot**. Normal boot stays password-free (menuentries are `--unrestricted`); the password
is required only to *edit* an entry. Keep `grub_superuser` to letters/underscores only. Test the hash on
a throwaway VM before a gold image.

### 9.4 TPM2 LUKS auto-unlock (opt-in, per machine)
Passphrase-free boot via the TPM. **Secure Boot must be ON** (§3.1). To enable, set in `group_vars/all.yml`:
```yaml
tpm_luks_enabled: true
luks_passphrase: !vault | ...        # ansible-vault encrypt_string '<your install passphrase>' --name 'luks_passphrase'
```
then **push → re-run → reboot**. It binds a **new** keyslot to **PCR 7** via `clevis` and **keeps your
install passphrase as recovery** (never replaces it — see §3.2). **Test on one box first** (the manual
equivalent is `sudo clevis luks bind -d /dev/<part> tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'` then
`sudo update-initramfs -u -k all`). A firmware/Secure-Boot/shim change that alters the PCRs falls back to
the passphrase prompt (not a brick) — re-bind if needed. Security note: TPM-only / no-PIN auto-unlock is a
deliberate data-at-rest deviation (§10).

### 9.5 AIDE builds itself after the first boot
AIDE's database is **no longer built during the run** (hashing the whole disk would stall the build).
Instead a one-shot timer builds it **~5 minutes after this first boot**, at idle priority, in the
background. Confirm later:
```bash
systemctl list-timers aide-init.timer
systemctl status aide-init.service
ls -l /var/lib/aide/aide.db          # exists once built
```
Because of this, the build-time scan's *"Build and Test AIDE Database"* rule is a **finding on the first
scan**; **re-scan offline** (§8) after the DB builds and it passes.

### 9.6 Confirm state & final reboot
- **USB storage** works only for `dta`-group members; everyone else (incl. admins) uses `sudo mount`.
- **Wallpaper** is set system-wide on desktop + lock screen (set `branding_lockscreen_wallpaper: false` to
  keep the STIG blank lock screen).
- **Classification banner** level is `classification_banner_level` (default `UNCLASSIFIED`).
- **Reboot** to apply hardening. You should reach a GDM login showing the **DCSA banner**. *(A hang at the
  boot splash is the known upstream `UBTU-24-200650` GDM bug — already worked around in this repo.)*

---

## 10. POA&M & accepted deviations — the assessor checklist

Hand these to your assessor as documented exceptions:

- **Disk encryption** — done at install time (LUKS), not by the playbook.
- **Separate mount partitions** (`/var`, `/var/log`, `/var/log/audit`, `/tmp`, `/home`) — install-time; open findings if not partitioned (§3.3).
- **FIPS mode** — requires an Ubuntu Pro token; not enabled.
- **Smartcard / CAC + SSSD** — image is password-login only by decision; smartcard controls POA&M'd (the harmless GNOME lock-on-removal *is* set).
- **GUI login-banner TEXT** — the SSG OVAL pins the *DoD* Standard Mandatory Notice; this image shows the **DCSA** banner by requirement, so the text rule stays failing as an **approved deviation** (banner-enable passes).
- **Last-logon PAM notification** — `pam_lastlog` removed in 24.04, `pam_lastlog2` not in `noble`; POA&M.
- **Audit-log offload** (remote server / external media) — disabled by default; set `stig_audit_remote_server` to enable au-remote.
- **GRUB password** — failing until you complete §9.3.
- **AIDE database** — first-scan finding; passes after the post-boot build (§9.5).
- **Blank screensaver overridden** — lock screen shows the wallpaper instead of blank (§9.6).
- **USB → `dta` group** — controlled-group access instead of blanket USB disable.
- **TPM-only LUKS auto-unlock** (if enabled) — no-PIN auto-unlock is a data-at-rest deviation, mitigated only by Secure Boot (§9.4).
- **TFTP / DHCP / DNS** — installed but disabled (mission-need provisioning services).

---

## 11. Configuration reference (`group_vars/all.yml`)

All operator-facing knobs. Values with a **cap** will *fail the scan* if exceeded.

**Tooling & users**
- `editor_choice: vscode` — `vscode` (needs internet) | `vim` | `neovim`.
- `wireshark_users: [austin_case_adm]`, `dev_tools_user: austin_case_adm` — **must match your operator account** (§3.4).
- `clamav_run_daemon`, `clamav_freshclam_*` — antivirus daemon + update cadence.

**STIG engine toggles**
- `ubtu24stig_cat1/cat2/cat3` — severity tiers (cat3 off by default).
- `ubtu24stig_disruption_high: false` — leave off until validated (the gap-remediation files cover what it skips).
- `dcsa_gui_banner` — the DCSA Authorized Warning Banner text (single-quoted, literal `\n`).

**STIG gap-remediation tunables**
- `pam_faillock_deny: 3`, `pam_faillock_unlock_time: 0`, `pam_faillock_fail_interval: 900` — account lockout.
- `stig_session_timeout: 900` *(cap ≤ 900)*, `stig_max_concurrent_sessions: 10` — session limits.
- `gnome_idle_delay_seconds: 600` *(cap: > 0 and ≤ 600)*, `gnome_lock_delay_seconds: 0` — screensaver lock.
- `stig_audit_space_left_action`, `stig_audit_admin_space_left_action`, `stig_audit_remote_server: ""` — auditd retention/offload.
- `stig_var_log_group: syslog` *(must be syslog)*, `stig_journal_dir_mode: "2640"` *(must be 2640, not 2750)*, `stig_journalctl_mode: "0740"`, `stig_kernel_dmesg_restrict: 1`.
- `stig_firewall_limit_ports` — ufw rate-limited inbound (default: ssh).

**Secrets to vault** 🔒
- `grub_password_pbkdf2` — GRUB hash (opt-in; self-skips on `CHANGEME`). `grub_superuser` must be `[a-zA-Z_]+` (no digits/hyphens).
- `luks_passphrase` — install LUKS passphrase, for `tpm_luks_unlock` (opt-in; `tpm_luks_enabled: false` by default).

**Accounts / access / branding**
- `local_groups`, `local_users`, `local_shared_dirs`, `usb_access_group: dta`.
- `branding_wallpaper_dest`, `branding_lockscreen_wallpaper: true`.
- `classification_banner_enabled`, `classification_banner_level: UNCLASSIFIED`.

**Scan**
- `scap_profile`, `ssg_content_version: "0.1.81"` — compliance content (pinned).

---

## 12. Troubleshooting & quick reference

**Command cheat-sheet**
```bash
# Run / watch
curl -fsSL https://raw.githubusercontent.com/casea1/ubuntu-stig-build/main/bootstrap.sh | sudo bash
journalctl -u stig-build -f ; systemctl status stig-build
sudo systemctl stop stig-build           # abort a run (then re-run; it's idempotent)

# Recover a locked-out account
sudo faillock --user <name> --reset

# Secrets
grub-mkpasswd-pbkdf2
ansible-vault encrypt_string '<value>' --name '<var>'

# TPM auto-unlock (manual equivalent)
sudo clevis luks bind -d /dev/<part> tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'
sudo update-initramfs -u -k all

# Re-scan offline (after air-gap)
sudo oscap xccdf eval --profile <profile> --report report.html <on-box ssg-ubuntu2404-ds.xml>
```

**Symptoms**
- **Build "hangs" at `aideinit`** — fixed: AIDE now builds post-boot via `aide-init.timer` (§9.5). If you're
  on an older revision, `sudo systemctl stop stig-build` and re-run after pulling the fix.
- **Boot hangs at the splash / GDM won't start** — the upstream `UBTU-24-200650` banner bug (the role
  writes the banner one-char-per-line). Worked around here (`ubtu24stig_200650: false`).
- **Lockout after hardening** — see faillock reset above; this is why §9.1 is a mandatory pre-reboot gate.
- **Re-running is safe** — every role is idempotent and the run is detached; re-run any time to converge,
  or after editing `grub_password_pbkdf2` / `luks_passphrase` / `tpm_luks_enabled` to apply them.

**Forked-repo URL checklist** (update every `casea1` reference, then push **public**):
- `bootstrap.sh` — `REPO_URL=` and the `curl` URL in its header comment
- `README.md` — the Quick-start `curl` one-liner
- `OPERATIONS.md` — the run block (the `curl` line and the `ansible-pull -U` line)
- `docs/imaging-guide.md` — this guide's `curl` URLs (§5 and §12)
