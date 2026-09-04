# Procedures

Every task, as numbered steps. Find the scenario, follow the steps.

- Commands run **on the box** unless it says otherwise. `it-*` commands self-elevate with `sudo`.
- **Warning:** lines mark the places where skipping a step has cost us a box. There are only a few.
- Facts (ports, paths, volumes, config variables) are in [reference.md](reference.md). Assessor material is in [compliance.md](compliance.md).

---

## 0. What can this box do?

```bash
it-help                  # every it-* command on this box, one line each
it-help it-clamav        # one command's full options
it-help --all | less     # everything
```

It reads the commands from what is actually installed, so an EMI laptop lists `it-vulnscan`, an AI node lists `it-ai`, and neither shows the other's tooling. No list to keep in step.


## Contents

| | |
|---|---|
| **[1. Build a box](#1-build-a-box)** | fresh install → hardened, from nothing |
| **[2. Deploy a box](#2-deploy-a-box)** | passwords, GRUB, going classified, air-gapping |
| **[3. Routine operations](#3-routine-operations)** | health, checklists, scans, transfers, USB |
| **[4. Patching](#4-patching)** | connected, air-gapped, ClamAV, the local apt repo |
| **[5. AI stack](#5-ai-stack-ai-profile)** | `ai` profile only |
| **[6. Recovery](#6-recovery)** | when something is broken |

---

# 1. Build a box

## 1.1 Decide these first — they cannot be changed later

| Decision | Why it is now-or-never |
|---|---|
| **UEFI + Secure Boot ON** | TPM auto-unlock seals to PCR 7, which is meaningless without Secure Boot. Firmware setting. |
| **LUKS full-disk encryption** | Installer-only. Cannot be added afterwards without reinstalling. |
| **Hostname** | Tied to log and audit identity. On the `ai` profile it also picks the node role (`dev-ai1` / `dev-ai2`). |
| **Admin account name** | Must match `dev_tools_user` in `group_vars/all.yml` (default `austin_case_adm`). A mismatch creates a *second*, locked account and gives it the group memberships instead of your login. |

Partition layout is **not** now-or-never for compliance — separate `/var`, `/home` etc. are a RHEL-derived org item, not an Ubuntu STIG rule (see [compliance.md](compliance.md)). Lay them out if you want them; nothing fails without them.

## 1.2 Install Ubuntu 24.04

1. Boot the 24.04.x installer in **UEFI** mode. Desktop for `development`/`emi`/`baseline`, Server for `ai`.
2. Set **Secure Boot = ON** in firmware.
3. Choose **"Erase disk and use LVM"** and tick **"Encrypt the new Ubuntu installation."** Set a strong LUKS passphrase.
4. **Record the LUKS passphrase and keep it.** It is the disk's only recovery key. TPM auto-unlock keeps it as the recovery keyslot; it never replaces it.
5. Create the admin account named **exactly** what `dev_tools_user` says (default `austin_case_adm`).
6. Set a unique hostname. Not `ubuntu`.
7. Connect to the internet and leave it connected for the whole build.

## 1.3 Trust the lab CA

Once per target, before anything can be fetched:

```bash
sudo curl -fsSLo /usr/local/share/ca-certificates/lab-root-ca.crt \
  http://git.asplab.com/lab-root-ca.crt
openssl x509 -in /usr/local/share/ca-certificates/lab-root-ca.crt -noout -fingerprint -sha1
```

Confirm the fingerprint is `03:DD:DD:55:C6:34:F5:8F:2D:1B:6B:25:D2:ED:73:93:54:A8:AE:F9`, then:

```bash
sudo update-ca-certificates
```

Skipping this gives `SSL certificate problem: unable to get local issuer certificate` on the next step.

## 1.4 Run the build

One command. Pick the profile:

```bash
B=https://git.asplab.com/ASPLAB/ubuntu-stig-build/raw/branch/main/bootstrap.sh

curl -fsSL $B | sudo bash                              # development (default)
curl -fsSL $B | sudo PROFILE=ai bash                   # AI server
curl -fsSL $B | sudo PROFILE=emi bash                  # EMI, classified-capable
curl -fsSL $B | sudo PROFILE=emi-unclass bash          # EMI, unclassified only
curl -fsSL $B | sudo PROFILE=baseline bash             # harden an already-built box
```

It prompts, hidden, for:

- the **Ubuntu Pro token** (or set `PRO_TOKEN=`, or pre-place it in `/etc/ubuntu-advantage/pro-token`);
- the **LUKS passphrase**, to bind TPM auto-unlock. Press Enter to skip.

**Every switch goes between `sudo` and `bash`**, as `NAME=value`, space-separated. A fully worked example — EMI, token supplied non-interactively, audit-only first pass, from a mirror:

```bash
curl -fsSL https://git.asplab.com/ASPLAB/ubuntu-stig-build/raw/branch/main/bootstrap.sh \
  | sudo PROFILE=emi \
         PRO_TOKEN=C1abcdEFGH23ijklMNOP \
         HARDEN=0 \
         REPO_URL=https://git.example.com/ASPLAB/ubuntu-stig-build.git \
         BRANCH=main \
         bash
```

| Switch | Values | Effect |
|---|---|---|
| `PROFILE` | `development` \| `ai` \| `emi` \| `emi-unclass` \| `baseline` | Which build. Default `development` |
| `PRO_TOKEN` | your Ubuntu Pro token | Supply it non-interactively instead of being prompted |
| `HARDEN` | `0` | Install everything, skip the disruptive `usg fix`. Omit for a normal run |
| `REPO_URL` | a git URL | Build from a mirror |
| `BRANCH` | a branch name | Default `main` |

> A token on the command line lands in your shell history. Prefer the prompt, or pre-place it in `/etc/ubuntu-advantage/pro-token` (`0600`, root-owned) and omit `PRO_TOKEN` entirely.

The build runs **detached** as the systemd unit `stig-build`, because hardening restarts GDM mid-run and would kill a foreground job.

## 1.5 Watch it

```bash
sudo journalctl -u stig-build -f
systemctl status stig-build        # "active (exited)" = success
```

Expect a long run — dozens of packages, the `/opt/eng-venv` build, a ~175 MB SCAP datastream, a full OpenSCAP evaluation. Watch the log rather than assuming a hang.

**`oscap` exit code 2 is not a failure.** It means the scan ran and some rules failed, which is expected.

## 1.6 Verify auth BEFORE you reboot

> **Warning.** Hardening rewrites PAM. A broken auth stack found *after* reboot, with no session open, needs a live USB to recover. ASP-2 lost an afternoon to exactly this.

With your current session still open, open a **second** terminal and confirm:

```bash
sudo -v                                  # sudo still works
sudo pam-auth-check                      # can common-auth authenticate at all?
```

Only reboot once both pass.

## 1.7 Collect the reports while still online

```bash
ls /opt/ia/usg/          # usg audit: HTML + XCCDF
ls /opt/ia/oscap/build/  # OpenSCAP: HTML report, ARF, STIG-Viewer XML
```

Copy them off now. The SCAP content download needs internet; afterwards scans run offline against the on-box datastream.

## 1.8 Reboot, then confirm

```bash
sudo reboot
```

After reboot:

```bash
sudo it-status            # everything at a glance
sudo it-checklist         # the org checklist, one line per item
cat /proc/sys/crypto/fips_enabled   # 1 on the profiles that enable FIPS
```

You should reach a GDM login showing the DCSA banner.

## 1.9 AIDE finishes on its own

AIDE's database is built by a one-shot timer ~5 minutes after first boot, not during the run. So the build-time scan reports "Build and Test AIDE Database" as a finding. Confirm later and re-scan:

```bash
systemctl list-timers aide-init.timer
ls -l /var/lib/aide/aide.db
sudo it-oscap
```

## 1.10 Re-running the build — `it-pull`

Safe and idempotent — Ansible applies only the delta. After changing anything in the repo:

```bash
sudo it-pull            # the light path. This is the one you want almost every time.
```

No URL, no tags, no `systemd-run`. It reads the repo and branch off the box's own
`ansible-pull` checkout (falling back to `https://git.asplab.com/ASPLAB/ubuntu-stig-build.git`),
runs detached as a transient unit so an RDP or GDM restart cannot kill it mid-run, and
follows the output. Ctrl-C stops watching, not the run.

| Command | What it runs | Reach for it when |
|---|---|---|
| `sudo it-pull` | config, `it-*` scripts, hardening re-assert. **No apt, no image builds, no scan, no container touched** | a config change, a new or fixed script — nearly always |
| `sudo it-pull scripts` | the `it_scripts` role alone | shipping a script fix, fastest path |
| `sudo it-pull full` | the above **plus** packages/images **plus** a fresh `usg audit` and SCAP scan | a package list changed, or you want evidence now |
| `sudo it-pull ai` | light **plus** the Docker/compose stacks | deliberately updating an AI node's containers (§5.8) |
| `sudo it-pull check` | `--check --diff` | rarely. See the warning below — check mode can report the **opposite** of the truth |
| `sudo it-pull status` | nothing that changes the box | "is this box behind, and what's coming?" — the commit comparison plus the **exact incoming commits and the files they touch** |
| `sudo it-pull log` | nothing | the last run's output, or follow one in progress |

**Neither `light` nor `full` touches Docker.** Both skip `ai-runtime` and `ai-gpu`, so an
AI node takes STIG, audit and script updates with its containers left alone — §5.8's
manual command is now just `sudo it-pull`. `it-pull ai` is the deliberate opt-in.

**A routine pull no longer scans.** It used to run three full benchmark evaluations —
`usg audit` in `usg_harden`, `usg audit` again in `usg_remediate`, and `oscap xccdf eval`
in `scap_scan` — plus a checklist build, every time. Evidence now comes from a box's
**first build**, the **weekly `oscap-scan.timer`**, and **`sudo it-stig run`** on demand.
That is `usg_audit_on_pull` / `scap_scan_on_pull` in `group_vars/all.yml` (`build` by
default, `always` restores the old behaviour), so a plain `ansible-pull` gets the same
treatment; `it-pull full` passes `always`.

> **`it-pull check` is not a reliable preview, and `status` is.** Ansible's check
> mode does not run commands, so a task that *reads* state with a command gets no
> answer — and the play can then conclude the opposite of the truth. On ASP-2 the
> `pro status` probe was skipped, the play decided the box was not Ubuntu
> Pro-attached, and `desktop_hardening`'s safety assert stopped the run with
> "this box is NOT Pro-attached". The box was attached the whole time; nothing was
> changed. The read-only probes that gate that decision are now marked
> `check_mode: false` so they run for real, but the playbook is not check-clean
> end to end and is not claimed to be. **For "what would this pull change", use
> `sudo it-pull status`** — it lists the actual incoming commits and the files
> they touch, which is the question you were asking.

### The deployment profile, and why it has to be persisted

`group_vars` defaults `deployment_profile` to `development`. `bootstrap.sh` overrides it
with `-e` for the build and — before 2026-09-01 — **nothing carried it forward**. So *any*
later `ansible-pull` without that `-e` rebuilt an EMI laptop as a development workstation:
USB storage off, the `dta` carve-out gone, the camera/mic lockdown gone. Nothing announces
it. ASP-2 was found in exactly that state, a USB DVD reader that would not appear being the
first visible symptom.

The profile now lives in **`/opt/it/site.yml`**, which `local.yml` loads above `group_vars`,
so every path builds the box the same way — `it-pull`, a hand-typed `ansible-pull`, the
`stig-build` timer. `bootstrap.sh` writes it at build time.

```bash
sudo it-pull --profile emi      # set it and pull; persists to /opt/it/site.yml
sudo it-pull status             # shows the profile and whether it is persisted
```

| | |
|---|---|
| Precedence | `--profile` → `PROFILE=` in the environment → `/opt/it/site.yml` → what the last run recorded |
| Changing it | prints what changes and makes you **type the new profile name back**. Going to or from `emi` changes USB storage, the `dta` carve-out, the camera/mic lockdown, the firewall service set and the installed application set — treat it as a rebuild and use `it-pull full` |
| Cannot determine one | `it-pull` **refuses to run** rather than proceed on the default |

> **`--profile`, not `PROFILE=`.** The script self-elevates with `sudo -- "$0" "$@"`, and
> sudo's `env_reset` drops the variable on the way through — so `PROFILE=emi it-pull`
> silently does nothing. `sudo PROFILE=emi it-pull` does work and is still honoured, but the
> flag is the form that cannot be got wrong.

**Recovering a box that was already reprofiled by accident.** Its on-disk `it-pull` is the
old one, so it cannot fix itself. Run the long form once — it applies the right profile
*and* installs the current scripts:

```bash
sudo sh -c 'printf "\ndeployment_profile: emi\n" >> /opt/it/site.yml'
sudo systemd-run --unit=stig-reprofile --collect --wait \
  ansible-pull -U https://git.asplab.com/ASPLAB/ubuntu-stig-build.git -C main \
  -i localhost, local.yml -e deployment_profile=emi
```

No `--skip-tags`: a profile change is a rebuild, and the application set differs. Watch it
with `sudo journalctl -u stig-reprofile -f`, and reboot afterwards.

**Overrides.** `REPO_URL=... BRANCH=... sudo -E it-pull` for one run, or put `REPO_URL=` /
`BRANCH=` in `/etc/stig-build/pull.conf` permanently — a box built from a mirror keeps
using that mirror.

Reboot afterwards for anything that needs it.

The long form still works, and `bootstrap.sh` is still what a *fresh* box runs:

```bash
sudo systemd-run --unit=stig-build --collect \
  ansible-pull -U https://git.asplab.com/ASPLAB/ubuntu-stig-build.git -C main -i localhost, local.yml \
  -e deployment_profile=emi
```

---

# 2. Deploy a box

## 2.1 Set passwords on the org accounts

Accounts ship **locked** — they exist but cannot log in. Set passwords per machine at deploy, never in a gold image:

```bash
sudo passwd overlord
sudo passwd austin_case_dta
sudo passwd adam_kabat_adm      # ... and _aud, _dta
sudo passwd pj_bates_adm        # ... and _aud
sudo passwd zac_mccamant_adm    # ... and _aud, _dta
```

Ten accounts, listed in `local_users` in `group_vars/all.yml`.

## 2.2 Set the GRUB bootloader password

Closes the only remaining `high` finding. This matters more than the severity suggests: LUKS is TPM-sealed to PCR 7, which does **not** measure the kernel command line — so without a GRUB password, physical access means a root shell on decrypted data.

**One box:**

```bash
sudo it-grub set        # prompts twice, applies immediately
sudo it-grub status     # confirm
```

**The whole fleet:**

```bash
sudo it-grub hash                                    # prints the PBKDF2 token
ansible-vault encrypt_string '<token>' --name 'grub_password_pbkdf2'
```

Paste the `!vault` block over `grub_password_pbkdf2` in `group_vars/all.yml`, push, re-run the build (§1.10), reboot.

Normal boot stays password-free — every menuentry is `--unrestricted`. The password is needed only to *edit* an entry.

## 2.3 Take a box classified (EMI)

```bash
sudo it-goclassified
```

It machine-checks Secure Boot, FIPS, the GRUB password, LUKS, base-image accounts, whether any interactive password still dates from imaging day, radios, USBGuard, and **whether antivirus actually detects** — then asks you to attest the things the OS cannot see (BIOS admin password, boot order, LUKS rotation, TPM re-seal, media removed).

The record goes to `/opt/ia/goclassified/<host>-<timestamp>.txt`. Exit 0 only when nothing failed and nothing is left open.

`sudo it-goclassified --report` runs the machine checks without the attestation prompts.

## 2.4 Air-gap the box

In this order:

1. Collect every report (§1.7).
2. Stage anything that needs the internet — SCAP content is already on disk; the ClamAV scanner image is not:
   ```bash
   sudo it-clamav image-save /mnt/usb      # on a connected box
   ```
3. Decide about the provisioning pull. `stig-build.timer`, if enabled, tries to reach the forge every run and will fail forever on an isolated network:
   ```bash
   systemctl is-enabled stig-build.timer
   sudo systemctl disable --now stig-build.timer
   ```
4. Disconnect.
5. Load what you staged, and confirm antivirus still detects:
   ```bash
   sudo it-clamav image-load /mnt/usb
   sudo it-clamav test          # must PASS
   ```

## 2.5 Install the FPGA toolchains (development)

The baseline installs **everything around** Vivado/Vitis and Libero SoC — the
24.04-correct dependencies, i386 multiarch, the compat shims, udev rules for the
programmer cables, the system-wide environment, and the licence server. It does
**not** install the toolchains themselves: both are interactive, authenticate
against a vendor account, and Xilinx alone is ~150 GB. Bake them into the image.

```bash
sudo it-fpga            # what is installed, licence, cables -- start here
```

### What is manual, and what the pull does

Everything below the line is done for you on every `ansible-pull`. Everything
above it is a person, once per box (or once on the golden image).

| Step | Xilinx | Libero |
|---|---|---|
| Stage the installer in `/opt/it/installers` | ✔ `.bin` | ✔ `.bin` (**not** the `.sh`) |
| Build the compat libraries | — | ✔ `sudo it-fpga compat build` |
| Hand the directory over | — | ✔ `sudo it-fpga install libero` |
| Run the installer | ✔ `sudo it-fpga install xilinx` (batch, unattended) | ✔ GUI, **as yourself, no sudo** |
| Take the tree back | ✔ `sudo it-fpga fixup` | ✔ `sudo it-fpga fixup` |
| JTAG cable drivers (no cables plugged in) | ✔ path printed by `fixup` | — |
| Point at the licence server | ✔ `sudo it-fpga license --server <port>@<host>` (both vendors at once) | ✔ same command |
| ─────────── | ─────────── | ─────────── |
| 24.04 dependencies, i386 multiarch | pull | pull |
| ncurses-5 symlinks, `/usr/tmp` 1777, RHEL CA path | pull | pull |
| udev rules for the programmer cables | pull | pull |
| `/etc/profile.d` environment + `vivado`/`vitis`/`libero` commands | pull | pull |
| App-grid tiles | pull | pull |
| `root:sentry`, group read+execute on the tree | pull | pull |
| Shared IP vault modes | — | pull |

Two of the manual steps are easy to skip and both fail confusingly:
`it-fpga compat build` is **per box** (the pull creates the directory empty), and
`it-fpga fixup` is what makes the install usable by anyone other than the person
who ran it. `sudo it-fpga status` reports the state of both.

```bash
sudo it-fpga status     # says which of the manual steps is still outstanding
sudo it-fpga check      # ldd on vivado + Microchip's own checker, translated
```

### Install once, image, deploy

Do this on the golden box, not on twelve workstations. The web installers pull
from AMD's and Microchip's CDNs and are the first thing a filtering proxy
breaks; the **SFD** (single-file download) installer is the reliable route.

Install to **`/tools/Xilinx`** and **`/opt/microchip`**, root-owned — the pull
creates both, empty. The vendors' guides tell you to install under `$HOME` to
dodge permission problems; that is single-machine advice. On a shared
workstation it means every engineer installs their own 30+ GB copy and the
second one to log in gets nothing.

**Xilinx runs under `sudo`; Libero must not.** Xilinx has a batch mode, so root
never needs a display and the tree lands root-owned. Libero has no response file
— its GUI has to run, and a GUI cannot run as root over RDP (see below).
`sudo it-fpga install libero` hands the directory over for the install and
`sudo it-fpga fixup` takes it back, which is how Libero still ends up
root-owned without root ever drawing a window.

> **If your versions differ from the defaults**, set them before the pull or the
> environment scripts point at paths that do not exist:
> ```yaml
> # /opt/it/site.yml  (or group_vars for the whole fleet)
> fpga_xilinx_version: "2024.2"
> fpga_libero_version: "2025.1"
> ```
> `sudo it-fpga status` tells you when a tree is not where it is expected.

**Do it once by hand, then automate the rest of the fleet.** Once a config
exists there is nothing interactive left:

```bash
# on the box you installed by hand:
sudo it-fpga install --save-config       # captures /root/.Xilinx/install_config.txt

# on every other box: stage the .bin in /opt/it/installers, then
sudo it-fpga install xilinx
journalctl -u xilinx-install -f
```

It finds the installer in `/opt/it/installers` or on attached media, extracts
it, and runs the batch install under **`systemd-run`** — so it survives a
dropped SSH session, a closed terminal and a logout, records an exit code, and
logs to the journal. A `tmux` session that vanished is exactly how the first
attempt on this fleet ended with nobody able to say whether it had finished.

Commit the saved config as `roles/fpga_tools/files/xilinx-install_config.txt`
and every box installs the same modules and device families — which is the
difference between a 40 GB install and a 150 GB one.

The by-hand path, for the first box:

```bash
# Xilinx -- needs root to write /tools/Xilinx
sudo ./FPGAs_AdaptiveSoCs_Unified_*_Lin64.bin

# scriptable, if you would rather not click through it
./FPGAs_AdaptiveSoCs_Unified_*_Lin64.bin --noexec --keep --target ~/xsetup
cd ~/xsetup && ./xsetup -b AuthTokenGen && ./xsetup -b ConfigGen
sudo ./xsetup --agree XilinxEULA,3rdPartyEULA \
     --batch Install --config ~/.Xilinx/install_config.txt --location /tools/Xilinx
```

> **Do not run Xilinx's `installLibs.sh`.** It uses 22.04 package names
> (`libasound2`, `compat-openssl10`) and fails on Noble. The role has already
> installed what it was trying to install. Same for Microchip's post-install
> script.

> **Run the installer under `sudo`, then fix the permissions.** The STIG sets
> `umask 077`, so an installer running as root creates its entire tree `0700`
> directories and `0600` files. Every engineer then gets *"Permission denied"*
> on `settings64.sh` — which looks exactly like a broken install and is not.
> `sudo it-fpga fixup` repairs it; `sudo it-fpga status` detects it, and the
> pull corrects it on its own from then on.

### Libero

Libero has no batch response file, so its GUI has to run — and it must **not**
run as root. `sudo` drops `DISPLAY` and `XAUTHORITY`, and root has no X cookie
for your session, so a `sudo`-launched installer dies with *"could not connect
to display"* however good the rest of the command is. `xhost +SI:localuser:root`
is not the answer either: it opens your display to root for everything else too.

```bash
sudo it-fpga install libero      # hands /opt/microchip to you, prints the command
```

Then run what it prints, **as yourself, no sudo**, in your desktop session:

| Installer field | Value |
|---|---|
| Installation directory | `/opt/microchip/Libero_SoC_2025.1` |
| Common IP vault | `/opt/microchip/common` |
| Installation type | **Full** — and decline the post-install script it offers |

Both fields matter. The installer defaults **both** to `~/microchip`, and the
vault is the one people leave alone: left in a home directory, every engineer
downloads their own copy of every IP core and none of them can see each other's.

> **"No write permission for the selected directory."** The pull re-asserts
> `root:root` on `/opt/microchip` every run, so an `ansible-pull` between
> `it-fpga install libero` and the installer takes the handover back. Run
> `sudo it-fpga install libero` again, then re-enter the path in the dialog so
> it re-checks — it validates when the field loses focus, not on **Continue**.

```bash
sudo it-fpga fixup               # takes the tree back
```

`fixup` **chowns** to `root:sentry` and applies `g+rX,o-rwx`, so nothing is left
owned by whoever happened to install it. Until you run it, `/opt/microchip` is
writable by you — which is the point, and also why it is not optional.

> **If the app-grid tile never appears**, the tree shape probably changed.
> 2025.1 moved the binaries from `<install dir>/Libero/bin64/` to
> `<install dir>/Libero_SoC/Designer/bin64/`, and every probe in the role used
> the old path — so a correct install read as "not installed" and no launcher
> was created. Confirm where they actually landed and set
> `fpga_libero_designer_dir` if it differs again:
> ```bash
> find /opt/microchip/Libero_SoC_2025.1 -maxdepth 5 -type f -name libero
> ```

> **Do NOT run the two post-install scripts the installer offers.**
> `check_linux_req.sh` reports in RPM names on a Debian box — `sudo it-fpga
> check` runs the same checker and translates it. `fp6_env_install` writes
> vendor udev rules at `MODE="0666"`, world-writable device nodes; the pull
> already covers those cables (`1514` FlashPro, `0403` FTDI, `03fd` Xilinx
> Platform Cable, `1443` Digilent) at `0660` with a group. Check with
> `sudo it-fpga cables` — if a programmer does not appear it is almost always
> USBGuard, not udev, and `sudo it-usb enroll` is the missing step.

> **Run the `.bin`, not the `.sh`.** The `.sh` is Microchip's OS gate — it
> prints `System OS NAME=Ubuntu` and stops, because Libero is supported on
> RHEL/CentOS only. The `.bin` is the actual installer and runs fine on 24.04.
> Nothing is wrong with the download.

> **`libpng15.so.15: cannot open shared object file`** is a different problem
> with the same shape, and there is no apt answer: noble ships libpng16, and
> libpng 1.5 → 1.6 was an **ABI break** (the structs became opaque), so a
> symlink onto libpng16 is *not* the ncurses situation — it links and then
> misbehaves, which is worse than failing at load.
>
> ```bash
> sudo it-fpga compat build      # builds libpng15 from upstream source into
>                                # /opt/microchip/compat/lib -- private to Libero
> sudo it-fpga compat            # what is built, and what is still missing
> ```
>
> **Per box.** The compat directory is created empty by the pull and populated
> by this command, so a box that has never run it has an empty one and the
> installer fails exactly as if nothing had been done.
>
> To run the **installer** with it, before the environment scripts exist:
> ```bash
> cd /opt/it/installers
> env LD_LIBRARY_PATH=/opt/microchip/compat/lib ./Libero_SoC_2025.1_online_lin.bin
> ```
> `env VAR=...`, not `sudo -E`: sudo strips `LD_*` unconditionally, so `-E`
> looks like it passes the variable and does not (trap 31). And no `sudo` at
> all here — this is the GUI installer, which needs your X cookie.
>
> It goes in a directory only Libero sees, on its `LD_LIBRARY_PATH`. **Never a
> symlink or a foreign `.deb` in `/usr/lib`** — that puts an unmaintained
> libpng in front of every program on the box. `it-fpga compat` then runs `ldd`
> against the Libero binaries and names anything still missing, so you find the
> whole set at once rather than one failed launch at a time.

> **`libxcb-cursor.so.0: cannot open shared object file`** means the pull has
> not run since that dependency was added. Libero 2025.1's installer is Qt6 and
> its xcb platform plugin needs `libxcb-cursor0` before it draws anything.
> `sudo it-pull full` fixes it for good; `sudo apt install libxcb-cursor0`
> unblocks you now.

Then the fixes that touch the vendor tree — a command, not a pull, because
Ansible never writes into a 150 GB install unattended:

```bash
sudo it-fpga fixup      # removes Libero's bundled RHEL libstdc++, and tells
                        # you where the Xilinx cable drivers are
sudo it-fpga check      # ldd on vivado + Microchip's own checker, translated
```

`fixup` **renames** the bundled `libstdc++.so.6` rather than deleting it, so it
can be put back. Without that, `libero_bin` dies with *GLIBCXX_3.4.30 not found*
— Noble's `libicuuc.so.74` needs a newer C++ runtime than the RHEL one Libero
ships.

The Xilinx JTAG cable drivers must be installed with **no cables plugged in**,
so `fixup` prints the command rather than running it.

### The licence server

Point every workstation at the FlexLM server; nothing is per-box, there is no
MAC to register and no `License.dat` on disk:

```bash
sudo it-fpga license --server 1702@licsrv                    # Microchip + Xilinx
sudo it-fpga license --server 1702@licsrv --xilinx 2100@licsrv   # different port/host
sudo it-fpga license --server 1702@a,1702@b,1702@c           # redundant triad
```

That writes **both** `/etc/profile.d/*.sh` (a new shell has it at once) **and**
`/opt/it/site.yml` (so the next pull renders the same thing). Set
`fpga_license_microchip` / `fpga_license_xilinx` in `group_vars` instead to make
it the fleet default and skip the per-box step entirely.

`it-fpga status` probes the port and says so when it is unreachable. **A licence
variable pointing at a host nobody can talk to looks identical to a correct one
until someone builds.**

> **FlexLM needs two ports open, not one.** `lmgrd` listens on the port you
> configured; the *vendor daemon* (`snpslmd`, `xilinxd`) gets a **random** port
> unless it is pinned in the licence file on the server. If the port below is
> open and checkout still fails, that is why — pin it server-side with a `PORT=`
> on the `DAEMON` line.

A box that must license standalone uses a node-locked file instead:

```bash
sudo it-fpga license --file /path/to/License.dat
```

That installs it `0600 root:root`, replaces Microchip's `<put.hostname.here>`
placeholder, and serves it from a **systemd unit** (`fpga-lmgrd.service`). The
vendor guides start `lmgrd` from a sourced environment script, which launches a
fresh daemon for every shell — that is what produces the stale daemon squatting
on the port, and the `lsof -i :1702` dance those guides then tell you to do.

### Who can use them

`root` owns the trees; **members of `sentry` may read and execute them; nobody
else can read them at all**. That gives every engineer the full toolchain —
Vivado, Vitis, Libero, Synplify, the programmers, licence checkout — while
nobody can modify a shared install.

Every standing account joins `sentry` (it also owns `/home/shared`), so a new
engineer created with `it-adduser` has full use with no extra step.

The pull enforces this. It tests **one file** per tree, so a correct box does no
work; only a tree that is actually wrong gets a recursive pass. That matters
because the state it corrects is not an edge case — it is what `umask 077` plus
a `sudo` install produces every single time.

```bash
sudo it-fpga status      # who can use each tree, and why not if they cannot
sudo it-fpga fixup       # apply it now rather than waiting for a pull
```

Change the group with `fpga_tools_access_group`, or set
`fpga_tools_enforce_access: false` to manage the modes yourself.

Nothing needs to be writable inside the install trees. Vivado keeps per-user
data in `~/.Xilinx`, both write projects wherever the user puts them, and FlexLM
uses `/usr/tmp` (which the role creates `1777`, sticky, so it is shared safely).

**One exception: Libero's IP vault** (`/opt/microchip/common`, set at install
time and changeable in Libero's settings). Libero writes into it whenever anyone
downloads or imports an IP core, so it is `root:sentry` **2775** — group
writable, setgid so a core one engineer adds stays group-owned and the next
engineer can use it. It sits beside the install tree, not inside it, so the
read-only pass never touches it. It is shared on purpose: a per-user vault means
the same multi-gigabyte core downloaded once per engineer.

```yaml
fpga_libero_vault_dir: /opt/microchip/common    # defaults/main.yml
```

### Never run the tools as root

Once the permissions are fixed, run them as yourself. Two things break under
`sudo`:

- **X11.** Root does not have your `.Xauthority` cookie, so a GUI launched from
  an RDP or desktop session dies with *"Authorization required, but no
  authorization protocol specified"* and `Can't connect to X11 window server`.
  That is not a display problem — it is the wrong user.
- **Your project files.** Anything Vivado writes ends up root-owned in your
  home directory, and you will be back with `sudo` forever.

If you find yourself reaching for `sudo` to launch an FPGA tool, the tree
permissions are wrong. Fix those instead:

```bash
sudo it-fpga status      # says "ROOT-ONLY" when this is the problem
sudo it-fpga fixup
```

### Launching them

**The installers do not create working shortcuts.** They make them only when the
install config asks, and a `--batch Install` run under `sudo` writes them to
`/root/Desktop`, where no engineer will ever see them — so a correctly installed
Vivado looks, from the desktop, exactly like a missing one. No reboot changes
that; there is nothing to find.

The pull creates them instead, system-wide, once a toolchain is actually
present: **Vivado**, **Vitis** and **Libero SoC** appear in the app grid for
every user, and `vivado`, `vitis` and `libero` work as commands:

```bash
vivado          # a wrapper in /usr/local/bin; sources settings64.sh for
libero          # that one process, not for every login shell on the box
```

If a tile is missing after an install, the pull has not run since:

```bash
sudo it-pull full
sudo it-fpga status          # is the tree where the entries expect it?
```

A tile that is present but whose tool has been removed says so in a dialog
rather than failing silently.

For a shell with the full vendor environment — `vivado -mode tcl`, the Vitis
command-line tools, Synplify:

```bash
vivado_env      # then the whole toolchain is on PATH in that shell
libero_env
sudo it-fpga env          # exactly what a user gets, and from which file
```

`settings64.sh` is deliberately **not** sourced for every login shell — it
prepends a large `PATH` and `LD_LIBRARY_PATH` for users who never touch Vivado,
and has broken unrelated system tools that way.

### Programmer cables

```bash
sudo it-fpga cables       # what is plugged in, and whether it can be reached
```

> **The udev rule is not enough on its own.** USBGuard authorises a device
> before udev ever names it, so a JTAG cable is blocked no matter what the rule
> says. Enrol each one once — `sudo it-usb enroll`, then re-plug. Same workflow
> as the dongles and COM adapters. `sudo it-usb blocked` shows what is being
> refused right now.

Engineers get device access through the `plugdev` (JTAG) and `dialout`
(USB-serial console) groups. Both are in `local_users_common_groups`, so every
standing account has them — there is no per-person `adduser` step.

The rules set `MODE="0660"` with a group, **not** the `MODE="0666"` both vendors
ask for: a world-writable device node is a finding and buys nothing over a group.

### The 32-bit libraries you will not get

Ubuntu ships only a **curated i386 subset** on 24.04 — the full 32-bit archive
stopped after 19.10. Several libraries every vendor guide lists cannot be
installed on noble: `libgtk2.0-0t64:i386` is published, but its dependencies
reach `libgnutls30t64:i386` and `libgcrypt20:i386`, which are not. The role asks
apt to resolve each one and installs only what actually resolves, **naming the
rest** rather than failing the pull:

```bash
sudo it-fpga check      # what is missing, and what it means
```

A vendor component that needs one of them will not start — that is the 32-bit
GUI half of Libero/Synplify and Vivado's cable drivers. **Do not pin a version
or side-load a foreign `.deb` to force one in**; find out on the pilot box
whether the component you actually need works without it.

### Before you trust it

Prove a full flow on the golden box — synthesis, licence checkout, and
programming a real device — before cutting the image. **These boxes run a FIPS
kernel and both toolchains bundle their own crypto.** This fleet has been bitten
by that twice: vLLM and Docling abort at startup without a FIPS provider, and
ClamAV reported every file clean while scanning *zero bytes*, because FIPS
refuses MD5. `it-fpga check` says so when FIPS is on.

---

# 3. Routine operations

## 3.1 Check a box

```bash
sudo it-status        # everything
sudo it-host          # OS, kernel, FIPS, uptime, disks
sudo it-luks          # encryption + TPM binding
sudo it-checklist     # the org checklist, one line per item
sudo it-inventory     # hardware/serials/listening ports -> /opt/it/inventory-<host>.txt
```

`it-checklist --fail-only` shows just what needs attention. Exit 0 means nothing FAILed; N/A and MANUAL never count as failures.

**`sudo it-checklist --fix`** adds a section after the table telling you how to close every FAIL, and what each MANUAL item needs from a human. It **prints steps and changes nothing** — several of the remedies restart auth or the firewall, which is not a decision a status command should make on its own.

## 3.2 Produce compliance evidence

```bash
sudo it-stig status       # what is staged, what is missing, when it last ran
sudo it-stig run          # scan + build the DISA checklist
sudo it-stig archive      # tar the evidence set for hand-off
```

Output: `/opt/ia/stig/checklists/<host>-<ts>.cklb`, plus the scan artifacts in `/opt/ia/oscap/manual/`.

`it-stig` wraps `it-oscap` (the scanner) and `it-ckl` (the checklist builder); run either alone when you only need one half.

**DISA's manual STIG XCCDF ships in the repo** (`roles/scap_scan/files/`) and lands on every box, so there is nothing to fetch from cyber.mil per machine.

**Where evidence comes from — three places, and a routine pull is not one of them.**

| Source | When | Lands in |
|---|---|---|
| A box's **first build** | once, at imaging | `/opt/ia/oscap/build/`, `/opt/ia/usg/` |
| The **weekly timer** | `oscap-scan.timer`, `Persistent=true` so a run missed while powered off fires at next boot | `/opt/ia/oscap/scheduled/` |
| **On demand** | `sudo it-stig run` | `/opt/ia/oscap/manual/` |

A pull used to run three full benchmark evaluations plus a checklist build *every time*, which is minutes of scanning to deploy a one-line change and a pile of near-identical result sets to prune. `usg_audit_on_pull` and `scap_scan_on_pull` (both `build`) now hold that to the first build; `sudo it-pull full` passes `always` when you want a fresh set immediately. The `.cklb` is built whenever a scan actually runs.

On a new STIG release: drop the new `*Manual-xccdf.xml` into `roles/scap_scan/files/`, point `scap_stig_manual_xccdf` at it, and delete the old one — `it-ckl` takes the newest match, so leaving both makes "which release is this checklist against" a guess.

A scheduled scan already runs weekly into `/opt/ia/oscap/scheduled/`:

```bash
systemctl list-timers oscap-scan.timer
```

## 3.2b Scan files brought on from removable media

After copying anything onto a box — before you use it, and before it moves anywhere else:

```bash
sudo it-clamav scan /opt/dta/incoming
sudo it-clamav scan /home/austin_case/Downloads/batch.zip /mnt/usb
```

It proves the engine detects the EICAR test file **first** and refuses to scan if it does not, because on a FIPS host ClamAV loads every signature and then scans zero bytes, reporting everything clean (trap 4). A CLEAN verdict from an unverified engine is worse than no scan.

| Result | Exit | Meaning |
|---|---|---|
| CLEAN | 0 | 0 infected, engine verified |
| INFECTED | 1 | Do not move the data. Isolate the media and report it. |
| PARTIAL | 2 | 0 infected, but files could not be read — they were **not** scanned. Re-run as root or fix permissions. |
| ENGINE-FAULT | 2 | No scan summary produced. Treat as not scanned; run `sudo it-clamav test`. |

Every run appends to `/var/log/clamav-scan.log` (timestamp, who, paths, verdict).

**For a transfer that needs a signed record** — who moved what, when, with per-file hashes — use `dta-log` instead. It scans *and* writes the transfer record in one step. `it-clamav scan` is the quick check; `dta-log` is the evidence.

## 3.2c Run the PowerStrux audit and read the report

```bash
sudo it-powerstrux              # run the audit (a few minutes)
it-powerstrux open              # open the newest report
it-powerstrux status            # schedule, last run, next run
```

Or from the app grid: **PowerStrux Audit** to run one, **PowerStrux Report (open
latest)** to read it. It also runs itself on a schedule (Wednesday 03:00 by
default, `it-powerstrux schedule "<spec>"` to change — the change is written to
`/opt/it/site.yml` as well as the timer, so a pull does not revert it).

> **The report will not open from `/opt/_AuditFiles` by double-clicking it, and
> that is not a permissions problem.** Firefox on 24.04 is a **snap**: it runs in
> its own mount namespace that contains your home directory and nothing under
> `/opt`. Pointed at `file:///opt/_AuditFiles/<report>.html` it says *File not
> found* about a file that is right there and readable to you. No `chmod` helps —
> the path does not exist inside the sandbox.
>
> `it-powerstrux open` copies the newest report to `~/PowerStrux-Reports/` (0600
> in a 0700 directory) and opens the copy. A finished audit run stages a copy for
> you automatically and prints the path. **The copy carries the same handling as
> the original** — it inventories the system.

Reading it needs membership of the `audit` group (`/opt/_AuditFiles` is
`2770 root:audit`); `id -nG` should list it.

## 3.2c-i Install PowerStrux

PowerStrux is vendor software and is **not** in this repo. Stage the zip and run
one command:

```bash
sudo cp PowerStrux*.zip /opt/it/installers/
sudo it-powerstrux install
```

It unpacks the archive, finds `Initiate-PowerstruxLA.ps1` inside it (by the
entry point, not by an expected folder name — the zip's top level has varied
between releases), puts the module where PowerShell looks for it, and sets the
reporting window and report directory in `PowerStruxLAConfig.txt`:

| | |
|---|---|
| Module | `/opt/microsoft/powershell/7/Modules/ReportHTML/`, `root:root`, world-readable, nothing writable |
| Reporting window | 8 days (`--days N`) — a weekly run then always overlaps the previous one, so no day falls between two reports |
| Report directory | `/opt/_AuditFiles` (`--dir PATH`) |

Then pick up the parts the pull skips until the tool exists:

```bash
sudo it-pull scripts     # desktop icon + weekly schedule
sudo it-powerstrux       # run it once and read the report
```

`install` also searches attached media, so on an air-gapped box the zip can stay
on the USB stick: `sudo it-powerstrux install --zip /media/<user>/<vol>/PowerStrux.zip`.

**Re-running it is safe.** An existing `PowerStruxLAConfig.txt` is kept, because
it is hand-tuned per site — that is the same reason the pull never writes it.
`--force-config` replaces it with the vendor's. Any previous module directory is
moved aside to `ReportHTML.bak-<timestamp>` rather than deleted.

**It never invents a config key.** A key is edited only where it already exists
in the vendor's file, so if a release renames one you get a clear "not found"
plus a printout of the keys the file actually has — never a silently appended
line the tool ignores, and never a mangled config an assessor reads months
later. Name the right key yourself with `--days-key` / `--dir-key`, or set them
once in `group_vars`.

```bash
sudo it-powerstrux config --days 8 --dir /opt/_AuditFiles
sudo it-powerstrux config --days-key EventLogDays --days 8
```

> `it-powerstrux` itself is installed on **every** box, whether or not
> PowerStrux is. It used to live inside the block gated on the tool being
> present, so the command that installs PowerStrux was the one thing you could
> not run — and "there is no `it-powerstrux` on this profile" looked like a
> profile gate when it was a bootstrap ordering bug. What still waits for the
> tool is the desktop icon, the schedule, and anything that runs it.

## 3.2d Send the report off the box (`it-powerstrux offload`)

The audit is only half the job — until the report leaves the box, a reimage
loses the evidence. `it-powerstrux offload` collects **the week's report, the
run logs behind it, and the config that produced it** into one dated folder and
copies that folder to a Windows file share.

```bash
sudo it-powerstrux offload            # what is collected, where it goes, last run
sudo it-powerstrux offload setup      # share, folder, account -- the whole thing
sudo it-powerstrux offload test       # prove the share works, do not wait a week
sudo it-powerstrux offload run        # build and push this week's folder NOW
```

`setup` writes **both** `/etc/stig-build/powerstrux-offload.conf` (which takes
effect immediately) **and** `/opt/it/site.yml` (so the next `ansible-pull` keeps
it). Every other command does the same. Editing the conf by hand works until the
next pull puts it back — that is the trap this avoids.

### The week folder

One folder per ISO week, `<YYYY>-W<nn>`, the same name locally and on the share:

```
//fileserver/audit$/dev-13/2026-W36/
    MANIFEST.txt              what is in here, with sha256 for every file
    powerstrux/               the report(s) this week produced
    powerstrux/logs/          the run logs behind them
    powerstrux/PowerStruxLAConfig.txt
    audit/                    the auditd archive   (off by default)
    containers/               `docker logs` per container (off by default)
    logs/                     anything else you added with `extra add`
```

`MANIFEST.txt` names the host, the profile, the baseline commit the box is
running and a sha256 for each file — an assessor opening the folder a year later
can tell which box and which build it came from.

The window is **8 days, not 7**: a run that slipped a day (the timer is
`Persistent=true` and catches up after the box was powered off) is still picked
up by the next offload. If a week produced no report the folder is still built,
the manifest says so, and the run prints a warning.

**The local copy is always kept**, in `/opt/ia/powerstrux-offload/<week>/`, even
when the push succeeds. A share that is unreachable, full or misconfigured must
never be why a week's evidence went missing. The newest 26 weeks are held and
then pruned. On an air-gapped box leave the share off — the folder is what the
DTA carries out on media.

### The account on the Windows side

`it-powerstrux offload creds` asks which kind of account this is, because
`mount.cifs` wants a different thing in each case:

| Choice | What is written | When |
|---|---|---|
| **1 Domain account** | `domain=CORP` | an AD service account. **This box does not have to be joined** to the domain |
| **2 Local account on the file server** | `domain=<the server's own name>` | a workgroup / standalone file server. `WORKGROUP` works on some servers and silently fails on others, so this defaults to the share's host |
| **3 Guest** | no credentials file | rarely works — SMB2+ refuses guest by default |

The account needs **Share = Change** and **NTFS = Modify** on the target folder.
Read-only is the most common misconfiguration and it fails at the `mkdir` of the
week folder, which `it-powerstrux offload test` reports in those words.

The password goes to `/etc/stig-build/powerstrux-offload.cred`, `0600 root:root`
— never to `site.yml`, never to the repo. It is not passed on a command line
either: `mount.cifs` gets `credentials=<path>`, so the secret never appears in
`ps`. Choosing guest **moves an existing credentials file aside** rather than
deleting it.

> **The share is not mounted between runs.** There is no `fstab` line and no
> automount unit: the job mounts it on `/run/powerstrux-offload.mnt`, copies,
> and unmounts — in every path, including failure. For the full write-up of the
> credential handling, the transport, and how to force SMB3 encryption, see
> [compliance.md → Getting evidence off the box](compliance.md#getting-evidence-off-the-box-how-the-smb-offloads-actually-work).

### Adding other logs

```bash
sudo it-powerstrux offload extra add /var/log/clamav-scan.log
sudo it-powerstrux offload extra add '/opt/_AuditFiles/*.csv'   # a glob, quoted
sudo it-powerstrux offload extra remove /var/log/clamav-scan.log
sudo it-powerstrux offload extra                                 # list them
sudo it-powerstrux offload audit on        # add the auditd archive as well
sudo it-powerstrux offload containers on   # add `docker logs` per container
```

A path or a glob; **a directory is copied whole**. (The older `audit-offload`
job took files only and logged a directory as *unreadable* — this does not.)

### When it runs

Straight after each scheduled audit, not on a clock of its own:
`powerstrux-audit.service` names the offload in `Wants=`, and
`powerstrux-offload.service` is `After=` the audit. So the offload starts when
the audit **finishes**, however long the audit took — and still runs if the
audit failed, because the log of a failed run is worth carrying off too.

> This is what the old arrangement got wrong. `/etc/cron.weekly/audit-offload`
> and `powerstrux-audit.timer` were two unrelated schedules, so the offload
> could and did run *before* the week's report existed.

`it-offload` (the auditd trail, `/etc/cron.weekly/audit-offload`) is a separate
job and stays that way — see §4.4b. The AU-4 artifact an assessor opens should
hold the audit trail and nothing else. Set `it-powerstrux offload audit on` if
you would rather have one folder per week holding everything.

### When the mount fails

```bash
sudo it-powerstrux offload test          # names the failure and what causes it
sudo it-powerstrux offload log 50        # the run log
smbclient -L //fileserver -U svc_audit   # is the share name even right?
```

An older NAS or Server 2008 R2 only speaks SMB 2.1:

```bash
sudo it-powerstrux offload opts 'vers=2.1,sec=ntlmssp,uid=0,gid=0,file_mode=0640,dir_mode=0750'
```

Going the other way — a share carrying system-audit reports should be
**encrypted in transit**, which SMB3 signing alone does not give you:

```bash
sudo it-powerstrux offload opts 'vers=3.1.1,seal,sec=ntlmssp,uid=0,gid=0,file_mode=0640,dir_mode=0750'
sudo it-powerstrux offload test     # `seal` fails the mount if the server will not encrypt
```

## 3.3 Run a vulnerability scan (EMI)

```bash
sudo it-vulnscan            # nmap vuln scripts + full AV scan
sudo it-vulnscan --quick    # nmap only, minutes rather than hours
sudo it-vulnscan --list     # past scans
sudo it-vulnscan --show     # read the newest
```

Reports append to `/opt/ia/vulnscans/<host>-vuln-scan-MM-DD-YYYY.txt`. Exit is non-zero when a `vuln` script flagged something or the AV scan found/faulted.

Scans loopback by default. `--target` exists for a deliberate, authorised scope.

**nmap cannot run on the FIPS host — it runs in a container instead.** The host nmap initialises OpenSSL at startup, the FIPS provider offers it no usable cipher suite, and it quits before probing anything:

```
OpenSSL failed to create a new SSL_CTX: error:0A0000A1:SSL routines::library has no ciphers
```

Same dead end as ClamAV, for the same reason: nmap links the host OpenSSL, and Ubuntu's FIPS OpenSSL takes FIPS from the kernel flag, so no config can turn it off for one process.

**Offline, this scan is only half a scan, and it says so.** Everything in `--script vuln` probes the target directly and works air-gapped — except `vulners`, which posts the detected service versions to vulners.com. With no route out it returns nothing, in silence. `it-vulnscan` detects that (no `vulners:` section against open ports) and reports the CVE-listing half as **not run** rather than letting it read as "no CVEs found". Judge patch state from the box instead:

```bash
sudo pro security-status     # local apt data, works offline
apt list --upgradable
```

**`vulners` findings are version-string matches, not confirmed vulnerabilities.** It reads the banner — `OpenSSH 9.6p1` — and lists every CVE ever filed against that upstream version. Ubuntu backports security fixes *without bumping the version*, so a fully patched sshd collects the lot. ASP-2 reported CVE-2024-6387 (regreSSHion) while running `9.6p1-3ubuntu13.18`, many revisions past the `13.3` that fixed it. The summary separates the two:

- **CONFIRMED VULNERABLE** — a script probed the service and said so. Real until disproved.
- **LISTED by vulners** — version-matched. Confirm each before filing: `sudo pro fix --dry-run CVE-2024-6387` (authoritative, needs internet).

Note the exit code counts both, so a box with only vulners noise still exits non-zero.

**If the build fails with a wall of `out of memory`** — every package installing fine and then one postinst dying — that is not the box running out of RAM. Seen on ASP-2: `ca-certificates`' postinst failed once per certificate (146 of them) while `nmap` itself installed cleanly.

The image no longer installs `ca-certificates`, which sidesteps it — nmap's TLS scripts read what a target presents rather than validating it against a CA bundle, so the package bought nothing here.

Root cause is **not confirmed**. `RLIMIT_NOFILE` was the first theory and is **ruled out**: setting `--ulimit nofile=1024:65536` explicitly on the build changed nothing. The leading theory is FIPS — Ubuntu's *stock* `libcrypto.so.3` contains `/proc/sys/crypto/fips_enabled`, so a container on a FIPS host is not the non-FIPS OpenSSL environment it appears to be, and `docker build` has no way to apply the `fips_off` bind-mount `it-vulnscan` uses at run time. To settle it:

```bash
# 1. reproduce on the base image alone
sudo docker run --rm ubuntu:24.04 sh -c \
  'apt-get update -qq >/dev/null && apt-get install -y --no-install-recommends ca-certificates 2>&1 | tail -3'

# 2. same, with the carve-out the runtime uses. succeeds -> FIPS confirmed
sudo docker run --rm -v /etc/stig-build/nmap-fips-off:/proc/sys/crypto/fips_enabled:ro \
  ubuntu:24.04 sh -c \
  'apt-get update -qq >/dev/null && apt-get install -y --no-install-recommends ca-certificates 2>&1 | tail -3'
```

The `nmap_container` role builds an image from a stock Ubuntu base — whose OpenSSL is not the FIPS variant — and records it **only after proving it can scan**. `it-vulnscan` then tries the host binary first and falls back to the container, reporting which one ran:

```
 nmap                    : OK (via container)
```

If the host nmap ever starts working, the marker is dropped and it goes back to running natively. `--no-container` forces the host binary.

**Air-gapped**, the image cannot be built on the box. Stage it from a connected one:

```bash
sudo it-vulnscan image-save /mnt/usb     # connected box
sudo it-vulnscan image-load /mnt/usb     # fielded box -- verifies before recording
```

`image-load` runs a real scan before writing the marker. An image that loads but cannot scan is not recorded, because `it-vulnscan` would then trust it.

If neither works, `NMAP-FAULT` is recorded, `it-checklist` item 28 FAILs, and the honest fallback is to run nmap from a non-FIPS box on the same segment and file that output.

**A desktop always has unscannable files.** X11, ICE, dbus and code-server sockets cannot be read by any scanner. `clamd` counts each one in `Total errors` and then **exits 2**, so the exit code alone reads "error" on a perfectly good scan. `it-vulnscan` judges by the scan summary instead: `CLEAN` with a count of unscannable special files, and `ERROR` only for errors that are *not* of that known-benign kind. The terminal shows the condensed result; the full output goes to the report, which is the evidence artifact.

| Verdict | Means |
|---|---|
| `CLEAN` | Scan completed, nothing infected. May note N unscannable sockets/FIFOs — normal |
| `INFECTED` | Something was found. Read the report |
| `ERROR` | Completed, but with errors that are not the benign unscannable kind |
| `ENGINE-FAULT` | The engine failed its EICAR self-test, or the scan produced no summary. **Nothing was scanned** |
| `SKIPPED` | `--quick`, or no engine available |

**What the AV half scans.** `/home /root /opt /srv /etc /usr/local /tmp /var/tmp /media /mnt` — where writable content actually lives, `/media` and `/mnt` included because removable media is the point on a DTA box. Not `/`: `clamdscan` has no `--exclude-dir` (that is a `clamscan`-only flag), so a `/` scan walks `/proc` printing "Failed to open file" for every task and then grinds through `/var/lib/docker`. Override with `VULNSCAN_AV_PATHS="/a /b"`.

## 3.4 Log a data transfer (EMI)

```bash
dta-log
```

Answers, in order: low-side form approved by AO and ISSM/ISSO (y/n) → DTA name → transfer type (L2H / H2H) → confirm the folder it found in `/opt/dta/incoming` or `/opt/dta/outgoing`, or type a path → it scans with ClamAV and records the verdict.

The record goes to `/opt/dta/logs`. Verdicts: `CLEAN`, `INFECTED`, `ENGINE-FAULT`, `SKIPPED`, `ABORTED`.

**`ENGINE-FAULT` means the scanner could not detect the EICAR test file** — the transfer was not scanned, whatever the file listing says. Fix the engine (§6.5) before proceeding.

## 3.5 Enrol a USB device

```bash
sudo it-usb status              # is USBGuard active, how many rules
sudo it-usb list                # devices it can see
sudo it-usb blocked             # what was refused
sudo it-usb enroll              # interactive: plug in, confirm, allow permanently
sudo it-usb allow <id> --permanent
sudo it-usb trust <id>          # allow this exact device across reboots
```

USBGuard runs on every profile including EMI. The initial policy is generated from whatever was attached at build time, so the built-in keyboard is always authorised.

### What needs enrolling, and what just works

Three classes still need `sudo it-usb enroll` once, because they are the ones
that can act on their own:

| Class | Why |
|---|---|
| `08:*:*` mass storage | moves data on and off the box |
| `03:*:*` HID | a BadUSB keystroke injector presents as a keyboard |
| `e0:*:*` wireless controller | a radio can pair a keyboard |

Everything else — USB-serial adapters, hubs and docks, printers, audio, video,
cameras, and the JTAG programmers (which present as vendor-specific) — is
authorised on connect. Before this, *every* device needed enrolling, which is a
lot of friction for classes that cannot do the thing USBGuard defends against,
and the predictable end state is somebody switching the daemon off.

The rule is one line at the **end** of `/etc/usbguard/rules.conf`:

```
allow with-interface none-of { 08:*:* 03:*:* e0:*:* }
```

Three things about it are deliberate:

- **`none-of`, so composite devices are judged by everything they present.** A
  flash drive that also claims a HID interface is still caught. An allow-list
  written the other way round would miss it.
- **At the end of the file, because USBGuard is first-match-wins.** The
  generated per-device rules sit above it, so the built-in keyboard and
  trackpad match their own rule and are unaffected.
- **An `allow`, never an explicit `block`.** `it-usb allow --permanent` appends
  *below* this line; a HID device does not match it, so evaluation falls through
  to the new rule and enrolment works. A `block with-interface { 03:*:* }` would
  shadow every keyboard anyone ever enrols.

Turn it off with `usbguard_class_policy_enabled: false` (the line is then removed
from the policy, not just ignored), or change the list with
`usbguard_manual_classes`.

**USBGuard is the layer that governs non-storage devices.** Blacklisting the USB
mass-storage drivers (`usb-storage` + `uas`, everywhere except the classified EMI
laptop) stops USB *drives* only — dongles, serial/COM adapters, printers, HID and
everything else still enumerate normally. What stops them is USBGuard's
allow-list.

### Who can actually use removable media

Two independent layers, and it is worth being clear which does what:

| Layer | What it decides | Where it applies |
|---|---|---|
| USBGuard | whether the kernel authorises the **device** at all — any class | every profile, EMI included |
| `usb-storage` + `uas` blacklist | whether a USB **drive** can bind a driver, for everyone including root | everywhere `usb_storage_enabled` is false — development, ai, baseline, emi-unclass |
| `dta` group (udev + udisks2 polkit) | which **accounts** may mount removable media | classified EMI only (`local_usb_transfer_enabled`) |

So on the **development workstations** there is no dta gate because there is
nothing to gate: USB mass storage is disabled outright, for standard users,
admins and auditors alike. That is stricter than "only dta may mount", and
`UBTU-24-300039` passes with no deviation to adjudicate.

On the **classified EMI laptop** the picture is the one you described: the
module is loaded, and the `dta` group is the only group that may mount. Standard
users, admins and auditors cannot.

If a development box ever genuinely needs removable media, set
`usb_storage_enabled: true` **and** `local_usb_transfer_enabled: true` in that
box's `/opt/it/site.yml` — the first loads the driver, the second creates the
dta group and the mount policy. Expect `UBTU-24-300039` to open, with the
adjudication rendering into the checklist.

A device that is refused shows up in `sudo it-usb blocked` — that, not a broken
cable, is the usual reason a new dongle "does nothing".

### "USBGuard allowed it and it still isn't there"

`blocked` cannot answer this one. A device USBGuard **authorised** still does
nothing if no driver can claim it — and a USB stick *or a USB DVD/CD reader*
needs `usb-storage` (plus `uas` on USB3), which is blacklisted wherever
`usb_storage_enabled` is false. The device enumerates, `dmesg` says `authorized
to connect`, `lsusb` lists it, and no `/dev/sr0` or `/dev/sd*` ever appears —
absent from `blocked` precisely *because* USBGuard allowed it.

`sudo it-usb status` now reports this directly:

```
usb mass storage: BLACKLISTED by /etc/modprobe.d/zz-stig-usb-storage.conf
optical devices : 
```

**Optical media on the EMI laptop.** EMI-classified already has
`usb_storage_enabled: true`, so the blacklist is removed there and a USB DVD
reader works — **with USBGuard still gating every device**, so the drive is
enrolled once like any other peripheral. If a box has the blacklist and should
not, the usual cause is that it was pulled under the wrong profile (see §1.10);
fix the profile and pull. `usg_remediate` removes the file, loads the drivers in
the same run, and tells you to re-plug: a device attached while the drivers were
blacklisted was probed once, found nothing, and is not re-probed on its own.

To allow removable media on a profile that normally blocks it, set
`usb_storage_enabled: true` in that box's `/opt/it/site.yml` and pull. USBGuard
remains the gate; UBTU-24-300039 opens on that box and the adjudication text
renders into the checklist automatically.

## 3.6 Back up an EMI box

Offline SSD duplication, by hand, **logged on paper**. Nothing on the box records it and nothing here tries to — `it-checklist` item 23 reports MANUAL and you verify it against the paper record.

> The clone is a full copy of a LUKS-encrypted disk. The spare inherits the original's classification and handling, and needs the same storage.
>
> Nothing in this process rehearses a restore. A clone nobody has booted is a hope, not a backup.

Development / AI / baseline boxes need nothing here — nothing primary is stored locally.

## 3.6b Review the accounts

```bash
sudo it-users                       # the table
sudo it-users --csv --out /opt/ia/accounts-$(hostname).csv
```

One row per account: type, state, **days until the password expires**, last login,
groups. Read-only — it changes nothing, so it is safe to hand to an assessor mid-review.

Password expiry is computed from `/etc/shadow` (`lastchg + max - today`) rather than
parsed back out of `chage -l`, whose dates are localised. `CHANGE NOW` means the forced
change after a reset; `EXPIRED 10d ago` means they cannot log in until they set a new one.

> **"never" under LAST LOGIN does not prove they never logged in.** It comes from
> `/var/log/lastlog` (written by `pam_lastlog`, which is deprecated and not in the 24.04
> stack) and from `wtmp`, which rotates. Treat it as "no record", not as evidence.

`it-passwd --list` is the shorter view with the faillock counter; `it-users` is the one
with expiry and groups.

## 3.6c VS Code and code-server for the engineers

### One copy of the extensions, not one per person

The extension set lives once in **`/opt/vscode-extensions`**. Each user's
`~/.vscode/extensions` (and `~/.local/share/code-server/extensions`) holds
**symlinks** into it, so an account costs bytes rather than the 3.0 GB /
27,395 files a real copy costs — which is what made a single `useradd` take
65 seconds when the set was seeded into `/etc/skel`.

```bash
sudo it-vscode                 # what is shared, and who is linked
sudo it-vscode link <user>     # link one account
sudo it-vscode link --all      # every human account
sudo it-vscode verify          # ask VS Code itself what it can see
```

New accounts get the links from `/etc/skel` automatically — `useradd` copies
symlinks as symlinks, so it stays instant. The pull links existing accounts on
every run, so adding an engineer needs no extra step.

**Users can still install their own extensions.** The directory is theirs and
writable; only the shared entries are links, and a real directory of the same
name is never replaced by one. `code --uninstall-extension` on a shared one
removes that user's *link*, not the store.

> **Verify this on the pilot box.** VS Code builds its extension list from a
> manifest (`extensions.json`), not by scanning the directory, so the links are
> only useful if the editor accepts the shared manifest. `sudo it-vscode verify`
> asks the editor directly. If it lists nothing, that version needs a real copy
> for that user — `sudo it-vscode copy <user>` — and the store is still worth
> having as the source.

### code-server, one per engineer

code-server is **single-user per instance** — there is no multi-tenant mode — so
every user gets their own, on their own port:

```
port = dev_code_server_port + (uid - dev_code_server_uid_base)
```

Derived from the UID, not from a position in a list, so removing one engineer
does not move everyone else's port. With the defaults, uid 1000 → 8080, 1001 →
8081, and so on.

```bash
sudo it-codeserver                    # who, on what port, and is it up
sudo it-codeserver password <user>    # their password (generated, root-only)
sudo it-codeserver url <user>
sudo it-codeserver restart <user>
sudo it-codeserver log <user> 100
```

**Entitlement is group membership.** Anyone in `dev_code_server_group`
(`sentry` by default — the group every standing account joins) gets an
instance on the next pull. Remove them from the group and the next pull stops
and disables it. Don't enable the unit by hand; the pull won't know about it.

Two filters apply automatically:

- **Accounts that cannot log in are skipped.** `auto_audit` is in `sentry` and
  is deliberately locked — a service for it would be a listening port nobody
  can use.
- **A UID outside the port span is skipped**, loudly, rather than landing on a
  port the firewall does not cover or on something else's.

The `dta` and `audit` accounts are in `sentry` too, because every standing
account is. Exclude them if you would rather they had no IDE:

```yaml
# /opt/it/site.yml
dev_code_server_exclude: [bob_smith_dta, amy_lee_aud]
```

### What this puts on the network

Each instance is password-authed over self-signed TLS, with its **own**
generated password in `/etc/code-server/<user>.password`, root-only. `ufw`
rate-limits the whole range rather than a single port.

> **These are on the LAN.** N ports, one per engineer, each a full IDE with
> shell access as that user. That is a real surface and an assessor will ask
> about it. To take them off the LAN entirely:
> ```yaml
> dev_code_server_bind_addr: 127.0.0.1
> ```
> The pull then removes the ufw rule as well. Users reach it from the RDP
> desktop's browser, or over a tunnel: `ssh -L 8080:127.0.0.1:<port> <box>`.
>
> Keep `dev_code_server_port_span` as tight as the number of engineers — it is
> exactly what is reachable.

## 3.7 Create a user account

```bash
sudo it-adduser
```

It asks the type, and both the username suffix and the groups follow from it:

| Type | Username | Groups |
|---|---|---|
| standard | `first_last` | `sentry` |
| dta | `first_last_dta` | `dta`, `sentry` |
| admin | `first_last_adm` | `sudo`, `sentry` |
| audit | `first_last_aud` | `audit`, `sudo`, `sentry` |

Then the name, then **how to set the password** — the same three-way question `it-passwd` asks:

| | |
|---|---|
| **1) Set one now** | you type it, checked against this box's policy |
| **2) Temporary password** | generated here and shown once. Read it to the user; nothing writes it to disk |
| **3) Leave it locked** | no password at all; set one later with `it-passwd <user>` |

Both password options force a change at first login, so neither you nor a generator ends up knowing what the user actually logs in with. `--no-expire` skips that for a typed password and is **ignored for a temporary one** — a temporary password nobody has to change is not temporary.

Non-interactive: `sudo it-adduser --type admin --first Jane --last Doe --temp` (or `--lock`). Without one of those and with no terminal to ask on, it stops rather than guess. `--dry-run` shows what would happen.

After the account exists it also sets the **account picture** (the GE emblem) by
writing `Icon=` into `/var/lib/AccountsService/users/<user>` — GNOME reads
AccountsService, not `~/.face`, so without this a new account shows the generic
avatar until the next pull happens to enumerate it — and, on a box with the VS
Code set installed, **offers** to copy it in, showing the size first. It is not
inherited automatically any more: the set is measured in GB and `useradd -m`
copies `/etc/skel` in full for every account. `--vscode` / `--no-vscode` decide
it without asking.

> **The build does not know about a hand-created account.** A rebuilt or re-imaged box will not have it. `it-adduser` prints the exact `local_users` line to paste into `group_vars/all.yml` — do that, or the account exists on one box only.

Passwords are checked against this box's own `pwquality` policy before being set. `chpasswd` does not go through PAM, so without that check a weak password would slip onto a hardened box. **A generated password is run through the same check**, so it can never be one the box would have rejected — the check, the generator and the prompt live in one file (`pw-common.sh`) that both commands source, precisely so they cannot drift apart.

Generated passwords are 20 characters with all four character classes, and deliberately contain no `0`/`O`/`1`/`l`/`I` or `:` — it gets read off one screen and typed on another, once, by someone who did not choose it, and a misread character is indistinguishable from "the reset did not work".

### What each password option does

Both `it-adduser` and `it-passwd` ask the same three-way question, and the
three answers differ in **who ends up knowing the password**:

| Choice | Result |
|---|---|
| **1 Set one now** | You type it, and that **is** the account's password. No forced change. The account is unlocked, faillock cleared, and the ageing clock restarts from today |
| **2 Temporary password** | Generated, shown once, stored nowhere. **Always** forced to change at first login — a temporary password nobody has to change is not temporary |
| **3 Leave locked / Keep current** | No password is set. `it-passwd` still unlocks and clears faillock |

Option 1 is for handing a password over in person. Option 2 is for one you read
off a screen and pass on, where you should not keep knowing it.

Override per run if you need to: `--expire` forces a change even on a typed
password, `--no-expire` is the default for one (and is ignored for a temporary
password).

> `it-passwd` also **clears an account expiry that is already in the past**,
> since that blocks login however good the password is and someone resetting a
> password is trying to get that person logged in. A *future* end-date is
> deliberate and is only reported.

## 3.8 Reset a password / unlock an account

```bash
sudo it-passwd                    # pick from a list
sudo it-passwd jane_doe_adm
sudo it-passwd --list             # every account: state, faillock, expiry
sudo it-passwd <user> --unlock-only
sudo it-passwd <user> --temp      # generated password, no prompt
```

It asks the same three-way question as `it-adduser`: **set one now**, **generate a temporary one**, or **keep the current password** and just clear what is blocking the login.

It does all three things that independently block a login, because fixing one and not the others is the usual reason someone still cannot get in:

1. sets the password (policy-checked),
2. **unlocks the account**,
3. **clears the faillock counter** — three bad attempts locks a user out regardless of the password.

It also warns when the *account* (not the password) has an expiry date set, which blocks login on its own.

> It refuses to unlock an account that has **no password hash**. `usermod -U` on a `!` placeholder leaves an empty password, which is worse than locked.

After a reset, `chage -l` reads "password must be changed" — that is the forced change at next login, not an error. The real expiry appears once they change it.

## 3.9 Set the classification banner

```bash
sudo it-set-classification UNCLASSIFIED
sudo it-set-classification SECRET
```

## 3.10 "RDP closes as soon as I authenticate"

The login succeeds, the desktop never appears, and the window shuts a second
later. Almost always a **stale session for the same user**, not a credential or
network problem.

```bash
sudo it-rdp status      # live sessions, orphans, reaping settings
sudo it-rdp sweep       # reap the orphans; live sessions untouched
```

`sweep` is safe to run with people working — an orphan is defined as an xrdp X
server whose process chain ends at init, so nothing can be managing it. If that
does not clear it, end everything for that user (**their desktop closes and
unsaved work in it is lost**, so it asks first):

```bash
sudo it-rdp reset austin_case_adm
```

### Why it happens

`gnome-session` refuses to start when the user already has a session manager
running, and **one GNOME session per user is a hard limit**. So an earlier
session that was never reaped — its `Xorg`, `xrdp-chansrv` and per-session
`xrdp-sesman` still running — makes every later login fail. sesman sees
`/tmp/.X11-unix/X10` occupied, starts the new session on `:11`, and gnome-session
there exits 1:

```
gnome-session-binary: WARNING: Session manager already running!
xrdp-sesman: [WARN] Window manager (pid 737111, display 11) exited with
                    non-zero exit code 1
```

Those two lines together are the signature. Anything else — the consent banner,
`gnome-initial-setup`, the keyring — is a different fault.

### What stops it recurring

| | |
|---|---|
| The pull will not restart `xrdp-sesman` while sessions are live | Restarting it orphans every session it holds. It defers, leaves `/run/xrdp-sesman-restart-pending`, and applies at the next reboot or the next pull on an idle box. `it-rdp status` reports it |
| sesman reaps orphans when it starts | A systemd drop-in runs `it-rdp sweep` as `ExecStartPre` |
| `xrdp-reap.timer` sweeps every 15 min | So the person who hits this is not waiting on an admin — their login just closes, and there is nothing they can do about it themselves. `dev_rdp_reap_enabled` / `dev_rdp_reap_interval` |
| Abandoned sessions time out | `KillDisconnected=true` + `dev_rdp_disconnected_time_limit` (default 8 h) |

The timeout only reaches sessions sesman still knows about, which is why the
others matter more: a session orphaned by a sesman restart is invisible to
sesman and no timeout will ever reach it.

**Reconnecting to your own session is not affected.** xrdp resumes a
disconnected session normally — `Policy=Default` matches on
`<User,BitPerPixel>`, so a different monitor, resolution or client machine
still finds your desktop, and `KillDisconnected` only fires after the grace
period. The only thing that breaks resume is a **sesman restart**, which empties
the table it matches against.

**What counts as an orphan**, and why it is asked this way: an `Xorg` that is
not a descendant of the `xrdp-sesman` systemd is currently running
(`systemctl show -p MainPID`). A PPID-of-1 test is not enough — mid-incident
there are several `xrdp-sesman` processes with PPID 1, the live one among them.
With no running sesman, nothing is treated as an orphan. The socket cleanup is
confined to `X11DisplayOffset`..`MaxDisplayNumber` (10–63), because gdm keeps
live sockets at `X1024`/`X1025` and removing those breaks the console greeter.

```yaml
# /opt/it/site.yml, or group_vars for the fleet
dev_rdp_disconnected_time_limit: 28800   # 0 disables reaping (xrdp's default)
dev_rdp_idle_time_limit: 0               # off; the screen lock covers this
```

> **`DisconnectedTimeLimit` is ignored unless `KillDisconnected` is true** —
> xrdp's own `sesman.ini` says so. Setting the timeout on its own does nothing,
> which is why the role writes both.

The grace period is deliberately generous: within it, closing the RDP window and
reconnecting later gets your desktop back as you left it. Eight hours reaps what
was abandoned overnight and never a same-day reconnect.

---

# 4. Patching

## 4.1 Patch a connected box

```bash
sudo pro security-status          # what Pro/ESM is offering
sudo apt update && sudo apt upgrade
sudo reboot                       # if the kernel moved
sudo it-oscap                     # re-scan afterwards
```

On the `ai` profile, after any kernel move confirm the GPU and FIPS both came back:

```bash
nvidia-smi
cat /proc/sys/crypto/fips_enabled
```

## 4.2 Patch an air-gapped box

Everything arrives on media, staged from a connected box that mirrors the fielded baseline.

**OS packages** — see §4.4.

**Container images and models:**

```bash
# on the connected box
sudo it-model-export /mnt/usb --images

# on the fielded box
sudo it-model-import /mnt/usb --images
sudo it-ai up
```

**Container image tags are pinned**, so `docker compose pull` is not an update. Patching a container means editing the tag in this repo and re-running the build.

## 4.3 Update ClamAV signatures

Signatures arrive as a `tar.gz` carried in on media.

```bash
sudo it-clamav                    # what is installed, how old, is the engine serving it
sudo it-clamav list               # archives waiting in /opt/it/clamavsigs
# drop the new archive in /opt/it/clamavsigs, then:
sudo it-clamav install
sudo it-clamav test               # must PASS
```

`install` validates the CVD's digital signature before touching the live database, backs up the old set, and confirms with an EICAR detection test. `it-clamav rollback` restores the previous set.

**Only `daily` ages meaningfully.** `main` and `bytecode` are published a couple of times a *year*, so a build date months back is normal. If `daily` is current, freshclam ran, and freshclam checks all three.

## 4.4 Run apt off the local repo (standalone / EMI)

The box is air-gapped with no ADM PC to serve packages, so apt reads a repo tree carried in on media.

```bash
sudo it-repo scan     # what is on the media, and what will be skipped
sudo it-repo load     # mirror it to /srv/repo -- finds the media itself
sudo it-repo enable   # park the online sources, switch apt
sudo it-repo          # status
sudo apt upgrade              # patch from the carried repo
```

**`load` finds the media and mirrors only what this box needs.** It searches the
automount paths and anything the kernel reports as removable/USB for a `dists/<suite>/Release`
— by structure, not by a folder called "repo" — so nothing has to be typed. Pass a path
(`sudo it-repo load /media/$USER/SSD/repo`) when you want a specific one.

| | |
|---|---|
| **Only this release** | The codename comes from the box's own `/etc/os-release`. The ADM media carries 22.04 and 24.04 side by side; a `noble` box mirrors `ubuntu/noble` and prints one line per tree it skipped. `--suite <name>` overrides |
| **All of the release's pockets** | `noble`, `noble-updates` **and `noble-security`** — a separate suite each, and apt reads only what the source file lists. `enable` and the `offline_repo` role now both write every suite the tree actually carries. `status` warns when no `-security` pocket is present, because a repo without one cannot deliver a security update no matter how many `.deb` it holds |
| **Only what changed** | Packages transfer additively on name+size — a `.deb` filename carries its version, so an unchanged one is never re-read off the USB bus. Re-loading a mostly-unchanged repo moves the handful of new files and nothing else |
| **Indexes last, and exactly** | `dists/` copies after the packages, with `--checksum --delete`. Interrupt the transfer and you are left with an index that under-promises, not one pointing at packages that never arrived |
| **Nothing is deleted** | unless you pass `--prune`. A withdrawn `.deb` left on disk is unreachable anyway once the index stops listing it |

`--dry-run` reports the transfer and copies nothing.

### Who runs it — the DTA, not the admin

On the EMI laptop the admin account **cannot mount the SSD**: mounting removable
media is restricted to the `dta` group by the polkit and udev rules in
`local_accounts`. Writing `/srv/repo` needs root. So the DTA has a sudo grant for
exactly this and nothing else:

```bash
# as the DTA, with the SSD plugged in and mounted by their desktop session
sudo it-repo scan     # confirm the media was found
sudo it-repo load     # mirror it. Asks for the DTA's password.
```

Four exact argv forms are granted — `scan`, `status`, `load`, `load --yes`,
`load --dry-run` — with **no wildcard**, so there is no path argument and no
`--suite`: a DTA cannot aim the mirror at another source or make it write outside
the repo directory. `enable` and `disable` are **not** granted; switching apt's
sources is an admin decision, made once when the box is first taken offline.
It is deliberately not `NOPASSWD` — the STIG requires sudo to authenticate, and
the run lands in `/var/log/sudo.log` with a name against it.

`it-repo` is installed as a **real file in `/usr/local/sbin`**, not symlinked into
`/opt/it/scripts` like the other `it-*` commands. `/opt/it` is `2770 root:sudo`, so a
DTA cannot traverse it — `stat()` on the symlink's target fails, bash skips the PATH
entry, and the shell says **`command not found`** for a command that is installed and
that the DTA is explicitly allowed to run. Confusing, and it cost a round trip. Running
it bare now works: the script self-elevates and sudo prompts for the DTA's password.

Steady state on a fielded box is therefore: **DTA** plugs in the SSD and runs
`sudo it-repo load`; **admin** runs `sudo apt upgrade`. Neither needs
what the other has. Turn the grant off with `offline_repo_dta_load_enabled: false`.

`enable` writes `offline_repo_enabled: true` into `/opt/it/site.yml` so the switch survives the next `ansible-pull`. Without that, the next pull re-adds the Microsoft and NodeSource repos, which are unreachable air-gapped and make every `apt-get update` stall on a timeout.

To go back online for a rebuild:

```bash
sudo it-repo disable      # restores the parked sources verbatim
```

The carried repo is **unsigned**, so apt is told to trust it. The trust boundary is the media it arrived on and the root-owned `/srv/repo`, not a signature check.

**Ubuntu Pro / ESM packages are not covered.** The tree holds the main archive only; anything shipped through ESM has to be carried in as a loose `.deb`.

## 4.3b Join a box to Active Directory

`development`, `ai` and `baseline` only. The EMI laptop stays standalone.

```bash
sudo it-domain preflight corp.example.mil   # changes nothing
sudo it-domain stage                        # download join packages for an OFFLINE join
sudo it-domain join corp.example.mil        # preflight, back up PAM, join, verify
sudo it-domain test alice                   # can it resolve a domain user?
sudo it-domain                              # status
```

> **A join regenerates the PAM stack.** `realm join` installs `libpam-sss`, whose postinst runs `pam-auth-update`, which rewrites `/etc/pam.d/common-*`. This build keeps `usg_fix_pam_stack: false` by default *because* regenerating those files is how a box in this fleet became unloggable and needed live-USB recovery.
>
> `it-domain join` backs them up first and verifies the stack afterwards with `pam-auth-check` — but **do it on a throwaway box first, and keep a second root TTY open.** Recovery is `sudo it-domain pam-restore`.

### What preflight checks

Everything that makes a join fail, before it can:

| Check | Why |
|---|---|
| `realm`, `adcli`, `kinit`, `net` present | the prerequisites the join needs |
| FQDN | AD wants `host.domain`, not a short name |
| `_ldap._tcp` / `_kerberos._udp` SRV records | this is what realmd actually discovers — DNS must be the DCs |
| Clock offset | **Kerberos rejects more than 300 s of skew** |
| TCP 88, 389, 445, 464, 3268 to a DC | Kerberos, LDAP, SMB, kpasswd, Global Catalog |
| Current PAM stack health | so you know it was sound *before* the join changed it |

### What is installed when

`ad_prep_packages` — `realmd`, `adcli`, `krb5-user`, `samba-common-bin`, `oddjob`, `oddjob-mkhomedir`, `packagekit`, `dnsutils` — ship on every non-EMI box at build time. **None of them touch PAM.**

`sssd-ad`, `sssd-tools`, `libnss-sss`, `libpam-sss` are installed **at join time only**, deliberately, because they are the ones that rewrite the PAM stack. `it-domain stage` downloads them to `/opt/it/ad-packages` so a join still works after the box is air-gapped.

### What changes, and what does not

| | Effect of joining |
|---|---|
| **Patching** | **Nothing changes.** AD membership has no effect on apt, Ubuntu Pro or ESM. WSUS does not serve Linux. |
| **Policy** | **Group Policy does not apply to Linux.** Ansible stays the policy engine and the STIG source of truth. |
| **Identity** | Domain logins, central account lifecycle, home directory at first logon, offline credential caching. |
| **sudo** | Can move to AD groups via `/etc/sudoers.d` or SSSD's sudo provider — a real gain over per-box `local_users`. |
| **SMB shares** | Replace guest/credential mounts with `--options sec=krb5`: the machine account authenticates and no share credentials are stored anywhere. |
| **Time** | Point `usg_chrony_servers` at the domain controllers. Kerberos will not tolerate drift. |

### The compliance consequence

The STIG adjudications currently de-scope the SSSD and smart-card rules on the grounds that this is a standalone box with local accounts and no directory service — `UBTU-24-100660`, `400020`, `400370`, `300020` in `ckl-answers.yml.j2`.

**Joining AD invalidates that justification.** `service_sssd_enabled` becomes genuinely applicable and should be re-selected in the tailoring rather than de-selected. It will pass, because SSSD really will be running — but it has to be a deliberate step, not a surprise at the next assessment.

It also moves the **CAC/PIV POA&M** materially closer: smart-card auth against AD is the standard path.

## 4.4a Mount a Windows / SMB file share

```bash
sudo it-smb add                 # asks for everything, one field at a time
sudo it-smb                     # every managed share, mounted or idle
sudo it-smb test <name>         # why will it not mount?
```

`add` with no arguments is the normal way in — you do not need to remember any syntax. It asks for the name, server, share, username, domain, password, mount point, read-only, and SMB version in turn, each with a default in brackets, **re-asking on bad input rather than dropping you back to the shell**. It probes the server on port 445 as soon as you name it, so you find out it is unreachable *before* typing a password. Nothing is written until you confirm at a review screen, and it offers to test the mount immediately afterwards.

The flags below exist for scripting and Ansible:

```bash
sudo it-smb add --name audit-logs --share '//logsrv.corp.local/audit$' \
  --user svc_audit --domain CORP --vers 3.1.1
sudo it-smb add --name eng --share '//fs01/Engineering' --user eng --domain CORP --ro
```

Options: `--mountpoint`, `--vers 3.1.1|3.0|2.1`, `--ro`, `--uid/--gid`, `--options "k=v,..."`.

### A guest / anonymous share, available to everyone

For a file server with no user accounts — the Linux equivalent of the login-script drive mapping on the Windows boxes:

```bash
sudo it-smb add --name pubshare --share '//fileserver/Public' --guest --group users
```

`--guest` stores **no credentials at all** (the mount option is `guest`, i.e. an empty password), so there is nothing on disk to protect or rotate. `--group NAME` makes the mount readable — and writable, unless `--ro` — by that group's members rather than root only.

**Do not do this per user.** One system automount serves everyone: it mounts on first access, survives logout, needs no login script, and there is one place to change it. If people want it to look like a mapped drive, symlink it into their home:

```bash
ln -s /mnt/smb/pubshare ~/Public          # per user
sudo ln -s /mnt/smb/pubshare /etc/skel/Public   # and for every future account
```

> Windows disables guest SMB2+ access by default from Windows 10 1709 onward. If the share works from your Windows boxes today, the server has it enabled and this will work too. Once the machines are domain-joined, replace this with `--options sec=krb5` and drop guest access entirely.

### Shares are automount units, not fstab lines

Three reasons, all of which bite on a hardened box:

- a share unreachable at boot **cannot delay or block the boot**;
- it mounts on first access and unmounts when idle, so a server that is down costs nothing until something wants the share;
- `systemctl status` and the journal give a real error, where a bad fstab line gives a boot-time message nobody sees.

The units *are* the registry — mountpoints under `/mnt/smb/<name>`, no second state file to drift.

### When it will not mount

`it-smb test <name>` walks the chain in order and stops at the first thing that is actually wrong:

```
  cifs-utils installed
  credentials /etc/stig-build/smb/audit-logs.cred (600)
  logsrv.corp.local does NOT resolve. DNS, /etc/hosts, or use an IP.
```

If it gets as far as a mount attempt, it captures **both** stderr and the kernel log — cifs puts the useful part in `dmesg`, which is why `mount error(13)` on its own tells you nothing — and translates the status code:

| What cifs says | What it tells you |
|---|---|
| `NT_STATUS_LOGON_FAILURE` | username, password or domain is wrong |
| `NT_STATUS_ACCESS_DENIED` | account is valid; no permission on the share |
| `NT_STATUS_BAD_NETWORK_NAME` | the share does not exist on that server |
| `mount error(95)` | dialect rejected — try `--vers 3.0` or `2.1` |
| `mount error(128)` | keyring rejected the credentials — suspect crypto/FIPS |

**On a FIPS host** the diagnosis warns when a share uses NTLM: if every check above is green and authentication still fails, that is the first thing to test.

Credentials live one file per share in `/etc/stig-build/smb/<name>.cred`, `0600 root:root`, prompted with the input masked and never written to the repo. `it-smb remove` shreds them.

## 4.4b Offload logs to a share (closed space)

The weekly `/etc/cron.weekly/audit-offload` job stages the rotated audit trail locally. In the closed space it can also collect container logs and push everything to an SMB share. **Off by default.**

> **This job has never collected the PowerStrux reports** and does not now. Those go out weekly through `it-powerstrux offload` — §3.2d — which is ordered after the audit run and writes one dated folder per week. Configure that one if the reports are what you need off the box.

```bash
sudo it-offload              # what is collected, where it goes, when it last ran
sudo it-offload setup        # walk through the whole configuration
sudo it-offload test         # run it NOW -- do not wait a week
```

`setup` asks four things: collect container logs, collect the Open WebUI audit trail, push to a share, and the credentials. It writes to `/opt/it/site.yml`, so the settings **survive `ansible-pull`**. Re-running it is safe — keys are replaced, never duplicated.

Individual pieces, if you prefer:

```bash
sudo it-offload containers on      # collect `docker logs` for every container
sudo it-offload push on|off        # the remote-share copy
sudo it-offload creds              # set share credentials (masked, written 0600 root-only)
sudo it-offload log 50             # last 50 lines of the run log
```

Settings take effect on the **next pull** — the job is a template rendered by `usg_remediate`, so `it-offload apply` tells you the command rather than writing a second copy of the job that could drift from the role's.

### What lands where

| Archive | Contents |
|---|---|
| `audit-<host>-<date>.tar.gz` | the rotated auditd logs, and nothing else |
| `logs-<host>-<date>.tar.gz` | container logs + any extra files you named |

Kept separate on purpose: the AU-4 artifact an assessor opens should hold the audit trail alone.

### Credentials

Never in the repo. `it-offload creds` prompts twice with the input masked and writes `/etc/stig-build/audit-offload.cred` as `0600 root:root`. The pull also warns if the push is enabled and that file is missing, rather than letting the first failure be a silent cron job a week later.

### Two behaviours worth knowing

**The local copy is always kept**, including when the push succeeds. A share that is unreachable, full or misconfigured must never be why an audit trail went missing — the push is a copy, and its failure is loud (logged, non-zero exit so cron reports it) but never destructive.

**The share is mounted on demand and unmounted straight after.** One left permanently mounted is a path onto the box and a boot-time dependency on a server that may not be there.

> `usg_audit_offload_command` **replaces the whole job**, staging included. It predates the above and is kept for a site already pushing to a SIEM its own way.

## 4.4c Forgot the apt command? `it-repo howto`

```bash
it-repo howto              # every section
it-repo howto fix          # just one: apt|find|fix|remove|hold|deb|offline|python|snap|after
it-repo howto | grep -i purge
```

A reference, not a wrapper — it prints commands and runs none, so it is safe to hand to
anyone and needs no sudo. Sections: everyday `apt`; finding what is installed and **which
repo it came from**; fixing a half-installed system; removing; holding a version; single
`.deb` files; this box's local repo; **pip on 24.04** (why `pip install` refuses, and the
venv/wheel answers); snaps; and what apt alone does not finish, like a pending reboot.

Written for an air-gapped box, where there is no internet to search from.

## 4.4d Get a new baseline onto an air-gapped box (`it-pull load`)

`it-repo` carries **packages** in on media. This carries **the baseline itself**, so a
fielded box can take a new `it-*` script or a STIG fix without ever reaching
`git.asplab.com`.

```bash
# on a connected box, onto the same media as the apt mirror
git clone --mirror https://git.asplab.com/ASPLAB/ubuntu-stig-build.git baseline.git

# on the air-gapped box, with the media plugged in
sudo it-pull load            # finds it, shows what is coming, asks, then adopts it
sudo it-pull                 # normal from here on -- no network involved
```

`load` mirrors the clone to `/srv/baseline.git` and writes `REPO_URL=` into
`/etc/stig-build/pull.conf`, which every later `it-pull` reads. Repeat the two commands
whenever there is something new to carry; the mirror is replaced each time.

| | |
|---|---|
| **It checks what it found** | a repository is only accepted if its `main` branch actually contains `local.yml` and `roles/it_scripts`. A directory named `ubuntu-stig-build.git` proves nothing, and adopting the wrong clone means running someone else's playbook as root |
| **It shows what is coming** | the commits between what this box runs and what the media holds, before anything changes |
| **It makes you type `YES`** | the next pull executes that repository as root. This is the only moment to look |
| **Admin only** | deliberately **not** in the `dta` sudoers grant that covers `it-repo load` |
| **Reversible** | delete the `REPO_URL` line from `/etc/stig-build/pull.conf` and the box goes back to the network |

> **On EMI the admin cannot mount the media** (the polkit/udev carve-out restricts that to
> `dta`), and `it-pull load` is not granted to the DTA — on purpose. Packages carried in on
> media are one thing; the baseline is *executed as root* by the next pull, so whoever
> chooses it chooses what runs on the box. The two-step is: **the DTA copies** `baseline.git`
> off the media to somewhere on disk, then **the admin runs**
> `sudo it-pull load /path/to/baseline.git`. If you decide that risk is equivalent to the
> unsigned apt repo the DTA already loads, the grant can be widened — it is a policy call,
> not a technical one.

`sudo it-pull status` afterwards shows `repo : /srv/baseline.git`, which is how you tell a
box is on carried media rather than the network.

## 4.5 Suggested cadence

| Activity | Cadence |
|---|---|
| `apt upgrade` on connected boxes | monthly |
| Review pinned image tags for upstream releases | monthly |
| Rebuild custom images (picks up npm/PyPI fixes) | quarterly, or on advisory |
| `it-oscap` + archive the report | monthly, and after any change |
| Air-gap patch run (USB cycle) | quarterly, or on critical advisory |
| ClamAV signatures on air-gapped boxes | with each USB cycle |
| Out-of-cycle | any applicable critical/IAVA advisory |

---

# 5. AI stack (`ai` profile)

Two nodes. The hostname picks the role: `dev-ai1` → System 1 (front end + chat model), `dev-ai2` → System 2 (helpers).

## 5.1 First-time setup of a node

1. Install Ubuntu 24.04 **Server**, hostname `dev-ai1` or `dev-ai2`, Ubuntu Pro selected.
2. Set the peer's IP so the containers can reach it, in `/opt/it/site.yml`:
   ```yaml
   ai_system1_addr: 192.168.1.104
   ai_system2_addr: 192.168.1.105
   ```
3. Run the build (§1.4) with `PROFILE=ai`.
4. Reboot — the GPU driver and FIPS both need it.
5. Confirm the GPU:
   ```bash
   nvidia-smi
   ```
6. Fetch the models (§5.4) and bring the stacks up:
   ```bash
   sudo it-ai up
   sudo it-ai status
   ```

## 5.2 Control the stacks

```bash
it-ai up                     # every default stack, in dependency order
it-ai up open-webui          # just one
it-ai down | stop | restart [STACK]
it-ai status | logs <STACK>
it-ai stacks                 # what this node has
```

**Start order matters.** `open-webui` is a separate stack from `pgvector`/`pgbouncer`/`redis`, so it cannot `depends_on` them. `it-ai up` handles the ordering; started alone it retries until the pooler appears.

**Stacks behind a `profiles:` tag read "n/a" in Dockge.** That is correct for the run-and-exit tools (`hfcli`, `openwiki`) and the opt-in services (`vllm-granite`, `oikb`), not a fault.

## 5.3 Switch System 1's chat model

Both chat models are served across System 1's two 48 GB GPUs and only one fits at a time.

```bash
sudo it-ai model status
sudo it-ai model granite
sudo it-ai model gpt-oss
```

## 5.4 Fetch a model

```bash
sudo it-ai run hfcli hf download <hf-repo> --local-dir /<volume-mount>
sudo it-models                # what is present, and how big
```

Volume mounts and API names are in [reference.md](reference.md).

## 5.5 Carry models to an air-gapped node

```bash
# connected box
sudo it-model-export /mnt/usb --images     # models + encodings + all container images

# fielded box
sudo it-model-import /mnt/usb --images
sudo it-ai up
```

## 5.6 Renumber the nodes

```bash
sudo it-set-ip
```

Run it on each box. It rewrites the peer address in `site.yml`, the host `/etc/hosts` entry, and every stack's `.env`.

## 5.7 Compare a box against the repo

Engineers edit compose files on the box; Ansible overwrites them on the next pull.

```bash
sudo it-stack-diff        # /opt/stacks/*/compose.yaml vs the ansible-pull clone
```

For a genuine per-box exception use `compose.override.yaml` — nothing manages that file.

## 5.8 Update a LIVE AI node without touching the containers

Brings a running node up to date on everything **except** Docker and the compose stacks — STIG remediation, audit rules, SCAP content, `it-*` scripts, GRUB, accounts, ClamAV, USBGuard.

```bash
sudo it-pull            # skips ai-runtime and ai-gpu by default -- this IS the safe path
```

`it-pull full` is equally container-safe and adds packages and a scan. Only `it-pull ai`
opts into the runtime. The long form is unchanged if you prefer it:

```bash
sudo systemd-run --unit=stig-build --collect \
  ansible-pull -U https://git.asplab.com/ASPLAB/ubuntu-stig-build.git -C main \
  -i localhost, local.yml -e deployment_profile=ai \
  --skip-tags ai-runtime,ai-gpu
```

Watch it: `sudo it-pull log` (or `sudo journalctl -u stig-build -f` for the long form)

**What `ai-runtime` covers** — the three roles that can disturb a running container:

| Role | Why it is skipped |
|---|---|
| `ai_stack` | Installs/upgrades docker-ce and notifies `restart docker` |
| `docker_hardening` | Merges `/etc/docker/daemon.json`, notifies `restart docker` |
| `ai_compose` | Rewrites every `compose.yaml` and `.env`; recreates containers when `ai_compose_deploy` is true |

`ai-gpu` is `gpu_fips_module`, which installs kernel-module packages. Nothing needs it unless the kernel is about to change, so it stays out of a routine run.

**`ai_firewall` deliberately still runs.** It only adds ufw rules and never touches a container — and `usg_remediate` re-asserts ufw on every run, so *skipping* it is the risky choice: the AI ports could end up closed.

### The containers are safe; the HOST is not untouched

Nothing outside the `ai-runtime` roles runs `docker`, `docker compose`, or writes to `/opt/stacks` — the containers are not restarted, recreated, or reconfigured. But 28 roles still run against the host, and five of them can change something an engineer would notice. **Check these before you run it, especially with people on the box:**

```bash
echo "== usg fix: will it re-run? (want: disa_stig) =="
sudo cat /var/lib/usg-harden/applied-profile 2>/dev/null || echo "  NO STAMP -- usg fix WOULD RUN"
echo "== USBGuard: already on? (want: active) =="
systemctl is-active usbguard 2>/dev/null || echo "  not active -- this run would ENABLE it"
echo "== ufw: already on? =="
sudo ufw status 2>/dev/null | head -1
echo "== free VG space (disk_expand acts only if non-zero) =="
sudo vgs --noheadings -o vg_name,vg_free 2>/dev/null || echo "  no LVM"
echo "== RAM headroom for clamd (~2 GB) =="
free -g | awk '/^Mem:/{print "  total "$2"G  used "$3"G  available "$7"G"}'
echo "== FIPS (1 = already on, no reboot pending) =="
cat /proc/sys/crypto/fips_enabled 2>/dev/null
```

| What it tells you | If it looks wrong |
|---|---|
| **No `usg fix` stamp** — `usg fix disa_stig` would run, rewriting PAM and services. The one genuinely disruptive outcome | `-e usg_fix_enabled=false` |
| **USBGuard not active** — the run enables it and builds a policy from *currently attached* devices. A KVM or console dongle plugged in later gets blocked | `-e usbguard_enabled=false` |
| **ufw not active** — the run turns it on with default-deny. Published container ports are unaffected (they bypass ufw, trap 1), but SSH/Cockpit/Dockge follow the rule set | check `ai_firewall_allow_ports` first |
| **Free VG space** — `disk_expand` grows the root LV online. Safe, but it is a live filesystem operation | `-e disk_autoexpand=false` |
| **RAM** — `clamav_container` starts clamd, ~2 GB resident | `-e clamav_container_enabled=false` |

The cautious form, if any of the above is unexpected:

```bash
sudo systemd-run --unit=stig-build --collect \
  ansible-pull -U https://git.asplab.com/ASPLAB/ubuntu-stig-build.git -C main \
  -i localhost, local.yml -e deployment_profile=ai \
  --skip-tags ai-runtime,ai-gpu \
  -e usg_fix_enabled=false -e usbguard_enabled=false \
  -e disk_autoexpand=false -e clamav_container_enabled=false
```

That still delivers `usg_remediate` (audit rules, ufw re-assert, PAM checks), `scap_scan`, every `it-*` script, `grub_password`, accounts and inventory — which is the point of the run.

`scap_scan` runs a full OpenSCAP evaluation either way: several minutes of CPU, no service impact, but it is real load on a box doing inference.

### Before you run it

Confirm the box is where you think it is, and snapshot what you are protecting:

```bash
sudo it-stack-diff                       # on-box compose vs the repo -- expect differences, that is the point
docker ps --format '{{.Names}}\t{{.Status}}' | tee /tmp/before.txt
sudo it-checklist | head -2              # which baseline it is on now
```

A dry run is available but noisy — `--check` reports "skipped" for every `command`/`shell` task, so read it as an indicator, not a contract:

```bash
sudo ansible-pull -U ... -C main -i localhost, local.yml \
  -e deployment_profile=ai --skip-tags ai-runtime,ai-gpu --check --diff
```

### Two things that will still happen

- **`clamav_container` will start a container.** Not AI, but it is a container, and clamd holds ~2 GB resident. On a node under GPU/RAM pressure decide deliberately: add `-e clamav_container_enabled=false` to skip it, and accept that antivirus does not detect on that box (see trap 4).
- **`usg_remediate` restarts auditd and re-asserts ufw.** That is the point of the run, but audit rules may need a reboot to reach the kernel (trap 13). The containers survive both.

### Afterwards

```bash
docker ps --format '{{.Names}}\t{{.Status}}' | diff /tmp/before.txt -   # nothing should have moved
sudo it-checklist
sudo it-stack-diff                       # unchanged from before the run
nvidia-smi
```

## 5.9 Connect an IDE

Client-side setup. Point Continue (VS Code) at System 1's OpenAI-compatible endpoint:

```yaml
models:
  - title: gpt-oss-120b
    provider: openai
    apiBase: http://dev-ai1:8000/v1
    model: gpt-oss-120b
    apiKey: none
```

Use vLLM's `--served-model-name`, not the Hugging Face repo path. Names are in [reference.md](reference.md).

---

# 6. Recovery

## 6.1 One account is locked out

Three bad passwords locks an account. From another admin session:

```bash
sudo faillock --user <name> --reset
```

## 6.2 Every account is locked out

Symptom: no console, no GDM, every password rejected, on a box that was working.

Cause, every time we have seen it: `/etc/pam.d/common-auth` has `pam_unix`'s `success=N` jump offset out of step with the modules beside it, so a *correct* password jumps over the auth modules and lands on `pam_deny`.

1. Boot a live USB, `chroot` into the install.
2. Restore the backup `usg_remediate` leaves beside it, or replace `common-auth` with a known-good stack.
3. Boot, and before doing anything else:
   ```bash
   sudo pam-auth-check
   ```

Prevention: `pam-auth-check` runs on every build and says plainly whether the stack can authenticate. Never reboot past a warning from it (§1.6).

## 6.3 Rotate or recover the LUKS passphrase

Changing it does **not** re-encrypt the disk and does **not** disturb TPM auto-unlock.

```bash
sudo blkid -t TYPE=crypto_LUKS -o device    # find the partition, e.g. /dev/nvme0n1p3
sudo cryptsetup luksChangeKey /dev/<part>   # current, then new twice
sudo cryptsetup luksDump /dev/<part>        # which slots are used
sudo cryptsetup luksAddKey /dev/<part>      # add another passphrase
sudo cryptsetup luksKillSlot /dev/<part> N  # remove an old one
```

> **Never kill your last passphrase slot and rely on the TPM alone.** A firmware or Secure Boot change alters the PCRs, and you would need a passphrase to get back in.

Re-vault `luks_passphrase` afterwards so a fresh image or a re-bind still authorizes.

## 6.4 TPM auto-unlock stopped working

A firmware, Secure Boot, or shim change alters PCR 7 and boot falls back to the passphrase prompt. Not a brick.

```bash
sudo it-luks              # what is bound
sudo it-luks-rebind       # unbind and re-bind to the current PCRs
```

Manual equivalent:

```bash
sudo clevis luks unbind -d /dev/<part> -s <slot>
sudo clevis luks bind -d /dev/<part> tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'
sudo update-initramfs -u -k all
```

`clevis-tpm2` is a **separate package** on 24.04. Without it the bind fails with *"tpm2 is not a valid pin"*.

## 6.5 Antivirus is not detecting

```bash
sudo it-clamav test
```

A FAIL here means the box has no working antivirus, whatever any scan reports. On a FIPS box this is expected — OpenSSL refuses MD5, which is what ClamAV hashes content with, so the engine loads every signature and then scans zero bytes and calls everything clean.

The fix is the containerised engine, applied automatically by the build:

```bash
sudo ansible-pull ...          # clamav_container self-skips unless the host engine fails
sudo it-clamav test            # must PASS
```

On an air-gapped box the image has to be carried in first (§2.4). **Allow 60–90 seconds after any restart** — clamd binds its socket only after loading ~3.6M signatures, and a test run before then falls back to the broken host engine and looks identical to a broken container.

Once upstream ships a fix, `sudo it-clamav revert` hands scanning back to the host engine. It refuses unless the host `clamscan` detects an EICAR file first.

## 6.6 The build failed

```bash
sudo journalctl -u stig-build -e         # the tail is usually enough
systemctl status stig-build
```

Then fix the cause and re-run (§1.10) — it is idempotent.

Known ones:

| Symptom | Cause |
|---|---|
| `unable to get local issuer certificate` | lab CA not trusted (§1.3) |
| `Failed to enable unit: ... is masked` | a role tried to enable a service another role deliberately masked |
| Everything after one role is skipped | that role failed; the tail of the log names it |
| `ansible-galaxy` collection errors | box has `ansible-core`, not the full `ansible` package |

## 6.7 Black screen or instant disconnect over RDP

```bash
grep WaylandEnable /etc/gdm3/custom.conf     # must be false; reboot after a change
id xrdp                                      # must include ssl-cert
sudo systemctl status xrdp
sudo journalctl -u xrdp -u xrdp-sesman
```

Also: do not be logged into the same account at the physical console at the same time. GDM's console session holds D-Bus names the RDP session needs.

## 6.8 Is this box running the fix?

Every box records the baseline revision it last pulled. `it-checklist` prints it on its second line, and `it-vulnscan` stamps it into the report header:

```bash
sudo it-checklist | head -2
cat /etc/stig-build/profile
```

Compare against `git log --oneline -1` on the repo. `unknown` means the box predates this, or `ansible-pull` did not run from a git checkout. Re-run the build (§1.10) to bring it forward.

## 6.9 Audit rules are on disk but not loaded

The STIG sets auditd immutable (`-e 2`), and the kernel then **refuses new rules until a reboot**. Rules a pull added sit in `/etc/audit/rules.d` doing nothing, and every file-based compliance check still passes.

```bash
sudo auditctl -l | wc -l                                   # loaded in the kernel
sudo sh -c "cat /etc/audit/rules.d/*.rules | grep -cvE '^[[:space:]]*(#|$)'"
sudo grep -cvE '^[[:space:]]*(#|$)' /etc/audit/audit.rules # what usg fix wrote
sudo auditctl -s | grep enabled                            # 2 = immutable
sudo augenrules --load                                     # read the errors it prints
```

`rules.d` is `0750`, so the glob must be inside `sudo sh -c '...'` — your own shell expands it first and cannot read the directory, which looks exactly like an empty directory.

If the two counts disagree:

```bash
sudo augenrules --load     # works only when not immutable
sudo reboot                # what actually loads them under -e 2
```

`it-checklist` item 6 compares the counts and FAILs when they diverge.

## 6.10 A box drifted from the repo

Nothing reports drift automatically — `ansible-pull` runs only when someone runs it.

```bash
sudo it-stack-diff        # ai profile: on-box compose vs the repo
sudo it-checklist         # config-level drift
sudo it-oscap             # STIG-level drift
```

Re-running the build (§1.10) re-asserts everything the baseline owns.
