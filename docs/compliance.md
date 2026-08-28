# Security & Compliance

For the IA / assessment team and the DCSA rep. Everything here is enforced by the version-controlled `ubuntu-stig-build` Ansible baseline — repeatable, auditable, identical across the fleet.

How to *run* any of this: [procedures.md](procedures.md). Ports, paths, software inventory: [reference.md](reference.md).

## Contents

| | |
|---|---|
| [Hardening posture](#hardening-posture) | what the build enforces, deviates from, and leaves open |
| [The org Linux checklist](#the-org-linux-checklist) | met / not met / N-A per item, with the command to verify |
| [DCSA / DoD RMF posture](#dcsa--dod-rmf-compliance-posture) | authorization context, 800-53 mapping, POA&M |
| [Producing the STIG checklist](#producing-the-stig-checklist) | the two scanners, and how the `.cklb` gets built |
| [Container-runtime compliance](#container-runtime-compliance-why-no-docker-stig) | why there is no Docker STIG, and what secures the layer instead |

## Hardening posture

Both profiles apply **Canonical USG `usg fix disa_stig`** (the DISA-STIG remediation), which closes most of the benchmark. Rule-level view:

- What the build remediates on top of `usg fix`.
- What's an approved deviation.
- What stays an open POA&M.

Per-rule detail (rule IDs, rationale): the two tables below. The [DCSA / DoD RMF compliance posture](#dcsa--dod-rmf-compliance-posture) gives the same picture at the RMF level.

USG audit report auto-copies to `/opt/ia/` every run (HTML + XCCDF), readable by the admin (`sudo`) group. Regenerated after remediation + firewall, so it reflects the fully-built box. Hand it to your assessor; re-run any time:

```bash
sudo usg audit --tailoring-file /etc/usg/managed-tailoring.xml
```

### ✅ Additionally remediated by `usg_remediate` (every run, idempotent)

`usg fix` is stamped run-once and its in-role audit is a mid-build snapshot. The `usg_remediate` role runs **after** USG + the firewall and closes these (none can lose password/SSH login):

| Finding (SSG rule) | STIG ID | What we do |
| --- | --- | --- |
| Smart Card Logins in PAM (`smartcard_pam_enabled`) | n/a | comment `pam_pkcs11.so` out of the auth stack → stops the "no smart card found" spam (this fleet is **password-login only**) |
| `/var/log` file perms (`file_permissions_var_log_stig`) | UBTU-24-700010 | strip setuid/exec/other bits off log files. Done **twice** — once early, once as the last thing in the role — plus a daily `stig-log-perms.timer`. apt, dpkg and unattended-upgrades recreate their logs `0644` *after* the early pass, so a single sweep left `/var/log/dpkg.log`, `/var/log/alternatives.log` and `/var/log/apt/*.log` over-permissive by the time the scan ran. That is why this rule kept failing fleet-wide despite a fix that was itself correct |
| **Cron audit rules** (`audit_rules_etc_cron_d`, `audit_rules_var_spool_cron`) | UBTU-24-200270 | USG ships no watch on the cron spool, so this failed on every box. `/etc/audit/rules.d/72-cron.rules` adds `-w /etc/cron.d/ -p wa -k cronjobs` and `-w /var/spool/cron/ -p wa -k cronjobs`. The DISA check greps `auditctl -l` for those lines **verbatim, key included**, so the key is not a free choice. Loads on the post-build reboot (auditd is `-e 2`) |
| **Shared library group ownership** (`root_permissions_syslibrary_files`) | UBTU-24-300009 | `chgrp root` on any `*.so*` under `/lib`, `/lib64`, `/usr/lib`, `/usr/lib64` that is not already group root — the DISA remediation verbatim. Deliberately **not** widened to every file in those trees; see the deviations table |
| `/var/log/audit` mode (`directory_permissions_var_log_audit`) | UBTU-24-901380 | `0750` when auditd's `log_group` is non-root, `0700` when it is root — the required mode is conditional, and a flat `0750` fails the scan on a `log_group = root` box |
| **Privileged-command audit rules** (`audit_rules_privileged_commands_*`, `audit_rules_execution_*`) | UBTU-24-900080…900330 | `usg fix` writes only part of the set (`su`/`fdisk`/`kmod`/`modprobe`/`unix_update` pass, ~19 others fail). We write the remainder to `/etc/audit/rules.d/72-privileged-commands.rules` — existing paths only, skipping any command another file already covers |
| audit rules.d perms (`file_permissions_etc_audit_rulesd`) | UBTU-24-900040 | `chmod 0600` on anything with user-exec or group/other bits |
| journal dir + `journalctl` perms (`dir_permissions_system_journal`, `file_permissions_journalctl`) | UBTU-24-700020/700030 | journal dirs to `2750` or tighter; `journalctl` to `0740` (root-execute only — read logs with `sudo journalctl`) |
| Account lockout (`accounts_passwords_pam_faillock_*`) | UBTU-24-200610 | `deny`/`fail_interval`/`unlock_time`/`audit`/`silent` in `/etc/security/faillock.conf`. **`unlock_time` defaults to 900 s, not 0** — the benchmark accepts any value ≥ 0, and a permanent lock on a standalone laptop is a self-inflicted outage. Set `usg_faillock_unlock_time: 0` if your ISSM requires the literal reading |
| **Legacy audit rules** (`audit_rules_*`) | UBTU-24-900080…900330 | Retire `/etc/audit/rules.d/stig.rules`, left behind by the old ansible-lockdown role. Its rules use `-F auid!=-1 -k <cmd>`; USG writes `-F auid!=unset -F key=privileged`. Both load fine, but each rule's OVAL requires **every** matching line to conform, so one stale line fails the rule even with a correct line beside it. Moved to `/root/usg-legacy-audit-rules`, not deleted |
| **PAM stack** (`accounts_passwords_pam_faillock_*`, `accounts_passwords_pam_faildelay_delay`) | UBTU-24-200610 / 300017 | Written but **`usg_fix_pam_stack: false` by default** — see the deviations table. Installs the `cac_faillock`, `cac_faillock_notify` and `cac_faildelay` **pam-auth-update profiles** and regenerates `common-auth`, verified by walking the jump offsets and rolled back from a backup on failure |
| **PAM pre-flight** (no rule — safety) | n/a | Every run checks whether `/etc/pam.d/common-auth` can authenticate **at all**, by following the `success=N` offsets from `pam_unix` and seeing whether they reach `pam_permit` or `pam_deny`. Read-only; warns loudly. Installed as `pam-auth-check` for use by hand |
| Audit-log offload (`auditd_offload_logs`) | UBTU-24-900240 | `/etc/cron.weekly/audit-offload` stages a compressed copy of the **rotated** audit logs under `/opt/ia/audit-offload`, pruned to the last 8. Point `usg_audit_offload_command` at a log host on a connected box |
| Remote time server (`chronyd_specify_remote_server`, `chronyd_server_directive`) | UBTU-24-600160 | write `server <host> iburst maxpoll` into `chrony.conf` itself and comment out `pool` (the OVAL reads `chrony.conf` + `confdir`, **not** `sourcedir`; see **NTP** below) |
| SSH banner path (`sshd_enable_warning_banner_net`) | UBTU-24-200640 | point sshd at `/etc/issue.net`, the literal path the rule checks for, which the banner tasks rewrite with the site text on every build |
| ufw active (`check_ufw_active`) | UBTU-24-300041 | firewall roles enable ufw; re-asserted here, plus `ufw limit` on SSH |
| File/dir modes, re-asserted | UBTU-24-700020/700030/900040/901380 | The journal dirs, `journalctl`, `/etc/audit/rules.d/*.rules` and `/var/log/audit` are set **again** immediately before the post-build re-audit. auditd and systemd-journald re-apply their own modes when handlers restart them, which is why a single early `chmod` was not enough. A `tmpfiles.d` drop-in re-applies the journal modes at boot, since `/run/log/journal` is tmpfs |

### ⚠️ Approved deviations (documented, not "failures")

| Control | Why | Where |
| --- | --- | --- |
| Smart Card / CAC + SSSD (`smartcard_pam_enabled`, `service_sssd_enabled`, `sssd_enable_user_cert`) | password-login only; local accounts, no directory/CAC → **de-selected in the USG tailoring** so they don't count against you | `usg_disable_smartcard*` |
| ufw rate-limit **all** ports (`ufw_rate_limit`, UBTU-24-600200) | on `ai`, rate-limiting the Open WebUI / vLLM / Docling ports throttles inference. Only **management** ports (SSH/RDP/Cockpit/Dockge) are `ufw limit`ed | firewall roles |
| GNOME login-banner **text**, blank-screensaver, USB→`dta` *(development profile only; the AI nodes disable USB storage)* | mission requirements (DCSA banner, org wallpaper, USB data-transfer) | deviations table |
| Banner **text** rules (`banner_etc_issue_net`, `dconf_gnome_login_banner_text`, `banner_etc_profiled_ssh_confirm`) | these check for the **exact DoD** string; we deliberately show the DCSA banner instead. Three permanent findings, accepted by choice — they close only by abandoning the DCSA text | `usg_remediate` §1b |
| PAM faillock in the auth stack (`accounts_passwords_pam_faillock_*`, `accounts_passwords_pam_faildelay_delay`) | Seven findings held open **by choice, for now.** The fix is written and uses the right mechanism, but it regenerates `common-auth` and an error there means nobody can log in. ASP-2 spent an afternoon unloggable from exactly this class of bug (a pre-USG role inserted faillock lines without recalculating `pam_unix`'s jump offset) and needed live-USB recovery. Enable on one throwaway box, verify with a second TTY, then roll out | `usg_fix_pam_stack` |
| USB storage driver (`kernel_module_usb-storage_disabled`, UBTU-24-300039) | Applies to **every box where `usb_storage_enabled` is true** — the EMI laptop's `dta` workflow and the engineering workstations both move deliverables on approved removable media. Blacklisting the module removes the capability from everyone rather than restricting it to the authorised, and defeats the group-based mount restriction (no block device ever appears, so there is nothing to authorise). Compensating controls: USBGuard blocks unknown devices at enumeration and audits the decision; mounting is restricted to the `dta` group via polkit + udev. The AI nodes leave the module blacklisted and simply pass the rule | `usbguard` role, `desktop_hardening` §4 |
| Library files group-owned by root (`root_permissions_syslibrary_files`, UBTU-24-300009) | Scanner scope exceeds the STIG's. DISA checks `*.so*` files only and its title permits "root **or a system account**"; the SSG OVAL checks *every* file and demands group root. The two files it objects to on a stock Ubuntu 24.04 are `utempter` (group `utmp`) and `dbus-daemon-launch-helper` (group `messagebus`) — setgid helpers whose group is exactly what keeps them from needing root. `chgrp root` breaks utmp accounting and D-Bus activation. The DISA check itself is clean and enforced every run | `usg_fix_library_group` |

### ❌ Open POA&M: need a secret or infra (NOT auto-applied)

| Finding | To close it |
| --- | --- |
| **UEFI/GRUB boot-loader password** (`grub2_uefi_password`, UBTU-24-102000) | **Closed on ASP-2** (`it-grub set`, verified 2026-08-27: password set, all 8 entries `--unrestricted`). It was the last `high`, and the 2026-08-25 scan has **zero high findings**. Still open **fleet-wide**: `grub_password_pbkdf2` in `group_vars` is the `CHANGEME` sentinel, so a newly built box skips the role and ships without one. Close it for good with `it-grub hash` + `ansible-vault encrypt_string`. This matters more than the severity suggests: LUKS is TPM-sealed to PCR 7 only, which does not measure the kernel command line, so without it physical access → root shell on decrypted data |
| **Password hashing rounds** (`accounts_password_pam_unix_rounds_password_auth`, UBTU-24-400220) | Now **on** (`usg_fix_pam_rounds: true`), writing the benchmark's `rounds=100000`. Worth understanding before you trust it: the value is an SHA-512 iteration count, but Ubuntu 24.04 hashes with **yescrypt**, whose cost parameter accepts only 1–11. Measured against libcrypt directly, `crypt_gensalt("$y$", N)` **returns NULL** for both 5000 and 100000 — it does not clamp. The `rounds=5000` on these boxes came from the pre-USG ansible-lockdown role (`pam_unix_rounds: 5000`, still in `group_vars` as a dead legacy variable), not from `usg fix`. Either way 100000 is not a new risk; both are equally out of range. The open question is what pam_unix does with an out-of-range value, and it is bigger than the finding: if it passes the value straight through, `passwd` is already broken on every hardened box. Verify once with a throwaway account (see `usg_fix_pam_rounds` in the role defaults) |
| **Full-disk encryption** (`Encrypt Partitions`) | bake LUKS into the Ubuntu autoinstall (pre-install; see [procedures.md §1.2](procedures.md#12-install-ubuntu-2404)) |

> **FIPS mode (`is_fips_mode_enabled`) is ENABLED** (`usg_enable_fips: true`). `usg_harden` runs `pro enable fips-updates` (installs the FIPS kernel/modules) and flags a reboot. The check passes **after that reboot**. It swaps the running kernel: validate on a throwaway box if you run unusual crypto/dev tooling. Set `usg_enable_fips: false` to defer it (POA&M).
>
> **GPUs + FIPS:** Canonical's prebuilt NVIDIA modules are kernel-flavour-locked, so the FIPS kernel swap would break `nvidia-smi`. On the `ai` profile the **`gpu_fips_module`** role stages the matching `linux-modules-nvidia-*-fips` module (from the `fips-updates` repo) in the same run, so the GPU comes back automatically on the single FIPS reboot. No manual DKMS/driver rebuild.

### Reading a real scan — ASP-2 (emi), 2026-08-25, score 96.41 %

**214 passed, 6 failed, 5 other. Zero high, zero low — all six are medium, and all six are deviations already documented above.** Nothing on this list is an unaddressed defect.

| Finding | Why it fails | Disposition |
| --- | --- | --- |
| `dconf_gnome_login_banner_text` | Checks for the **exact DoD** string; we show the DCSA banner | Permanent deviation, by choice |
| `banner_etc_issue_net` | Same | Permanent deviation, by choice |
| `banner_etc_profiled_ssh_confirm` | Same | Permanent deviation, by choice |
| `ufw_rate_limit` | Has **no OVAL** — an OCIL/manual check, so it reports fail regardless of configuration | Deviation. SSH is `ufw limit`ed; rate-limiting the imaging/AI service ports would be a self-inflicted outage |
| `kernel_module_usb-storage_disabled` | The EMI laptop's `dta` workflow needs USB mass storage | Mission deviation; USBGuard is the compensating control |
| `chronyd_specify_remote_server` | Box points at the site time server; the benchmark's rendered value is `0.us.pool.ntp.mil` | Deviation — an air-gapped box cannot reach a `.mil` pool. Close it by tailoring `var_multiple_time_servers`, or accept |

**What moved, 2026-08-20 → 2026-08-25 (88.70 % → 96.41 %):**

| Was failing | Now | How |
| --- | --- | --- |
| 22 × `audit_rules_privileged_commands_*` / `audit_rules_execution_*` | pass | The stale `/etc/audit/rules.d/stig.rules` retired by `usg_remediate` |
| 6 × `accounts_passwords_pam_faillock_*` + `faildelay` | pass | — |
| 4 × journal / `journalctl` / `rules.d` / `/var/log/audit` modes | pass | Re-asserted immediately before the re-audit, plus `tmpfiles.d` for the tmpfs journal |
| `sshd_enable_warning_banner_net` | pass | `usg_ssh_banner_path` pointed at the literal `/etc/issue.net` |
| `accounts_password_pam_unix_rounds_password_auth` | pass | `usg_fix_pam_rounds` |
| `auditd_offload_logs` | pass | `/etc/cron.weekly/audit-offload` |
| `grub2_uefi_password` *(the only high)* | pass | `it-grub set` on the box |

**The one thing this scan does not settle** is item 2 of the org checklist. `sshd -T` on the same box reported `permitrootlogin without-password` — root can still SSH in **with a key**. The benchmark rule only forbids a root *password* login, so the scan is satisfied and the org requirement is not. `usg_remediate` now writes `PermitRootLogin no` (`usg_ssh_disable_root_login`). **A passing benchmark is not the same as a compliant box**, and this is the cheapest available example of it.

### The seven open findings, and which are fixable

From ASP-2's first complete checklist (194 rules: 179 NotAFinding, 8 N/A, 7 Open, **0 Not_Reviewed**):

| Finding | Cause | Fixable in the build? |
| --- | --- | --- |
| UBTU-24-102000 *(high)* — boot loader password | `grub_password_pbkdf2` was the CHANGEME sentinel | **Fixed.** `it-grub set` applied; vault the hash to roll it fleet-wide |
| UBTU-24-300028 *(high)* — no PAM accounts with null passwords | Ubuntu's `pam-auth-update` writes `pam_unix.so nullok` | **Fixed in the build.** `usg_remediate` strips `nullok`, then re-verifies the auth stack. Only narrows what pam_unix accepts, so it cannot reject a currently-valid password |
| UBTU-24-100660, 400020, 400370 — SSSD / smart card / PKI mapping | No CAC reader, no directory service, password auth only | **No.** Permanent deviation. De-selected in the USG tailoring, and now adjudicated in `answers.yml` so an untailored scan still reads correctly |
| UBTU-24-300039 — USB mass storage driver | The EMI `dta` workflow needs removable media | **No.** Mission deviation; USBGuard is the compensating control |
| UBTU-24-200043 — session lock conceals the display | The check wants `picture-uri` **empty**; `desktop_branding` sets the org lock-screen image | **No.** The objective — concealing the display — is met; only the prescribed means differs. Both are mandated controls that happen to conflict |

So of seven: two close in the build, five are deviations that will never close and now carry their reasoning in the checklist rather than being re-argued each cycle.

**The lesson worth keeping:** the score barely moved during that build (88.476 → 88.703 after remediation) even though the remediation role ran every task. Two whole categories of fix were being written correctly and still failing — a stale file poisoning rules that were otherwise satisfied, and PAM values written into a config file that nothing read because the module was not in the stack. Neither shows up as an Ansible failure. **A green playbook is not evidence; the re-audit is.**

### Fleet checklist review, 2026-08-27

Checklists from dev-13, dev-ai1 and dev-ai2 (194 rules each). Five distinct rules were Open across the three boxes; four of the five carried **no adjudication at all**, so they read as unexplained findings.

| Rule | Boxes | Root cause | Disposition |
| --- | --- | --- | --- |
| UBTU-24-102000 *(high)* — single-user-mode password | all three | `grub_password_pbkdf2` is still the CHANGEME sentinel, so `grub_password` skips | **Fixable now, per box: `sudo it-grub set`.** Not a deviation. The checklist entry now names that command and stops rendering once a hash is set |
| UBTU-24-200270 — audit scripts called by cron | all three | USG ships no watch on `/etc/cron.d` or the cron spool | **Fixed in the build.** `72-cron.rules`; lands in the kernel on the next reboot |
| UBTU-24-700010 — `/var/log` file modes | all three | The fix was correct but ran too early: apt/dpkg recreate their logs `0644` afterwards | **Fixed in the build.** Swept again at the end of the role plus a daily timer |
| UBTU-24-300009 — library files group-owned by root | all three | SSG checks a wider set than the STIG, and demands group root where the STIG allows "root or a system account" | **Adjudicated, with evidence.** DISA fix applied to `*.so*`; the two setgid helpers SSG objects to are documented and load-bearing |
| UBTU-24-300039 — USB mass storage | dev-13 | Deliberate deviation, but the adjudication was gated on `is_emi` so it rendered only for the EMI laptop | **Adjudicated.** Now gated on `usb_storage_enabled`, so every box with the deviation carries the reason |

Expected after the next pull and reboot: two Open on the AI nodes and dev-13 (GRUB until `it-grub set`, USB where the deviation applies), both carrying their justification and evidence rather than "NO SITE ADJUDICATION RECORDED".

### The audit ruleset was not reaching the kernel at all (2026-08-28)

Item 6 of `it-checklist` reported `only 1 of 68 (rules.d) reached the kernel` on dev-13, with `auditctl -s` showing `enabled 1` — so not the immutable case, and a reboot did not help. `augenrules --load` named it:

```
Syscall name unknown: kexec_load
There was an error in line 6 of /etc/audit/audit.rules
```

Line 6 was this repo's own `71-reboot.rules`:

```
-a always,exit -F arch=b32 -S reboot -S kexec_load -k reboot
```

**Syscall names are per-architecture.** In the i386 table, entry 283 is `sys_kexec_load`; only the x86_64 table calls it `kexec_load`. And **auditctl applies the compiled ruleset top-down and stops at the first rule it cannot apply** — so one wrong name on line 6 left the other 67 rules unloaded. Every file-based OVAL still passed, because the audit OVALs read files, not the kernel. Nothing in any scan showed it.

A second instance of the same class was queued behind it: USG watches `/var/log/sudo.log` (UBTU-24-500010) and nothing in the build ever created that file, so a watch on a missing path would have aborted the load at the next line.

| Fix | Where |
| --- | --- |
| Resolve syscall names against the box's own tables before writing the rule; skip an architecture with nothing resolvable | `usg_remediate`, `audit_reboot_rules_syscalls` |
| Create `/var/log/sudo.log` and point sudo at it (`Defaults logfile`, visudo-validated) | `usg_sudo_logfile_enabled` |
| Report the failing line and the `rules.d` file it came from whenever `augenrules --load` fails | `usg_remediate` handlers |
| Check both faults read-only and name them in the FAIL line | `it-checklist` item 6 |

> **`ausyscall <arch> <name>` is not a valid check.** It fuzzy-matches and exits 0 for `b32 kexec_load`, the exact name auditctl rejects. Test for an exact match in `ausyscall <arch> --dump`.

**The pattern worth keeping:** three of the five had a correct fix in the repo already. Two failed on *ordering* (a sweep overtaken by later tasks; audit rules staged but not yet in the kernel) and one on *scope* (an adjudication gated on the wrong variable). None of them showed up as an Ansible failure — the same lesson as ASP-2. Read the checklist, not the playbook output.

### NTP / time source

The chrony remediation defaults `usg_chrony_servers` to **`ntp.ubuntu.com`**. Change this to your enclave's internal NTP server(s) in `group_vars/all.yml`. The STIG config check passes either way, but actual time sync needs a *reachable* server (an air-gapped net can't reach the public pool):

```yaml
# group_vars/all.yml
usg_chrony_servers:
  - 10.0.0.1          # your site time server(s), written as `server <host> iburst`
  - 10.0.0.2
```

Set `usg_chrony_servers: []` to leave chrony untouched (the finding then stays a POA&M).

### Admin working folders `/opt/ia` and `/opt/it`

The `managed_dirs` role creates both on every box:

- Owned `root:{{ ia_it_group }}` (default `sudo`), mode `2770` + a default ACL.
- Only admins (the `sudo` group) can enter them; no `sudo` prefix needed to create/edit files or run commands inside.
- Files created there stay group-shared even under the STIG's `umask 077`.
- `/opt/ia` doubles as the USG report drop.
- Change the owning group with `ia_it_group`, or set `managed_dirs_enabled: false` to skip.

---

## The org Linux checklist

The org's Linux checklist, what this build does about each item, and the command to prove it. Run it:

```bash
sudo it-checklist              # every check, one line per item
sudo it-checklist --fail-only  # only what needs attention
sudo it-checklist --out /opt/ia/checklist-$(hostname).txt
```

Exit 0 when nothing FAILs. **N/A** and **MANUAL** never count as failures. This is a fast indicator — the authoritative evidence is `usg audit disa_stig` and `it-oscap`.

| # | Item | Status | How / why | Verify |
|---|---|---|---|---|
| 1 | AD integration (SSSD) | **N/A** | Local accounts by design; the SSSD/smartcard STIG rules are de-selected as a documented deviation (`usg_disable_smartcard_rules`). No directory service on these networks. | `getent passwd \| tail` |
| 2 | No root SSH login | **Met (by `usg_remediate`, not by `usg fix`)** | This is the **root account over SSH**, nothing else. `usg fix` leaves Ubuntu's `PermitRootLogin prohibit-password`, which still allows a root login **by SSH key** — the benchmark rule it satisfies only forbids a root *password* login. Found on ASP-2, 2026-08-27. `usg_remediate` now writes `PermitRootLogin no` in `/etc/ssh/sshd_config.d/00-1-no-root-login.conf` (`usg_ssh_disable_root_login`). Admins still log in as themselves and **elevate with `sudo`** — that path is untouched, and is what makes the audit trail attributable to a person rather than to `root`. The check also reports whether `/root/.ssh/authorized_keys` holds keys (inert while `PermitRootLogin no` stands, but worth knowing). | `sshd -T \| grep -i permitrootlogin` |
| 3 | DCSA banners + last login | **Met** | `classification_banner` role + SSH banner drop-in + GDM banner. | `sshd -T \| grep -iE 'banner\|printlastlog'` |
| 4 | Anti-virus | **Met via container on FIPS boxes** | ClamAV on all profiles (daemon + weekly scan). Docker volumes excluded — scanning 60 GB of model weights is pointless I/O. **FIPS breaks ClamAV** — OpenSSL in FIPS mode will not initialise MD5, which is what ClamAV hashes file content with, so MD5-based signatures cannot be evaluated and **the EICAR test file is not detected** (confirmed on ASP-2, 2026-08-26). Upstream [Cisco-Talos/clamav#1786](https://github.com/Cisco-Talos/clamav/issues/1786), open with no fix; not configurable around — Ubuntu's FIPS OpenSSL takes FIPS from the kernel flag, so even `OPENSSL_CONF=/dev/null` fails, and `--fips-limits` does not help. The fix is `clamav_container`: clamd moves into a container whose OpenSSL is a stock build, so MD5 works, while the **host kernel stays in FIPS**. Scans go over its socket with `clamdscan --fdpass`, so a DTA needs no docker access. **On-access scanning is lost — on-demand only (POA&M).** `sudo it-clamav test` is the per-box check and must PASS before a box is relied on; air-gapped boxes need `it-clamav image-load` first, and clamd needs ~60–90s after a restart before its socket answers. **Verified on ASP-2, 2026-08-26.** Signatures also go stale air-gapped; **`it-clamav install` is the manual path** — drop a signature `tar.gz` in `/opt/it/clamavsigs`, it validates the CVD digital signature before installing and confirms with an EICAR test. | `sudo it-clamav test` |
| 5 | Password complexity / lockout | **Met** | USG `disa_stig`. | `sudo usg audit disa_stig` |
| 6 | Audit rules incl. reboot | **Met** | USG auditd rules. | `auditctl -l \| wc -l` |
| 7 | BIOS hardened + password | **Partly automated** | Two of the three parts *are* machine-readable and `it-checklist` now reads them: **Secure Boot** (`mokutil --sb-state`, falling back to the `SecureBoot-*` EFI variable) and the **BIOS admin password**, via the vendor firmware-attributes driver — `/sys/class/firmware-attributes/*/authentication/Admin/is_enabled`, exposed by `dell-wmi-sysman` / `think-lmi` / `hp-wmi-sysman`. Secure Boot off, or an admin password readably **unset**, is a **FAIL**. The rest of "BIOS hardened" — boot order, disabled ports and radios — is not readable from the OS, so a box where everything detectable looks right still reports **MANUAL** rather than passing on half the evidence. On hardware without the vendor driver both fall back to manual. | `sudo it-checklist \| grep ' 7 '` ; `mokutil --sb-state` |
| 8 | Vendor supported release | **Met** | Ubuntu 24.04 LTS (support to ~2029; ~2034 with Pro). | `lsb_release -ds && pro status` |
| 9 | FIPS crypto (OS + drive) | **Met** | FIPS kernel via Ubuntu Pro. **Disclose:** vLLM/Docling *containers* mask `fips_enabled` because those images ship no FIPS provider — the host stays FIPS. | `cat /proc/sys/crypto/fips_enabled` |
| 10 | DARE | **Met** | LUKS, TPM-auto-unlocked (`tpm_luks_unlock`). | `lsblk -o NAME,TYPE \| grep crypt` |
| 11 | GRUB2 password | **Set on ASP-2; sentinel fleet-wide** | Applied per box with `it-grub set` (ASP-2 verified 2026-08-27: set, all 8 entries `--unrestricted`). `grub_password_pbkdf2` in `group_vars` is still the `CHANGEME` sentinel, so a newly built box skips the role — vault a hash to close it fleet-wide. **Not redundant with LUKS here** — the TPM seals to PCR 7 only, which doesn't measure the kernel cmdline, so without it physical access → root shell on decrypted data. Activate: `it-grub hash` (fleet) or `it-grub set` (one box). | `sudo it-grub status` |
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
| 23 | Backup + restore | **Two answers, by profile** | **EMI → MANUAL.** The box is standalone and air-gapped, so there is no file server to push to: backup is an **offline SSD duplication**, done by hand and **logged on paper**. Nothing on the box can see it, so `it-checklist` reports MANUAL rather than pretending to have evidence — verify it against the paper record. **Development / AI / baseline → N/A.** Nothing is kept locally; the file servers are backed up and users are directed to store there. No endpoint agent is the intended design, so there is nothing to install or check per box. (Macrium SiteBackup's Linux agent is Insider-preview only anyway, and would not be acceptable on an accredited system.) The profile comes from `/etc/stig-build/profile`, written by `it_scripts`. | paper record |
| 24 | Scheduled OSCAP job | **Met** | `it-oscap` on a systemd timer (or `/etc/cron.d`, via `scap_schedule_method`). Results → `/opt/ia/oscap/scheduled`. Runs as **root** because `auto_audit` is locked and can't sudo unattended. | `systemctl list-timers oscap-scan.timer` |
| 25 | iDRAC / OME | **Manual** | Server hardware, out-of-band. | iDRAC web UI |
| 26 | Current compliance scan | **Met (process)** | Scheduled OpenSCAP scan produces the artifact; reviewing it is a human step. FAILs once the newest report is over 45 days old. | `ls -t /opt/ia/oscap/*/stig-report-*.html \| head -1` |
| 27 | Latest STIG version | **Met** | USG content ships via Pro; SSG datastream pinned in `group_vars`. Confirm the benchmark version you're held to. | `dpkg-query -W usg` |
| 28 | nmap vulnerability scan | **Met (EMI)** | The Linux counterpart to the org's `MUSA_Vuln_Scan` Windows job: `nmap -sV --script vuln` against this host, then a full anti-virus scan, both appended to one dated report in `/opt/ia/vulnscans`. **EMI profiles only** — `nmap` is installed there and `it-vulnscan` is placed there. FAILs when a vuln script flagged something, when the newest scan is over 45 days old, or when it has never run. The row is omitted entirely on profiles that do not carry the tool. | `sudo it-vulnscan` ; `sudo it-vulnscan --list` |

**Open items**

1. **GRUB password fleet-wide** (11) — set on ASP-2 by hand; `group_vars` still holds the `CHANGEME` sentinel, so a newly built box ships without one. Vault a hash.
2. **Firewall policy** (20) — the checklist and the build disagree; decide which is right.
3. **nmap does not run under FIPS** (28) — it quits at startup with `library has no ciphers`, the same OpenSSL problem as ClamAV. `it-vulnscan` records `NMAP-FAULT` and item 28 FAILs rather than reporting a clean scan. The AV half is unaffected. Until it is solved, take the nmap half from a non-FIPS box on the same segment.

Closed since the last revision: **backup** (23) is a file-server function on dev/AI and a manual SSD duplication on EMI, neither of which needs an endpoint agent; **partitioning** (15) is a RHEL-derived org item, not an Ubuntu STIG rule; **ClamAV signatures air-gapped** (4) now have `it-clamav install`, and FIPS detection is fixed by `clamav_container`.

---

## DCSA / DoD RMF compliance posture

Summarizes how the two-node AI inference platform and its automated build (`ubuntu-stig-build`) implement DoD/DCSA security controls, to support an RMF Assessment & Authorization (A&A) package and the DCSA ISSP discussion.

> **Scope / disclaimer.** This is a **control-implementation summary**, not an authorization. The system operates under the Risk Management Framework (RMF); the **Authorizing Official (AO)** makes the final risk determination and grants the ATO. This document describes the technical baseline and evidence we bring to that decision, and states our open items (POA&Ms) honestly.

### Authorization context

- **Process:** NIST RMF (DoDI 8510.01) as administered by DCSA (DAAPM / NIST SP 800-53 Rev 5), assessed in eMASS.
- **Categorization:** As a National Security System, categorized per **CNSSI 1253** (confidentiality/integrity/availability) with the applicable classified/overlay controls; final categorization set with the ISSM/ISSP.
- **Control baseline:** NIST SP 800-53 Rev 5, implemented via the **DISA Canonical Ubuntu 24.04 LTS STIG** using **FIPS 140-validated cryptography**.

### System description

Self-hosted, on-premises AI chat/document system on two hardened Ubuntu 24.04 servers. Runs **fully disconnected (air-gapped)** after build: models and inference run locally, no external/cloud AI calls at runtime.

All data (prompts, responses, documents, vector index) stays inside the accreditation boundary. **Inference only**: static weights are read-only, not retrained/updated by user data.

- **System 1 (`dev-ai1`):** user chat UI (Open WebUI), chat LLM engine (vLLM), database (PostgreSQL/pgvector: accounts, chats, document vectors), websocket/cache store (Redis).
- **System 2 (`dev-ai2`):** document extraction (Docling, Apache Tika), embedding + vision models (vLLM), monitoring (LGTM/Grafana), experiment tracking + model registry (MLflow), knowledge-base sync (oikb).

### Compliance baseline (what the build enforces)

Every box is provisioned by a version-controlled Ansible build: repeatable, auditable, identical across the fleet (supports CM-2/CM-6, configuration-as-code evidence). Rule-level view of what's additionally remediated, deviated, or left open: [Hardening posture](#hardening-posture) above.

| Area | Implementation |
|------|----------------|
| **STIG hardening** | Canonical **USG** applies the **DISA `disa_stig` profile**; `usg audit` produces XCCDF + HTML compliance reports (evidence artifacts). |
| **FIPS cryptography** | **Ubuntu Pro FIPS** (FIPS 140-validated modules); FIPS kernel enabled fleet-wide (`fips=1`), verified via `/proc/sys/crypto/fips_enabled`. |
| **Data at rest** | **LUKS full-disk encryption**; TPM2-sealed auto-unlock bound to Secure Boot state (PCR 7); install passphrase retained as recovery. |
| **Audit** | `auditd` enabled with STIG rules; low-disk actions configured; journald/log permissions hardened. |
| **Identity & access** | Local least-privilege accounts and groups; locked (non-empty) default passwords; PAM **faillock** (lockout), fail-delay, password policy, session timeout + concurrent-session limits. |
| **Boundary protection** | Host firewall (**ufw default-deny inbound**, rate-limited); only required service ports opened, cross-node ports restricted by source IP. |
| **Access banner** | **DCSA Authorized Warning Banner** presented at GUI/console/SSH logon (the unclassified EMI variant substitutes an unclassified EMI warning banner; the banner-enable control is satisfied in both cases). |
| **Least functionality** | Lean package set; unneeded listening services disabled + masked (e.g. **CUPS**/`:631` on all profiles, `disable_cups`); privileged management surfaces (Cockpit, Dockge) restricted to admin subnets. |
| **Removable media** | USB mass storage disabled on the AI nodes (USG blacklists the `usb-storage` module on a server; no carve-out). The authorized data-transfer group carve-out (udev + polkit) is development-profile only and is not enabled here. |
| **Continuous monitoring** | `usg audit` re-run at end of build and re-runnable any time; OpenSCAP available offline; Ubuntu Pro **ESM + Livepatch** for ongoing vulnerability/patch management. |

### NIST SP 800-53 Rev 5 control-family mapping (representative)

| Family | How this baseline supports it |
|--------|-------------------------------|
| **AC** Access Control | Least-privilege accounts/groups, sudo control, session limits/timeout, warning banner, restricted admin interfaces. |
| **AU** Audit & Accountability | `auditd` with STIG ruleset (host); **Open WebUI audit log** (`AUDIT_LOG_LEVEL=METADATA`, attributable user activity: who/endpoint/when/result) plus OpenTelemetry to the LGTM/Grafana stack on System 2; log-permission hardening. |
| **CM** Configuration Management | Config-as-code (Ansible), pinned package/image versions, reproducible baseline, `usg` compliance scans. |
| **IA** Identification & Auth | PAM password policy/faillock; FIPS-validated crypto for auth (IA-7). *(CAC/PIV, see POA&M.)* |
| **SC** System & Comm. Protection | FIPS 140-validated crypto (SC-13), LUKS data-at-rest (SC-28), host firewall/boundary (SC-7), TLS for management. |
| **SI** System & Info Integrity | ClamAV (dev baseline), Ubuntu Pro patching/ESM/Livepatch, STIG integrity settings. |
| **SR/SA** Supply Chain / Sys & Svcs Acq. | Pinned open-source component versions; images buildable/mirrorable internally; model weights hash-verifiable and stageable offline. |

### Configuration Management (CM family)

The build is configuration-as-code, so it maps directly onto the CM family. The `ubuntu-stig-build` git repo is the authoritative baseline; every box is provisioned from it, so the fielded configuration equals the documented one.

| Control | How the build meets it |
|---|---|
| **CM-2 Baseline Configuration** | The full baseline is version-controlled Ansible (`group_vars/all.yml`, roles, compose files) in git. Commits and tags version the baseline and support rollback. |
| **CM-2(2) Automation support** | `ansible-pull` is idempotent: a re-run applies only the delta and corrects drift back to baseline. `usg_remediate` re-asserts residual STIG settings every run; `usg audit` regenerates current-state evidence on demand. |
| **CM-3 Configuration Change Control** | Changes are made in the repo and flow through git commits + pull requests (reviewable diffs, full history). The repo is the change record; a re-pull overwrites ad-hoc box edits, so the baseline stays authoritative. |
| **CM-4 Impact Analysis** | Validate on a throwaway VM before imaging production (the DISA profile can be breaking). `HARDEN=0` runs an audit-only first pass to assess impact before `usg fix` is applied. |
| **CM-5 Access Restrictions for Change** | Repo write access gates baseline changes. On the box, config changes need root/sudo; admin folders `/opt/ia` and `/opt/it` are restricted to the `sudo` group (mode `2770` + ACL); secrets (Pro token, LUKS passphrase, DB/API keys) stay out-of-band, root-only, never in the repo. |
| **CM-6 Configuration Settings** | Mandated settings come from the DISA STIG applied by USG (`usg fix disa_stig`) plus documented tunables in `group_vars/all.yml` (lockout counts, timeouts, audit retention, banner, FIPS). `usg audit` (XCCDF + HTML) is the settings-compliance evidence; deviations are enumerated in [Hardening posture](#hardening-posture). |
| **CM-7 Least Functionality** | Lean per-profile package sets; provisioning services installed but disabled + stopped; `ufw` default-deny inbound with only required ports opened; Cockpit/Dockge restricted to admin subnets; USB mass storage disabled on the AI nodes. |
| **CM-8 System Component Inventory** | Component versions pinned across `group_vars`, the compose files, and the Dockerfiles. The [software inventory](reference.md#software-inventory) enumerates tool, version, publisher, and purpose per profile; images and model repos are listed with versions. |
| **CM-9 Configuration Management Plan** | Organizational/procedural control. This repo is the technical baseline the site CM Plan references; the plan itself is a program document. |
| **CM-10 / CM-11 Software Usage & User-Installed Software** | Components are open-source with tracked licenses (software lists). Standard users are non-privileged; installs require sudo. The `docker` group (root-equivalent) is a documented developer-workstation exception; no unmanaged package channels are enabled. |
| **CM-14 Signed Components** | Third-party apt repos (Docker, NVIDIA, Microsoft) are added with GPG-key verification; distro packages are apt-signed. Images and model weights are hash-verifiable and mirrorable to an internal registry for provenance. Full SBOM/signing attestation is an SSP/POA&M item. |

### AI-specific risk considerations

Questions an AO/ISSP raises about an AI system specifically; our position:

- **Data stays in-boundary.** No runtime calls to external/cloud AI services; inference is local. Accredit at the classification level of the data it will process.
- **No model learning from user data.** Inference runs against static, read-only weights; prompts/responses are not used to retrain.
- **Data at rest is encrypted** (LUKS); chats/documents/vectors persist only in encrypted local storage inside the boundary.
- **Software provenance.** All components open-source with **pinned versions**; container images and the **open-weight models** (Apache-2.0) can be **hash-verified and mirrored to an internal registry** for air-gapped operation (supports SR/SA controls and software assurance review).
- **User accountability.** Application access via named local accounts; host `auditd` plus Open WebUI/telemetry provide an activity record.
- **Spillage/handling** governed by the site's data-handling procedures; the platform does not exfiltrate and can run disconnected.

### Open items / POA&M (stated honestly)

Known deviations to remediate or risk-accept with the AO. None hidden; each is documented above and in `group_vars/all.yml`.

| Item | Status / plan |
|------|---------------|
| **CAC/PIV multifactor (IA-2)** | Currently **password-only** (accounts locked until a password is set). CAC/PIV is the DoD expectation; the build de-selects the smartcard STIG rules as a documented deviation and can re-enable them once CAC readers/certs/SSSD are fielded. **Primary POA&M for the AO discussion.** |
| **GRUB/UEFI bootloader password (CM/AC)** | Ships as a safe sentinel; set a vaulted PBKDF2 hash to close. |
| **Audit-log offload (AU-4/AU-6)** | Local audit logging is on; central `audisp-remote` collector not yet configured (needs a log server). POA&M until a collector exists. |
| **FIPS inside inference containers** | **Host is fully FIPS**; the inference/extraction containers (vLLM, and docling via its bundled OpenCV/OpenSSL) use standard crypto. Those images ship no FIPS provider and aren't FIPS-validated, so on the FIPS host their OpenSSL selftest aborts unless carved out. Container traffic is host-local/enclave-internal. Documented POA&M; host-level FIPS is what the STIG assesses. |
| **AI/ML software assurance** | vLLM, Open WebUI, Docling, etc. are open-source and not separately accredited; recommend internal image scanning + registry mirroring as part of the SSP. |

## Producing the STIG checklist

The whole process, end to end. Two scanners run on these boxes and they answer different questions — knowing which is which prevents a lot of confusion.

| | `usg audit` | `it-oscap` |
|---|---|---|
| Content | Canonical's USG (SSG-derived) | the SSG datastream `scap_scan` stages |
| Tailoring | uses `/etc/usg/managed-tailoring.xml` | now uses it too (`--no-tailoring` to skip) |
| Runs | inside the build, after `usg_remediate` | by hand, and weekly by timer |
| Output | `/opt/ia/usg/usg-report-*.html` + `usg-results-*.xml` | `/opt/ia/oscap/{build,scheduled,manual}/stig-{report,arf,viewer}-*` |
| Use it for | the compliance score and the accreditation artifact | the checklist, and ad-hoc re-checks |

**They must be tailored the same way or they disagree.** `usg_harden` de-selects the smart-card and SSSD rules — this fleet is password-login only with no CAC reader — and a raw `oscap` run ignores that, reporting `smartcard_pam_enabled`, `service_sssd_enabled` and `sssd_enable_user_cert` as findings the accredited baseline has formally de-scoped. `it-oscap` now picks up the tailoring file automatically.


### Which tool is which

Four commands with overlapping names. They are two pairs, and each pair is *checklist* vs *scan*:

| Command | What it is | Input | Output |
|---|---|---|---|
| `it-checklist` | **The org checklist above.** A shell script with one hand-written check per row — fast, opinionated, human-readable. A quick indicator, not evidence. | the live box | one line per item on stdout, `--out` to a file |
| `it-ckl` | **The DISA STIG checklist.** Builds a real `.cklb`/`.ckl` for STIG Viewer by merging DISA's manual STIG XCCDF (the skeleton of every V-ID), the SCAP results, and this repo's `answers.yml` adjudications. That last part is the point: `Not_Reviewed` comes to mean "needs a human on *this* box" rather than "nobody has typed it in yet". | STIG XCCDF + scan results + `answers.yml` | `/opt/ia/stig/checklists/<host>-<ts>.cklb` |
| `it-oscap` | **The scanner.** One `oscap xccdf eval` run against the SSG (or DISA) datastream, honouring the USG tailoring file. This is what the weekly timer runs. | a SCAP datastream | `stig-report-*.html`, `stig-arf-*.xml`, `stig-viewer-*.xml` in `/opt/ia/oscap/{build,scheduled,manual}` |
| `it-stig` | **The wrapper.** Runs `it-oscap` then `it-ckl` in the right order, checks the prerequisites up front instead of failing halfway, and can `archive` the evidence set for hand-off. | — | whatever the two produce, plus a tarball |

So: **`it-checklist` answers "is this box configured the way we said", `it-stig run` produces the artifact an assessor wants.** `it-oscap` and `it-ckl` are its two halves, useful on their own when you only need one.

`it-vulnscan` is separate from all four — it is the org's `MUSA_Vuln_Scan` process (nmap `vuln` scripts + a full AV scan), not a STIG artifact, and it lands in `/opt/ia/vulnscans`.

#### How a rule actually gets its status

Four inputs, in this order. Later steps can only move a rule under the rules below — nothing silently upgrades a failure.

**1. The manual STIG XCCDF is the skeleton.** All 194 V-IDs with their title, severity, discussion, check content, fix text and CCIs. **Every rule starts `Not_Reviewed`.**

**2. The SCAP results fill in most of them.** This is the part that surprises people: a scan against **SSG** content produces results keyed by *SSG* rule ids (`xccdf_org.ssgproject.content_rule_…`), not DISA V-IDs. `it-ckl` bridges them by reading the `<reference>` elements out of the SSG datastream — SSG tags each of its rules with the DISA id it implements (`UBTU-24-nnnnnn`). That map is why **one SSG scan populates the large majority of the checklist**, not a handful.

- Lookup tries, in order: `UBTU-24-nnnnnn` → `V-nnnnnn` → `SV-…_rule` → legacy ids. Results are indexed under every key derivable from the `idref`, so `--results` and `--stig-viewer` output both work.
- **Many SSG rules routinely map to one STIG rule** (the `setxattr` family is seven SSG rules and one V-ID). When that happens **the worst result wins** — a STIG rule is not satisfied because part of it passed. The checklist records which SSG rules contributed and what each returned.

| OpenSCAP result | Checklist status |
|---|---|
| `pass`, `fixed` | NotAFinding |
| `fail` | **Open** |
| `notapplicable`, `notselected` | Not_Applicable |
| `error`, `unknown`, `notchecked`, `informational` | Not_Reviewed |

**3. `answers.yml` adjudicates what the scan cannot** — currently **19 rules**, rendered per profile by `scap_scan` from `ckl-answers.yml.j2`. This covers the permanent deviations (DCSA banner text, no CAC/SSSD, USB for the DTA workflow) and the OCIL-only rules with no automated check.

It may set a status **only** when the rule is `Not_Reviewed`, or `override: true` is set, or the rule is already `Open`. And the safety rule that makes the whole artifact trustworthy:

> If SCAP reports **fail** and `answers.yml` proposes something else **without** `override: true`, the rule **stays Open** and a NOTE is written into it saying so. A stale hand-written note can never quietly mark a genuinely failing control compliant.

It can also attach `finding_details`, `comments`, and an `evidence_cmd` whose output is captured into the checklist — real evidence an assessor can re-run, rather than prose asserting compliance.

**4. Whatever is still unanswered stays `Not_Reviewed`** and gets a comment saying why. Every Open or Not_Reviewed rule carrying no adjudication also gets one naming the key to record it under, so nobody meets a finding with no explanation. `sudo it-ckl --unjustified` lists exactly those — it is the operator's to-do list.

> **Scanning with DISA's own SCAP benchmark skips step 2's mapping entirely** — its rule ids already match the manual STIG, so results land 1:1. Use `it-oscap --content <benchmark>.xml`.

#### Where everything lives

`/opt/ia` is subdivided so **each directory has exactly one writer**. Everything used to land in two flat directories, which is how a build-time scan and an ad-hoc scan ended up side by side in `/opt/ia/oscap` under near-identical names — and `it-ckl` picked the wrong one. Separating by writer also makes retention safe: pruning ad-hoc runs can no longer delete the build-time artifact an accreditation package refers to.

```
/opt/ia/
  usg/                  `usg audit` reports + results -- the compliance score
  oscap/
    build/              scan taken during a build/pull      (scap_scan role)
    scheduled/          the weekly timer                    (oscap-scan.timer)
    manual/             ad-hoc runs                         (it-oscap)
  stig/
    content/            DISA-published input YOU stage (manual XCCDF, SCAP benchmark)
    answers.yml         the adjudications, rendered per profile
    checklists/         generated .ckl / .cklb
    evidence/           `it-stig archive` bundles
  audit-offload/        weekly staged audit logs
```

Tell the two scan styles apart by their filename: the role stamps date-only (`stig-arf-2026-08-24.xml`), `it-oscap` stamps date **and time** (`stig-arf-20260824-143656.xml`). `it-ckl` reads from all three scan directories, newest first — any of them is valid input.

Existing boxes are migrated automatically on the next pull: `managed_dirs` moves the legacy flat files into place with `mv -n`, so it never overwrites and re-running is a no-op.

#### One-time setup per box

```bash
sudo it-stig status       # names anything missing, and how to fix it
```

The directories are created by the `managed_dirs` role, `answers.yml` is rendered by `scap_scan`, and **DISA's manual STIG XCCDF now ships in the repo** (`roles/scap_scan/files/`) and is placed in `/opt/ia/stig/content/` on every box. If any of the three is missing, run a pull.

#### Getting DISA's content

From [public.cyber.mil/stigs/downloads](https://public.cyber.mil/stigs/downloads/), for Canonical Ubuntu 24.04 LTS:

| Download | Take it? | Why |
|---|---|---|
| **Canonical Ubuntu 24.04 LTS STIG** | **Already in the repo** | The manual STIG — the checklist skeleton (every V-ID, check text, fix text). V1R6 ships in `roles/scap_scan/files/`. Download it again only for a **new release**: drop the `*Manual-xccdf.xml` in, update `scap_stig_manual_xccdf`, delete the old one. |
| **STIG SCAP Benchmark** | Recommended | DISA's own SCAP content. Its rule ids match the manual STIG exactly, so `it-ckl` maps 1:1 instead of by inference: `it-oscap --content <benchmark>.xml`. Often a release behind the manual STIG; rules only in the newer release simply stay Not_Reviewed. |
| **STIG for Ansible** | **Do not run** | Supplemental automation that *applies* the STIG — a remediation engine, like `usg fix` and this repo. Running it puts a third engine on the same files. That is exactly how ASP-2 ended up with a `common-auth` that denied every login. Useful as a **reference** for DISA's canonical fix: `grep -rl 'UBTU-24-600200' <unzipped>/`. |
| **STIG for Chef** | No | Not used here. |

Copy the XML into `/opt/ia/stig/content/` — unclassified, so USB is fine for the air-gapped boxes.

#### The routine

```bash
sudo it-stig status     # is everything staged? when did it last run?
sudo it-stig run        # scan + checklist
sudo it-stig archive    # tar the evidence set for hand-off
```

`it-stig` wraps the two underlying tools and refuses to start if a prerequisite is missing, rather than failing halfway. `scan` and `checklist` run either half on its own. The underlying commands still work directly when you want them:

```bash
sudo it-oscap                        # scan; a few minutes
sudo it-ckl --format both --summary  # -> /opt/ia/stig/checklists/<host>-<ts>.cklb and .ckl
```

Read the `it-ckl` header before trusting the output:

```
STIG      : Canonical Ubuntu 24.04 LTS STIG  (Release: 6 Benchmark Date: 01 Jul 2026)
Rules     : 194
Scan      : stig-viewer-20260824-134321.xml  -> 171 rules matched
ID map    : 1832 SSG->STIG references from ssg-ubuntu2404-ds.xml  -> 171 STIG ids resolved
Answers   : 9 adjudications loaded from /opt/ia/stig/answers.yml
```

**`-> 0 rules matched` means the checklist is meaningless** — every rule falls through to Not_Reviewed. The tool says so loudly and names the likely cause. `it-ckl --debug` prints the three id namespaces side by side (scan idrefs, id-map entries, the keys the manual STIG looks up) and the size of their intersection, which shows immediately which join is failing.

**On the results file.** `oscap --stig-viewer` looked like the obvious input and turned out, on this content, to produce a file with **zero** rule-results — so the checklist came out empty regardless of the id mapping. `it-ckl` therefore tries candidates newest-first across all three scan directories — `stig-arf-*`, `stig-viewer-*`, then the `usg audit` output — and uses the first that actually contains results, reporting what it skipped and why. `--results` forces a specific file.

#### Why an ID map is needed

The manual STIG names a rule `UBTU-24-200640` / `V-270691`. A scan against SSG content names the same rule `xccdf_org.ssgproject.content_rule_banner_etc_issue_net`. They share no key, and `oscap --stig-viewer` does **not** rewrite ids into DISA's namespace when the content is SSG. SSG's datastream carries the link as an xccdf `<reference>` on each Rule, so `it-ckl` reads it and builds the mapping, finding the datastream on the box automatically. Scanning with DISA's benchmark makes the ids line up directly and needs no map.

Several SSG rules routinely cover one STIG id — `setxattr` and siblings are seven SSG rules and one STIG rule. **The worst result wins**, and `finding_details` names every contributing rule and its result:

```
V-270784   UBTU-24-900130   Open
    Automated: OpenSCAP evaluated this rule as 'fail'.
    SCAP rules checked: audit_rules_dac_modification_fsetxattr=fail,
                        audit_rules_dac_modification_setxattr=pass
```

A STIG rule is not satisfied because part of it passed.

#### Baking the answers in

Everything already adjudicated lives in `roles/scap_scan/templates/ckl-answers.yml.j2` and is rendered per profile, so an entry can differ between an AI node and the EMI laptop. Keyed by STIG id, V-ID, or SSG rule name:

```yaml
UBTU-24-600200:
  status: not_a_finding
  override: true
  finding_details: |
    ufw rate-limits inbound SSH. Remaining listening ports are application
    service ports whose normal traffic exceeds ufw's threshold.
  comments: Manual/OCIL rule -- always reports fail in SCAP.
```

An entry can also carry **`evidence_cmd`**, whose output is captured into `finding_details`. That is how the manual/OCIL rules get answered without an operator pasting terminal output into STIG Viewer on every box — and it keeps the checklist honest, since the evidence is what the machine actually reported rather than a claim in prose:

```yaml
UBTU-24-600130:
  status: not_a_finding
  finding_details: |
    Membership of the sudo group is defined in version control and limited to
    named administrator accounts.
  evidence_cmd: "getent group sudo; grep -rn NOPASSWD /etc/sudoers /etc/sudoers.d/ || echo 'none'"
```

Output is trimmed to 40 lines, a 30-second timeout applies, and a command that fails records the failure rather than breaking the run. The answer file is root-owned and rendered from this repo, so its commands carry the same trust as the playbook; `--no-evidence` skips them all. **Read the captured output before accepting the status** — the entries are pre-filled with what is correct for a standard build, so a box that has drifted will show it there.

**A SCAP failure always beats the answer file** unless the entry sets `override: true`. Without that rule a stale adjudication could quietly mark a broken control compliant, which is the one mistake that makes a checklist worthless. When an entry proposes a pass over a real failure the rule stays **Open** and the reason is written into its comments.

**No status goes out unexplained.** Any rule that ends Open, Not Applicable or Not Reviewed *without* a matching answer-file entry gets a generated comment saying so — for an Open rule, naming the key to file it under:

```
NO SITE ADJUDICATION RECORDED for this rule. The status above comes purely from
the automated scan. If this is an accepted deviation or a compensating control,
record it once in roles/scap_scan/templates/ckl-answers.yml.j2 keyed on
UBTU-24-102000 -- it then appears on every box and every future checklist
instead of being re-argued. If it is a real finding, remediate it in the build
rather than answering it here.
```

A Not Applicable that came from the scanner rather than a human says that too, so an assessor can tell the difference between "the rule does not apply here" and "somebody decided it does not apply". Every run prints the count of unexplained rules, and `it-ckl --unjustified` lists them with the key to file each under — that is the operator's to-do list. UBTU-24-200660 sat Open across two cycles with no justification purely because its adjudication was never written; this makes that impossible to miss.

After answering the `Not_Reviewed` list by hand, push anything reusable back into the template. That list should shrink every cycle; if it does not, the answers are not being captured.

#### Cadence

| When | What |
|---|---|
| Weekly, automatic | `oscap-scan.timer` re-scans to `/opt/ia/oscap/scheduled` (`Persistent=true`, so a run missed while powered off fires at next boot) |
| Before you start | `sudo it-stig status` — confirms the manual STIG, SSG content, tailoring file and `answers.yml` are all in place |
| After any change | `sudo it-oscap` and compare against the last run |
| Monthly / on demand | `sudo it-ckl`, answer the remainder, archive the `.cklb` |
| Per STIG release | Re-stage the manual XCCDF, regenerate, re-answer what moved |

Keep the generated `.cklb` alongside the `usg audit` report — together they are the evidence that the box matches its documented baseline.

### Assessment artifacts we can provide

- **This repository** (`ubuntu-stig-build`): the full, reviewable configuration-as-code baseline.
- **`usg audit` reports** (XCCDF `.xml` + HTML) collected to `/opt/ia` on each box. STIG compliance evidence per host.
- **This document:** every documented deviation and POA&M.
- **[Container-runtime compliance](#container-runtime-compliance-why-no-docker-stig):** why there's no docker-ce STIG and how the container layer is secured (CIS Docker Benchmark).
- **Architecture, ports, software inventory:** [`reference.md`](reference.md).
- Host inventory, FIPS status, and encryption/TPM binding evidence on request.

*Prepared to support A&A discussions. Final control selection, categorization, and authorization are determined with the ISSM/ISSP and the AO.*

---

## Container-runtime compliance (why "no Docker STIG")

Common question: the OS is STIG-hardened by USG, is Docker STIG'd too? Short answer: **USG does not cover Docker, there is no applicable DISA STIG for the Docker engine we run, and the container layer is secured to the CIS Docker Benchmark.**

### 1. USG hardens the OS, not Docker

Canonical's USG applies the **DISA Ubuntu 24.04 LTS STIG**, an **operating-system** benchmark. It does not assess or configure the Docker daemon, container settings, or images. "The box passed `usg audit`" is an **OS** statement; the container runtime is a separate control surface.

### 2. There is no applicable DISA STIG for docker-ce

- The only Docker STIG DISA publishes is the **"Docker Enterprise 2.x Linux/UNIX STIG"**, written for **Docker Enterprise / Mirantis (UCP, DTR, RBAC)**, a different product. We run **`docker-ce`** (Community Edition). The Enterprise STIG's controls are product-specific (UCP/DTR web consoles, enterprise RBAC) and **do not map** to a plain `docker-ce` + Compose host.
- DISA's **Container Platform SRG** and the **Kubernetes STIG** target orchestration platforms (OpenShift/Kubernetes). We run **plain Docker Compose**, no orchestrator, so those don't apply.

**Conclusion:** no drop-in STIG to run against this Docker host. That's why industry and DoD assessors use the **CIS Docker Benchmark** for `docker-ce` instead.

### 3. How the container layer *is* secured (CIS Docker Benchmark alignment)

The `docker_hardening` role (ai profile) applies CIS-aligned daemon settings, **merged** into `/etc/docker/daemon.json` (the NVIDIA GPU runtime is preserved):

| Setting | CIS ref | Effect |
|---------|---------|--------|
| `no-new-privileges: true` | 5.25 (daemon-wide) | No container can gain privileges via setuid binaries |
| `live-restore: true` | 2.14 | Containers survive a daemon restart (availability) |
| `userland-proxy: false` | 2.15 | Kernel hairpin NAT instead of `docker-proxy` (smaller attack surface) |
| `log-opts` size/rotate | 6.x | Bounded container log growth |

Plus, by design of the stack:

- **No privileged containers**, no host PID/IPC/network sharing; the AI workload runs unprivileged.
- **Least capabilities** where practical (e.g. Redis runs `cap_drop: ALL` + only `SETGID/SETUID/DAC_OVERRIDE`).
- **Network isolation.** Services share a single user-defined bridge (`oi`); only required ports published, cross-node ports firewall-restricted to the peer (USG's ufw default-deny + `ai_firewall`).
- **Docker socket** not mounted into workload containers (only Dockge, an admin tool, restricted to admins).
- **Host is FIPS + STIG-hardened** (the kernel/OS the containers share), and the **model runs inference only**. See [AI-specific risk considerations](#ai-specific-risk-considerations).
- **Image provenance.** All images pinned by exact tag, can be **mirrored to an internal registry** and hash-verified for air-gap (supply-chain / SR controls).

### 4. Optional evidence: docker-bench-security

Run CIS's own scanner and file the report with the USG reports in `/opt/ia`:

```bash
sudo docker run --rm --net host --pid host --userns host --cap-add audit_control \
  -v /etc:/etc:ro -v /var/lib:/var/lib:ro -v /usr/lib/systemd:/usr/lib/systemd:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  docker/docker-bench-security | sudo tee /opt/ia/docker-bench-$(date +%Y%m%d).txt
```

### 5. Control mapping (NIST 800-53 Rev 5)

| Control | How the container layer supports it |
|---------|-------------------------------------|
| **CM-6 / CM-7** | Hardened, version-controlled daemon config; least functionality (no privileged/host-namespace containers) |
| **AC-6** | `no-new-privileges`, least-capability containers, no workload access to the Docker socket |
| **SC-7** | User-defined network isolation + host firewall (default-deny), only required ports published |
| **SI-7 / SR** | Pinned, mirrorable, hash-verifiable images; reproducible build |

*Bottom line for the AO/ISSP: the host is STIG+FIPS hardened by USG; the Docker layer (no docker-ce STIG exists) is hardened to the CIS Docker Benchmark and documented here. `docker-bench-security` provides on-demand evidence.*

---

## Software inventories

Per-profile software lists — Software/Tool, Version, Publisher, Purpose — are in **[reference.md → Software inventory](reference.md#software-inventory)**.

Everything is pinned and reproducible from this baseline, and can be mirrored to an internal registry or staged offline for air-gap. External data sources read by oikb (GitLab / Confluence / S3, per `site.yml`) are org services, not installed software.
