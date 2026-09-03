# Project context for Claude Code

Ansible baseline that builds and STIG-hardens Ubuntu 24.04 boxes. Two deployment
profiles matter most: `development` (engineering workstation) and `ai` (a
two-node self-hosted AI stack). Boxes provision themselves via `ansible-pull`
from this repo — there is no control node.

Start with `README.md`, then `docs/`. Do not duplicate those here.

## Layout

| Path | What |
|---|---|
| `local.yml` | the playbook `ansible-pull` runs |
| `bootstrap.sh` | what an operator runs on a fresh box |
| `it-pull` (`roles/it_scripts/files/pull.sh`) | what an operator runs on an EXISTING box. `it-pull` = light (no apt, no scan, no container touched), `full`, `scripts`, `ai`, `status` (incoming commits + files), `log`, `load` (adopt a baseline carried in on media; air-gapped boxes). `check` exists but Ansible check mode skips command probes and can report the OPPOSITE of the truth (it decided ASP-2 was not Pro-attached); `status` is the reliable preview |
| `group_vars/all.yml` | nearly all configuration and profile gating |
| `roles/` | one role per concern (`ai_compose`, `ai_stack`, `usg_harden`, `local_accounts`, …) |
| `roles/ai_compose/files/stacks/<stack>/compose.yaml` | the per-service Docker stacks, deployed to `/opt/stacks/<stack>/` |
| `docs/` | operator + IA documentation |

## Working conventions

- **Push to `main` immediately** unless there's a real reason not to. That is the
  owner's standing instruction, not an assumption.
- **Never commit secrets.** Passwords are auto-generated per box into
  `/etc/stig-build/*.pw` and rendered into each stack's root-only `.env`. Compose
  files use `${VAR:?set in .env}` so a missing value fails loudly. This repo was
  public until recently — treat anything ever committed as compromised.
- **Docs are three files, and that is deliberate.** `procedures.md` is steps,
  `reference.md` is tables, `compliance.md` is for assessors. Eight overlapping
  documents drifted (build.md still described the retired `stig_harden` role and
  the wrong report path). Add to the right one of the three rather than starting
  a fourth.
- **Comments earn their place.** Compose files were deliberately trimmed to ~9%
  comments. Keep a comment only if removing it would let someone break something
  (the FIPS carve-out, the docling mount trap, PersistentConfig). Do not restate
  the YAML or narrate history.
- **A routine pull no longer scans.** It used to run three full benchmark
  evaluations (`usg audit` in `usg_harden`, again in `usg_remediate`, and
  `oscap xccdf eval` in `scap_scan`) plus a checklist build, every time.
  `usg_audit_on_pull` / `scap_scan_on_pull` (both `build`) hold those to a box's
  first build; evidence otherwise comes from the weekly `oscap-scan.timer` and
  `it-stig run`. The `usg_harden`-stage audit is skipped whenever
  `usg_remediate` will re-audit. Role tags `packages` and `scripts` exist
  alongside `ai-runtime`/`ai-gpu`; `it-pull` is the only place the skip-tag
  strings are written down. `scripts` covers `it_scripts` AND `powerstrux`, so
  `it-pull scripts` ships `it-powerstrux` and its offload too.
- **The deployment profile is persisted in `/opt/it/site.yml`**, loaded above
  `group_vars` by `local.yml`'s pre_tasks. It has to be: `group_vars` defaults
  to `development`, so any `ansible-pull` without `-e deployment_profile=` used
  to rebuild an EMI laptop as a development box -- silently turning off USB
  storage, the dta carve-out and the camera/mic lockdown. ASP-2 was found that
  way. `bootstrap.sh` writes it; `it-pull --profile <name>` sets and persists
  it, and refuses to run when it cannot determine one.
- **Verify before asserting.** Several bugs here came from plausible-sounding
  assumptions. Check the actual file, the actual package, the actual box.
- **Profile gating** is computed in `group_vars` (`is_ai`, `is_emi`,
  `emi_classified`, …). "All profiles except emi-unclass" is a real pattern — see
  `local_auto_audit_enabled`.

## Gotchas that have already caused outages

1. **Docker bypasses ufw.** Published container ports are DNAT'd before ufw's
   INPUT chain, so ufw rules do **not** filter them. Confirmed on dev-ai2:
   port 5000 was absent from ufw and still reachable from the LAN. `DOCKER-USER`
   is empty. MLflow is protected by an nginx allow-list instead; every other
   published port is still effectively open on the LAN.
2. **Ansible overwrites on-box edits.** Every file `ai_compose` places is a plain
   `copy`/`template` — `compose.yaml`, `.env`, `fips_off`, dashboards. Only
   `.oikb.yaml` is preserved (`force: false`). A hand-edit on a box is lost on the
   next pull, and if `ai_compose_deploy` is true the container is recreated too.
   For a genuine per-box exception use `compose.override.yaml`, which nothing
   manages.
3. **The FIPS carve-out.** The host runs a FIPS kernel; vLLM and Docling images
   have no FIPS OpenSSL provider and abort at startup. They bind-mount a
   `fips_off` file over `/proc/sys/crypto/fips_enabled`. The host stays FIPS.
4. **Docling's models are baked into its image**, with runtime downloads
   disabled. Mounting a volume over its model cache **hides** them and docling
   crash-loops. To add a model, mount its own subdirectory, never the parent.
5. **Image tags are pinned**, so `docker compose pull` is not an update. Patching
   a container means editing the tag in this repo. See `docs/procedures.md` §4.
6. **Volumes are external**, so `docker compose down -v` cannot delete model
   weights or databases. Also means Postgres keeps its original password on an
   existing volume regardless of the env var.
7. **Open WebUI RAG settings are `PersistentConfig`** — env seeds a *fresh*
   database only. On an existing box they must be changed in the UI.
8. **Stacks behind a `profiles:` tag read "n/a" in Dockge.** That is correct
   behaviour for the run-and-exit tools, not a fault.

- **Two offloads, deliberately.** `/etc/cron.weekly/audit-offload` (`it-offload`)
  carries the **auditd** trail and nothing else -- that is the AU-4 artifact an
  assessor opens. The PowerStrux reports go out through `it-powerstrux offload`,
  which builds one folder per ISO week (`/opt/ia/powerstrux-offload/<YYYY>-W<nn>/`:
  report + run logs + `PowerStruxLAConfig.txt` + a sha256 `MANIFEST.txt` naming
  host/profile/baseline) and copies it to an SMB share. Do NOT merge them by
  adding `/opt/_AuditFiles` to `usg_audit_offload_extra`: that stage copies
  files with `cp -p` in a glob loop, so a directory logs "unreadable", and the
  two schedules are unrelated so it can run before the week's report exists.
  The new one is ordered instead -- `powerstrux-audit.service` has
  `Wants=powerstrux-offload.service` and the offload is `After=` it, so it
  starts when the audit FINISHES however long that took, and still runs when
  the audit failed. Its settings are written to BOTH
  `/etc/stig-build/powerstrux-offload.conf` (immediate) and `/opt/it/site.yml`
  (survives the pull); the share password only ever reaches the 0600
  `powerstrux-offload.cred`. Windows auth is a three-way choice because
  `mount.cifs` wants different things: `domain=<AD domain>`, `domain=<the file
  server's own name>` for a LOCAL account, or guest.

- **The FPGA toolchains are scaffolding-only, deliberately.** `fpga_tools`
  (development profile only) installs the 24.04-correct deps, i386 multiarch,
  the ncurses-5 symlinks, `/usr/tmp` 1777, the RHEL CA path, udev rules and the
  `/etc/profile.d` environment. It NEVER installs or writes into Vivado or
  Libero: they are interactive, authenticated, ~150 GB, and baked into the
  image. The tree-touching fixes are `it-fpga fixup`, a command run once after
  an install, not a pull task. Four things not to undo:
  1. `vivado_env` / `libero_env` use UNDERSCORES. `/etc/profile.d/*.sh` is
     sourced by **dash** for `sh` logins and dash rejects a hyphen in a function
     name -- it passes an interactive bash test and breaks every `sh -l`.
  2. Licences come from a FlexLM **server**; `it-fpga license --server` writes
     both `/etc/profile.d/*.sh` and `site.yml`. A LOCAL daemon is a systemd unit,
     never a line in an env script -- that starts one daemon per shell, which is
     the "stale lmgrd on the port" the vendor guides work around instead of fix.
  3. udev is `MODE="0660"` + group, not the vendors' `0666`. And **USBGuard
     blocks the cable before udev names it** -- `it-usb enroll` is the step
     people miss.
  4. `dialout`/`plugdev` are in BOTH `local_groups` and
     `local_users_common_groups`. They must be created in `local_groups`
     because `local_accounts` runs long before `fpga_tools` and
     `user: append:false` FAILS on a group that does not exist yet.
  5. The STIG's `umask 077` means a sudo-run vendor installer builds a
     ROOT-ONLY tree (0700/0600), so engineers get "Permission denied" on
     settings64.sh and it looks like a failed install. `it-fpga fixup` does
     `chmod -R a+rX`; `it-fpga status` detects it. Never launch the tools with
     sudo to work around it -- root has no Xauthority cookie for the user's
     RDP session and the GUI then fails on X11 instead. See trap 29.
  6. The i386 list is a WISH. Ubuntu publishes only a curated i386 subset on
     24.04, several vendor-listed libraries cannot be installed, and ONE
     unresolvable name fails the whole apt transaction -- that stopped a pull
     on dev-14 and took the 64-bit half with it. The role probes with
     `apt-get -s install` and installs what resolves; the 64-bit list stays
     strict. Use `apt-get -s`, NOT `apt-cache policy`: policy answers "has a
     candidate", which is not "can be installed", and that mistake cost a
     second failed pull on dev-13. See traps 26 and 27.
  i386 multiarch is written up as an approved deviation in `compliance.md`.

- **VS Code extensions are shared, not copied.** One store in
  `/opt/vscode-extensions`; users hold symlinks, `/etc/skel` holds the same so
  `useradd` stays instant. The old `/etc/skel` seeding was a real 3.0 GB /
  27,395-file copy per account (65 s per `useradd`) and is off. A user's own
  real directory is never replaced by a link. VS Code loads from
  `extensions.json`, NOT by scanning, so the shared manifest travels with the
  links -- `it-vscode verify` asks the editor rather than the filesystem, and
  `it-vscode copy <user>` is the fallback if a version rejects it.
- **code-server is single-user per instance.** Every engineer gets their own on
  `dev_code_server_port + (uid - dev_code_server_uid_base)` -- derived from the
  UID, never from a list position, or removing one person moves everyone else's
  port. Entitlement is membership of `dev_code_server_group` (`sentry`), applied
  by the pull; the pull also DISABLES instances for people no longer in it.
  Locked accounts are skipped by their shell. Default bind is `0.0.0.0`, so this
  is N IDEs on the LAN with shell access as that user -- `127.0.0.1` takes them
  off it and the pull then removes the ufw range.

## Open threads

- **Rotate the leaked credentials.** The old pgvector password, Open WebUI
  session key, and MLflow password were committed while the repo was public.
  Scrubbed from the working tree, still in history. An `it-rotate-secrets`
  script (new password + `ALTER USER` on the live DB + `.env` + recreate) was
  proposed and not written.
- **`DOCKER-USER` firewall rules** in `ai_firewall`, so the ufw policy actually
  applies to published ports. This is the systemic fix for gotcha 1.
- **Unpinned custom images.** `hfcli` (pip `--upgrade`), `repomix` (npm latest)
  and `oikb` (`git clone` with no ref, plus `sed` patches against specific
  upstream lines) are not reproducible. `openwiki` is pinned via
  `ARG OPENWIKI_VERSION` and is the pattern to follow.
- **Models track HF `main`** with no revision pin; a re-fetch can change weights
  silently. An incomplete gpt-oss download already caused a garbage-output bug.
- **`auto_audit` has no job.** The scheduled OpenSCAP scan runs as **root** (via
  `it-oscap` + a systemd timer) precisely because `auto_audit` is locked and
  cannot sudo unattended. If nothing else needs the account, dropping it from
  `sudo` is the least-privilege end state.
- **USBGuard is on for every profile including EMI.** The initial policy is
  generated from attached devices, so the built-in keyboard is always
  authorised; peripherals are enrolled with `it-usb enroll`.
- **GRUB password is inert until a hash is vaulted** — `grub_password_pbkdf2` is
  still the CHANGEME sentinel, so the role skips. Activate with `it-grub hash`
  (fleet) or `it-grub set` (one box); check with `it-grub status`. This matters
  more here than usual: LUKS is TPM-sealed to PCR 7 only, which does not measure
  the kernel command line, so without the GRUB password physical access → root
  shell on decrypted data.
- **openwiki generation** is wired to System 1's vLLM but has never produced a
  real wiki. Getting the repo into `/work` and publishing output where the viewer
  reads it is still a manual three-step.
- **granite-docling VLM** is not deployed; it needs a custom docling image with
  the weights baked in. `external_granite_vision` is not a valid preset name.
- **BOTH AI nodes have drifted from the repo. Full as-built record is in
  `docs/reference.md` -> "AI nodes -- as-built".** Captured read-only
  2026-08-28; NOTHING has been changed on either box, the engineers are still
  testing. The headlines:
  - **`pgbouncer` publishes `5432:5432` on BOTH nodes** (System 1's Open WebUI
    DB, System 2's MLflow DB). The repo publishes nothing. A published container
    port cannot be filtered by ufw (gotcha 1), so Postgres is genuinely on the
    LAN twice. Raise before the next accreditation pass.
  - **The ufw allow for 8002 names the wrong host.** Both nodes carry
    `8002/tcp ALLOW IN 192.168.1.102`, but System 1 is **192.168.1.104**.
    Embeddings work today only because the published port bypasses ufw --
    the day `DOCKER-USER` rules land (the fix for gotcha 1), RAG breaks unless
    this is corrected first. Fix the rule BEFORE the firewall fix.
  - **`docling`'s `restart: unless-stopped` is commented out on dev-ai2**, so it
    does not come back after a reboot. Runtime confirms `restart=no`.
  - **`oikb`'s `profiles: ["oikb"]` guard is commented out**, so it starts
    unguarded and has been crash-looping (Exited 1) for two weeks.
  - **`vllm-vision` is stopped**, while System 1's Open WebUI still lists
    `192.168.1.110:8003` as a chat endpoint -- a dead endpoint in the UI.
  - `open-webui` also publishes `8050:8050`; `vllm-gptoss` hardcodes
    `192.168.1.110` where the repo uses `${SYSTEM2_ADDR}` (so `it-set-ip`
    cannot renumber it) and drops `--override-generation-config`;
    `pgvector`'s memory limit is 2G on the box, 4G in the repo;
    `prometheus` runs as `prometheus-standalone` off an ANONYMOUS volume and
    the stale `/opt/it/docker/grafana/prometheus.yml` path.
  - `/opt/stacks/ai` and `ai-system1`/`ai-system2` are the stale pre-split dirs.
  - The two nodes are on DIFFERENT baselines (`06d49fc` / `6b458b1`), both
    behind main.
- **The audit-rule gap WAS fleet-wide, and the cause is found (2026-08-28).**
  This was recorded here as ASP-2-specific on the strength of dev-ai1 loading
  60 of 68 rules; that reading was wrong. dev-13 showed the same 1-of-68 with
  auditd NOT immutable, and `augenrules --load` named it:
  `Syscall name unknown: kexec_load` / `error in line 6`. Line 6 was this
  repo's own `71-reboot.rules` b32 line. **Syscall names are per-architecture**
  -- the i386 table calls entry 283 `sys_kexec_load`, only x86_64 calls it
  `kexec_load` -- and **auditctl stops at the first rule it cannot apply**, so
  one bad name left the other 67 rules unloaded while every file-based OVAL
  still passed. A box showing more than 1 loaded was running rules from an
  earlier boot under `-e 2`, not succeeding.
  Fixed: names are now resolved against the box's own tables before the rule is
  written. Two things to know if you touch this:
  1. `ausyscall <arch> <name>` is NOT a valid oracle -- it fuzzy-matches and
     exits 0 for `b32 kexec_load`, which auditctl rejects. Test for an EXACT
     match in `ausyscall <arch> --dump`.
  2. The same abort happens for a watch on a path that does not exist. USG
     watches `/var/log/sudo.log` (UBTU-24-500010) and nothing created it, so it
     was the next line the load would have died on. `usg_remediate` now creates
     it and points sudo at it.
  `it-checklist` item 6 checks for both faults read-only and names them.
- **Offline apt is half-solved.** The main archive is covered: `offline_repo` +
  `it-repo` carry a repo tree in on media and point apt at
  `/srv/repo` over `file://` (standalone/EMI only -- the dev/ai fleet uses the
  ADM-Toolkit's HTTP repo server). `it-repo load` auto-detects the media,
  mirrors only the box's own release (the ADM media carries jammy AND noble),
  copies packages additively on name+size and the `dists/` indexes last with
  `--checksum --delete`, and both it and the role now list every pocket the tree
  carries -- `noble-security` is a separate suite, and listing only `noble` meant
  a box could hold every security `.deb` and still report "0 to upgrade". Two
  things remain: the carried repo is **unsigned** (`Trusted: yes`; set
  `offline_repo_signed_by` if the builder ever signs it), and **Ubuntu Pro / ESM
  packages are still not reachable** offline. The BASELINE half is solved
  separately by `it-pull load`, which adopts a `git clone --mirror` carried in
  on the same media (`/srv/baseline.git` + `REPO_URL` in `pull.conf`). It is
  admin-only on purpose -- the baseline runs as root on the next pull -- so on
  EMI the DTA copies it off the media and the admin loads it.

## Docs

| Doc | For |
|---|---|
| `docs/procedures.md` | **the takeover doc.** Every task as numbered steps: build, deploy, patch, scan, recover |
| `docs/reference.md` | lookup: traps, `it-*` commands, paths, config vars, AI ports/volumes, software inventory |
| `docs/compliance.md` | IA / DCSA posture, the org checklist, POA&M, STIG-checklist generation |
