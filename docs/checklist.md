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
| 2 | No root via SSH | **Met** | Set by `usg fix disa_stig`. | `sshd -T \| grep -i permitrootlogin` |
| 3 | DCSA banners + last login | **Met** | `classification_banner` role + SSH banner drop-in + GDM banner. | `sshd -T \| grep -iE 'banner\|printlastlog'` |
| 4 | Anti-virus | **AT RISK** | ClamAV on all profiles (daemon + weekly scan). Docker volumes excluded — scanning 60 GB of model weights is pointless I/O. **FIPS breaks ClamAV silently** — OpenSSL in FIPS mode will not initialise MD5, so on a FIPS box the engine loads its signatures and scans 0 bytes while reporting every file clean (confirmed on ASP-2, 2026-08-26). `it-clamav test` is the check that catches it; until it passes on a given box, treat that box as having no antivirus. Signatures also go stale air-gapped; **`it-clamav install` is the manual path** — drop a signature `tar.gz` in `/opt/it/clamavsigs`, it validates the CVD digital signature before installing and confirms with an EICAR test. | `sudo it-clamav test` |
| 5 | Password complexity / lockout | **Met** | USG `disa_stig`. | `sudo usg audit disa_stig` |
| 6 | Audit rules incl. reboot | **Met** | USG auditd rules. | `auditctl -l \| wc -l` |
| 7 | BIOS hardened + password | **Manual** | Per-box hardware step; not automatable. | Check at POST |
| 8 | Vendor supported release | **Met** | Ubuntu 24.04 LTS (support to ~2029; ~2034 with Pro). | `lsb_release -ds && pro status` |
| 9 | FIPS crypto (OS + drive) | **Met** | FIPS kernel via Ubuntu Pro. **Disclose:** vLLM/Docling *containers* mask `fips_enabled` because those images ship no FIPS provider — the host stays FIPS. | `cat /proc/sys/crypto/fips_enabled` |
| 10 | DARE | **Met** | LUKS, TPM-auto-unlocked (`tpm_luks_unlock`). | `lsblk -o NAME,TYPE \| grep crypt` |
| 11 | GRUB2 password | **Inert until activated** | `grub_password` role is built but skips while the hash is the `CHANGEME` sentinel. **Not redundant with LUKS here** — the TPM seals to PCR 7 only, which doesn't measure the kernel cmdline, so without it physical access → root shell on decrypted data. Activate: `it-grub hash` (fleet) or `it-grub set` (one box). | `sudo it-grub status` |
| 12 | File perms + SELinux | **Met (translated)** | Ubuntu uses **AppArmor**, not SELinux — the checklist item is RHEL-derived. Permissions are USG's. | `sudo aa-status` |
| 13 | Local accounts | **Met** | `local_accounts` manages them declaratively and purges base-image defaults. | `awk -F: '$3>=1000&&$3<65534{print $1}' /etc/passwd` |
| 14 | CUPS not running | **Met** | `usg_remediate` disables **and masks** cups, cups.socket, cups-browsed. | `systemctl is-active cups` |
| 15 | XFS + separate filesystems | **Partial** | Root is **ext4**; XFS is a RHEL-ism and **not** an Ubuntu STIG requirement. What *is* required — separate `/var`, `/var/log`, `/var/log/audit`, `/home`, `/tmp` — is an **autoinstall-seed** decision outside this repo and needs a rebuild. | `findmnt -no FSTYPE /` ; `findmnt /var/log/audit` |
| 16 | Port/process capture | **Met** | `it-inventory` records every listening socket → process → owning package, plus container port publications. | `sudo it-inventory` |
| 17 | Chrony/NTP | **Met** | `usg_remediate` writes `server` + `maxpoll` into `chrony.conf`. | `chronyc -n sources` |
| 18 | USBGuard | **Met** | Allow-list on every profile incl. EMI. Separate layer from the `dta` mount controls. Enrol devices with `it-usb enroll`. | `sudo it-usb status` |
| 19 | Solarwinds | **N/A** | Not used in this environment. | — |
| 20 | Local firewall **disabled** | **Conflict** | The build **enables** ufw. Note it's partly moot on the AI nodes: Docker's DNAT precedes ufw, so published container ports aren't filtered by it. Needs a policy decision. | `sudo ufw status verbose` ; `sudo iptables -L DOCKER-USER -n` |
| 21 | Splunk agent | **N/A** | Not used in this environment. | — |
| 22 | DNS records (COMPASS) | **Manual** | Org infrastructure. | `dig +short <host>` |
| 23 | Backup + restore | **Not met** | No backup tooling installed. Macrium SiteBackup's Linux agent is **Insider-preview only**, not GA — unsuitable for an accredited system. restic/borg are the offline-friendly options; blocked on target + scope. | — |
| 24 | Scheduled OSCAP job | **Met** | `it-oscap` on a systemd timer (or `/etc/cron.d`, via `scap_schedule_method`). Results → `/opt/ia/oscap/scheduled`. Runs as **root** because `auto_audit` is locked and can't sudo unattended. | `systemctl list-timers oscap-scan.timer` |
| 25 | iDRAC / OME | **Manual** | Server hardware, out-of-band. | iDRAC web UI |
| 26 | Current vulnerability scan | **Met (process)** | Scheduled scan produces the artifact; reviewing it is a human step. | `ls -t /opt/ia/oscap/*/stig-report-*.html \| head -1` |
| 27 | Latest STIG version | **Met** | USG content ships via Pro; SSG datastream pinned in `group_vars`. Confirm the benchmark version you're held to. | `dpkg-query -W usg` |

## Open items

1. **Backup** (23) — needs a target and scope decision. Model weights are reproducible from the USB workflow; only the databases and app data are irreplaceable.
2. **GRUB password** (11) — built, needs a hash vaulted to take effect.
3. **Firewall policy** (20) — the checklist and the build disagree; decide which is right.
4. **Partitioning** (15) — next imaging cycle; check the `usg audit` report first, it may already be flagged.
5. **ClamAV signatures air-gapped** (4) — no CVD staging path yet.

## The DISA STIG checklist

The table above is the **org** Linux checklist. The **DISA STIG** checklist (`.ckl` / `.cklb` for STIG Viewer) is a separate artifact, generated rather than hand-filled:

```bash
sudo it-stig status   # is everything staged?
sudo it-stig run      # scan + checklist -> /opt/ia/stig/checklists/<host>-<ts>.cklb
```

`it-ckl` merges DISA's manual STIG, the scan results, and the adjudications this repo carries, so `Not_Reviewed` means "needs a human on this box" rather than "not typed in yet". Full process, including which DISA downloads you need and which to avoid: [compliance.md](compliance.md#scanning-and-building-the-stig-checklist).
