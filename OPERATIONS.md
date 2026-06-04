# ubuntu-stig-build

Ansible-pull repo to provision and DoD-STIG-harden an **Ubuntu 24.04 Desktop (GNOME)**
machine, then produce an OpenSCAP compliance report — all in one run, while the box
still has internet, before it's moved to an air-gapped network.

> For the full step-by-step lifecycle (Ubuntu install → run → post-install checklist), see the
> **[Imaging Guide](docs/imaging-guide.md)**. This file is the subsystem-by-subsystem reference.

## What it does, in order

1. **base_packages** — ClamAV, Wireshark/tshark, Python3 (+pip/venv), PuTTY (GUI) and
   putty-tools (plink/pscp/psftp), OpenSSH client, git, OpenSCAP, and your editor
   (VS Code by default; vim/neovim selectable).
2. **app_config** — Starts ClamAV daemon + freshclam updates + a weekly scan timer;
   restricts Wireshark capture to a `wireshark` group (STIG requirement).
3. **stig_harden** — Runs the `ansible-lockdown/UBUNTU24-STIG` remediation role
   (CAT I + II by default, CAT III off), then a set of **SSG gap-remediation task
   files** (`tasks/*.yml`: audit, pam, sessions, gnome, ssh, services, filesystem,
   grub) that close the ComplianceAsCode `stig`-profile findings the Lockdown role
   skips under `disruption_high: false`. See *STIG gap remediation* below.
4. **scap_scan** — Runs `oscap` against the DISA STIG profile and writes an HTML report
   plus a DISA-STIG-Viewer-importable XML into `/var/log/stig-scan`.

## One-time setup

Edit **`group_vars/all.yml`**:
- `wireshark_users` → real local accounts that need packet capture
- `editor_choice` → `vscode` | `vim` | `neovim`
- `ubtu24stig_cat3` → flip to `true` once you've validated low-severity controls
- `stig_skip_tags` → add control tags you must skip on Desktop (document each as a POA&M)

Push this repo to a **public** GitHub/GitLab repo.

## Running it on the Dell (during imaging, online)

```bash
sudo apt update && sudo apt install -y ansible git curl
# Install the pinned Lockdown role from requirements.yml:
curl -fsSL https://raw.githubusercontent.com/casea1/ubuntu-stig-build/main/requirements.yml -o /tmp/requirements.yml
sudo ansible-galaxy install -r /tmp/requirements.yml
# Run DETACHED as a systemd unit -- hardening restarts GDM mid-run, which would
# kill a foreground job launched from the GUI session. systemd-run survives it:
sudo systemd-run --unit=stig-build --collect \
  ansible-pull -U https://github.com/casea1/ubuntu-stig-build.git -C main -i localhost, local.yml
# Watch:  journalctl -u stig-build -f      Result: systemctl status stig-build
```

Or just run `bootstrap.sh` (below), which does all of that — and also **prompts (hidden) for the disk
encryption password** to enable TPM auto-unlock before launching the detached build (press Enter to skip;
it auto-skips on an unencrypted or already-bound disk). See *TPM2 LUKS auto-unlock*.

## Critical gotchas

- **Desktop vs Server STIG.** DISA only publishes a *Server* 24.04 STIG. On GNOME you
  WILL get findings about the display manager / graphical target. Don't let the Lockdown
  role disable the GUI — `ubtu24stig_gui: true` guards against that. Triage the GUI
  findings into documented exceptions.
- **Order is load-bearing.** Packages first, harden second, scan last. Hardening sets
  `noexec` on /tmp, tightens umask, and locks down PAM — doing it before installs can
  break pip and apt.
- **The role/content versions are pinned.** `requirements.yml` pins `UBUNTU24-STIG` to `v1.3.0`
  and the SSG datastream to `0.1.81`, so every machine you image is identical. Bump deliberately
  and re-test.
- **Collect reports before air-gapping.** `/var/log/stig-scan/*.html` and the
  `stig-viewer-*.xml` are your audit artifacts. Grab them while the box is online.
- **High-impact controls are gated.** `ubtu24stig_disruption_high: false` makes the
  Lockdown role SKIP its most breaking controls (there is no `ubtu24stig_fullauto` var or
  interactive pause in 1.3.0). The `stig_harden/tasks/*.yml` gap files remediate the SSG
  findings those skips leave behind; flip `disruption_high: true` only after a clean,
  validated pass.
- **Re-scan after air-gapping.** `oscap` works offline too (drop `--fetch-remote-resources`).
  Keep the SSG datastream on the box for periodic re-checks.

## STIG gap remediation (SSG scan findings)

The box is hardened by `ansible-lockdown/UBUNTU24-STIG`, but the **scan grades it with the
SSG / ComplianceAsCode `stig` profile** — a different project whose rules don't map 1:1 to
the Lockdown role. With `disruption_high: false` (Lockdown skips its most breaking controls)
and `cat3: false`, a large set of SSG rules fail out of the box. `stig_harden` therefore
includes **idempotent, desktop-safe, SSG-rule-targeted** task files
(`roles/stig_harden/tasks/*.yml`) that run after the Lockdown role and close those gaps:

| File | Closes (SSG rule families) |
|------|----------------------------|
| `audit.yml` | auditd syscall/watch rules (DAC, file-deletion, unsuccessful-access, kernel-modules, privileged-cmds, sudoers.d/journal/cron), data-retention actions, dispatcher plugins, rules.d perms |
| `pam.yml` | faillock lockout (deny/interval/unlock/audit/silent), faildelay, password-hashing rounds, no-empty-password |
| `sessions.yml` | concurrent-login cap, interactive (`TMOUT`) session timeout |
| `gnome.yml` | screensaver idle/lock/blank, automount off, Ctrl-Alt-Del off, smartcard-removal lock, GDM login-banner enable — all dconf-locked |
| `ssh.yml` | `X11Forwarding no`, `PubkeyAuthentication yes`, SSH `/etc/issue.net` banner |
| `services.yml` | chrony (NTP) + remove timesyncd, ufw enable + rate-limit, AIDE init + daily check, rsyslog remote-access monitoring |
| `filesystem.yml` | `/lib*` group-owner root, `/var/log` + journal perms, `journalctl` perms, `kernel.dmesg_restrict`, RTC=UTC |
| `grub.yml` | GRUB2 bootloader password (BIOS + UEFI) — **self-guarded, see below** |

All tunables (lockout counts, timeouts, retention, firewall ports, GRUB superuser/hash) live
in the **`STIG GAP-REMEDIATION TUNABLES`** section of `group_vars/all.yml`. These files also
need the `community.general` collection (now pinned in `requirements.yml`).

### Required: set the GRUB bootloader password

`grub.yml` ships a deliberate `CHANGEME` placeholder and **self-skips** until you supply a
real hash, so a forgotten hash can never brick boot (the two GRUB rules just stay failing).
To activate it:

```bash
grub-mkpasswd-pbkdf2          # type the GRUB password twice; copy the grub.pbkdf2.sha512... token
ansible-vault encrypt_string 'grub.pbkdf2.sha512.10000.<salt>.<hash>' --name 'grub_password_pbkdf2'
```

Paste the resulting `!vault` block over `grub_password_pbkdf2` in `group_vars/all.yml`. Keep
`grub_superuser` to letters/underscores only (the SSG regex rejects digits/hyphens). Normal
boot stays **password-free** (menuentries are generated `--unrestricted`); the credential is
required only to *edit* an entry or use the GRUB shell. **Test the hash on a throwaway VM
before baking a gold image** — recovery from a bad hash means a GRUB edit from install media.

### Validate PAM on a snapshot first

`pam.yml` edits `common-auth`/`common-account`. It keeps `pam_unix`, never sets
`even_deny_root`, and defaults `unlock_time=0` (admin-unlock), so failures are recoverable —
but **mis-ordered PAM can lock everyone out**. On the first apply: keep a root shell open,
confirm login works, fail 3 logins to confirm lockout, then `sudo faillock --user <name>
--reset` to recover. The VM snapshot is the real safety net. The faillock pamd anchors assume
a stock 24.04 `common-auth`; re-verify if `pam-auth-update` ran with extra profiles.

### POA&M — findings NOT auto-remediated by the build

These need a secret, a subscription, install-time action, or an environment this image
doesn't have. Document each as a POA&M for your assessor:

- **Disk encryption (`Encrypt Partitions`)** — LUKS happens in the installer, before
  ansible-pull runs. See *Full-disk encryption at install time* below.
- **FIPS mode (`/proc/sys/crypto/fips_enabled`)** — requires an Ubuntu Pro token
  (`pro enable fips-updates`) + reboot. Not enabled on this image.
- **Smartcard / CAC + SSSD** (opensc, pam_pkcs11, SSSD enable / cert-mapping / OCSP / cache,
  "Enable Smart Card Logins in PAM") — this image is **password-login only** by decision. The
  one harmless smartcard-adjacent control (GNOME *lock-on-smartcard-removal*) IS set.
- **GUI login-banner TEXT (`Set the GNOME3 Login Warning Banner Text`)** — the SSG OVAL
  pattern-matches the configured text against the **DoD Standard Mandatory Notice**; this
  image displays the **DCSA Authorized Warning Banner** by requirement, so the text rule
  stays failing as an **approved deviation**. (`banner-message-enable` passes.)
- **Last-logon PAM notification** — `pam_lastlog` was removed in 24.04 and `pam_lastlog2` is
  not in `noble` main; `pam.yml` wires it only if present, else POA&M (or backport
  `libpam-lastlog2` into your mirror).
- **Audit log offload** (`...Send Logs To Remote Server`, `Offload audit Logs to External
  Media`) — set `stig_audit_remote_server` to a collector to enable au-remote; external-media
  offload is operational.
- **GRUB password** — failing until you complete the vault step above.
- **TFTP / DHCP / DNS** provisioning services — installed-but-disabled mission-need
  exceptions (pre-existing).
- **Blank screensaver overridden** (`Implement Blank Screensaver`) — by requirement the
  session lock screen shows the org wallpaper (`desktop_branding` role) instead of blank, so
  `org.gnome.desktop.screensaver picture-uri` is non-empty. Approved deviation; the lock
  *timing* (idle-delay, lock-enabled, lock-delay) is still STIG-enforced.
- **USB storage restricted to the `dta` group** (not blanket-disabled) — a deliberate, more
  granular control than the STIG's "disable USB mass storage." If your benchmark strictly
  requires USB *disabled*, document this group-based allowance as the exception.
- **TPM-only LUKS auto-unlock (opt-in, `tpm_luks_enabled`)** — when enabled, the disk
  auto-decrypts via the TPM with no boot secret (PCR 7 / Secure Boot). A deliberate data-at-rest
  deviation accepted for operational need, mitigated only by Secure Boot; the install passphrase
  is retained as a recovery keyslot. See *TPM2 LUKS auto-unlock* below.

### Full-disk encryption at install time (autoinstall)

`Encrypt Partitions` can't be done post-install. Bake LUKS into the **Ubuntu autoinstall**
(`user-data`) so fresh images come up encrypted. Simplest is LUKS-on-LVM via the guided
layout:

```yaml
#cloud-config
autoinstall:
  version: 1
  storage:
    layout:
      name: lvm
      password: "REPLACE_WITH_A_STRONG_DISK_PASSPHRASE"   # turns on LUKS full-disk encryption
  # ... identity / network / late-commands that kick off ansible-pull ...
```

- The `password` is the **disk-unlock passphrase**, prompted at every boot. For unattended
  reboots on 24.04, enroll a TPM2 key after install (`systemd-cryptenroll --tpm2-device=auto
  /dev/<luks-part>`) or use Ubuntu 24.04's TPM-backed FDE, then adjust prompting per policy.
- Vault the passphrase; never commit it in cleartext.
- This is install-media config, **separate from this ansible-pull repo** — keep it with your
  autoinstall seed.

## Local accounts, access groups & branding

The `local_accounts` role provisions the standing users/groups, the group-shared folders, and
the USB access policy; `desktop_branding` sets the wallpaper. All driven from `group_vars/all.yml`
(`local_groups`, `local_users`, `local_shared_dirs`, `usb_access_group`, `branding_*`).

**Accounts are created LOCKED.** Each exists but cannot log in until you set a password
**per-machine at deploy** (a locked account is not an empty password, so STIG stays satisfied):

```bash
sudo passwd overlord
sudo passwd austin_case_dta
# ... one per account, on the fielded box (not baked into the gold image)
```

Supplementary groups are **declarative** — a re-run re-asserts exactly the `groups:` list for
each user (so a manually-added group gets removed on the next `ansible-pull`). `sudo`-group
membership grants full sudo. The `audit` group is for `/opt/_AuditFiles` access; sudo is granted
to the named auditor accounts individually (their `groups:` include `sudo`), **not** to the whole
`audit` group — change `local_users` if you want group-wide sudo.

**Base-box default accounts are purged.** The role removes any account listed in
`purge_default_accounts` (default: `vagrant`) along with its home, its insecure SSH key, and any
matching `/etc/sudoers.d/` drop-in. Vagrant/Packer base images ship a `vagrant` user with a
well-known password + `NOPASSWD` sudo + a publicly-published SSH key (a STIG finding); this build
doesn't create it, but cleans it up if your base image had one. Removal is idempotent. **Never add
your operator account or a `local_users` name to that list.**

**Access groups & shared folders**

| Group | Grants | Shared folder |
|-------|--------|---------------|
| `dta` | USB storage access | — |
| `audit` | `/opt/_AuditFiles` (auditors; sudo per-account) | `/opt/_AuditFiles` → `root:audit 2770` |
| `sentry` | `/home/shared` | `/home/shared` → `root:sentry 2770` |

The folders are `setgid` **plus a POSIX default ACL** (`g:<group>:rwx`) — this matters because the
STIG `umask 077` would otherwise make new files `0600` and break group sharing; the default ACL
bypasses the umask so group members get full access to everything created inside, and others are
denied. Needs the `acl` package (installed by the role).

**USB storage → `dta` only.** Out of the box USB was *not* restricted (the STIG work only disabled
auto-mounting). This role adds two layers:
- a **polkit rule** (`/etc/polkit-1/rules.d/49-dta-usb.rules`) allowing udisks2 mount/unmount/eject
  only for `dta` members (the Files / `udisksctl` desktop path);
- a **udev rule** (`/etc/udev/rules.d/99-dta-usb.rules`) setting raw USB block devices to
  `root:dta 0660` (the manual `mount`/`dd` path).

Non-`dta` users (including admins) can't mount USB storage via the desktop; `sudo mount` as root
remains a break-glass path. To change the gated group, edit `usb_access_group`.

**Wallpaper.** `desktop_branding` deploys `roles/desktop_branding/files/SHB_Background.jpg` to
`/usr/share/backgrounds/` and sets it **system-wide and locked** (users can't change it) on the
**desktop background** and the **session lock screen**. The lock-screen part overrides the STIG
blank-screensaver control (see POA&M above). The **GDM login screen** is best-effort only —
Ubuntu's greeter usually renders its themed background and ignores the dconf key; a guaranteed
login JPG needs a fragile `gnome-shell` gresource patch that is intentionally not done. Flip
`branding_lockscreen_wallpaper: false` to brand only the desktop and keep the STIG blank lock screen.

## TPM2 LUKS auto-unlock (on by default; passphrase supplied out-of-band)

`tpm_luks_unlock` binds a keyslot of the install-time LUKS volume to the machine's **TPM2** (via
`clevis` — the path Ubuntu 24.04's stock initramfs auto-unlocks reliably; `systemd-cryptenroll`'s
`tpm2-device=` is *not* honoured by Ubuntu's default initramfs) so the disk unlocks at boot with
**no passphrase**. It is **`tpm_luks_enabled: true` by default**, but it only binds once it can read
the install passphrase — and that passphrase is **never stored in this public repo**.

**Supply the passphrase out-of-band.** The role reads it from a root-only (`0600`) file on the box,
`luks_passphrase_file` (default `/etc/luks/initial-passphrase`). Your **private autoinstall seed**
writes that file during install — it already has the passphrase (it sets `storage.layout.password`),
so no new secret location is introduced and nothing lands in git:
```yaml
# in your autoinstall user-data (PRIVATE install media, NOT this repo):
late-commands:
  - install -d -m 700 /target/etc/luks
  - printf '%s' 'YOUR-INSTALL-PASSPHRASE' > /target/etc/luks/initial-passphrase
  - chmod 600 /target/etc/luks/initial-passphrase
```
The role consumes it once to authorize the TPM keyslot (never needed at boot afterwards) and then
**deletes the file** by default (`luks_passphrase_purge_after_bind: true`), so the per-box passphrase
doesn't linger on the auto-unlocking disk — re-drop it only if you need to re-bind. Each box uses its
**own** passphrase (the seed writes that box's value), so a stolen booted box can only leak its own.
For a **private/offline** repo only you may instead set an inline/vaulted `luks_passphrase` — but
**never** paste a secret into a public repo; the encrypted blob is permanent in git history. The build
won't fail without the passphrase — it just skips the bind (and says so) until the file is present.

The role installs clevis, binds a **new** keyslot to **PCR 7** (Secure Boot state — stable across
*signed* kernel updates), and rebuilds the initramfs. Your **original passphrase keyslot is kept
as recovery** and is never removed.

**Read before enabling fleet-wide:**
- **Per physical machine.** The keyslot is sealed to *that* box's TPM; it cannot be baked into a
  cloned gold image — the role must run on each machine (the per-machine ansible-pull does).
- **Secure Boot must be ON** or PCR 7 is meaningless (the role warns if off). TPM-only / no-PIN is
  a deliberate data-at-rest deviation: a stolen powered-off disk auto-decrypts on its own hardware.
- **Test on one box first** — TPM/PCR behaviour is hardware-specific, and the non-interactive bind
  (passphrase via stdin) should be confirmed once before fleet rollout. Manual equivalent:
  `sudo apt install -y clevis clevis-luks clevis-initramfs clevis-tpm2 tpm2-tools` (**`clevis-tpm2`
  is a SEPARATE package on Ubuntu 24.04** — without it the bind errors *"tpm2 is not a valid pin"*),
  then `sudo clevis luks bind -d /dev/<part> tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'` and
  `sudo update-initramfs -u -k all`.
- **Recovery:** a firmware/Secure-Boot/shim update that changes the PCRs makes boot fall back to the
  passphrase prompt (not a brick). Re-bind with `clevis luks unbind` + `clevis luks bind` if needed.

### Rotating the LUKS passphrase

The disk passphrase you set at install lives in a LUKS **keyslot**, and you can change it any time
**without re-encrypting** the disk. It is **independent of the TPM keyslot** — changing it does not
disturb auto-unlock, and the box keeps booting via the TPM.

```bash
sudo blkid -t TYPE=crypto_LUKS -o device       # find the LUKS partition, e.g. /dev/sda3 or /dev/nvme0n1p3
sudo cryptsetup luksChangeKey /dev/<part>       # prompts: current passphrase, then the new one twice
# inspect / manage slots:
sudo cryptsetup luksDump   /dev/<part>          # shows used slots (your passphrase + the clevis/TPM slot)
sudo cryptsetup luksAddKey /dev/<part>          # ADD another passphrase (authorize with an existing one)
sudo cryptsetup luksKillSlot /dev/<part> <N>    # remove an old slot by number
```
`cryptsetup` operates on the **LUKS partition** (the bottom layer), not the LVM volumes inside it. No
reboot needed — it applies to future unlocks immediately.

**Keep the vaulted value in sync.** `luks_passphrase` (group_vars) is used **only once** — to authorize
the initial `clevis luks bind`; the role skips it on a box that's already bound, so rotating the
passphrase won't break an already-unlocking machine. But re-vault it so a **fresh image** or a
**re-bind** (after a PCR/firmware change) still authorizes:
```bash
ansible-vault encrypt_string '<new-passphrase>' --name 'luks_passphrase'
```
Update the autoinstall seed too if you bake the passphrase there.

**Don't kill your only passphrase slot** and rely solely on the TPM — a firmware/Secure-Boot/shim
change alters the PCRs and you'd need a passphrase to get back in. The TPM bind deliberately keeps
your passphrase as recovery. If you've forgotten the passphrase but the box still auto-unlocks via the
TPM, a new one can still be added from the running (unlocked) system — a more involved procedure; ask
before attempting.

## Windows servers

This repo is Linux-only. STIG automation for Windows uses a different stack (PowerShell
DSC / the DISA-provided GPOs / Ansible `ansible.windows` + `microsoft.iis` etc.). Keep
that as a separate playbook.
