# Reference

Lookup tables. For "how do I do X", see [procedures.md](procedures.md).

## Contents

| | |
|---|---|
| **[Traps](#traps)** | things that have already cost us a box — read once |
| **[Profiles](#profiles)** | what each one builds |
| **[Commands](#commands)** | every `it-*` and what it does |
| **[Paths](#paths)** | where everything lives |
| **[Configuration](#configuration)** | the variables worth knowing |
| **[AI stack](#ai-stack)** | nodes, ports, stacks, volumes, models |
| **[AI nodes — as-built](#ai-nodes--as-built-2026-08-28)** | what the two boxes actually run, drift and faults included |
| **[Software inventory](#software-inventory)** | IA/DCSA inventory per profile |

---

## Traps

Each of these caused a real outage or a wrong conclusion.

**1. Docker bypasses ufw.** Published container ports are DNAT'd before ufw's INPUT chain, so ufw rules do not filter them. Confirmed on dev-ai2: port 5000 was absent from ufw and still reachable from the LAN. `DOCKER-USER` is empty. MLflow is protected by an nginx allow-list instead; every other published port is effectively open on the LAN. The systemic fix — `DOCKER-USER` rules in `ai_firewall` — is not written yet.

**2. Ansible overwrites on-box edits.** *(To update a live AI node without this happening, skip the `ai-runtime` tag — [procedures.md §5.8](procedures.md#58-update-a-live-ai-node-without-touching-the-containers).)* Every file `ai_compose` places is a plain `copy`/`template`: `compose.yaml`, `.env`, `fips_off`, dashboards. Only `.oikb.yaml` is preserved. A hand-edit is lost on the next pull, and the container is recreated with it. For a genuine per-box exception use `compose.override.yaml`, which nothing manages.

**3. Ansible's `copy` and `link` only ever create.** Removing something from a profile needs an explicit `state: absent` task, or a box that got it from an earlier build keeps it forever. `it_scripts` does this for the AI and EMI tooling; copy that pattern.

**4. ClamAV silently does nothing on a FIPS host.** OpenSSL in FIPS mode refuses MD5, which is what ClamAV hashes content with, so the engine loads every signature and then scans **zero bytes**, reports every file clean, and exits 0. No error an operator would see. Upstream [clamav#1786](https://github.com/Cisco-Talos/clamav/issues/1786), open, no fix, and not configurable around — Ubuntu's FIPS OpenSSL takes FIPS from the kernel flag, so even `OPENSSL_CONF=/dev/null` fails. The fix is `clamav_container`. **`sudo it-clamav test` is the only thing that settles it.**

**5. nmap does not run on a FIPS box either.** It initialises OpenSSL at startup, the FIPS provider gives it no usable cipher suite, and it quits before probing anything — `library has no ciphers`. Same root cause as trap 4 and equally unconfigurable: nmap links the host OpenSSL. Fixed the same way — `nmap_container` builds an image on a stock base and `it-vulnscan` falls back to it, reporting `OK (via container)`. When neither works it records `NMAP-FAULT` and item 28 FAILs. **A vuln report reading "0 open ports, nothing flagged" because the scanner never started is the exact failure this repo keeps meeting.**

**6. clamd needs 60–90 s after a restart** before its socket answers — it binds only after loading ~3.6M signatures. A test in that window falls back to the broken host engine and looks exactly like a broken container.

**7. The FIPS carve-out for containers.** vLLM and Docling images have no FIPS OpenSSL provider and abort at startup, so they bind-mount a `fips_off` file over `/proc/sys/crypto/fips_enabled`. The host kernel stays FIPS. Do not "clean this up".

**8. Docling's models are baked into its image**, with runtime downloads disabled. Mounting a volume over its model cache **hides** them and docling crash-loops. To add a model, mount its own subdirectory, never the parent.

**9. Image tags are pinned**, so `docker compose pull` is not an update. Patching a container means editing the tag in this repo.

**10. Volumes are external**, so `docker compose down -v` cannot delete model weights or databases. It also means Postgres keeps its original password on an existing volume regardless of the env var.

**11. Open WebUI RAG settings are `PersistentConfig`.** Env seeds a *fresh* database only. On an existing box they must be changed in the UI.

**12. SSG's two cron audit OVALs disagree about a trailing slash.** One STIG rule (UBTU-24-200270), two automated checks, and they want the watch written differently — verified against `ssg-ubuntu2404-ds.xml` 0.1.81:

```
/etc/cron.d/      contains: ^\s*-w\s+/etc/cron.d/\s+-p\s+wa(\s|$)+     <- requires the slash
/var/spool/cron   contains: ^\s*-w\s+/var/spool/cron\s+-p\s+wa(\s|$)+  <- requires NO slash
```

Writing both with a trailing slash — which is exactly what DISA's fix text tells you to do — passes `audit_rules_etc_cron_d` and fails `audit_rules_var_spool_cron`. `auditctl` normalises the slash away, so `auditctl -l` prints the same thing either way and DISA's own check text (which greps the **kernel**) is satisfied by both forms; only the file-reading OVAL cares. `audit_cron_watches` in `group_vars` carries the exact text per path. **Do not tidy them into a consistent form.**

**17. A symlink into `/opt/it` reads as "command not found" to a non-admin.**
`/opt/it` is `2770 root:sudo`. Every `it-*` command is a symlink in
`/usr/local/sbin` pointing there, so for a user outside the `sudo` group `stat()`
on the target fails with EACCES, bash skips the PATH entry and reports
**`command not found`** — not "Permission denied", which is what you would go
looking for. The command is installed and the user may even hold a sudoers grant
for it. `sudo <cmd>` works (sudo resolves the path as root); the bare name does
not. Any script a non-admin group is meant to run therefore goes in
`it_scripts_public`, which installs it as a real file in `/usr/local/sbin`
(`it-repo` for the `dta` group). `dta-log` solves the same problem the other way,
by living in `/opt/dta` (2750 root:dta) with a link in `/usr/local/bin`.

**18. A snap browser cannot open a file in `/opt`, and says "File not found".**
Firefox on 24.04 is a **snap**. It runs in its own mount namespace containing
the user's home and, if the interface is connected, removable media — and no
`/opt` at all. Point it at `file:///opt/_AuditFiles/<report>.html` and it
reports *File not found* for a file that is right there and readable, which
sends you hunting a permissions problem that does not exist. `chmod` cannot
fix it; the path does not exist inside the sandbox. `run-powerstrux open`
copies the newest report into the auditor's home (0600 in a 0700 directory)
and opens that. The same applies to anything else under `/opt` or `/srv` you
try to open from the desktop.

**19. Everything in `/etc/skel` is copied again for every account.** `useradd -m`
duplicates the whole tree per user, so a large file seeded there is paid for on
every account the build creates and every one an admin creates afterwards. VS
Code extensions were seeded there for convenience; on ASP-2 that reached **3.0 GB
across 27,395 files**, and `useradd -m` measured **65 seconds** — reported, twice,
as `it-adduser` hanging. Nothing in the account-creation path was wrong. Keep
`/etc/skel` to dotfiles: `sudo du -sh /etc/skel` should be kilobytes.

**20. A new account has no AccountsService record, so GNOME shows the generic
avatar.** `desktop_branding` sets `Icon=` in `/var/lib/AccountsService/users/<user>`
for every user *that exists when it runs*, and seeds `/etc/skel/.face`. GNOME
reads AccountsService, not `~/.face` — so an account created between pulls
inherits the image file and still shows the default picture until the next pull
happens to enumerate it. `it-adduser` writes the record itself now.

**21. A malformed `/opt/it/site.yml` stops the ENTIRE pull, before any role runs.**
`local.yml` loads it with `include_vars` in `pre_tasks`, so a YAML error there
fails the play at task 2 — nothing is applied, and the failure names the file
rather than whatever you were actually trying to change. `expected '<document
start>'` is the usual one: it means a `---` or `...` appears mid-file and the
content after it is a second document. **Appending to site.yml by hand is how
this happens** — `it-pull --profile <name>`, `it-offload`, `it-repo enable` and
`run-powerstrux schedule` all edit it properly. `sudo it-pull status` now
reports a file that will not parse, before the pull does. Check by hand with:

```bash
sudo grep -n '^\(---\|\.\.\.\)' /opt/it/site.yml
python3 -c "import yaml; yaml.safe_load(open('/opt/it/site.yml'))"
```

**13. A passing benchmark is not a compliant box.** `usg fix` leaves `PermitRootLogin prohibit-password`, which satisfies the STIG rule (it only forbids a root *password* login) while still allowing root in **by SSH key** — which the org checklist forbids outright. Found on ASP-2 with a 96.41 % scan. Check what the rule actually asserts, not just its colour.

**13. Audit rules on disk are not audit rules in the kernel, and they may not be in `rules.d`.** Two separate traps in one place. First, `usg fix` writes **`/etc/audit/audit.rules` directly**, not `rules.d/*.rules` — so an empty `rules.d` is normal on a USG box, and counting only `rules.d` reports "no rules" on a box with a full ruleset. Second, whatever is on disk still has to reach the kernel: the STIG sets auditd `-e 2` (immutable), after which new rules are refused until a reboot. Either way **every file-based OVAL still passes**, because those check files. ASP-2 ran with **1 rule in the kernel** against 8.5 KB in `audit.rules` and the 96.41 % scan said nothing. `it-checklist` item 6 counts whichever source holds rules and compares it against the kernel. Diagnose with:

> **Mind the glob.** `/etc/audit/rules.d` is `root:root 0750`, so `sudo cat /etc/audit/rules.d/*.rules` fails with *"No such file or directory"* — your **unprivileged shell** expands the glob before `sudo` runs, and it cannot read the directory. That looks exactly like an empty directory and is not. Wrap it: `sudo sh -c 'cat ...'`.

```bash
sudo auditctl -l                                              # what the kernel enforces
sudo grep -cvE '^\s*(#|$)' /etc/audit/audit.rules             # what usg fix wrote
sudo sh -c "cat /etc/audit/rules.d/*.rules | grep -cvE '^[[:space:]]*(#|$)'"   # rules.d
sudo auditctl -s | grep enabled                               # 2 = immutable, needs a reboot
sudo augenrules --check                                       # is audit.rules out of step with rules.d?
```

**14. A green playbook is not evidence.** ASP-2's compliance score barely moved (88.476 → 88.703) across a full remediation run — two whole categories of fix were being written correctly and still failing, because a stale file was poisoning rules that were otherwise satisfied and PAM values were being written into a file nothing read. Neither showed as an Ansible failure. **The re-audit is the evidence.**

**16. Blacklisting `usb-storage` does not disable USB storage.** SSG's UBTU-24-300039 covers that one module, which drives the bulk-only transport. A USB3 device that speaks USB Attached SCSI binds **`uas`**, a separate module the rule never mentions — so the scan passes green while a modern USB SSD mounts normally. `usg_remediate` blacklists both wherever `usb_storage_enabled` is false. Conversely, neither module has anything to do with **non-storage** USB: dongles, serial/COM adapters (`ftdi_sio`, `cp210x`, `ch341`, `cdc_acm`), HID and printers are unaffected, and **USBGuard** is what blocks those until `it-usb enroll` authorises them. Verify with `lsmod | grep -E '^(usb_storage|uas)'` (empty is correct) — not with the scan result.

**22. Two offloads, and only one of them carries the report.** `/etc/cron.weekly/audit-offload` (`it-offload`) has only ever collected the rotated **auditd** trail — its extra-file stage takes files, not directories, and nothing pointed it at `/opt/_AuditFiles`. Its schedule is also unrelated to `powerstrux-audit.timer`, so even pointed there it could run *before* the week's report existed. The PowerStrux reports go out through **`it-powerstrux offload`** instead, which is pulled in by `powerstrux-audit.service` (`Wants=`) and ordered `After=` it, so it starts when the audit finishes however long that took. Do not "fix" this by adding `/opt/_AuditFiles` to `usg_audit_offload_extra`; it would log *unreadable, not collected* and still race.

**23. A hyphen in a `/etc/profile.d` function name breaks every `sh` login.** `/etc/profile` sources `/etc/profile.d/*.sh`, and for an `sh` login that shell is **dash**, which rejects a hyphen in a function name — `Syntax error: Bad function name`, printed at every login on every workstation. Bash accepts it, so it passes an interactive test and fails for cron, scripts and `sh -l`. The FPGA helpers are `vivado_env` / `libero_env` with underscores for exactly this reason; do not "tidy" them. Test any profile.d change with `dash -c '. /etc/profile.d/x.sh'`, not just bash.

**24. Starting a licence daemon from a login script starts one per shell.** Both FPGA vendors' guides end their environment script with `lmgrd -c License.dat`, then tell you to hunt the stale daemon with `lsof -i :1702` when checkout fails with *"Cannot locate license file"*. The port was simply taken by the copy the last shell started. A local daemon is `fpga-lmgrd.service`, one per machine. Better still, use a licence server and run no daemon at all.

**25. FlexLM needs two ports, and one of them is random.** `lmgrd` listens where you configured it; the *vendor* daemon (`snpslmd`, `xilinxd`) picks a random port at startup unless it is pinned with `PORT=` on the `DAEMON` line in the server's licence file. Through a firewall the symptom is a licence server that answers on the port you opened and still fails every checkout. `it-fpga status` probes the `lmgrd` port and says this when it succeeds.

**26. Ubuntu 24.04 publishes only a CURATED i386 subset, and one unresolvable name fails the whole apt transaction.** Ubuntu stopped building a full 32-bit archive after 19.10. `libgtk2.0-0t64:i386` pulls `libcups2t64:i386` -> `libgnutls30t64:i386`, which noble does not satisfy for i386; same chain via `libsystemd0:i386` -> `libgcrypt20:i386`. Every FPGA vendor guide on the internet lists these as prerequisites, and apt refuses the **entire** install — which on dev-14 took the 64-bit half down with it and stopped the pull. `fpga_tools` splits the 64-bit list (strict) from the 32-bit one (probed, best-effort) and reports by name what it skipped. Never pin a version or side-load a foreign `.deb` to force one in; `sudo it-fpga check` lists what is missing and why.

**27. `apt-cache policy` does not tell you whether a package can be installed.** It answers "does this NAME have a candidate", which is a different question from "does its dependency closure resolve". `libgtk2.0-0t64:i386` has a candidate on noble and still cannot be installed. The tell is in apt's own wording: *"not installable"* means no candidate, *"not going to be installed"* means there is one and the resolver refused — and a policy probe cannot distinguish them. This cost a second failed pull on dev-13 after the first fix used policy as the oracle. The correct oracle is **`apt-get -s -q install -y <pkg>`**, which resolves the whole tree, does no dpkg work, and exits 100 when it cannot. Both `fpga_tools` and `it-fpga check` use it.

**28. Ansible's free-form `shell:` splits arguments, and double quotes inside Jinja break it.** `shell: |` with `{{ x | default("") }}` in the body fails at parse time with *"failed at splitting arguments, either an unbalanced jinja2 block or quotes"* — before anything runs, so it looks like a YAML error and is not. Use the `cmd:` key (`shell:` → `cmd: |`), which is not split. Same script, same Jinja, parses fine.

**29. The STIG umask makes every sudo-run vendor installer produce a root-only tree.** `umask 077` is the baseline setting, so an installer run under `sudo` -- which Vivado and Libero both need, to write `/tools` and `/opt` -- creates `0700` directories and `0600` files throughout. Engineers then get *"Permission denied"* sourcing `settings64.sh`, which reads as a failed install and is not one; the natural workaround, running the tool under `sudo su`, then fails differently because root has no `.Xauthority` cookie for the user's RDP session (*"Can't connect to X11 window server"*). Neither error names the cause. `sudo it-fpga fixup` applies `chmod -R a+rX` -- capital X, so data files do not come out executable -- and `it-fpga status` detects it with one stat. Applies to anything else installed the same way.

**15. Pre-USG leftovers.** Two separate outages traced to files the current baseline neither writes nor removes, left by the old ansible-lockdown role (`/etc/audit/rules.d/stig.rules`, and `pam_faillock` lines in `common-auth` with `pam_unix`'s jump offset never recalculated). Assume there are others on any box built before the USG switch.

---

## Profiles

Set with `deployment_profile` in `group_vars/all.yml`, or `PROFILE=` on `bootstrap.sh`. Default `development`. `desktop`/`server` are aliases for `development`/`ai`.

| Profile | For | What it builds |
|---|---|---|
| `development` | Engineering workstation | Dev toolchain, GNOME desktop over **RDP**, code-server, Cockpit |
| `ai` | Two-node inference server | Docker + NVIDIA + Dockge + the compose stacks. Headless |
| `emi` | Imaging / field workstation, **classified-capable** | `development` app set minus RDP, plus VPN/recon/CJK-IME, an imaging firewall (DHCP/TFTP/DNS/OpenVPN), and a camera + mic lockdown. FIPS + LUKS/TPM on, full `usg fix` |
| `emi-unclass` | Same hardware, **unclassified only** | As `emi` but FIPS/LUKS/TPM off and the disruptive `usg fix` skipped. USG audit + ufw/dconf/banner hardening still apply. No `auto_audit`, no DTA gate on USB |
| `baseline` | An already-built box | Provision + harden only. No app installs, no RDP |

Every profile attaches Ubuntu Pro, creates the org accounts/groups and `/opt/ia` + `/opt/it`, runs USBGuard, and drops a USG report in `/opt/ia/usg`.

Gating is computed in `group_vars` — `is_ai`, `is_emi`, `emi_classified`, `is_development`, `is_baseline`. "All profiles except emi-unclass" is a real pattern; see `local_auto_audit_enabled`.

---

## Commands

All self-elevate with `sudo`. Scripts live in `/opt/it/scripts`, symlinked into `/usr/local/sbin`.

> **`it-help` lists all of this, on the box.** It discovers the commands from
> what is actually installed, so it is right for that machine's profile without
> anyone maintaining a list. `it-help <command>` prints one command's full
> options; `it-help --all` prints every one.

### Every profile

| Command | Does |
|---|---|
| `it-pull` | Re-run the baseline. `it-pull` (light — config + scripts, no apt, no scan, **no container touched**), `full` (+ packages and a fresh audit/scan), `scripts` (that role alone), `ai` (opts into the compose stacks), **`load [PATH]`** (air-gapped: adopt a baseline repo carried in on media — mirrors it to `/srv/baseline.git`, sets `REPO_URL` in `pull.conf`, admin-only, verifies the repo by content and requires a typed `YES`), `check` (Ansible `--check`; unreliable — check mode can report the opposite of the truth, see procedures §1.10), `status` (behind origin? plus the incoming commits and files), `log`. Reads the repo/branch off the box's own `ansible-pull` checkout; override in `/etc/stig-build/pull.conf` |
| `it-status` | Everything at a glance |
| `it-host` | OS, kernel, FIPS, uptime, disks |
| `it-luks` | Encryption state + TPM binding |
| `it-luks-rebind` | Re-bind LUKS to the current PCRs after a firmware change |
| `it-grub` | `status` / `hash` (fleet) / `set` (one box) — GRUB password |
| `it-usb` | USBGuard: `status`, `list`, `blocked`, `enroll`, `allow`, `trust` |
| `it-checklist` | The org checklist, one line per item. `--fail-only`, `--out FILE`, and **`--fix`** — prints how to close every FAIL and what each MANUAL item needs from a human. Prints steps, changes nothing |
| `it-oscap` | Run an OpenSCAP DISA-STIG scan now |
| `it-powerstrux` | Run the PowerStrux audit. `open` copies the newest report to `~/PowerStrux-Reports/` and opens it — **necessary**, because Firefox is a snap and cannot see `/opt` (trap 18). Also `status`, `schedule "<spec>"`, `enable`/`disable`; a schedule change is persisted to `site.yml` |
| `it-powerstrux offload` | Carry the week's report off the box. `status` (default), `setup`, `creds`, `test`, `run [--local]`, `extra list\|add\|remove`, `list`, `log [N]`, `on\|off`, `push on\|off`, `audit on\|off`, `containers on\|off`, `opts <cifs-options>`, `where`. Builds one dated folder per ISO week — the report, its run logs, `PowerStruxLAConfig.txt`, a sha256 `MANIFEST.txt` — and copies it to a Windows share. Runs **after** the scheduled audit, not on a clock of its own. Writes both `/etc/stig-build/powerstrux-offload.conf` (immediate) and `/opt/it/site.yml` (survives the pull) |
| `it-ckl` | Build the DISA `.cklb`/`.ckl` from the scan + `answers.yml` |
| `it-stig` | `status` / `run` / `scan` / `checklist` / `archive` — wraps the two above |
| `it-domain` | `status`, `preflight`, `stage`, `join`, `test`, `leave`, `pam-restore`. Joins a box to AD. **`preflight` changes nothing** and checks the things that actually make joins fail: SRV records, clock skew, ports 88/389/445/464/3268, PAM health. `join` backs up the PAM stack first — `realm join` regenerates it |
| `it-smb` | `status`, `add`, `test`, `mount\|umount [--all]`, `creds`, `remove`, `log`. Mounts Windows/SMB shares as systemd **automount** units — an unreachable server cannot delay boot, and the share mounts on first access. `test` walks cifs-utils → credentials → DNS → port 445 → a real mount attempt, and translates the cifs status code into a cause |
| `it-offload` | `status`, `setup`, `creds`, `containers on\|off`, `push on\|off`, `test`, `log [N]`, `apply`. Configures the weekly **auditd** offload — what is collected, the remote share, the credentials. Writes to `/opt/it/site.yml` so it survives `ansible-pull`; re-running is idempotent. **It does not collect the PowerStrux reports** — that is `it-powerstrux offload` |
| `it-clamav` | `check`, `list`, `install`, **`scan PATH...`**, `test`, `sync`, `rollback`, `revert`, `image-save`, `image-load`. `scan` proves the engine detects EICAR **before** trusting a verdict and refuses to scan if it does not — a CLEAN from an unverified engine is worse than no scan. Reports unreadable paths as PARTIAL rather than folding them into "0 infected". Records every run in `/var/log/clamav-scan.log` |
| `it-goclassified` | Pre-classification gate. `--report` for machine checks only |
| `it-repo` *(was `it-offline-repo` until 2026-09-01; the old symlink is removed on the next pull)* | `scan` / `load` / `enable` / `disable` / `verify` — run apt off a local repo. `scan` finds repo trees on attached media; `load` (no path needed) mirrors **only this box's release** — all of its pockets including `-security` — incrementally, packages first then indexes. `--prune`, `--dry-run`, `--suite <name>`. **`howto [topic]`** is a package-management cheat sheet — apt, dpkg, single `.deb` files, pip on 24.04, the local repo, what needs a reboot. It prints commands and runs none; `it-repo howto` alone lists every section, `it-repo howto python` one of them |
| `it-users` | Every local account on one screen: state, days until the password expires, last login, groups. Read-only. `--all` includes system accounts, `--wide` stops truncating groups, `--csv` and `--out FILE` for evidence (the saved copy is written without colour) |
| `it-adduser` | Create a local account. Asks the type (standard/dta/admin/audit) and derives both the username suffix and the group set from it, then **how to set the password: type one, generate a temporary one, or leave it locked**. `--temp` / `--lock` skip the question for scripted use |
| `it-passwd` | Reset a password, unlock the account, and clear its faillock counter. Asks the same three-way question as `it-adduser`: type one, **generate a temporary one** (`--temp`), or keep the current one. `--list` shows every account's state and expiry; `--unlock-only` skips the password |
| `it-fpga` *(development only)* | The FPGA toolchains: `status` (default — what is installed, licence reachability, cables), `license --server <port>@<host> [--xilinx …]` / `--file <License.dat>` / `--none`, `check`, `fixup`, `cables`, `env`. The baseline installs the scaffolding, **not** Vivado or Libero — those are baked into the image. A licence change writes both `/etc/profile.d/*.sh` and `/opt/it/site.yml` |
| `it-vscode` *(development)* | One copy of the VS Code extension set for the box. `status` (default), `link <user>\|--all`, `unlink`, `copy`, `verify`. Users get **symlinks** into `/opt/vscode-extensions`, so an account costs bytes rather than 3 GB; `/etc/skel` holds the same links so `useradd` stays instant. `verify` asks the editor what it can actually see |
| `it-codeserver` *(development)* | Who has a browser IDE. `status` (default), `password <user>`, `url`, `restart`, `log`. code-server is single-user per instance, so each engineer runs their own on `dev_code_server_port + (uid - 1000)`. Entitlement is membership of `dev_code_server_group` — applied by the pull, not by enabling the unit |
| `it-set-classification` | Set the banner level |
| `it-inventory` | Hardware/serials/listening ports → `/opt/it/inventory-<host>.txt` |
| `pam-auth-check` | Can `common-auth` authenticate at all? Read-only |

### EMI profiles only

| Command | Does |
|---|---|
| `it-vulnscan` | nmap `vuln` scripts + AV scan → `/opt/ia/vulnscans`. Falls back to the containerised nmap when the host one cannot start under FIPS; `image-save`/`image-load` stage that image for an air-gapped box. Records `NMAP-FAULT` / `ENGINE-FAULT` and exits non-zero when a scanner did not actually run. `VULNSCAN_AV_PATHS` overrides what the AV half walks |
| `dta-log` | Record and scan a data transfer → `/opt/dta/logs` |

### AI profile only

| Command | Does |
|---|---|
| `it-ai` | `up`, `down`, `stop`, `restart`, `status`, `logs`, `stacks`, `model`, `run`, `oikb` |
| `it-models` | What model weights are present, and how big |
| `it-docker` | Docker/container health |
| `it-restart` | Restart the Docker layer |
| `it-set-ip` | Renumber a node — rewrites `site.yml`, `/etc/hosts`, every `.env` |
| `it-model-export` | Gather models + images onto a USB (online box) |
| `it-model-import` | Load them on the fielded box |
| `it-stack-diff` | On-box compose files vs the `ansible-pull` clone |

---

## Paths

| Path | What |
|---|---|
| `/opt/ia/` | IA area, `root:sudo 2770`. Admins enter without `sudo` |
| `/opt/ia/usg/` | `usg audit` reports (HTML + XCCDF) — the compliance score |
| `/opt/ia/oscap/build,scheduled,manual/` | OpenSCAP artifacts, one directory per writer so retention never prunes another's evidence |
| `/opt/ia/stig/content,checklists,evidence/` | DISA's manual STIG XCCDF (shipped by `scap_scan`, no longer staged by hand), generated checklists, archived bundles |
| `/opt/ia/goclassified/` | Pre-classification records |
| `/opt/ia/vulnscans/` | `it-vulnscan` reports (EMI) |
| `/opt/ia/audit-offload/` | Weekly staged audit logs (`it-offload`) |
| `/opt/ia/powerstrux-offload/<YYYY>-W<nn>/` | The week's PowerStrux folder: report, run logs, config, `MANIFEST.txt`. Always kept locally even after a successful push. `root:audit 0750`, newest 26 weeks |
| `/opt/_AuditFiles/` | PowerStrux reports and `logs/`. `root:audit 2770` — reading needs the `audit` group. Also holds `run-powerstrux.sh` and `powerstrux-offload.sh` |
| `/opt/it/` | IT admin area, same ownership |
| `/opt/it/scripts/` | The `it-*` scripts |
| `/opt/it/site.yml` | **Per-node overrides. Beats `group_vars`.** Never in git |
| `/opt/it/clamavsigs/` | Drop ClamAV signature archives here |
| `/opt/it/apt-sources-backup/` | Online apt sources parked by `it-repo enable` |
| `/opt/dta/incoming,outgoing,logs/` | Data-transfer staging and records (EMI) |
| `/tools/Xilinx`, `/opt/microchip` | FPGA toolchains (development). **Not managed by Ansible** — baked into the image or installed by hand. Root-owned, NOT under a home directory: `$HOME` is the vendors' single-machine advice and means one 30+ GB copy per engineer |
| `/etc/profile.d/{xilinx,microchip}.sh` | The FPGA environment every user gets at login. `vivado_env` / `libero_env` load the heavy `PATH` per shell |
| `/usr/local/bin/{vivado,vitis,libero}` | Launchers. Source the vendor settings for that one process, not for every login shell. Written only when the toolchain is actually installed |
| `/usr/share/applications/fpga-*.desktop` | App-grid tiles for every user. The vendors' installers do not make usable ones — a `--batch Install` under sudo puts them in `/root/Desktop` |
| `/etc/stig-build/fpga/License.dat` | Node-locked FPGA licence, `0600 root:root`. Absent when a licence server is used, which is the fleet default |
| `/opt/vscode-extensions/` | The box's single copy of the VS Code extension set. Users hold symlinks into it; `/etc/skel` holds the same. root:root 0755 |
| `/etc/code-server/<user>.password` | Per-user code-server password, `0600 root:root`. Generated once, stable across pulls |
| `/opt/stacks/<stack>/` | AI compose stacks — Dockge watches this dir |
| `/srv/repo/` | The carried offline apt repo. `root:root 0755` |
| `/etc/stig-build/` | Root-only. Generated `*.pw`, the GRUB hash, `profile` — which records the deployment profile and the **baseline revision** this box last pulled — and the offload configs/credentials |
| `/etc/stig-build/powerstrux-offload.conf` | What `it-powerstrux offload` reads. Rendered from `site.yml` by the pull; the commands write both |
| `/etc/stig-build/powerstrux-offload.cred` | The share service account, `0600 root:root`. Never in git, never in `site.yml` |
| `/etc/luks/initial-passphrase` | Read once to bind the TPM, then deleted |
| `/var/lib/clamav-container/` | The containerised scanner's own signature database |

`/etc/stig-build/site.yml` still works as a legacy location for per-node overrides.

---

## Configuration

Everything is in [`group_vars/all.yml`](../group_vars/all.yml), with comments. Per-node overrides go in `/opt/it/site.yml` — see [`site.yml.example`](site.yml.example).

The ones worth knowing:

| Variable | Default | Effect |
|---|---|---|
| `deployment_profile` | `development` | Which build |
| `emi_classified` | true unless `emi-unclass` | FIPS + LUKS/TPM + full `usg fix` |
| `editor_choice` | `vscode` | `vscode` \| `vim` \| `neovim`. The only setting that removes an internet dependency |
| `dev_tools_user` | `austin_case_adm` | **Must match the account you created in the installer** |
| `usg_fix_enabled` | true | The disruptive `usg fix disa_stig` |
| `usg_enable_fips` | true | FIPS kernel via Pro. Needs a reboot |
| `usg_fix_pam_stack` | **false** | Regenerates `common-auth`. Off by choice — see [compliance.md](compliance.md) |
| `usg_chrony_servers` | `ntp.ubuntu.com` | Set to your enclave's time server; an air-gapped box cannot reach a public pool |
| `usg_faillock_unlock_time` | 900 | Seconds. `0` = admin reset only |
| `usg_fix_log_permissions` | true | `/var/log` file modes (UBTU-24-700010). Swept at build time and daily by `stig-log-perms.timer` |
| `usg_fix_library_group` | true | `chgrp root` on `*.so*` under the library dirs (UBTU-24-300009) |
| `audit_cron_rules_enabled` | true | `72-cron.rules` — watch `/etc/cron.d` and the cron spool, key `cronjobs` (UBTU-24-200270) |
| `audit_reboot_rules_syscalls` | `reboot`, `kexec_load` | Names are resolved per-arch before the rule is written — i386 says `sys_kexec_load`, x86_64 says `kexec_load`, and a wrong name aborts the **whole** rule load |
| `usg_sudo_logfile_enabled` | true | Create `/var/log/sudo.log` + `Defaults logfile` so UBTU-24-500010's watch can load |
| `ia_retention_keep` | 3 | How many of each pull-created evidence file to keep (scan sets, `.cklb`, USG reports). Per file **kind**, so a scan set stays whole. `1` keeps only the newest |
| `ia_retention_targets` | see `group_vars` | Which directories and globs the prune covers. Scheduled/ad-hoc oscap dirs are excluded — they self-prune via `scap_schedule_keep` |
| `usg_disable_smartcard_rules` | 3 rules | De-selected in the USG tailoring. Rules **absent from USG's own bundled content** get an explicit `<select selected="false">` added, so a scan against the newer `ssg_content_version` de-scopes them too |
| `grub_password_pbkdf2` | `CHANGEME` | The role skips until a real hash is vaulted |
| `tpm_luks_enabled` | true except `emi-unclass` | Binds LUKS to PCR 7 |
| `offline_repo_enabled` | false | Switch apt to `/srv/repo`. Set by `it-repo enable` |
| `offline_repo_dta_load_enabled` | true | Sudo grant letting the `dta` group run `it-repo scan/status/load` (four exact argv forms, no wildcard, not NOPASSWD). On EMI the admin cannot mount removable media and the DTA cannot write `/srv/repo`, so without it the tree has to be copied to local disk first. Written by `local_accounts`, removed when the toggle or `local_usb_transfer_enabled` is false |
| `base_packages_full_upgrade` | false | `apt full-upgrade` early in the build |
| `scap_stig_manual_xccdf` | `U_CAN_…_V1R6_Manual-xccdf.xml` | DISA's manual STIG, shipped in `roles/scap_scan/files/`. Update on a new STIG release |
| `usg_audit_on_pull` | `build` | When `usg audit` runs during a pull. `build` = only on a box with no report yet; `always` = every pull (pre-2026-08 behaviour, what `it-pull full` passes); `never` = timer only. The `usg_harden`-stage audit is now skipped whenever `usg_remediate` will re-audit — one evaluation, not two |
| `scap_scan_on_pull` | `build` | Same for `oscap xccdf eval`. A routine pull runs **no** benchmark evaluation; evidence comes from the first build, the weekly `oscap-scan.timer`, and `it-stig run` |
| `scap_ckl_on_pull` | true | Build the `.cklb` from the scan that just ran. Now also requires that a scan actually ran this pull — without one it would rewrite an identical checklist every time |
| `local_accounts_enabled` | true | Org users/groups/ACL'd folders |
| `powerstrux_offload_enabled` | true | Build a week folder after each scheduled audit. With the share off it stages locally only — which is what an air-gapped box carries out on media |
| `powerstrux_offload_window_days` | 8 | How far back "this week" reaches. 8 not 7, so a run the `Persistent=true` timer caught up late is still collected |
| `powerstrux_offload_keep` | 26 | Week folders held locally before pruning (~6 months) |
| `powerstrux_offload_smb_enabled` | false | Copy each week folder to a Windows share |
| `powerstrux_offload_smb_share` / `_subdir` | — / hostname | `//fileserver/audit$` and the per-box folder under it |
| `powerstrux_offload_smb_auth` | `domain` | `domain` \| `workgroup` \| `guest`. Decides what `mount.cifs` gets in `domain=` — an AD domain, or the **file server's own name** for a local account |
| `powerstrux_offload_smb_options` | `vers=3.1.1,sec=ntlmssp,…` | An older NAS or Server 2008 R2 needs `vers=2.1`; `it-powerstrux offload test` says so when the mount fails |
| `powerstrux_offload_include_audit` / `_containers` / `_extra` | false / false / `[]` | Also put the auditd archive, `docker logs`, or named paths/globs in the week folder. A directory in `_extra` is copied whole |
| `powerstrux_offload_oncalendar` | `""` | Empty = chained to the audit run, which is what you want. Set a calendar spec only to give the offload a schedule of its own as well |
| `fpga_tools_enabled` | development only | The FPGA scaffolding. i386 multiarch is an approved deviation on the engineering workstations and has no business on EMI or an AI node |
| `fpga_license_mode` | `none` | `server` \| `local` \| `none`. `server` is the fleet answer: no local daemon, no per-box `License.dat`, no MAC registration |
| `fpga_license_microchip` / `_xilinx` | — | `<port>@<host>`, comma-separated for a redundant triad. Set here for a fleet default, or per box with `it-fpga license` |
| `fpga_device_group` | `plugdev` | Who may talk to the JTAG programmers. `dialout` covers USB-serial consoles; both are in `local_users_common_groups` |
| `fpga_ncurses5_shim` | true | Symlink `libtinfo.so.5`/`libncurses.so.5` onto the ncurses 6 sonames. Vivado hangs at *"Generating installed device list"* without it |
| `dev_code_server_group` | `sentry` | Who gets a code-server instance. Every standing account joins `sentry`, so a new engineer gets one on the next pull. Empty = the primary user only |
| `dev_code_server_exclude` | `[]` | Accounts in that group that should not get one. Locked accounts are skipped already (by shell); this is for `dta`/`audit`, which are in `sentry` too |
| `dev_code_server_port` / `_uid_base` / `_port_span` | 8080 / 1000 / 20 | `port = base + (uid - uid_base)`. Derived from the UID so it is stable per person; a UID outside the span is skipped rather than colliding. The span is what ufw opens |
| `dev_code_server_bind_addr` | `0.0.0.0` | **N IDEs on the LAN, one per engineer.** `127.0.0.1` takes them off it (RDP browser or SSH tunnel) and the pull removes the ufw rule |
| `vscode_shared_extensions_dir` | `/opt/vscode-extensions` | One copy of the extension set for the whole box |
| `dev_tools_vscode_skel_seed` | false | The old behaviour: a real 3 GB copy in `/etc/skel`, so every `useradd` copies it. Superseded by the symlink store |
| `ai_model_fetch` | — | Fetch model weights during the build |
| `ai_compose_deploy` | — | Bring the stacks up during the build |

---

## AI stack

### The two nodes

| Node | Hostname | Job |
|---|---|---|
| System 1 | `dev-ai1` | Front end + chat model — Open WebUI, vLLM, pgvector, PgBouncer, Redis |
| System 2 | `dev-ai2` | Helpers — embedding/vision vLLM, Docling, Tika, Grafana, Prometheus, MLflow, oikb |

The hostname picks the role.

### Open in a browser

| What | URL |
|---|---|
| Chat (Open WebUI) | `http://dev-ai1:3000` |
| Grafana | `http://dev-ai2:3001` — first login `admin`/`admin` |
| MLflow | `http://dev-ai2:5000` |
| Doc wiki | `http://dev-ai2:4321` |
| Dockge / Cockpit | `:9001` / `:9090` on each box |

### Stacks

One Dockge stack per service, each with its own `compose.yaml` and root-only `.env`. All share the external `oi` network and external named volumes.

**System 1**

| Stack | Port | Profile | Job |
|---|---|---|---|
| `vllm-gptoss` | `:8000` | default | Chat model (gpt-oss-120B) |
| `vllm-granite` | `:8001` | `granite` | Alternate chat model |
| `pgvector` | internal | default | Accounts, chats, settings + vector index |
| `pgbouncer` | internal | default | Connection pooler — every DB URL points here |
| `redis` | internal | default | Websocket coordination + cache |
| `open-webui` | `:3000` | default | The chat website |

**System 2**

| Stack | Port | Profile | Job |
|---|---|---|---|
| `vllm-embed` | `:8002` | default | RAG embeddings |
| `vllm-vision` | `:8003` | default | Vision / image understanding |
| `docling` | `:5001` | default | Document structure + OCR |
| `tika` | `:9998` | default | Text extraction, other file types |
| `grafana-otel` | `:3001` `:4317` `:4318` | default | Grafana + OTel |
| `prometheus` | `:9091` | default | Scrapes the vLLM/docling `/metrics` |
| `mlflow` | `:5000` | default | Experiment tracking, nginx-fronted, 5 replicas |
| `openwiki-view` | `:4321` | default | Browse the generated doc wiki |
| `oikb` | `:8081` | `oikb` | Knowledge-base sync → System 1 |
| `hfcli` | — | `tools` | Download models into volumes |
| `openwiki` | — | `tools` | Generate a doc wiki from a repo |

Stack name ≠ container name for `docker logs`: `vllm-gptoss` → `vllm-server`, `docling` → `docling-serve`, `grafana-otel` → `open-webui-lgtm`, `mlflow` → `mlflow` + `mlflow-db` + `mlflow-proxy`, `openwiki-view` → `openwiki-view` + `openwiki-view-proxy`.

**Postgres is reached through PgBouncer.** Open WebUI runs 9 uvicorn workers, each with its own pool, which exhausted Postgres' connection slots — so `DATABASE_URL` and `VECTOR_DB_URL` point at `pg-bouncer:5432`. The pooler runs in **transaction** mode, so session state does not persist between statements: anything needing it (session-level `SET`, advisory locks, `LISTEN`/`NOTIFY`) must talk to `pgvector:5432` directly. Neither publishes a port — the `oi` network is the only way in, deliberately, since ufw cannot filter a published container port (trap 1).

**Break-glass.** The pre-split single-file compose stays at `/opt/it/docker/docker-compose.consolidated.yaml`, not deployed and deliberately not named `docker-compose.yaml`. Same volumes, so `docker compose -f ... up -d` brings the node up as one project with no data move.

### How the nodes talk

Containers cannot resolve the peer's hostname, so cross-node addressing comes from `site.yml` IPs rendered into each `.env`.

- **System 1 → System 2** (`ai_system2_addr`): embeddings `:8002`, vision `:8003`, Docling `:5001`, OTel `:4317`
- **System 2 → System 1** (`ai_system1_addr`): oikb calls Open WebUI's API on `:3000`. Opt-in — no API key, no oikb

### Volumes

**System 1**

| Volume | Contents | Mount |
|---|---|---|
| `vllm` | gpt-oss-120b weights (~61 GB) | `/gpt120b` |
| `granite32b` | granite-4.1-30b weights | `/granite30b` |
| `encodings` | tiktoken vocab for gpt-oss | `/etc/encodings` |
| `pgvector-data` | Postgres + vector store | `/var/lib/postgresql/data` |
| `open-webui` | Users, chats, uploads | `/app/backend/data` |
| `redis-data` | Redis persistence | `/data` |

**System 2**

| Volume | Contents | Mount |
|---|---|---|
| `granite-embed` | granite-embedding-small-english-r2 | `/granite-embed` |
| `granite-vision` | granite-vision-4.1-4b | `/granite-vision` |
| `lgtm-data` | Grafana dashboards + TSDB | `/data` |
| `prometheus-data` | Scraped metrics | `/prometheus` |
| `mlflow-artifacts` | MLflow artifact store | `/mlflow/artifacts` |
| `postgres_mlflow_data` | MLflow's Postgres | `/var/lib/postgresql/data` |
| `openwiki-out` | Generated wiki markdown | `/work` |

**Docling has no volume** — its models ship baked into the image (trap 8).

```bash
sudo docker volume inspect vllm                  # find its Mountpoint
sudo du -sh /var/lib/docker/volumes/vllm/_data   # size on disk
```

### Model API names

What to send as `model` to the OpenAI-compatible endpoints. This is vLLM's `--served-model-name`, **not** the Hugging Face repo path.

| Model | Node | Port | API name |
|---|---|---|---|
| gpt-oss-120b | S1 | `:8000` | `gpt-oss-120b` |
| granite-4.1-30b | S1 | `:8001` | `granite-4.1-30b` |
| granite-embedding-small-english-r2 | S2 | `:8002` | `granite-embedding-small-english-r2` |
| granite-vision-4.1-4b | S2 | `:8003` | `granite-vision-4.1-4b` |

System 1's two chat models are **alternates** — both are served tensor-parallel across its two 48 GB GPUs and only one fits.

---

## AI nodes — as-built, 2026-08-28

**This records what the boxes ACTUALLY run, faults included.** It is not a target state and not a repo description — where the live config differs from `roles/ai_compose/files/stacks/`, the live config is what is written here, because that is what an assessor will find and what an engineer will be debugging. The repo remains the intended state; the drift table below is the delta.

Captured read-only from both nodes. Nothing was changed. Reproduce with `sudo it-stack-diff --full` plus the runtime capture in [procedures.md §4](procedures.md).

### Nodes

| | System 1 | System 2 |
|---|---|---|
| Host | `dev-ai1` | `dev-ai2` |
| Address | 192.168.1.104 | 192.168.1.110 |
| Kernel | 6.8.0-136-fips | 6.8.0-136-fips |
| FIPS | enabled (`fips_enabled=1`) | enabled |
| GPU | **2 ×** RTX 6000 Ada, 48 GB, driver 595.84 | **1 ×** RTX 6000 Ada, 48 GB, driver 595.84 |
| Docker | 29.6.2, Compose v5.3.1 | 29.6.2, Compose v5.3.1 |
| Baseline at capture | `06d49fc` | `6b458b1` |
| Pending apt updates | 51 | 47 |

Both baselines are behind `main`, and they differ from each other — the two nodes are not on the same commit.

### System 1 — running containers

| Container | Image | Published | Restart | Mem limit | GPU |
|---|---|---|---|---|---|
| `open-webui` | `ghcr.io/open-webui/open-webui:v0.10.2` | `3000→8080`, **`8050→8050`** | unless-stopped | — | — |
| `vllm-server` | `vllm/vllm-openai:v0.22.1-cu129-ubuntu2404` | `8000` | unless-stopped | — | both |
| `pgvector` | `pgvector/pgvector:pg16-trixie` | — | unless-stopped | **2 G** | — |
| `pg-bouncer` | `edoburu/pgbouncer:v1.25.1-p0` | **`5432→5432`** | unless-stopped | — | — |
| `redis` | `redis:7.2.14-bookworm` | — | unless-stopped | — | — |
| `dockge` | `louislam/dockge:1` | `9001→5001` | always | — | — |
| `clamav-container` | `clamav/clamav:1.4.3` | — | **no** | 3 G | — |

`vllm-granite` is defined but not running — it sits behind the `granite` profile and only one chat model fits VRAM. Correct behaviour.

### System 2 — running containers

| Container | Image | Published | Restart | GPU |
|---|---|---|---|---|
| `vllm-embed` | `vllm/vllm-openai:v0.22.1-…` | `8002` | unless-stopped | yes |
| `docling-serve` | `ghcr.io/docling-project/docling-serve-cu128:v1.24.0` | `5001` | **no** | yes |
| `tika` | `apache/tika:3.3.1.0` | `9998` | unless-stopped | — |
| `open-webui-lgtm` | `grafana/otel-lgtm:0.29.0` | `3001→3000`, `4317`, `4318` | unless-stopped | — |
| `prometheus-standalone` | `prom/prometheus:v3.14.0` | `9091→9090` | unless-stopped | — |
| `mlflow-db` | `pgvector/pgvector:pg16-trixie` | — | unless-stopped | — |
| `mlflow-mlflow-1…5` | `mlflow:v3.15.1-psycopg2` | — | unless-stopped | — |
| `mlflow-proxy` | `nginx:1.30.4-alpine` | `5000` | unless-stopped | — |
| `pg-bouncer` | `edoburu/pgbouncer:v1.25.1-p0` | **`5432→5432`** | unless-stopped | — |
| `openwiki-view` | `openwiki:latest` | `4321→8080` | unless-stopped | — |
| `openwiki-view-proxy` | `openwiki-view:latest` | (shares netns) | unless-stopped | — |
| `dockge` | `louislam/dockge:1` | `9001→5001` | always | — |
| `clamav-container` | `clamav/clamav:1.4.3` | — | **no** | — |

**Not running:**

| Container | State | Consequence |
|---|---|---|
| `vllm-vision` | Exited (0), 2 weeks | **Open WebUI on System 1 still lists `http://192.168.1.110:8003/v1` as a chat endpoint.** The vision model is a dead endpoint from the UI's point of view. |
| `oikb` | Exited (1), 2 weeks | Its `profiles: ["oikb"]` guard was commented out on the box, so it starts by default and crash-loops. In the repo the profile keeps it off. |

### Drift from the repo

Every item below is the **box** differing from `roles/ai_compose/files/stacks/`. A pull with `ai_compose` un-skipped would revert all of it.

**System 1**

| Stack | Repo | On the box | Why it matters |
|---|---|---|---|
| `pgbouncer` | no `ports:` at all | `5432:5432` | Postgres reachable from the LAN. A published container port **cannot** be filtered by ufw (trap 1), so this is genuinely open. |
| `open-webui` | `3000:8080` only | also `8050:8050` | Undocumented second listener. |
| `pgvector` | `limits: memory 4G` | `2G` | Halved. Under RAG load this is where an OOM would come from. |
| `vllm-gptoss` | `${SYSTEM2_ADDR}` | hardcoded `192.168.1.110` | `it-set-ip` cannot renumber the box. |
| `vllm-gptoss` | `--override-generation-config={"temperature":1.0,"top_p":1.0,"repetition_penalty":1.1}` | dropped | Sampling defaults differ from the accredited config. |

**System 2**

| Stack | Repo | On the box | Why it matters |
|---|---|---|---|
| `mlflow` (`pg-bouncer`) | no `ports:` | `5432:5432` | Same LAN exposure as System 1, second instance. |
| `docling` | `restart: unless-stopped` | commented out | **Docling does not come back after a reboot.** Runtime confirms `restart=no`. |
| `oikb` | `profiles: ["oikb"]` | commented out | Starts unguarded, crash-loops. |
| `vllm-vision` | no `logging:` block | `logging:` **misindented under `deploy:`** | Not a valid service key there, so the container has **no log rotation**. |
| `prometheus` | `container_name: prometheus`, named volume `prometheus-data`, `./prometheus.yml` | `prometheus-standalone`, **anonymous** volume, `/opt/it/docker/grafana/prometheus.yml` | TSDB is in an unnamed volume nothing tracks; config comes from the stale pre-split path. |

**Both nodes**

| Item | State |
|---|---|
| `/opt/stacks/ai` | symlink → `/opt/it/docker`; holds `docker-compose.consolidated.yaml`, `docker-compose.yaml.bac`, `.env`, `fips_off` — the pre-split layout |
| `/opt/stacks/ai-system1` / `ai-system2` | empty directories, no compose file |
| `DOCKER-USER` chain | `-N DOCKER-USER` — **empty**, confirming trap 1 fleet-wide |

### Network exposure, as measured

Published container ports bypass ufw entirely (trap 1). What is actually reachable on the LAN:

| Node | Port | Service |
|---|---|---|
| S1 | 3000 | Open WebUI |
| S1 | 8000 | vLLM gpt-oss-120b (no auth) |
| S1 | 8050 | Open WebUI, second listener (undocumented) |
| S1 | **5432** | **PgBouncer → Postgres** |
| S1/S2 | 9001 | Dockge |
| S2 | 3001 / 4317 / 4318 | Grafana / OTLP |
| S2 | 5000 | MLflow (behind its nginx allow-list) |
| S2 | 5001 | Docling |
| S2 | 8002 | vLLM embeddings |
| S2 | 9091 | Prometheus |
| S2 | 9998 | Tika |
| S2 | **5432** | **PgBouncer → MLflow Postgres** |
| S2 | 4321 | OpenWiki viewer |

**The ufw allow-list for 8002 names the wrong host.** Both nodes carry `8002/tcp ALLOW IN 192.168.1.102`, but System 1 is **192.168.1.104**. Embeddings work today only because the published port bypasses ufw. The day `DOCKER-USER` rules are added — the planned fix for trap 1 — RAG embeddings break unless this is corrected first.

### Volumes

System 1: `open-webui`, `pgvector-data`, `redis-data`, `vllm`, `encodings`, `granite32b`, `dockge_data`. Unused leftovers: `docling-models`, `granite-embed`, `portainer_data`.

System 2: `granite-embed`, `granite-vision`, `lgtm-data`, `mlflow-artifacts`, `postgres_mlflow_data`, `openwiki-out`, `docling-models`, `dockge_data`, `pg-bouncer`, plus **seven anonymous hash-named volumes** (one is Prometheus' TSDB) and `portainer_data` from a container that no longer exists.

`docling-models` exists on both nodes and is mounted by nothing — correct, per trap 8: Docling's models are baked into the image and mounting over the cache hides them.

---

## Software inventory

IA / DCSA inventory. Versions are pinned in `group_vars/all.yml`, the compose files, and the image Dockerfiles.

### Every profile

| Software | Version | Publisher | Purpose |
|---|---|---|---|
| Ubuntu | 24.04 LTS | Canonical | Host OS |
| Ubuntu Security Guide (`usg`) | via Pro | Canonical | DISA STIG remediation + audit |
| OpenSCAP + SSG content | distro / pinned | OpenSCAP, ComplianceAsCode | Compliance scanning |
| ClamAV | distro | Cisco Talos | Anti-virus |
| USBGuard | distro | USBGuard project | USB device allow-listing |
| chrony | distro | chrony project | Time sync |
| AIDE | distro | AIDE project | File integrity |
| Cockpit | distro | Red Hat | Web management console |
| PowerShell | 7.4.16 LTS | Microsoft | `pwsh`; required by PowerStrux auditing |
| cifs-utils, smbclient, net-tools, unzip, cron | distro | — | Common tooling |
| clevis + tpm2-tools | distro | Latchset / tpm2-software | TPM-bound LUKS unlock |

### `development` and `emi` additionally

| Software | Version | Publisher | Purpose |
|---|---|---|---|
| GCC / build-essential, CMake, gdb | distro | GNU, Kitware | C/C++ toolchain |
| Python 3.12 + `/opt/eng-venv` | distro | PSF | Shared engineering venv (~140 libs) |
| Node.js | 22.x LTS | NodeSource | JS runtime |
| VS Code | latest | Microsoft | Editor (`editor_choice`) |
| code-server | opt-in | Coder | VS Code in the browser (`development` only) |
| Wireshark / tshark | distro | Wireshark Foundation | Packet capture, gated to `wireshark_users` |
| PuTTY | distro | PuTTY project | Serial / SSH client |
| Docker (docker.io) | distro | Docker Inc. | Containers |
| xrdp + xorgxrdp | distro | xrdp project | RDP (`development` only) |
| nmap | distro | Nmap project | Vulnerability scanning (`emi` only) |
| OpenVPN, tftpd-hpa, isc-dhcp-server, dnsmasq | distro | — | Imaging services (`emi`), installed **disabled** |

### `ai` additionally

| Software | Version | Publisher | Purpose |
|---|---|---|---|
| NVIDIA GPU driver | ≥ 595.71.05 | NVIDIA | GPU driver |
| NVIDIA Container Toolkit | ≥ 1.19.1 | NVIDIA | GPU access in containers |
| docker-ce / -cli / containerd.io | 29.6.1 / 2.2.6 | Docker Inc., CNCF | Container engine |
| docker-buildx / compose / model / sbx plugins | 0.35.0 / 5.3.1 / 1.2.6 / 0.35.0 | Docker Inc. | Build, Compose v2, model runner, sandbox |
| Dockge | pinned | Dockge project | Compose stack UI |

**Container images (pulled)**

| Image | Version | Publisher | Purpose |
|---|---|---|---|
| vllm/vllm-openai | v0.22.1-cu129-ubuntu2404 | vLLM project | LLM inference (S1, S2) |
| open-webui | v0.10.2 | Open WebUI | Chat UI (S1) |
| pgvector/pgvector | pg16-trixie | pgvector | DB + vector store (S1) |
| redis | 7.2.14-bookworm | Redis | Coordination + cache (S1) |
| edoburu/pgbouncer | v1.25.1-p0 | edoburu | Postgres pooler (S1, S2) |
| apache/tika | 3.3.1.0 | Apache | Text/metadata extraction (S2) |
| docling-serve | v1.24.0 (cu128) | IBM / Docling | Structure + OCR (S2) |
| grafana/otel-lgtm | 0.29.0 | Grafana Labs | Monitoring (S2) |
| nginx | 1.30.4-alpine | nginx / F5 | Wiki viewer front-end (S2) |
| prom/prometheus | v3.14.0 | Prometheus | Metrics scraper (S2) |

**Container images (built on the box)**

| Image | Version | Publisher | Purpose |
|---|---|---|---|
| mlflow | v3.15.1 (+psycopg2) | MLflow / LF AI & Data | Experiment tracking (S2) |
| openwiki | 0.3.3 (Node 22.23.1) | openwiki project | Generate a doc wiki (S2) |
| openwiki-view | latest (nginx 1.30.4) | this repo | LAN front-end, vendors its JS so it renders offline (S2) |
| oikb | latest (base oikb 0.3.6) | Open WebUI | Sync data sources into KBs (S2) |
| hfcli | latest (Python 3.12) | Hugging Face | Download models into volumes (S2) |
| repomix | latest (Node 22.23.1) | repomix project | Pack a repo into one file (S2) |

> `oikb`, `hfcli` and `repomix` are **not pinned** (`git clone` with no ref, `pip --upgrade`, `npm latest`). `openwiki` is pinned via `ARG OPENWIKI_VERSION` and is the pattern the others should follow. Open item.

**AI models** (Hugging Face, all Apache-2.0, tracking repo `main` with no revision pin — open item)

| Model | Publisher | Purpose |
|---|---|---|
| gpt-oss-120b | OpenAI | Primary text generation (S1) |
| granite-4.1-30b | IBM | Secondary text generation, switchable (S1) |
| granite-embedding-small-english-r2 | IBM | Embeddings / RAG (S2) |
| granite-vision-4.1-4b | IBM | Vision / document understanding (S2) |

Plus `o200k_base.tiktoken` and `cl100k_base.tiktoken` (OpenAI) — vocab for the gpt-oss harmony tokenizer.

> **granite-docling-258M is not deployed.** Adding it needs a custom docling image with the weights baked in — see trap 8.

External sources read by oikb (GitLab, Confluence, S3, per `site.yml`) are org services, not installed software.
