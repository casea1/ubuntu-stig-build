# Linux checklist — status & verification

The org Linux checklist, what this build does about each item, and the command to prove it.

```bash
sudo it-checklist              # run every check, one line per item
sudo it-checklist --fail-only  # only what needs attention
sudo it-checklist --out /opt/ia/checklist-$(hostname).txt
```

Exit code is 0 when nothing FAILs. **N/A** and **MANUAL** never count as failures.
This is a fast indicator — the authoritative evidence is `usg audit disa_stig` and `it-oscap`.

| # | Item | Status | How / why | Verify |
|---|---|---|---|---|
| 1 | AD integration (SSSD) | **N/A** | Local accounts by design; the SSSD/smartcard STIG rules are de-selected as a documented deviation (`usg_disable_smartcard_rules`). No directory service on these networks. | `getent passwd \| tail` |
| 2 | No root SSH login | **Met** | This is the **root account over SSH**, nothing else: `PermitRootLogin no`, set by `usg fix disa_stig`. Admins still log in as themselves and **elevate with `sudo`** — that path is untouched, and is what makes the audit trail attributable to a person rather than to `root`. The check also reports whether `/root/.ssh/authorized_keys` holds keys (inert while `PermitRootLogin no` stands, but worth knowing). | `sshd -T \| grep -i permitrootlogin` |
| 3 | DCSA banners + last login | **Met** | `classification_banner` role + SSH banner drop-in + GDM banner. | `sshd -T \| grep -iE 'banner\|printlastlog'` |
| 4 | Anti-virus | **Met via container on FIPS boxes** | ClamAV on all profiles (daemon + weekly scan). Docker volumes excluded — scanning 60 GB of model weights is pointless I/O. **FIPS breaks ClamAV** — OpenSSL in FIPS mode will not initialise MD5, which is what ClamAV hashes file content with, so MD5-based signatures cannot be evaluated and **the EICAR test file is not detected** (confirmed on ASP-2, 2026-08-26). Upstream [Cisco-Talos/clamav#1786](https://github.com/Cisco-Talos/clamav/issues/1786), open with no fix; not configurable around — Ubuntu's FIPS OpenSSL takes FIPS from the kernel flag, so even `OPENSSL_CONF=/dev/null` fails, and `--fips-limits` does not help. The fix is `clamav_container`: clamd moves into a container whose OpenSSL is a stock build, so MD5 works, while the **host kernel stays in FIPS**. Scans go over its socket with `clamdscan --fdpass`, so a DTA needs no docker access. **On-access scanning is lost — on-demand only (POA&M).** `sudo it-clamav test` is the per-box check and must PASS before a box is relied on; air-gapped boxes need `it-clamav image-load` first, and clamd needs ~60–90s after a restart before its socket answers. **Verified on ASP-2, 2026-08-26.** Signatures also go stale air-gapped; **`it-clamav install` is the manual path** — drop a signature `tar.gz` in `/opt/it/clamavsigs`, it validates the CVD digital signature before installing and confirms with an EICAR test. | `sudo it-clamav test` |
| 5 | Password complexity / lockout | **Met** | USG `disa_stig`. | `sudo usg audit disa_stig` |
| 6 | Audit rules incl. reboot | **Met** | USG auditd rules. | `auditctl -l \| wc -l` |
| 7 | BIOS hardened + password | **Partly automated** | Two of the three parts *are* machine-readable and `it-checklist` now reads them: **Secure Boot** (`mokutil --sb-state`, falling back to the `SecureBoot-*` EFI variable) and the **BIOS admin password**, via the vendor firmware-attributes driver — `/sys/class/firmware-attributes/*/authentication/Admin/is_enabled`, exposed by `dell-wmi-sysman` / `think-lmi` / `hp-wmi-sysman`. Secure Boot off, or an admin password readably **unset**, is a **FAIL**. The rest of "BIOS hardened" — boot order, disabled ports and radios — is not readable from the OS, so a box where everything detectable looks right still reports **MANUAL** rather than passing on half the evidence. On hardware without the vendor driver both fall back to manual. | `sudo it-checklist \| grep ' 7 '` ; `mokutil --sb-state` |
| 8 | Vendor supported release | **Met** | Ubuntu 24.04 LTS (support to ~2029; ~2034 with Pro). | `lsb_release -ds && pro status` |
| 9 | FIPS crypto (OS + drive) | **Met** | FIPS kernel via Ubuntu Pro. **Disclose:** vLLM/Docling *containers* mask `fips_enabled` because those images ship no FIPS provider — the host stays FIPS. | `cat /proc/sys/crypto/fips_enabled` |
| 10 | DARE | **Met** | LUKS, TPM-auto-unlocked (`tpm_luks_unlock`). | `lsblk -o NAME,TYPE \| grep crypt` |
| 11 | GRUB2 password | **Inert until activated** | `grub_password` role is built but skips while the hash is the `CHANGEME` sentinel. **Not redundant with LUKS here** — the TPM seals to PCR 7 only, which doesn't measure the kernel cmdline, so without it physical access → root shell on decrypted data. Activate: `it-grub hash` (fleet) or `it-grub set` (one box). | `sudo it-grub status` |
| 12 | File perms + SELinux | **Met (translated)** | Ubuntu uses **AppArmor**, not SELinux — the checklist item is RHEL-derived. Permissions are USG's. | `sudo aa-status` |
| 13 | Local accounts | **Met** | `local_accounts` manages them declaratively and purges base-image defaults. | `awk -F: '$3>=1000&&$3<65534{print $1}' /etc/passwd` |
| 14 | CUPS not running | **Met** | `usg_remediate` disables **and masks** cups, cups.socket, cups-browsed. | `systemctl is-active cups` |
| 15 | XFS + separate filesystems | **N/A** | **Org requirement, RHEL-derived — not an Ubuntu STIG rule.** XFS is a RHEL default; the separate-mount list came with it. Neither is levied by the Ubuntu 24.04 STIG, so this is out of scope rather than an open finding. `it-checklist` still prints the box's actual root filesystem and which of those mounts happen to be separate, because an assessor will ask. | `findmnt -no FSTYPE /` ; `findmnt /var/log/audit` |
| 16 | Port/process capture | **Met** | `it-inventory` records every listening socket → process → owning package, plus container port publications. | `sudo it-inventory` |
| 17 | Chrony/NTP | **Met** | `usg_remediate` writes `server` + `maxpoll` into `chrony.conf`. | `chronyc -n sources` |
| 18 | USBGuard | **Met** | Allow-list on every profile incl. EMI. Separate layer from the `dta` mount controls. Enrol devices with `it-usb enroll`. | `sudo it-usb status` |
| 19 | Solarwinds | **N/A** | Not used in this environment. | — |
| 20 | Local firewall **disabled** | **Conflict** | The build **enables** ufw. Note it's partly moot on the AI nodes: Docker's DNAT precedes ufw, so published container ports aren't filtered by it. Needs a policy decision. | `sudo ufw status verbose` ; `sudo iptables -L DOCKER-USER -n` |
| 21 | Splunk agent | **N/A** | Not used in this environment. | — |
| 22 | DNS records (COMPASS) | **Manual** | Org infrastructure. | `dig +short <host>` |
| 23 | Backup + restore | **Two answers, by profile** | **EMI → MANUAL.** The box is standalone and air-gapped, so there is no file server to push to: backup is an **offline SSD duplication**, done by hand. That leaves no trace on the box, so the only on-box evidence it happened is what the operator writes into `/opt/ia/backups` — a note per duplication is enough, and `it-checklist` reports how long ago the newest one was. **Development / AI / baseline → N/A.** Nothing is kept locally; the file servers are backed up and users are directed to store there. No endpoint agent is the intended design, so there is nothing to install or check per box. (Macrium SiteBackup's Linux agent is Insider-preview only anyway, and would not be acceptable on an accredited system.) The profile comes from `/etc/stig-build/profile`, written by `it_scripts`. | `ls -t /opt/ia/backups \| head -1` |
| 24 | Scheduled OSCAP job | **Met** | `it-oscap` on a systemd timer (or `/etc/cron.d`, via `scap_schedule_method`). Results → `/opt/ia/oscap/scheduled`. Runs as **root** because `auto_audit` is locked and can't sudo unattended. | `systemctl list-timers oscap-scan.timer` |
| 25 | iDRAC / OME | **Manual** | Server hardware, out-of-band. | iDRAC web UI |
| 26 | Current compliance scan | **Met (process)** | Scheduled OpenSCAP scan produces the artifact; reviewing it is a human step. FAILs once the newest report is over 45 days old. | `ls -t /opt/ia/oscap/*/stig-report-*.html \| head -1` |
| 27 | Latest STIG version | **Met** | USG content ships via Pro; SSG datastream pinned in `group_vars`. Confirm the benchmark version you're held to. | `dpkg-query -W usg` |
| 28 | nmap vulnerability scan | **Met (EMI)** | The Linux counterpart to the org's `MUSA_Vuln_Scan` Windows job: `nmap -sV --script vuln` against this host, then a full anti-virus scan, both appended to one dated report in `/opt/ia/vulnscans`. **EMI profiles only** — `nmap` is installed there and `it-vulnscan` is placed there. FAILs when a vuln script flagged something, when the newest scan is over 45 days old, or when it has never run. The row is omitted entirely on profiles that do not carry the tool. | `sudo it-vulnscan` ; `sudo it-vulnscan --list` |

## Open items

1. **GRUB password** (11) — built, needs a hash vaulted to take effect.
2. **Firewall policy** (20) — the checklist and the build disagree; decide which is right.

Closed since the last revision: **backup** (23) is a file-server function on dev/AI and a manual SSD duplication on EMI, neither of which needs an endpoint agent; **partitioning** (15) is a RHEL-derived org item, not an Ubuntu STIG rule; **ClamAV signatures air-gapped** (4) now have `it-clamav install`, and FIPS detection is fixed by `clamav_container`.

## Which tool is which

Four commands with overlapping names. They are two pairs, and each pair is *checklist* vs *scan*:

| Command | What it is | Input | Output |
|---|---|---|---|
| `it-checklist` | **The org checklist above.** A shell script with one hand-written check per row — fast, opinionated, human-readable. A quick indicator, not evidence. | the live box | one line per item on stdout, `--out` to a file |
| `it-ckl` | **The DISA STIG checklist.** Builds a real `.cklb`/`.ckl` for STIG Viewer by merging DISA's manual STIG XCCDF (the skeleton of every V-ID), the SCAP results, and this repo's `answers.yml` adjudications. That last part is the point: `Not_Reviewed` comes to mean "needs a human on *this* box" rather than "nobody has typed it in yet". | STIG XCCDF + scan results + `answers.yml` | `/opt/ia/stig/checklists/<host>-<ts>.cklb` |
| `it-oscap` | **The scanner.** One `oscap xccdf eval` run against the SSG (or DISA) datastream, honouring the USG tailoring file. This is what the weekly timer runs. | a SCAP datastream | `stig-report-*.html`, `stig-arf-*.xml`, `stig-viewer-*.xml` in `/opt/ia/oscap/{build,scheduled,manual}` |
| `it-stig` | **The wrapper.** Runs `it-oscap` then `it-ckl` in the right order, checks the prerequisites up front instead of failing halfway, and can `archive` the evidence set for hand-off. | — | whatever the two produce, plus a tarball |

So: **`it-checklist` answers "is this box configured the way we said", `it-stig run` produces the artifact an assessor wants.** `it-oscap` and `it-ckl` are its two halves, useful on their own when you only need one.

`it-vulnscan` is separate from all four — it is the org's `MUSA_Vuln_Scan` process (nmap `vuln` scripts + a full AV scan), not a STIG artifact, and it lands in `/opt/ia/vulnscans`.

## The DISA STIG checklist

The table above is the **org** Linux checklist. The **DISA STIG** checklist (`.ckl` / `.cklb` for STIG Viewer) is a separate artifact, generated rather than hand-filled:

```bash
sudo it-stig status   # is everything staged?
sudo it-stig run      # scan + checklist -> /opt/ia/stig/checklists/<host>-<ts>.cklb
```

`it-ckl` merges DISA's manual STIG, the scan results, and the adjudications this repo carries, so `Not_Reviewed` means "needs a human on this box" rather than "not typed in yet". Full process, including which DISA downloads you need and which to avoid: [compliance.md](compliance.md#scanning-and-building-the-stig-checklist).
