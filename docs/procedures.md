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

**`sudo it-checklist --fix`** adds a section after the table telling you how to close every FAIL, and what each MANUAL item needs from a human. It **prints steps and changes nothing** — several of the remedies restart auth or the firewall, which is not a decision a status command should make on its own.

## 3.2 Produce compliance evidence

```bash
sudo it-stig status       # what is staged, what is missing, when it last ran
sudo it-stig run          # scan + build the DISA checklist
sudo it-stig archive      # tar the evidence set for hand-off
```

Output: `/opt/ia/stig/checklists/<host>-<ts>.cklb`, plus the scan artifacts in `/opt/ia/oscap/manual/`.

`it-stig` wraps `it-oscap` (the scanner) and `it-ckl` (the checklist builder); run either alone when you only need one half.

**DISA's manual STIG XCCDF ships in the repo** (`roles/scap_scan/files/`) and lands on every box, so there is nothing to fetch from cyber.mil per machine. **A `.cklb` is built at the end of every pull** from the scan that just ran — `scap_ckl_on_pull: false` turns that off.

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

## 3.6 Back up an EMI box

Offline SSD duplication, by hand, **logged on paper**. Nothing on the box records it and nothing here tries to — `it-checklist` item 23 reports MANUAL and you verify it against the paper record.

> The clone is a full copy of a LUKS-encrypted disk. The spare inherits the original's classification and handling, and needs the same storage.
>
> Nothing in this process rehearses a restore. A clone nobody has booted is a hope, not a backup.

Development / AI / baseline boxes need nothing here — nothing primary is stored locally.

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

Then the name, then the password — set now or leave the account locked. A password set now forces a change at first login (`--no-expire` to skip).

Non-interactive: `sudo it-adduser --type admin --first Jane --last Doe`. `--dry-run` shows what would happen.

> **The build does not know about a hand-created account.** A rebuilt or re-imaged box will not have it. `it-adduser` prints the exact `local_users` line to paste into `group_vars/all.yml` — do that, or the account exists on one box only.

Passwords are checked against this box's own `pwquality` policy before being set. `chpasswd` does not go through PAM, so without that check a weak password would slip onto a hardened box.

## 3.8 Reset a password / unlock an account

```bash
sudo it-passwd                    # pick from a list
sudo it-passwd jane_doe_adm
sudo it-passwd --list             # every account: state, faillock, expiry
sudo it-passwd <user> --unlock-only
```

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
sudo systemd-run --unit=stig-build --collect \
  ansible-pull -U https://git.asplab.com/ASPLAB/ubuntu-stig-build.git -C main \
  -i localhost, local.yml -e deployment_profile=ai \
  --skip-tags ai-runtime,ai-gpu
```

Watch it: `sudo journalctl -u stig-build -f`

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
