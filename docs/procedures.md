# Procedures

Every task, as numbered steps. Find the scenario, follow the steps.

- Commands run **on the box** unless it says otherwise. `it-*` commands self-elevate with `sudo`.
- **Warning:** lines mark the places where skipping a step has cost us a box. There are only a few.
- Facts (ports, paths, volumes, config variables) are in [reference.md](reference.md). Assessor material is in [compliance.md](compliance.md).

---

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

## 1.10 Re-running the build

Safe and idempotent — Ansible applies only the delta. After changing anything in the repo:

```bash
sudo systemd-run --unit=stig-build --collect \
  ansible-pull -U https://git.asplab.com/ASPLAB/ubuntu-stig-build.git -C main -i localhost, local.yml \
  -e deployment_profile=emi
```

Reboot afterwards for anything that needs it.

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

## 3.2 Produce compliance evidence

```bash
sudo it-stig status       # what is staged, what is missing, when it last ran
sudo it-stig run          # scan + build the DISA checklist
sudo it-stig archive      # tar the evidence set for hand-off
```

Output: `/opt/ia/stig/checklists/<host>-<ts>.cklb`, plus the scan artifacts in `/opt/ia/oscap/manual/`.

`it-stig` wraps `it-oscap` (the scanner) and `it-ckl` (the checklist builder); run either alone when you only need one half. The **one** input this cannot generate is DISA's manual STIG XCCDF — download it from cyber.mil once and drop it in `/opt/ia/stig/`. `it-stig status` says so.

A scheduled scan already runs weekly into `/opt/ia/oscap/scheduled/`:

```bash
systemctl list-timers oscap-scan.timer
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

**nmap does not run on a FIPS box.** It initialises OpenSSL at startup, the FIPS provider offers it no usable cipher suite, and it quits before probing anything:

```
OpenSSL failed to create a new SSL_CTX: error:0A0000A1:SSL routines::library has no ciphers
```

Same class of failure as ClamAV, and not configurable around for the same reason — nmap links the host OpenSSL, which takes FIPS from the kernel flag. `it-vulnscan` detects this, records **`NMAP-FAULT`** in the report, exits non-zero, and `it-checklist` item 28 FAILs on it. A report that says "0 open ports, nothing flagged" because the scanner never started is not evidence.

Until it is solved, get the nmap half from a non-FIPS box on the same segment and file that output alongside the AV scan:

```bash
nmap -sV --script vuln <emi-box-ip>      # from a non-FIPS host, authorised scope only
sudo it-vulnscan --quick --no-av         # nothing useful; use the AV half instead
sudo it-vulnscan                         # AV scan still works and still counts
```

The AV half is unaffected and is the part the engine gate protects.

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

## 3.6 Back up an EMI box

Offline SSD duplication, by hand, **logged on paper**. Nothing on the box records it and nothing here tries to — `it-checklist` item 23 reports MANUAL and you verify it against the paper record.

> The clone is a full copy of a LUKS-encrypted disk. The spare inherits the original's classification and handling, and needs the same storage.
>
> Nothing in this process rehearses a restore. A clone nobody has booted is a hope, not a backup.

Development / AI / baseline boxes need nothing here — nothing primary is stored locally.

## 3.7 Set the classification banner

```bash
sudo it-set-classification UNCLASSIFIED
sudo it-set-classification SECRET
```

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
sudo it-offline-repo load /media/$USER/SSD/repo   # copy the tree to /srv/repo
sudo it-offline-repo enable                       # park the online sources, switch apt
sudo it-offline-repo                              # status
sudo apt upgrade                                  # patch from the carried repo
```

`enable` writes `offline_repo_enabled: true` into `/opt/it/site.yml` so the switch survives the next `ansible-pull`. Without that, the next pull re-adds the Microsoft and NodeSource repos, which are unreachable air-gapped and make every `apt-get update` stall on a timeout.

To go back online for a rebuild:

```bash
sudo it-offline-repo disable      # restores the parked sources verbatim
```

The carried repo is **unsigned**, so apt is told to trust it. The trust boundary is the media it arrived on and the root-owned `/srv/repo`, not a signature check.

**Ubuntu Pro / ESM packages are not covered.** The tree holds the main archive only; anything shipped through ESM has to be carried in as a loose `.deb`.

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

## 5.8 Connect an IDE

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

## 6.8 A box drifted from the repo

Nothing reports drift automatically — `ansible-pull` runs only when someone runs it.

```bash
sudo it-stack-diff        # ai profile: on-box compose vs the repo
sudo it-checklist         # config-level drift
sudo it-oscap             # STIG-level drift
```

Re-running the build (§1.10) re-asserts everything the baseline owns.
