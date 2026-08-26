# Operations & Reference

Ansible-pull repo. Provisions and DoD-STIG-hardens an **Ubuntu 24.04 Desktop (GNOME)** box, then produces an OpenSCAP compliance report. One run, while the box still has internet, before it's air-gapped.

> Full lifecycle (Ubuntu install to run to post-install checklist): **[Build Guide](build.md)**. This file is the subsystem reference.

## Contents

- [AI stack: quick reference](#ai-stack-quick-reference)
- [What it does, in order](#what-it-does-in-order)
- [One-time setup](#one-time-setup)
- [Running it on the Dell (during imaging, online)](#running-it-on-the-dell-during-imaging-online)
- [Critical gotchas](#critical-gotchas)
- [STIG gap remediation (SSG scan findings)](#stig-gap-remediation-ssg-scan-findings)
- [Local accounts, access groups & branding](#local-accounts-access-groups--branding)
- [TPM2 LUKS auto-unlock (on by default; passphrase supplied out-of-band)](#tpm2-luks-auto-unlock-on-by-default-passphrase-supplied-out-of-band)
- [Remote desktop (development profile, GNOME over RDP)](#remote-desktop-development-profile-gnome-over-rdp)
- [Ubuntu Pro Server (USG + AI stack)](#ubuntu-pro-server-usg--ai-stack)
- [Windows servers](#windows-servers)

## AI stack: quick reference

Self-hosted, on-prem AI chat. Users open a browser, chat with an LLM, and query their own documents. Runs on two STIG-hardened Ubuntu boxes. No internet needed once set up.

> This is the day-to-day lookup. Deeper detail (roles, tunables, POA&Ms, air-gap) is in [Ubuntu Pro Server (USG + AI stack)](#ubuntu-pro-server-usg--ai-stack) below.

### The two machines

| Machine | Hostname | Job |
|---------|----------|-----|
| **System 1** | `dev-ai1` | Front end + brain. Chat website and the LLM(s). |
| **System 2** | `dev-ai2` | Helpers. Document reading, embeddings + vision, monitoring, knowledge sync. |

```
                 users (browser)
                       │
                       ▼
   ┌──────────── SYSTEM 1 · dev-ai1 ────────────┐
   │  Open WebUI  ──►  vLLM (the chat model)     │
   │      ├─► Postgres (accounts/chats/search)   │
   │      └─► Redis    (live updates + cache)     │
   └───────────────────┬─────────────────────────┘
                       │  uses System 2 for embeddings,
                       ▼  vision, document reading, monitoring
   ┌──────────── SYSTEM 2 · dev-ai2 ─────────────────────────┐
   │  Docling + Tika (read files) · embedding + vision models │
   │  Grafana (dashboards) · MLflow (tracking) · oikb (sync)  │
   └───────────────────────────────────────────────────────────┘
```

### What each piece does

| Piece | Where | Job |
|-------|-------|-------------------|
| **vLLM** | 1 | Runs the chat model (gpt-oss-120B or Granite, switchable). |
| **Open WebUI** | 1 | The chat website. |
| **Postgres (pgvector)** | 1 | The database: user accounts/logins, chats, settings, and the searchable document-vector index. |
| **Redis** | 1 | Real-time updates (websockets) and shared cache across the 9 workers. Not logins. |
| **Embedding + vision models** | 2 | Documents to searchable vectors; read images/PDFs. |
| **Docling** | 2 | Text/table extraction from PDFs and Office files. |
| **Tika** | 2 | Text extraction from other file types. |
| **LGTM / Grafana** | 2 | Health dashboards and logs. |
| **MLflow** | 2 | Experiment tracking + model registry (web UI `:5000`, Postgres-backed). |
| **oikb** | 2 | Syncs documents from sources (e.g. GitLab) into the AI's knowledge. |
| **hfcli / repomix / openwiki** | 2 | Helpers (download models; pack a repo for the AI; generate a doc wiki from a repo). |

### How to set up a machine (same steps for either)

1. **Install Ubuntu 24.04** with the standard encrypted-disk installer. **Name it `dev-ai1` or `dev-ai2`**: the name decides its job.
2. **Run the build** (needs internet):
   ```bash
   curl -fsSL https://git.asplab.com/ASPLAB/ubuntu-stig-build/raw/branch/main/bootstrap.sh | PROFILE=ai bash
   ```
   Hardens the box, installs Docker + the GPU stack, drops the AI stack into **`/opt/it/docker`**. Auto-grows the disk and builds the helper images.
3. **(Optional) per-machine settings** go in `/opt/it/site.yml` (the build drops an editable template there; legacy `/etc/stig-build/site.yml` still works). Exceptions only (different hostname, existing DB password, oikb secrets). A correctly-named box usually needs nothing.
4. **Download the model + start the stack.** Add to that machine's `site.yml`:
   ```yaml
   ai_model_fetch: true      # download the model (~200 GB, one time)
   ai_compose_deploy: true   # start the containers
   ```
   Re-run the build. (By hand: `sudo it-ai up`.)
5. **Connect the chat UI to the model** (System 1, one time): Open WebUI → **Admin → Settings → Connections** → add an OpenAI connection: URL `http://chat-llm:8000/v1`, key `sk-noauth`. `chat-llm` always points at the running model, so switching needs no UI change.

### Where to go

| Thing | Address |
|-------|---------|
| Chat (Open WebUI) | `http://dev-ai1:3000` |
| Monitoring (Grafana) | `http://dev-ai2:3001` |
| Compose-stack manager (Dockge) | `http://‹host›:9001` (each box) |
| Server console (Cockpit) | `https://‹host›:9090` (each box) |

### Handy commands (run on the machine)

```bash
# Admin status/health scripts (self-elevate with sudo; in /opt/it/scripts):
it-status                              # everything at a glance (host/docker/models/luks)
it-docker                              # container health
it-models                             # model volumes + service endpoints
it-restart                             # restart ALL AI-stack containers (docker compose restart)
it-restart --up                        #   ...as `up -d` instead, to apply .env / compose edits
it-restart oikb                        #   ...restart just one service
it-ai up | down | stop | status | logs <stack>   # control the AI stacks from anywhere (wraps docker compose)
it-ai up open-webui                    # ...or just one stack
it-ai model gpt-oss | granite | status # System 1: swap the chat model (separate vllm stacks)
it-ai run hfcli hf download <repo> --local-dir /granite-embed   # run a one-off `tools` utility (auto --rm)
it-ai run openwiki openwiki <args>     #   ...generate a doc wiki; `it-ai tools` lists the utilities
it-set-ip                              # renumber when the box leaves the lab (interactive)
it-set-ip --peer 10.0.5.20             #   ...just repoint the cross-node/peer IP + firewall + containers
it-set-ip --self 10.0.5.11/24 --gateway 10.0.5.1 --dns 10.0.5.2   # ...this box's own static IP (netplan)
it-model-export /mnt/usb [--images]    # AIR-GAP gather (online box): models+encodings (+images) -> USB
it-model-import /mnt/usb [--images]    # AIR-GAP install (fielded box): USB -> external volumes
it-stack-diff                          # what the engineers changed in /opt/stacks vs the repo baseline
it-stack-diff --out /tmp/stacks.txt    #   ...also write it to a file to send back

# The AI stack is split into one Dockge stack per service under /opt/stacks/<stack>/:
it-ai status                           # what's running / healthy across all stacks
it-ai up                               # start every default stack (right order)
it-ai restart open-webui               # restart one stack
sudo docker logs -f vllm-server        # watch the model start up
it-ai run hfcli hf download <repo> --local-dir /llm/<name>   # download an extra model on demand
```

**Grafana dashboard.** A pre-provisioned **"Open WebUI (OTel)"** dashboard ships in the LGTM stack (request rate by route/status, latency p50/p95/p99, 5xx errors, and the Open WebUI log stream). Open `http://dev-ai2:3001` (first login `admin`/`admin`, then set a password) → **Dashboards → Open WebUI (OTel)**. Panels fill in once Open WebUI serves traffic; if a panel is empty, generate a chat message and wait ~15 s (metric export interval).

### Admin scripts (`it-*`)

The `it_scripts` + `inventory_report` roles install short admin commands into `/usr/local/sbin`; the `it_scripts` ones live in `/opt/it/scripts` and are symlinked, while `it-inventory` is installed directly. Each **self-elevates with `sudo`**, so you can run them as a normal admin. Run `it-status` for the at-a-glance rollup; the rest are focused.

The rows marked **ai only** are the AI-stack tooling. They are placed on the `ai` profile alone, and **actively removed** on every other profile — so a `development` or `emi` box that received them from an older build loses them on the next pull. Override with `it_scripts_ai_enabled: true` in `site.yml` if a dev box genuinely needs them.

| Command | Script | What it does |
|---|---|---|
| `it-status` | `status.sh` | Runs all the checks below in one rollup (host, LUKS, plus docker/models on an AI node). |
| `it-host` | `status-host.sh` | Host state: hostname, FIPS, Secure Boot, kernel, uptime, disk. |
| `it-docker` | `status-docker.sh` | `docker compose ps` across the per-service AI stacks (`/opt/stacks/<stack>/`) + flags any container not up/healthy. *(ai only)* |
| `it-models` | `status-models.sh` | Model volumes (populated?) + probes the local vLLM/Docling/Tika endpoints. *(ai only)* |
| `it-luks` | `status-luks.sh` | LUKS/TPM auto-unlock status (binding, clevis-in-initramfs, Secure Boot) with a verdict. |
| `it-luks-rebind` | `luks-rebind.sh` | Re-seals the TPM2 keyslot to the **current** PCR 7 when the box prompts for the passphrase despite a stale binding. Binds a fresh slot before removing the old one (no lockout). |
| `it-restart` | `restart-docker.sh` | Restart the AI stacks under `/opt/stacks/`. `--up` uses `docker compose up -d` (apply `.env`/compose edits); a **stack** name limits it to one. (Thin wrapper over `it-ai restart|up`.) *(ai only)* |
| `it-oscap` | `oscap-scan.sh` | Run the OpenSCAP DISA-STIG evaluation now; results to `/opt/ia/oscap/manual`. The weekly timer writes to `oscap/scheduled` and the build-time scan to `oscap/build` — one directory per writer, so retention never prunes another's evidence. `--content` scans DISA's own SCAP benchmark; `--no-tailoring` skips the USG tailoring file. |
| `it-usb` | `usb-guard.sh` | USBGuard device allow-list. `list` renders the devices as a **tree** — decoded USB class (hub / HID / MASS STORAGE / network), port, and each device nested under what it is plugged into — with `!` marking the classes that can act on their own (keyboards, storage, radios). `--raw` gives usbguard's own output. `enroll` is the guided whitelist; `allow`/`block` take either the device number or the `vendor:product` id, with `--all` for a pair matching several devices. **`trust <vid:pid> [serial]`** pre-authorises by id *without the device present* — needed for hardware that disconnects itself when the host does not authorise it in time (write blockers do this). Also `status`/`blocked`/`policy`/`regenerate`. |
| `it-checklist` | `checklist.sh` | Run the org Linux checklist against this box; one PASS/FAIL/N-A line per item. `--fail-only`, `--out FILE`. See [checklist.md](checklist.md). |
| `it-grub` | `grub-password.sh` | GRUB bootloader password: `status` (is it configured + will it pass the scan), `hash` (generate one to vault), `set` (apply to this box), `remove`. |
| `it-ai` | `ai-stack.sh` | One control surface for the per-service AI stacks (`/opt/stacks/<stack>/`), runnable from anywhere: `up`/`down`/`stop`/`restart`/`status`/`logs`/`pull` (all, or one `[STACK]`), `stacks` (list), `oikb` (opt-in sync), `model gpt-oss|granite|status` (System 1 chat-model switch), and `run <stack>` for the on-demand `tools` utilities (`hfcli`/`openwiki`). `it-ai tools` lists them. *(ai only)* |
| `it-set-classification` | `set-classification.sh` | Change the on-screen classification banner level (interactive menu or arg). Updates the autostart entry + `site.yml`, and restarts the banner live in each GUI session. GUI profiles. |
| `it-set-ip` | `set-ip.sh` | Renumber the node when it leaves the lab: repoints the peer/cross-node IP (`site.yml` + `.env` + `/etc/hosts` + ufw + recreates containers) and/or this box's own static IP via netplan. Interactive or `--peer` / `--self`. *(ai only)* |
| `it-model-export` | `model-export.sh` | **Air-gap gather side** (online box): `hf download` the models + tiktoken encodings (+ `--images` to `docker save` the containers) onto a USB with a manifest. Completeness-checked. *(ai only)* |
| `it-model-import` | `model-import.sh` | **Air-gap install side** (fielded box): read the USB manifest and load models/encodings straight into their external Docker volumes (+ `--images` to `docker load`). No internet/repo/helper-image needed. *(ai only)* |
| `it-stack-diff` | `stack-diff.sh` | Shows how `/opt/stacks/` on this box differs from what the repo would deploy: a unified diff per `compose.yaml`, the full file for a stack the repo does not know about, and any `compose.override.yaml`. Use it to capture on-box edits **before** the next pull overwrites them (gotcha 2). Reads no `.env` — only reports that one exists — so the output is safe to paste. `--full`, `--out FILE`, or a single stack name. *(ai only)* |
| `it-stig` | `stig-run.sh` | The whole STIG evidence cycle in one command: `status` (what is staged, what is missing, when it last ran), `run` (scan + checklist), `scan`, `checklist`, `archive` (tar the evidence set for hand-off). Wraps `it-oscap` and `it-ckl` and checks prerequisites before running anything. |
| `it-clamav` | `clamav-sigs.sh` | **Manual ClamAV signature updates** for air-gapped boxes, plus `test` (does the engine actually detect an EICAR file?) and `image-save`/`image-load` for staging the containerised scanner image. `check` (default) reports installed databases, their age, whether the digital signature verifies, whether the running daemon is actually serving what is on disk, and whether a non-admin DTA can reach the scanner socket. `install` takes the newest `*.tar.gz` from `/opt/it/clamavsigs` — validating and version-checking it **before** touching the live database, backing up, then confirming with the daemon's own reported version and an EICAR detection test. `rollback` restores the previous set. `--force` allows a same/older version, `--no-test` skips the detection test. |
| `it-goclassified` | `go-classified.sh` | **Pre-classification gate.** Runs before a box holds classified data: machine-checks Secure Boot, FIPS, the GRUB password and whether every boot entry is `--unrestricted`, LUKS, base-image accounts, whether any interactive password still dates from imaging day, radios, USBGuard, **whether antivirus actually detects**, and OpenSCAP/checklist evidence — then puts the things the OS cannot see (BIOS admin password, boot order, LUKS rotation, TPM re-seal, media removed) to the operator as attestations recorded against their name. Writes the record to `/opt/ia/goclassified/`. `--report` for machine checks only. Exit 0 only when nothing failed and nothing is left open. |
| `it-ckl` | `stig-checklist.py` | Builds a DISA STIG checklist (`.cklb` / `.ckl`) from the manual STIG XCCDF + the SCAP results + the repo's adjudications, with asset fields filled in. `--summary` lists what still needs a human. See [compliance.md](compliance.md#building-the-stig-checklist-it-ckl). |
| `it-powerstrux` | `run-powerstrux.sh` | Runs the PowerStrux LA audit (`pwsh -NoProfile -File Initiate-PowerstruxLA.ps1`), logs to `/opt/_AuditFiles/logs/`, and reports where the HTML landed. Auditors double-click **PowerStrux Audit** in the app menu instead. Runs weekly on its own — **Wednesday 03:00**, `powerstrux-audit.timer`. `status` shows the schedule, last run and next run; `schedule "<spec>"` changes it — writing both the live timer **and** `/opt/it/site.yml`, so a pull does not revert it — and `enable`/`disable` turn the weekly run off and on. `--where` prints the paths without running anything. |
| `dta-log` | `dta-transfer-log.sh` | **DTA transfer record.** Asks the approval / DTA name / transfer-type questions, auto-detects the most recent folder under `/opt/dta/incoming` or `/opt/dta/outgoing` for the operator to confirm (or takes a typed path), scans it with ClamAV, and writes a dated record plus a sha256 manifest to `/opt/dta/logs`. `list` / `show last` review past records; `--no-hash` skips the manifest on a large transfer. Runs **as the DTA**, not root, so the record names a person — hence `/usr/local/bin`, not `sbin`. Also **Data Transfer Record** in the app menu. *(profiles with a `dta` group)* |
| `it-inventory` | `it-inventory.sh` | Writes `/opt/it/inventory-<host>.txt`: service tag, BIOS, DIMM/SSD serials, MACs, GPU, LVM/LUKS layout. |

### If something's wrong (things we've already handled in the tool)

- **Disk fills up.** The build grows the root disk to the full drive automatically.
- **Model container keeps restarting.** On a FIPS machine the model container gets a compatibility file (`fips_off`) so its encryption works. Automatic. The *host* stays FIPS-compliant.
- **Model loads but chat shows no model.** Tokenizer files (encodings) download automatically with the model; and add the Open WebUI connection (step 5).

> Admin detail is below: [Baking in the AI stack](#baking-in-the-ai-stack-ai_compose), [Gathering the models](#gathering-the-models-automated--hfcli), [FIPS + inference containers](#fips--inference-containers-poam).

## What it does, in order

> **Profiles + USG.** Three profiles: `development` (default), `ai`, and `baseline` (old names `desktop`/`server` still alias the first two). **All harden with Canonical's USG** (`usg fix disa_stig`), not the ansible-lockdown role. See [Ubuntu Pro Server (USG + AI stack)](#ubuntu-pro-server-usg--ai-stack) and [Remote desktop](#remote-desktop-development-profile-gnome-over-rdp). Steps below describe the legacy `development` pipeline (ansible-lockdown + OpenSCAP); the hardening/scan steps (3, 4) are superseded by `usg_harden` + `desktop_hardening` and `usg audit`.

> **`emi` profile — local-GUI imaging/field workstation (two variants).** Runs the `development` app set + `dev_tools` **minus RDP** (local desktop only), plus `base_packages/tasks/emi.yml` extras (`openvpn`, `nmap`, `arp-scan`, IBus CJK input methods), the shared provisioning (accounts/USB→`dta`, `/opt/ia`+`/opt/it`, Cockpit), USG + `usg_remediate`, wallpaper + classification banner, `emi_firewall` (opens DHCP `67/udp`, TFTP `69/udp`, DNS `53`, OpenVPN `1194/udp` after USG), and `peripheral_lockdown` (blacklists the camera modules + mutes the mic; `emi_disable_camera`/`emi_disable_mic`, and `emi_disable_all_audio` to kill speakers too). Two variants via **`emi_classified`**: `PROFILE=emi` (classified-capable → FIPS + LUKS/TPM on, full `usg fix`) vs `PROFILE=emi-unclass` (unclassified-only → FIPS/LUKS off **and `usg fix` skipped** via `usg_fix_enabled: false` — USG audit + the lighter role hardening (ufw/GNOME dconf/banners) still apply). Both start at banner **UNCLASSIFIED**. **USB:** the classified `emi` gets the `dta`-group-gated removable-media policy (only `dta` members mount USB); `emi-unclass` sets `local_usb_transfer_enabled: false`, so it has **no dta gate** — USB just works for any local desktop user. The `dta` group + `*_dta` accounts aren't created on that box, and `local_accounts` **actively removes** them (plus the USB polkit/udev rule files) if the box was rebuilt/repurposed from a classified image that had them. The imaging daemons (TFTP/DHCP/dnsmasq/OpenVPN) install **disabled** — the firewall port is open, but nothing listens until you configure + enable the service. LUKS still requires selecting full-disk encryption at the Ubuntu install (the tool binds TPM, it doesn't create the LUKS volume). Switch classification later with `classification_banner_level` in `/opt/it/site.yml`.

> **`baseline` profile — harden an already-built box.** For a box where **all software is already installed** and you only need org provisioning + STIG (a hand-built Ubuntu **Desktop** endpoint logged into locally). It runs `local_accounts` (users/groups/ACL'd folders + the USB→`dta` carve-out), `managed_dirs` (`/opt/ia` + `/opt/it`), `cockpit`, `usg_harden` + `usg_remediate`, the **GUI-preserving** parts of `desktop_hardening` (graphical target, GDM DCSA banner, GNOME dconf hardening, and re-enabling `usb-storage` after USG), `desktop_branding` (the DoD SHB wallpaper + lock screen), and `classification_banner` (the docked top/bottom classification bars) — but installs **no** app set (`base_packages` ensures only the common `cifs-utils`/`net-tools`), **no** RDP/xrdp, and does **not** resize the root LV. (The classification banner **does** force the login session to **Xorg** — the docked bars require it — so a baseline desktop with the banner enabled runs Xorg rather than Wayland.) Run it with `sudo PROFILE=baseline bash` on `bootstrap.sh`, or `-e deployment_profile=baseline`. Still needs an Ubuntu Pro token (USG). Set each provisioned account's password with `sudo passwd <user>` after the build.

1. **base_packages.** ClamAV, Wireshark/tshark, Python3 (+pip/venv), PuTTY (GUI) and putty-tools (plink/pscp/psftp), OpenSSH client, git, OpenSCAP, editor (VS Code default; vim/neovim selectable).
2. **app_config.** Starts ClamAV daemon + freshclam updates + a weekly scan timer; restricts Wireshark capture to a `wireshark` group (STIG requirement).
3. **stig_harden.** Runs `ansible-lockdown/UBUNTU24-STIG` remediation (CAT I + II by default, CAT III off), then **SSG gap-remediation task files** (`tasks/*.yml`: audit, pam, sessions, gnome, ssh, services, filesystem, grub) that close the ComplianceAsCode `stig`-profile findings Lockdown skips under `disruption_high: false`. See *STIG gap remediation* below.
4. **scap_scan.** Runs `oscap` against the DISA STIG profile. Writes an HTML report plus a DISA-STIG-Viewer-importable XML into `/var/log/stig-scan`.

**Inventory report.** At the end of the build (both profiles) the `inventory_report` role writes `/opt/it/inventory-<host>.txt`: system/service tag, BIOS, DIMM + SSD models/serials, MAC addresses, GPU, and the LVM/LUKS layout, for cross-referencing with the imaging checklist. Re-run any time with `sudo it-inventory`; re-run after the post-build reboot for final FIPS + GPU state.

## One-time setup

Edit **`group_vars/all.yml`**:
- `wireshark_users` → local accounts that need packet capture
- `editor_choice` → `vscode` | `vim` | `neovim`
- `ubtu24stig_cat3` → `true` once low-severity controls are validated
- `stig_skip_tags` → control tags to skip on Desktop (document each as a POA&M)

Push this repo to a **public** GitHub/GitLab repo.

## Running it on the Dell (during imaging, online)

```bash
sudo apt update && sudo apt install -y ansible git curl
# Install the pinned Lockdown role from requirements.yml:
curl -fsSL https://git.asplab.com/ASPLAB/ubuntu-stig-build/raw/branch/main/requirements.yml -o /tmp/requirements.yml
sudo ansible-galaxy install -r /tmp/requirements.yml
# Run DETACHED as a systemd unit: hardening restarts GDM mid-run, which would
# kill a foreground job launched from the GUI session. systemd-run survives it:
sudo systemd-run --unit=stig-build --collect \
  ansible-pull -U https://git.asplab.com/ASPLAB/ubuntu-stig-build.git -C main -i localhost, local.yml
# Watch:  sudo journalctl -u stig-build -f      Result: systemctl status stig-build
```

Or run `bootstrap.sh` (below), which does all that. It also **prompts (hidden) for the disk encryption password** to enable TPM auto-unlock before launching the detached build (Enter to skip; auto-skips on an unencrypted or already-bound disk). See *TPM2 LUKS auto-unlock*.

## Critical gotchas

- **Desktop vs Server STIG.** DISA only publishes a *Server* 24.04 STIG. On GNOME you WILL get findings about the display manager / graphical target. `ubtu24stig_gui: true` stops the Lockdown role disabling the GUI. Triage GUI findings into documented exceptions.
- **Order is load-bearing.** Packages first, harden second, scan last. Hardening sets `noexec` on /tmp, tightens umask, and locks down PAM. Doing it before installs can break pip and apt.
- **Base OS patching is opt-in.** The build refreshes the apt cache and installs the packages it needs, but does **not** `apt full-upgrade` by default (an unattended upgrade can pull a kernel/library that conflicts with the pinned NVIDIA driver / FIPS kernel). Set **`base_packages_full_upgrade: true`** to run `apt full-upgrade` early (on the ai profile a kernel bump means re-checking `nvidia-smi` + FIPS after reboot), or patch the fresh install by hand first. Ongoing patches come via Ubuntu Pro (ESM + `canonical-livepatch`).
- **Root disk auto-grows first.** Ubuntu autoinstall often leaves a small root LV (e.g. 100G) on a large disk, which fills once the AI model volumes land under `/var/lib/docker`. The `disk_expand` role runs **first** and grows the root LV + filesystem to all free VG space (online, idempotent; no-op if not LVM / already full). Disable with `disk_autoexpand: false` (e.g. if you keep separate `/var` `/home` partitions); override `disk_root_vg`/`disk_root_lv` in `site.yml` if your names differ from `ubuntu-vg`/`ubuntu-lv`.
- **Versions are pinned.** `requirements.yml` pins `UBUNTU24-STIG` to `v1.3.0` and the SSG datastream to `0.1.81`, so every imaged box is identical. Bump deliberately and re-test.
- **Collect reports before air-gapping.** USG audit report lands in `/opt/ia/` (`*.html` + XCCDF `*.xml`); the legacy OpenSCAP `stig-viewer-*.xml` (dev scan, if run) is in `/var/log/stig-scan/`. Grab them while online.
- **High-impact controls are gated.** `ubtu24stig_disruption_high: false` makes the Lockdown role SKIP its most breaking controls (there is no `ubtu24stig_fullauto` var or interactive pause in 1.3.0). The `stig_harden/tasks/*.yml` gap files remediate the SSG findings those skips leave behind; flip `disruption_high: true` only after a clean, validated pass.
- **Re-scan after air-gapping.** `oscap` works offline (drop `--fetch-remote-resources`). Keep the SSG datastream on the box for periodic re-checks.

## STIG gap remediation (SSG scan findings)

The box is hardened by `ansible-lockdown/UBUNTU24-STIG`, but the **scan grades it with the SSG / ComplianceAsCode `stig` profile**, a different project whose rules don't map 1:1 to the Lockdown role. With `disruption_high: false` and `cat3: false`, a large set of SSG rules fail out of the box. `stig_harden` includes **idempotent, desktop-safe, SSG-rule-targeted** task files (`roles/stig_harden/tasks/*.yml`) that run after the Lockdown role and close those gaps:

| File | Closes (SSG rule families) |
|------|----------------------------|
| `audit.yml` | auditd syscall/watch rules (DAC, file-deletion, unsuccessful-access, kernel-modules, privileged-cmds, sudoers.d/journal/cron), data-retention actions, dispatcher plugins, rules.d perms |
| `pam.yml` | faillock lockout (deny/interval/unlock/audit/silent), faildelay, password-hashing rounds, no-empty-password |
| `sessions.yml` | concurrent-login cap, interactive (`TMOUT`) session timeout |
| `gnome.yml` | screensaver idle/lock/blank, automount off, Ctrl-Alt-Del off, smartcard-removal lock, GDM login-banner enable (all dconf-locked) |
| `ssh.yml` | `X11Forwarding no`, `PubkeyAuthentication yes`, SSH `/etc/issue.net` banner |
| `services.yml` | chrony (NTP) + remove timesyncd, ufw enable + rate-limit, AIDE init + daily check, rsyslog remote-access monitoring |
| `filesystem.yml` | `/lib*` group-owner root, `/var/log` + journal perms, `journalctl` perms, `kernel.dmesg_restrict`, RTC=UTC |
| `grub.yml` | GRUB2 bootloader password (BIOS + UEFI); **self-guarded, see below** |

All tunables (lockout counts, timeouts, retention, firewall ports, GRUB superuser/hash) live in the **`STIG GAP-REMEDIATION TUNABLES`** section of `group_vars/all.yml`. These files also need the `community.general` collection (pinned in `requirements.yml`).

### Required: set the GRUB bootloader password

`grub.yml` ships a `CHANGEME` placeholder and **self-skips** until you supply a real hash, so a forgotten hash can't brick boot (the two GRUB rules just stay failing). To activate:

```bash
grub-mkpasswd-pbkdf2          # type the GRUB password twice; copy the grub.pbkdf2.sha512... token
ansible-vault encrypt_string 'grub.pbkdf2.sha512.10000.<salt>.<hash>' --name 'grub_password_pbkdf2'
```

- Paste the resulting `!vault` block over `grub_password_pbkdf2` in `group_vars/all.yml`.
- Keep `grub_superuser` to letters/underscores only (the SSG regex rejects digits/hyphens).
- Normal boot stays **password-free** (menuentries generated `--unrestricted`); the credential is required only to *edit* an entry or use the GRUB shell.
- **Test the hash on a throwaway VM before baking a gold image.** Recovery from a bad hash means a GRUB edit from install media.

### Validate PAM on a snapshot first

`pam.yml` edits `common-auth`/`common-account`. It keeps `pam_unix`, never sets `even_deny_root`, and defaults `unlock_time=0` (admin-unlock), so failures are recoverable. But **mis-ordered PAM can lock everyone out**.

On first apply:
- Keep a root shell open, confirm login works.
- Fail 3 logins to confirm lockout, then `sudo faillock --user <name> --reset` to recover.
- The VM snapshot is the real safety net.

The faillock pamd anchors assume a stock 24.04 `common-auth`; re-verify if `pam-auth-update` ran with extra profiles.

### POA&M: findings NOT auto-remediated by the build

These need a secret, a subscription, install-time action, or an environment this image doesn't have. Document each as a POA&M:

- **Disk encryption (`Encrypt Partitions`).** LUKS happens in the installer, before ansible-pull runs. See *Full-disk encryption at install time* below.
- **FIPS mode (`/proc/sys/crypto/fips_enabled`):** **ENABLED** (`usg_enable_fips: true`). `usg_harden` runs `pro enable fips-updates` (installs the FIPS kernel/modules) and flags a reboot; the `is_fips_mode_enabled` check passes **only after that reboot**. Swaps the running kernel. Set `usg_enable_fips: false` to defer it (then it's a POA&M).
- **ClamAV does not work on a FIPS host — OPEN FINDING, no fix available.** ClamAV fingerprints file content with MD5, which is not FIPS-approved, so OpenSSL refuses the digest: MD5-based signatures cannot be evaluated and **the EICAR test file is not detected**, while the scan still exits 0 and reports every file clean (confirmed on ASP-2, 2026-08-26). This is upstream [Cisco-Talos/clamav#1786](https://github.com/Cisco-Talos/clamav/issues/1786), open with no fix. **It cannot be configured around:** Ubuntu's FIPS OpenSSL takes FIPS mode from the kernel flag rather than from config, so even `OPENSSL_CONF=/dev/null` fails on the box, and the reporter of #1786 found `--fips-limits` / `FIPSCryptoHashLimits` do not help either. The `clamav_fips` role attempts the OpenSSL carve-out on every pull and removes it again when it does not work, so it costs nothing and self-heals if this is ever fixed upstream. **The working fix is `clamav_container`**, which moves clamd into a container whose OpenSSL is a stock build while the host kernel stays in FIPS — see *The fix: a containerised engine* above. Two residual items belong on the POA&M with it: **on-access scanning is lost** (the containerised engine is on-demand only), and the scanning engine is **not a FIPS-validated cryptographic module** — which is the point, since the hashing in question is malware fingerprinting rather than a control protecting data. Check per box with `sudo it-clamav test`; a box where that does not PASS has no working antivirus regardless of what any scan reports.
- **Smartcard / CAC + SSSD** (opensc, pam_pkcs11, SSSD enable / cert-mapping / OCSP / cache, "Enable Smart Card Logins in PAM"). This image is **password-login only** by decision. The one harmless smartcard-adjacent control (GNOME *lock-on-smartcard-removal*) IS set.

  The DISA rule *Enable Smart Card Logins in PAM* (`smartcard_pam_enabled`) would wire `pam_pkcs11.so` into the auth stack, which on a box with **no CAC reader/card** logs `ERROR:pam_pkcs11.c:365: no suitable token available` / `Error 2308: No smart card found` on **every login, sudo, and screen-unlock**. To avoid that, `usg_harden` auto-generates a USG tailoring file (`usg generate-tailoring`, written to `/etc/usg/managed-tailoring.xml`) and **de-selects** those rules before `usg fix`, so `pam_pkcs11` is never wired in and the audit won't flag it. Controlled by `usg_disable_smartcard` (default **true**) and `usg_disable_smartcard_rules` in `group_vars/all.yml`; set the toggle `false` (or supply your own `usg_tailoring_file`) once you deploy CAC readers + certs and want CAC login.

  > **Already-hardened boxes self-heal.** The tailoring opt-out only affects a *fresh* `usg fix`, but the **`usg_remediate`** role (runs every ansible-pull, both profiles) also **strips `pam_pkcs11` back out** of the PAM stack: it comments out any active `pam_pkcs11.so` auth line under `/etc/pam.d/` (never touching `pam_unix`, so password login can't be lost). A box hardened before the opt-out existed is fixed on its next pull, no manual step. Toggle with `usg_cleanup_pam_pkcs11` (defaults to follow `usg_disable_smartcard`). By hand, keep a second root session open and:
  > ```bash
  > sudo grep -rn pkcs11 /etc/pam.d/ /usr/share/pam-configs/
  > sudo sed -ri.bak 's/^(auth.*pam_pkcs11\.so.*)/# \1/' /etc/pam.d/common-auth
  > sudo -k; sudo true    # verify password auth still works, no pkcs11 error
  > ```

### Residual findings auto-remediated by `usg_remediate`

`usg fix` is stamped run-once and its in-role `usg audit` is a **mid-build snapshot** (taken before the firewall roles bring ufw up), so the report shows findings open that are transient or that `usg fix` doesn't remediate. The **`usg_remediate`** role runs *after* USG **and** the firewall roles, on **both** profiles, and closes the low-risk ones idempotently every pull (nothing here can lose password/SSH login):

| Finding (SSG rule) | What `usg_remediate` does |
| --- | --- |
| Smart Card Logins in PAM (`smartcard_pam_enabled`) | comments out any active `pam_pkcs11.so` line (see above) |
| `/var/log` file perms (`file_permissions_var_log_stig`, UBTU-24-700010) | `find` over-permissive files, strip `u-xs,g-xws,o-xwrt` (mirrors DISA remediation) |
| `/var/log/audit` mode (`directory_permissions_var_log_audit`) | `chmod 0750 /var/log/audit` |
| Remote time server (`chronyd_specify_remote_server`, `chronyd_server_directive`) | write `server <host> iburst` into `/etc/chrony/sources.d/stig.sources`, ensure `sourcedir`, comment out any `pool` line, set `makestep`; set `usg_chrony_servers` to your enclave NTP |
| ufw active (`check_ufw_active`) | re-assert `ufw` enabled |
| Reboot/shutdown auditing (not a USG rule) | drop `/etc/audit/rules.d/71-reboot.rules` auditing the `reboot(2)`/`kexec_load(2)` syscalls (reboot/poweroff/halt/kexec), keyed `reboot`; toggle `audit_reboot_rules_enabled` |
| SSSD service + cert mapping (`service_sssd_enabled`, `sssd_enable_user_cert`) | **de-selected in the tailoring**; no central directory/CAC on this fleet (documented deviation) |

After remediation the role **re-runs `usg audit`** (Pro-attached boxes; `usg_remediate_reaudit`) so the report in `usg_report_dir` reflects the fully-built box, not the mid-build snapshot. Re-run manually with `sudo usg audit --tailoring-file /etc/usg/managed-tailoring.xml`.

> **`ufw` rate-limit (`ufw_rate_limit`, UBTU-24-600200)** stays a **documented deviation on the `ai` profile**: the STIG check wants *every* listening port rate-limited, but rate-limiting the Open WebUI / vLLM / Docling ports would throttle legitimate inference traffic. Only the **management** ports (SSH, RDP, Cockpit, Dockge) are `ufw limit`ed; the AI service ports are plain `allow`. On `development` everything exposed is limited, so the rule passes there.
- **GUI login-banner TEXT (`Set the GNOME3 Login Warning Banner Text`).** The SSG OVAL pattern-matches the configured text against the **DoD Standard Mandatory Notice**; this image displays the **DCSA Authorized Warning Banner** by requirement, so the text rule stays failing as an **approved deviation**. (`banner-message-enable` passes.)
- **Last-logon PAM notification.** `pam_lastlog` was removed in 24.04 and `pam_lastlog2` is not in `noble` main; `pam.yml` wires it only if present, else POA&M (or backport `libpam-lastlog2` into your mirror).
- **Audit log offload** (`...Send Logs To Remote Server`, `Offload audit Logs to External Media`). Set `stig_audit_remote_server` to a collector to enable au-remote; external-media offload is operational.
- **GRUB password.** Failing until you complete the vault step above.
- **TFTP / DHCP / DNS** provisioning services: installed-but-disabled mission-need exceptions (pre-existing).
- **Blank screensaver overridden** (`Implement Blank Screensaver`). By requirement the lock screen shows the org wallpaper (`desktop_branding` role) instead of blank, so `org.gnome.desktop.screensaver picture-uri` is non-empty. Approved deviation; the lock *timing* (idle-delay, lock-enabled, lock-delay) is still STIG-enforced.
- **USB storage re-enabled and restricted to the `dta` group** (not blanket-disabled). Deliberate, more granular than the STIG's "disable USB mass storage." The lockdown role blacklists the `usb-storage` kernel module (`/etc/modprobe.d/usb-storage.conf`), which `stig_harden` then **strips** (when `usb_storage_enabled: true`, the default) so USB works for the data-transfer agents; the `dta` udev + polkit policy governs who may mount. If your benchmark strictly requires USB *disabled*, set `usb_storage_enabled: false` and document the `dta` allowance as the exception only where you enable it.
- **TPM-only LUKS auto-unlock (opt-in, `tpm_luks_enabled`).** When enabled, the disk auto-decrypts via the TPM with no boot secret (PCR 7 / Secure Boot). A deliberate data-at-rest deviation for operational need, mitigated only by Secure Boot; the install passphrase is retained as a recovery keyslot. See *TPM2 LUKS auto-unlock* below.

### Full-disk encryption at install time (autoinstall)

`Encrypt Partitions` can't be done post-install. Bake LUKS into the **Ubuntu autoinstall** (`user-data`) so fresh images come up encrypted. Simplest is LUKS-on-LVM via the guided layout:

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

- `password` is the **disk-unlock passphrase**, prompted at every boot. For unattended reboots on 24.04, enroll a TPM2 key after install (`systemd-cryptenroll --tpm2-device=auto /dev/<luks-part>`) or use 24.04's TPM-backed FDE, then adjust prompting per policy.
- Vault the passphrase; never commit it in cleartext.
- This is install-media config, **separate from this ansible-pull repo**. Keep it with your autoinstall seed.

## Local accounts, access groups & branding

The `local_accounts` role provisions the standing users/groups, group-shared folders, and the USB access policy; `desktop_branding` sets the wallpaper. Driven from `group_vars/all.yml` (`local_groups`, `local_users`, `local_shared_dirs`, `usb_access_group`, `branding_*`).

> **Runs on BOTH profiles** (`local_accounts_enabled: true`, default) so org groups/accounts are consistent fleet-wide.
>
> - On the **ai** profile the groups, accounts, and ACL'd shared folders all work, but the dta USB *mount* carve-out is **inert**: USG blacklists `usb-storage` on a server and nothing re-enables it there (the `development` profile's `desktop_hardening` does). For USB-for-dta on an ai box, add the re-enable to the ai path.
> - Set `local_accounts_enabled: false` to skip the role on a box.

**Accounts are created LOCKED.** Each exists but cannot log in until you set a password **per-machine at deploy** (a locked account is not an empty password, so STIG stays satisfied):

```bash
sudo passwd overlord
sudo passwd austin_case_dta
# ... one per account, on the fielded box (not baked into the gold image)
```

**Automation account: `auto_audit`.** Created on **every profile except `emi-unclass`** (which carries no audit tooling), in the `audit` and `sudo` groups, for the scheduled audit/compliance jobs. `crontab` is available everywhere — the `cron` package is in `base_common_packages`. Governed by `local_auto_audit_enabled` / `local_automation_users` in `group_vars`; on an `emi-unclass` box the role also **removes** it, so a machine repurposed from a classified image ends up clean.

> **`auto_audit` cannot use `sudo` until you give it a credential.** Like every account here it is created **locked**, and `sudo` group membership still requires the user's own password — so an unattended cron job running as `auto_audit` will fail at the `sudo` prompt. Pick one deliberately:
> - **Run the job as root** (`/etc/cron.d` or root's crontab) and drop `auto_audit` from `sudo`. Least privilege, no new credential, and usually what a scheduled audit actually needs.
> - **Set a password** (`sudo passwd auto_audit`) if a human ever runs it interactively. Does not help unattended jobs.
> - **Add a scoped `NOPASSWD` sudoers rule** for the specific audit commands. This works unattended but is a STIG finding (`sudo` must re-authenticate) and needs documenting as a POA&M — do not do it fleet-wide or for `ALL`.

Supplementary groups are **declarative**: a re-run re-asserts exactly the `groups:` list for each user (a manually-added group gets removed on the next `ansible-pull`). `sudo`-group membership grants full sudo. The `audit` group is for `/opt/_AuditFiles` access; sudo is granted to the named auditor accounts individually (their `groups:` include `sudo`), **not** to the whole `audit` group; change `local_users` for group-wide sudo.

**Base-box default accounts are purged.** The role removes any account listed in `purge_default_accounts` (default: `vagrant`) along with its home, insecure SSH key, and any matching `/etc/sudoers.d/` drop-in. Vagrant/Packer base images ship a `vagrant` user with a well-known password + `NOPASSWD` sudo + a publicly-published SSH key (a STIG finding); this build doesn't create it, but cleans it up if your base image had one. Removal is idempotent.

**Never add your operator account or a `local_users` name to `purge_default_accounts`.**

**Access groups & shared folders**

| Group | Grants | Shared folder |
|-------|--------|---------------|
| `dta` | USB storage access | (none) |
| `audit` | `/opt/_AuditFiles` (auditors; sudo per-account) | `/opt/_AuditFiles` → `root:audit 2770` |
| `sentry` | `/home/shared` | `/home/shared` → `root:sentry 2770` |

The folders are `setgid` **plus a POSIX default ACL** (`g:<group>:rwx`). This matters because STIG `umask 077` would otherwise make new files `0600` and break group sharing; the default ACL bypasses the umask so group members get full access to everything created inside, and others are denied. Needs the `acl` package (installed by the role).

**USB storage → `dta` only.** Out of the box USB was *not* restricted (the STIG work only disabled auto-mounting). This role adds two layers:
- a **polkit rule** (`/etc/polkit-1/rules.d/49-dta-usb.rules`) allowing udisks2 mount/unmount/eject only for `dta` members (the Files / `udisksctl` desktop path);
- a **udev rule** (`/etc/udev/rules.d/99-dta-usb.rules`) setting raw USB block devices to `root:dta 0660` (the manual `mount`/`dd` path).

Non-`dta` users (including admins) can't mount USB storage via the desktop; `sudo mount` as root remains a break-glass path. To change the gated group, edit `usb_access_group`.

**Wallpaper.** `desktop_branding` deploys `roles/desktop_branding/files/SHB_Background.jpg` to `/usr/share/backgrounds/` and sets it **system-wide and locked** (users can't change it) on the **desktop background** and the **session lock screen**. The lock-screen part overrides the STIG blank-screensaver control (see POA&M above).

- The **GDM login screen** is best-effort only: Ubuntu's greeter usually renders its themed background and ignores the dconf key; a guaranteed login JPG needs a fragile `gnome-shell` gresource patch that is intentionally not done.
- Flip `branding_lockscreen_wallpaper: false` to brand only the desktop and keep the STIG blank lock screen.

## TPM2 LUKS auto-unlock (on by default; passphrase supplied out-of-band)

`tpm_luks_unlock` binds a keyslot of the install-time LUKS volume to the machine's **TPM2** so the disk unlocks at boot with **no passphrase**. It uses `clevis`, the path Ubuntu 24.04's stock initramfs auto-unlocks reliably (`systemd-cryptenroll`'s `tpm2-device=` is *not* honoured by Ubuntu's default initramfs).

It is **`tpm_luks_enabled: true` by default**, but only binds once it can read the install passphrase, and that passphrase is **never stored in this public repo**.

**Supply the passphrase out-of-band.** The role reads it from a root-only (`0600`) file, `luks_passphrase_file` (default `/etc/luks/initial-passphrase`). Your **private autoinstall seed** writes that file during install. It already has the passphrase (it sets `storage.layout.password`), so no new secret location is introduced and nothing lands in git:
```yaml
# in your autoinstall user-data (PRIVATE install media, NOT this repo):
late-commands:
  - install -d -m 700 /target/etc/luks
  - printf '%s' 'YOUR-INSTALL-PASSPHRASE' > /target/etc/luks/initial-passphrase
  - chmod 600 /target/etc/luks/initial-passphrase
```
- The role consumes it once to authorize the TPM keyslot (never needed at boot afterwards), then **deletes the file** by default (`luks_passphrase_purge_after_bind: true`), so the per-box passphrase doesn't linger on the auto-unlocking disk. Re-drop it only to re-bind.
- Each box uses its **own** passphrase (the seed writes that box's value), so a stolen booted box can only leak its own.
- For a **private/offline** repo only, you may instead set an inline/vaulted `luks_passphrase`. **Never** paste a secret into a public repo; the encrypted blob is permanent in git history.
- The build won't fail without the passphrase; it skips the bind (and says so) until the file is present.

The role installs clevis, binds a **new** keyslot to **PCR 7** (Secure Boot state, stable across *signed* kernel updates), and rebuilds the initramfs. Your **original passphrase keyslot is kept as recovery** and never removed.

**Read before enabling fleet-wide:**
- **Per physical machine.** The keyslot is sealed to *that* box's TPM; it can't be baked into a cloned gold image; the role must run on each machine (the per-machine ansible-pull does).
- **Secure Boot must be ON** or PCR 7 is meaningless (the role warns if off). TPM-only / no-PIN is a deliberate data-at-rest deviation: a stolen powered-off disk auto-decrypts on its own hardware.
- **Test on one box first.** TPM/PCR behaviour is hardware-specific, and the non-interactive bind (passphrase via stdin) should be confirmed once before fleet rollout. Manual equivalent: `sudo apt install -y clevis clevis-luks clevis-initramfs clevis-tpm2 tpm2-tools` (**`clevis-tpm2` is a SEPARATE package on Ubuntu 24.04**, without it the bind errors *"tpm2 is not a valid pin"*), then `sudo clevis luks bind -d /dev/<part> tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'` and `sudo update-initramfs -u -k all`.
- **Recovery:** a firmware/Secure-Boot/shim update that changes the PCRs makes boot fall back to the passphrase prompt (not a brick). Re-bind with `clevis luks unbind` + `clevis luks bind` if needed.

### Rotating the LUKS passphrase

The disk passphrase lives in a LUKS **keyslot** and can change any time **without re-encrypting** the disk. It is **independent of the TPM keyslot**: changing it doesn't disturb auto-unlock, and the box keeps booting via the TPM.

```bash
sudo blkid -t TYPE=crypto_LUKS -o device       # find the LUKS partition, e.g. /dev/sda3 or /dev/nvme0n1p3
sudo cryptsetup luksChangeKey /dev/<part>       # prompts: current passphrase, then the new one twice
# inspect / manage slots:
sudo cryptsetup luksDump   /dev/<part>          # shows used slots (your passphrase + the clevis/TPM slot)
sudo cryptsetup luksAddKey /dev/<part>          # ADD another passphrase (authorize with an existing one)
sudo cryptsetup luksKillSlot /dev/<part> <N>    # remove an old slot by number
```
`cryptsetup` operates on the **LUKS partition** (the bottom layer), not the LVM volumes inside it. No reboot needed; it applies to future unlocks immediately.

**Keep the vaulted value in sync.** `luks_passphrase` (group_vars) is used **only once**, to authorize the initial `clevis luks bind`; the role skips it on a box that's already bound, so rotating the passphrase won't break an already-unlocking machine. But re-vault it so a **fresh image** or a **re-bind** (after a PCR/firmware change) still authorizes:
```bash
ansible-vault encrypt_string '<new-passphrase>' --name 'luks_passphrase'
```
Update the autoinstall seed too if you bake the passphrase there.

**Don't kill your only passphrase slot** and rely solely on the TPM: a firmware/Secure-Boot/shim change alters the PCRs and you'd need a passphrase to get back in. The TPM bind keeps your passphrase as recovery. If you've forgotten the passphrase but the box still auto-unlocks via the TPM, a new one can be added from the running (unlocked) system, a more involved procedure; ask before attempting.

## Remote desktop (development profile, GNOME over RDP)

The `development` profile installs a GNOME desktop and **xrdp** (via the `remote_desktop` role) so the box can run on headless server hardware that users reach over RDP. Driven from the **`REMOTE DESKTOP`** block in `group_vars/all.yml`.

> **Hardening interaction.** `development` is hardened by **USG** (`usg fix disa_stig`, needs an Ubuntu Pro token, same as `ai`). USG's DISA profile targets Ubuntu Server, so the `desktop_hardening` role runs **after** USG to re-assert the graphical target, GDM, xrdp, Wayland-off, and the SSH+RDP ufw openings, then applies the GNOME/GDM banner + dconf locks + USB carve-out.
>
> **Validate on a throwaway VM first.** After `usg fix` + reboot, confirm RDP still connects and lands in a GNOME session. If USG disabled something, the fix belongs in `desktop_hardening` (re-assert it there).

**Connecting.** Point any RDP client (Windows `mstsc`, Remmina, FreeRDP) at `‹host›:3389`. The session is TLS-secured; accept the self-signed cert on first connect (or set `rdp_tls_cert` / `rdp_tls_key` to a trusted pair). Log in as a **local account**: accounts ship locked, so set a password first (`sudo passwd <user>`). RDP auth goes through PAM, so the STIG faillock lockout applies (3 bad tries → locked; `sudo faillock --user <name> --reset` to recover).

**What the role does (and the 24.04 gotchas it handles):**
- Installs `{{ dev_gnome_package }}` (default `ubuntu-desktop-minimal`) + `gdm3`, sets the default boot target to graphical.
- Installs `xrdp` + `xorgxrdp`, and **disables Wayland** (`WaylandEnable=false` in `/etc/gdm3/custom.conf`). Wayland can't be driven by xrdp and yields a black screen.
- Adds the `xrdp` user to **`ssl-cert`** so it can read the TLS key, and points `xrdp.ini` at the snakeoil cert with `security_layer=tls`, `crypt_level=high`.
- Drops a **polkit rule** (`/etc/polkit-1/rules.d/02-allow-colord-packagekit.rules`) so the colord "authentication required" prompt and repo-refresh prompt don't block/crash the session.
- **Rate-limits RDP** on ufw (`ufw limit 3389/tcp`); the rule is added here and enforced once `stig_harden` enables ufw (default-deny inbound).

**Security notes / POA&M.** RDP (3389) is an inbound remote-access service and a STIG-relevant exposure. It's TLS-wrapped, rate-limited, and PAM/faillock-gated, but for a real deployment prefer **tunnelling RDP over SSH** or restricting the ufw rule to source subnets, and consider setting `dev_rdp_allowed_group` to gate RDP to a named group. Set `dev_rdp_enabled: false` to omit xrdp entirely (GUI stays, reachable only at the physical console).

**Troubleshooting a black screen / instant disconnect:**
- Confirm Wayland is off: `grep WaylandEnable /etc/gdm3/custom.conf` → `false`; reboot after a change.
- Confirm xrdp can read the key: `id xrdp` includes `ssl-cert`; `sudo systemctl status xrdp`.
- Don't be logged into the same account on the physical console (tty) at the same time; GDM's console session holds D-Bus names the RDP session needs.
- Logs: `sudo journalctl -u xrdp -u xrdp-sesman` and `~/.xorgxrdp.*.log`.

## Ubuntu Pro Server (USG + AI stack)

The `ai` profile (`deployment_profile: ai`, or `PROFILE=ai` to `bootstrap.sh`) builds a headless Ubuntu Pro AI box. Role order: `base_packages` (lean) → `ai_stack` → `usg_harden` → optional `tpm_luks_unlock`. Same rule as development: **install online, harden last.**

### Running it on the server (online)

```bash
# All tools, GPU, hardening. Prompts (hidden) for the Ubuntu Pro token:
curl -fsSL https://git.asplab.com/ASPLAB/ubuntu-stig-build/raw/branch/main/bootstrap.sh \
  | sudo PROFILE=ai bash

# Env-var options (piped bash can't take flags):
#   PRO_TOKEN=<tok>   supply the Pro token non-interactively (else you're prompted)
#   HARDEN=0          host prep + `usg audit` only, SKIP the disruptive `usg fix`
```

> **Ansible does host prep only.** The AI tools ship as your own prebuilt images + compose files; Ansible installs Docker + NVIDIA, hardens with USG, and opens the container ports; it does not manage the containers. There is no `TOOLS`/`HF_TOKEN` anymore.

Watch: `sudo journalctl -u stig-build -f`. The `usg audit` report (HTML + XCCDF) auto-copies to **`/opt/ia/`** (admin-readable; `usg_remediate` re-runs the audit at the end so it reflects the fully-built box). **Reboot** afterwards to apply USG controls and load the NVIDIA driver, then re-run `sudo usg audit --tailoring-file /etc/usg/managed-tailoring.xml` for accurate post-reboot numbers.

### USG hardening

- **Pro token (secret).** Never in the repo. `bootstrap.sh` writes it to `/etc/ubuntu-advantage/pro-token` (0600); the `usg_harden` role reads it out-of-band, `pro attach`es, `pro enable usg`, `apt install usg`. Not attachable → USG **self-skips** (POA&M), build still succeeds.
- **Admin password backstop.** `usg fix disa_stig` (and the DISA profile) lock out password-less admins. The role verifies a `sudo`/`admin` account has a hashed password in `/etc/shadow` before running the fix; if none, it **skips the fix** and warns. Set one with `sudo passwd <admin>` and re-run.
- **Run-once.** The fix is stamped at `/var/lib/usg-harden/applied-profile`, so re-running the build doesn't re-apply it. Force a re-fix with `-e usg_force_fix=true`.
- **FIPS.** **On** (`usg_enable_fips: true`). The role runs `pro enable fips-updates` (swaps to the FIPS kernel) and flags a reboot; `is_fips_mode_enabled` passes only **after** that reboot. Validate on a throwaway box if you run unusual crypto/dev tooling; set `usg_enable_fips: false` to defer (POA&M).
- **Manual audit any time:** `sudo usg audit --tailoring-file /etc/usg/managed-tailoring.xml` (USG writes results under `/var/lib/usg/`; the build copies them to `/opt/ia/`). To customize/relax rules further, generate your own tailoring file (`usg generate-tailoring …`) and point `usg_tailoring_file` at it.
- **Report drop `/opt/ia`.** The audit report auto-copies to `/opt/ia/` (owner `root`, group `{{ ia_it_group }}`/`sudo`, `0640`), the admin-only IA collection point created by `managed_dirs`. Override with `usg_report_dir`.

### Running a USG / SCAP compliance scan & getting the report

USG (`usg audit`) *is* the SCAP scan: it runs OpenSCAP under the hood against the DISA STIG benchmark and writes standard XCCDF results plus an HTML report. Three ways to run it:

**1. Automatically (every build).** The build runs `usg audit` at the end (`usg_remediate_reaudit`) so a freshly imaged/re-pulled box always has a current report in `/opt/ia`. Nothing to do.

**2. On demand (any time, on the box).** As an admin:

```bash
# Use the SAME target the build uses (tailoring file if present, else the stock profile):
sudo usg audit --tailoring-file /etc/usg/managed-tailoring.xml    # if that file exists
sudo usg audit disa_stig                                          # otherwise, stock DISA STIG profile

# Copy the fresh results to the IA drop with the others:
sudo cp /var/lib/usg/usg-report-*.{html,xml} /opt/ia/usg/ 2>/dev/null || true
```

- **Tailoring vs. profile: pick ONE, never both** (USG errors if you pass a profile *and* a tailoring file). This build de-selects the smart-card/SSSD rules via a tailoring file, so use the tailoring form above when that file exists; `ls /etc/usg/managed-tailoring.xml` to check.
- Re-running via the tool: a normal `ansible-pull`/`bootstrap.sh` re-runs the audit through `usg_remediate` and re-drops the report; no separate step.

**3. Where to get it (`/opt/ia/` on each box):**

```bash
ls -lt /opt/ia/                       # newest report first
#   usg-report-YYYYMMDD.HHMM.html     <- human-readable, open in a browser
#   usg-report-YYYYMMDD.HHMM.xml      <- XCCDF results (import into DISA STIG Viewer / eMASS)
```

`/opt/ia` is admin-only (group `sudo`/`ia_it_group`, mode `2770`). **Collect the report while the box is still online / before air-gapping.** To read it from your workstation: `sudo cp /opt/ia/usg/usg-report-*.html ~/ && chown $USER ~/usg-report-*.html`, or pull it over your admin channel (Cockpit's file browser, `scp`).

- **Score / findings:** open the HTML for the pass/fail summary; the XCCDF `.xml` is the machine-readable evidence for the A&A package. Open findings that remain are the documented POA&Ms (see below).
- **Override the drop location** with `usg_report_dir` (e.g. back to `/var/log/stig-scan`).

### Host prep + firewall (Ansible), then bring your own compose

Ansible does **host prep only** on the ai profile; the AI containers are deployed from **your own prebuilt images + compose files**.

- **Docker + GPU (`ai_stack`):** installs docker-ce (≥29.5.2) + the compose v2 plugin + the extra plugins in `docker_extra_packages` (default `docker-model-plugin`, `docker-sbx`), and (when `gpu_enabled`) the NVIDIA driver + `nvidia-container-toolkit` with the `nvidia` runtime wired into Docker. The driver is autoselected unless you pin `nvidia_driver_package` (needed to reach the 7960 baseline **≥595.71.05**; the RTX PRO 6000 Blackwell cards want the `-open` variant, which may require NVIDIA's CUDA apt repo / the graphics-drivers PPA); the role **asserts** the active driver ≥ `nvidia_driver_min_version` after reboot. Verify: `docker --version`, `docker model version`, `docker info | grep -i runtime`, `nvidia-smi`. `ai_stack_user` is added to the `docker` group.
- **GPU + FIPS (`gpu_fips_module`, runs after `usg_harden`):** Canonical's prebuilt NVIDIA modules (`linux-modules-nvidia-<branch>-<variant>-<kernel>`) are **flavour-locked to the generic kernel**, so when `usg_enable_fips` swaps in the FIPS kernel, `nvidia.ko` is missing after the reboot and `nvidia-smi` fails ("couldn't communicate with the NVIDIA driver"). This role detects the installed NVIDIA flavour + the installed FIPS kernel and **stages the matching `linux-modules-nvidia-*-fips` module** (from the `esm.ubuntu.com/fips-updates` repo) for that kernel *before* the reboot (apt installs modules for any installed kernel ABI, not just the running one), so the single FIPS reboot brings up FIPS **and** working GPUs with no manual DKMS/driver rebuild. Prefers the flavour metapackage (`…-fips`) so future FIPS-kernel updates keep the module in step; falls back to the version-locked package. If the driver was installed via `.run`/DKMS (no prebuilt `-generic` package), it logs a POA&M note instead. Gated `is_ai` + `gpu_enabled` + `usg_enable_fips`. **Recovering a box where FIPS was enabled before this existed:** boot the `-fips` kernel, then `sudo apt-get install -y linux-modules-nvidia-<branch>-<variant>-$(uname -r)` and `sudo modprobe nvidia`.
- **Dockge (`ai_stack`, `dockge_enabled`):** a Docker-Compose-stack management web UI on `http://‹host›:9001` (opened by `ai_firewall`, rate-limited; HTTP, so use `http://`). **Create the admin account on first login.** It mounts the Docker socket (root-equivalent), so restrict its port to admins (add a `from:` entry in `ai_firewall_allow_ports`) or front it with a proxy. Dockge manages compose stacks under **`dockge_stacks_dir`** (`/opt/stacks`), bind-mounted at the same path in the container.
  - **The AI stacks show up automatically.** `ai_compose` writes each service straight into **`/opt/stacks/<stack>/compose.yaml`** (one Dockge stack per service — `vllm-gptoss`, `pgvector`, `open-webui`, …; see [ai-stack.md](ai-stack.md#compose-stacks--what-runs-and-how)), and that whole dir is bind-mounted into Dockge, so every stack is visible and individually manageable with no extra steps or symlinks. If Dockge shows a stack as `exited`/`?` while `docker ps` shows its containers `Up` (e.g. it was started outside Dockge), reconcile by opening the stack in Dockge and clicking **Stop** then **Start**; the external named volumes (models, DB, encodings) are untouched by a restart. Dockge (root, via the socket) can read each stack's `.env`, so its secrets are visible in the UI -- an accepted consequence of it being a root-equivalent admin tool.
  - Update Dockge later with `docker pull <dockge_image> && docker rm -f dockge` then re-run the play (`dockge_image` in group_vars). Set `dockge_enabled: false` to skip. (Dockge replaced Portainer; the build removes an old `portainer` container and its `9443` firewall rule on re-run.)
- **Cockpit (`cockpit` role, `cockpit_enabled`, BOTH profiles):** a web server-management console on `https://‹host›:{{ cockpit_port }}` (9090 by default), opened **rate-limited** by the firewall roles after USG. Systemd units, journald, storage, networking, updates, and a browser terminal. Log in with a local account. Privileged surface: set **`cockpit_allow_from`** to an admin CIDR to restrict it (else it's opened to any source). Change the port with `cockpit_port` (writes a `cockpit.socket` override). `cockpit_extra_packages` adds add-ons (e.g. `cockpit-pcp` for historical metrics). Set `cockpit_enabled: false` to skip.
- **Firewall (`ai_firewall`, after USG):** USG enables ufw with **default-deny inbound**, so the ports your containers publish must be opened here. Edit **`ai_firewall_allow_ports`** in `group_vars/all.yml`:

  ```yaml
  ai_firewall_allow_ports:
    - { port: 443, proto: tcp, rule: allow }                        # reverse proxy (TLS) -> Open WebUI :3000
    - { port: 80,  proto: tcp, rule: allow }                        # reverse proxy (HTTP redirect to 443)
    - { port: 8002, proto: tcp, rule: allow, from: "10.0.0.10/32" } # System 2 vLLM embeddings, from System 1 only
    - { port: 8003, proto: tcp, rule: allow, from: "10.0.0.10/32" } # System 2 vLLM vision, from System 1 only
    - { port: 5001, proto: tcp, rule: allow, from: "10.0.0.10/32" } # System 2 Docling, from System 1 only
  ```

  > **Open WebUI listens on `3000`, not 80/443.** The default opens 80/443 because Open WebUI is meant to be fronted by a **reverse proxy** (TLS termination, e.g. `https://oi.atolab.cui`) that maps 80/443 -> the container's `3000`; the stack does **not** ship that proxy, so stand one up (nginx/Caddy/Cockpit) or you'll have an open 80/443 with nothing behind it. **Exposing Open WebUI directly instead?** Drop 80/443 and open **`3000`** here.

  `rule: limit` rate-limits a port; `from:` restricts it to a source CIDR (use it for the cross-node vLLM/Docling/pgvector ports so they aren't fleet-wide). SSH is always kept (rate-limited). The role also **enables ufw itself**, so an ai box is never left with an inactive firewall even if USG was skipped. Check: `sudo ufw status verbose`.

  > **Per-node values without editing the public repo.** Every box pulls the same repo, so putting `ai_firewall_allow_ports` (and internal IPs) in `group_vars/all.yml` makes them global. For **per-node** settings, edit the **`/opt/it/site.yml`** the build drops on each box (legacy `/etc/stig-build/site.yml` still honoured); the playbook auto-loads it and it **overrides** `group_vars`. That's where System 1's and System 2's different firewall rules (and NTP, the Docling peer IP, a Cockpit cert, …) live, out of git. See **[`site.yml.example`](site.yml.example)**. Override the path with `-e site_overrides_file=…`.

### Baking in the AI stack (`ai_compose`)

The two-node stack is baked into the image so a fielded box comes up with its stacks in place. The **`ai_compose`** role (ai profile, `ai_compose_enabled: true`) writes the node's services as **one Dockge stack per service** into **`/opt/stacks/<stack>/compose.yaml`** (each with a root-only `.env` beside it), creates the shared external **`oi`** network, **builds the custom images** the stack needs, creates the named volumes, optionally auto-fetches the model, and (opt-in) `up -d` each stack. The per-service stacks by **`ai_node_role`** (full table in [ai-stack.md](ai-stack.md#compose-stacks--what-runs-and-how)):

| role (node) | stacks | serves |
|------|------|------|
| `system1` (dev-ai1) | `vllm-gptoss` (:8000) + switchable `vllm-granite`, `open-webui` (:3000), `redis`, `pgvector` | UI / text generation |
| `system2` (dev-ai2) | `vllm-embed` (:8002), `vllm-vision` (:8003), `docling` (:5001), `tika` (:9998), `grafana-otel` (:3001,:4317), `mlflow` (:5000), `openwiki-view` (:4321), `oikb` (:8081), `hfcli`/`openwiki` | extraction / embeddings / monitoring / tracking / sync |

**One stack per service, one shared network.** All stacks on a node join the external **`oi`** network, so services resolve each other by name across stacks (`chat-llm`, `pgvector`, `redis`, `dev-ai1`/`dev-ai2`). Because cross-stack `depends_on` can't span separate compose projects, `open-webui` **retries** its DB/cache connection on boot instead of health-gating — bring `pgvector`/`redis` up first (`it-ai up` does this ordering). Each service is now started/stopped/edited on its own (`it-ai up open-webui`, `it-ai restart pgvector`, or per-stack in Dockge).

> The pre-split single-file compose is kept as a **dormant fallback** at `/opt/it/docker/docker-compose.consolidated.yaml` (same external volumes; not deployed). Break-glass: `cd /opt/it/docker && sudo docker compose -f docker-compose.consolidated.yaml up -d` brings the whole node up as one project.

Notes:
- **Cross-node wiring.** System 1's Open WebUI reaches System 2 by **`ai_system2_addr`** (default the hostname `dev-ai2`): chat vision (:8003) as a second OpenAI endpoint, RAG embeddings (:8002), Docling extraction (:5001), and OTel → LGTM (:4317). System 2's **oikb** reaches System 1's Open WebUI (:3000) by **`ai_system1_addr`**. Set IPs in `site.yml` if the hostnames don't resolve across the boxes, and open the cross-node ports restricted to the peer (see `site.yml.example`). **Renumbering (e.g. deploying out of the lab)?** Run **`sudo it-set-ip`** on each box: it repoints the peer IP in `site.yml` + the live `.env` (`SYSTEM2_ADDR` / `OPEN_WEBUI_URL` + the container `extra_hosts`), fixes `/etc/hosts` and the ufw `from:` rules, recreates the containers, and can also set this box's own static IP via netplan. It edits files directly (works offline) and updates `site.yml` so a later online pull stays consistent. Change one box's own IP -> run `it-set-ip --peer <that new IP>` on the other.
- **Open WebUI** runs as the engineer tuned it (Redis for websocket coordination + cache across workers, DB connection pool, 9 uvicorn workers). The model / embedding / Docling / vision **connections are wired via env** to System 2 (override/blank in `site.yml` to configure them in the admin UI instead). Extraction defaults to Docling; set `CONTENT_EXTRACTION_ENGINE=tika` + `TIKA_SERVER_URL` to use Tika.
- **Custom images** `oikb`, `hfcli`, `repomix` (System 2 only) aren't on any registry; `ai_compose` **builds them on the box** (`ai_compose_build_images: true`). The `oikb` Dockerfile git-clones at build time → the box needs internet during imaging (or an internal mirror). `hfcli` is a `tools`-profile service (never auto-starts); `repomix` is a build-only utility.
- **Docling (System 2).** `docling-serve` runs on the System-2 GPU for document structure/OCR extraction using the **image's baked-in models**. This image runs with `--artifacts-path` (runtime model downloads **disabled**) and ships its OCR/layout/tableformer models under `/opt/app-root/src/.cache/docling/models`, so **no model volume is mounted** — mounting an external volume over that cache hides the built-in models and docling crash-loops with a `RapidOcr ... .onnx does not exists`-style `FileNotFoundError`. The models travel **with the image**, so `it-model-export --images` (and `it-model-import`) is all that's needed for air-gap. The **granite-docling-258M VLM is not deployed**: adding it would require building a **custom docling image** with the weights baked in (docling's own `docling-tools ... download-hf-repo` into a mounted volume re-triggers the crash-loop above). A future task if VLM→DocTags conversion is needed; structure/OCR works today on the baked-in models.
- **OpenWiki: generate vs. browse (System 2).** Two stacks, on purpose. **`openwiki`** (`tools` profile, on-demand) *generates* the wiki — markdown pages written into the `openwiki-out` volume: `it-ai run openwiki openwiki --init`. **`openwiki-view`** (:4321, always on) *browses* it. The viewer is openwiki's own `openwiki visualize` (an interactive graph + live markdown reader — note the command is **`visualize`**, there is no `serve`), which binds **127.0.0.1 only** and has no bind-address flag; so an nginx sidecar (`openwiki-view-proxy`, image `openwiki-view:latest`) shares its network namespace and serves 0.0.0.0:8080 → 127.0.0.1:4321, published as host **:4321**. Restrict who can reach it in `ai_firewall_allow_ports` (shipped open to `192.168.1.0/24` and `10.10.99.0/24`). The viewer's HTML normally pulls four libraries (force-graph, marked, DOMPurify, mermaid) from a public CDN — those are **vendored into the `openwiki-view` image at build time** and nginx rewrites the CDN prefix to a local `/vendor/` path, so the wiki renders **air-gapped**. (Google Fonts is left alone: offline it just falls back to a system sans-serif.) The `openwiki` npm package is **pinned** in its Dockerfile — an earlier unpinned build picked up a version whose LangChain dependency had moved and the viewer died at startup; bump `OPENWIKI_VERSION` deliberately and re-test `visualize`, and if a bump changes the CDN library versions, update the `ARG`s in `images/openwiki-view/Dockerfile` to match or the graph silently stops rendering offline.
- **Docling VLM conversion is not configured.** Plain extraction (layout/OCR — what Open WebUI calls) works out of the box on the image's baked-in models. The VLM pipeline is a separate path and needs a model. Running one locally is off the table: mounting a volume over docling's model cache hides the built-in models and it crash-loops. Calling one over the network is enabled (`DOCLING_SERVE_ENABLE_REMOTE_SERVICES=true`, `DOCLING_SERVE_ALLOW_CUSTOM_VLM_CONFIG=true`), but every built-in remote preset hardcodes a localhost URL, so none reach System 2's `vllm-vision`. Note also that `external_granite_vision` is **not** a valid preset name — docling's built-ins are `granite_docling`, `granite_docling_vllm`, `granite_vision`, `granite_vision_vllm`, `granite_vision_ollama`, `smoldocling`, `glm_ocr`, `lightonocr`, and friends. To point docling at `vllm-vision` (both are on the `oi` network), define a custom preset in the docling stack and make it the default:
  ```yaml
  - DOCLING_SERVE_CUSTOM_VLM_PRESETS={"lab_granite_vision":{"url":"http://vllm-vision:8003/v1/chat/completions","params":{"model":"granite-vision-4.1-4b","max_tokens":4096},"timeout":90,"scale":2.0,"temperature":0.0,"response_format":"markdown"}}
  - DOCLING_SERVE_DEFAULT_VLM_PRESET=lab_granite_vision
  ```
  This is derived from docling's `ApiVlmOptions` shape but has **not** been verified against a running conversion — test one before relying on it.
### GRUB2 bootloader password

**What it protects:** editing a GRUB menu entry (`e`) or dropping to the GRUB shell (`c`). Without it, anyone at the console appends `init=/bin/bash` to the kernel command line and gets a root shell with no authentication.

> **Why this matters more here than on a typical box.** `tpm_luks_unlock` seals the LUKS key to **PCR 7 (Secure Boot state) with no PIN**. PCR 7 does **not** measure the kernel command line, so editing it does not change the PCR — the TPM still releases the key and the disk auto-decrypts. The GRUB password is therefore the only control between physical access and a root shell on decrypted data. It is not redundant with LUKS on this fleet.

**Normal boot stays password-free.** Setting `superusers` makes GRUB demand the password for *every* entry unless entries carry `--unrestricted`; the role adds that flag, so unattended reboot still works.

#### Activating it

There are two paths. Both are driven by **`it-grub`**.

**Check what a box has right now:**

```bash
sudo it-grub status
```

It reports each condition separately — drop-in present, `set superusers` in `grub.cfg`, superuser name passing SSG's regex, `password_pbkdf2` present, **every menu entry `--unrestricted`**, and `grub.cfg` at `0600` — then a single overall verdict. The `--unrestricted` line is the one to read carefully: if any entry lacks it, **every boot will prompt for the password**.

**Path A — fleet-wide (the supported path).** Generate a hash, vault it, and let the role roll it out:

```bash
sudo it-grub hash
```

It runs `grub-mkpasswd-pbkdf2`, parses out just the token, and prints the exact `ansible-vault encrypt_string` command to run. Paste the resulting `!vault` block over `grub_password_pbkdf2` in `group_vars/all.yml`, commit, and re-run the pull on each box.

Until you do, the value is a `CHANGEME` sentinel and **the role skips entirely** — deliberately, because writing a bogus credential can make a box unbootable. The rule shows as an open finding until then.

**Path B — activate one box now:**

```bash
sudo it-grub set
```

Prompts for the password, applies it to that box only, and runs the same safety checks as the role: it generates a candidate `grub.cfg`, refuses to install it unless the credential is present and no entry is restricted, and keeps a recovery copy. Useful for testing on a throwaway box before committing to the fleet.

> These two do not fight. The role skips while `group_vars` holds the sentinel, so a locally-set password survives an `ansible-pull`. Once you vault a real hash, the role becomes authoritative and overwrites the local one.

**Removing it** (recovery, one box): `sudo it-grub remove`. Note the role re-applies it on the next pull if a hash is vaulted.

**Test it before trusting it.** On a throwaway box: `sudo it-grub set`, reboot, confirm it boots to the login prompt **without** asking for anything, then reboot again and press `e` — that should demand the superuser name and password.

**Safety built into the role.** It generates a candidate `grub.cfg` to a temp file, then refuses to install it unless the credential is present, at least one menu entry exists, and **no** entry lacks `--unrestricted`. A restricted entry would make every boot hang waiting for input, so that check is a hard failure rather than a warning. The first known-good config is preserved at `/boot/grub/grub.cfg.pre-grubpw`.

**Caveats.** `grub_superuser` must be letters/underscores only — SSG's check regex rejects digits and hyphens, and you would get a working password that still fails the scan. A `grub-common` package update can revert the `--unrestricted` edit in `/etc/grub.d/10_linux`; the next pull re-applies it.

**Recovery:** boot from install media, `chroot`, and either restore `/boot/grub/grub.cfg.pre-grubpw` or remove `/etc/grub.d/01_superusers` and re-run `update-grub`.

### Scheduled OpenSCAP scan (`it-oscap`)

The build-time SCAP scan is a point-in-time artifact. A scheduled re-scan keeps producing evidence into the IA collection point.

```bash
sudo it-oscap                      # run now -> /opt/ia/oscap
sudo it-oscap --keep 24            # retain more result sets
systemctl list-timers oscap-scan.timer
```

Each run writes three timestamped files: an HTML report, the full ARF results, and a STIG-Viewer-importable XML. They go to **`/opt/ia/oscap/scheduled`** for the timer, `oscap/manual` for an ad-hoc `it-oscap`, and `oscap/build` for the scan the build itself runs — one directory per writer, so pruning to `scap_schedule_keep` (default 12) can never delete an artifact a different process owns.

It runs as **root**, not `auto_audit`: `oscap` needs to read privileged configuration, and `auto_audit` is created with a locked password so it cannot use `sudo` unattended.

**Scheduler choice** — `scap_schedule_method`:

| Value | Behaviour |
|---|---|
| `timer` (default) | systemd timer with `Persistent=true`, so a run missed while the box was **powered off** fires at next boot. Correct for the EMI laptop. |
| `cron` | `/etc/cron.d/oscap-scan` — literal "crontab" compliance if an assessor greps for it. A run missed while powered off is lost. |

Only one is ever installed; switching methods removes the other.

### ClamAV signatures on an air-gapped box (`it-clamav`)

`freshclam` cannot reach anything once the box is off the network, so signatures come in by hand. Drop the archive in `/opt/it/clamavsigs` and run the installer:

> **Check that the engine actually detects — `sudo it-clamav test`.** ClamAV can load every signature and then scan *nothing*. See the FIPS carve-out below for why, and run the test on any box you are about to rely on. `it-clamav check` runs it too, and `dta-log` runs it before scanning a payload — recording `ENGINE-FAULT` rather than `CLEAN` if it fails.

#### The FIPS carve-out (`clamav_fips`)

ClamAV fingerprints file content with **MD5**, which is not a FIPS-approved algorithm. On a FIPS host OpenSSL refuses to create the digest context, so every file scan bails before reading a byte:

```
LibClamAV Error: cli_scan_fmap: Error initializing md5 hash context
/opt/it/inventory-ASP-2.txt: OK
...
Data read:    2.05 MiB
Data scanned: 0 B          <-- read 2 MB, scanned nothing
Infected files: 0
```

Exit status 0. Daemon healthy. Weekly scan "passing". **Antivirus does nothing while every report says clean.** Confirmed on ASP-2, 2026-08-26; `openssl md5 /etc/hostname` on that box returns `Algorithm (MD5 : 100) ... unsupported`.

The `clamav_fips` role writes `/etc/clamav/openssl-clamav.cnf` — an OpenSSL config activating the **default provider**, which has MD5 — and points `clamav-daemon`, `clamav-freshclam` and `clamav-scan` at it with a systemd `Environment=OPENSSL_CONF=` drop-in. `it-clamav` and `dta-log` export it too, which also matters for `sigtool` when it verifies a CVD signature. The kernel stays in FIPS mode and nothing else on the host is affected — the same shape as the `fips_off` mount the vLLM and Docling containers use.

The role **validates the config before applying it** (`OPENSSL_CONF=… openssl md5 /dev/null`) and changes nothing if that fails, since a bad `OPENSSL_CONF` would stop clamd starting. After applying it runs an EICAR test and says plainly whether the engine now detects. Set `clamav_fips_carveout_enabled: false` to leave ClamAV pure-but-blind; the role then removes the carve-out cleanly, and does the same automatically if the box stops being FIPS.

**The carve-out does not work on Ubuntu FIPS, and cannot.** Verified on ASP-2: Ubuntu's FIPS OpenSSL takes FIPS mode from the kernel flag rather than from configuration, so `OPENSSL_CONF=/dev/null openssl md5 /dev/null` fails just as the carve-out config does. The role detects this, removes the config it wrote, and says so. It is left in place because it costs one command per pull and starts working by itself if this is ever fixed.

This is upstream [Cisco-Talos/clamav#1786](https://github.com/Cisco-Talos/clamav/issues/1786) — open, no fix, no maintainer response. The reporter also tested `--fips-limits` and `FIPSCryptoHashLimits`; neither helps. ClamAV 1.5 did add FIPS-mode work (external `.cvd.sign` signatures replacing the MD5+RSA database check), but that fixes *database verification*, not the MD5 hashing of scanned content.

#### The fix: a containerised engine (`clamav_container`)

The scanning engine moves into a container whose OpenSSL is a stock build, so MD5 works there. **The host kernel stays in FIPS mode** — same shape as the `fips_off` mount the vLLM and Docling containers use, which is already accredited here.

The role **self-skips**: it writes an EICAR file, runs the host `clamscan` against it, and only acts if the host fails to detect. On a box where ClamAV works it does nothing, so it is safe on every profile. If the host engine later starts working, it tears the container down and unmasks `clamav-daemon` again.

What it stands up:

| | |
|---|---|
| `clamav-container.service` | `clamd` from `clamav/clamav:1.4.3` (pinned — see [patching.md](patching.md)), `--network none`, memory-capped |
| `/run/clamav-container/clamd.sock` | its socket, mode `0666` on the host. That directory **is** the container's `/tmp` — the image's clamd listens on `/tmp/clamd.sock` and bind-mounting over `/tmp` is the documented way to expose it |
| `/etc/clamav/clamd-container.conf` | client config so `clamdscan -c … --fdpass` reaches it |
| `/var/lib/clamav-container` | the container's **own** signature database, seeded from the host's on first run. It cannot share `/var/lib/clamav`: the image's entrypoint chowns its database directory to the container's `clamav` user, and the two would fight over ownership every restart. `it-clamav` writes here automatically when the container is in use, and restarts it afterwards |

The host `clamav-daemon` is **stopped and masked**: it holds ~2 GB resident and cannot detect anything, so running both is waste.

**Why `--fdpass` is what makes this work.** The client opens the file and hands the daemon the file *descriptor*, so nothing being scanned is ever mounted into the container, and the daemon reads with the calling user's rights. That matters most for the thing that would otherwise sink this design: **a DTA never needs access to `docker`**, which is root-equivalent. They run the ordinary `clamdscan` client against a socket.

`dta-log`, `it-clamav test` and the weekly scan all prefer the containerised engine when its socket answers, fall back to the host daemon, then to standalone `clamscan`.

**Allow ~60–90s after a restart.** clamd binds its socket only *after* loading the signature set, so a `systemctl restart clamav-container` followed immediately by `it-clamav test` finds no socket and silently falls back to the host engine — which reports FAIL for the usual FIPS reason and looks exactly like a broken container. `it-clamav test` now recognises that window and says so. Confirmed working on ASP-2, 2026-08-26: `PASS -- containerised clamd detected the EICAR test file`.

**Air-gapped staging.** The pull cannot fetch the image on a fielded box. On an online one:

```bash
sudo it-clamav image-save /mnt/usb     # docker save + a manifest
```

then on the fielded box:

```bash
sudo it-clamav image-load /mnt/usb
sudo ansible-pull ...                  # clamav_container starts the daemon
sudo it-clamav test                    # must PASS
```

**`sigtool` moves too.** Verifying a CVD's digital signature needs MD5, so on a FIPS host `it-clamav install` would reject every archive as unverifiable. It runs `sigtool` in the same image when the host cannot do MD5; `it-clamav test` reports which mode is in use.

**What this does not fix.** The on-access/real-time scanning the host `clamav-daemon` would have done is gone — this is on-demand scanning only. Say so on the POA&M rather than letting it be found.

The options that were considered and rejected: accept degraded scanning (a transfer gate that cannot detect EICAR is indefensible), procure a different AV for FIPS boxes (cost and accreditation), or drop FIPS on EMI (trades away `UBTU-24-600030` — the wrong trade).

Diagnosing it by hand needs two details that are easy to get wrong:

```bash
# As ROOT. `sudo` resets the environment, so `OPENSSL_CONF=... sudo ...` is silently dropped.
printf '%s%s' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR' '-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > /tmp/canary
clamscan /tmp/canary                       # OK      -> broken
OPENSSL_CONF=/dev/null clamscan /tmp/canary  # FOUND -> FIPS confirmed
```

Use **`clamscan`**, not `clamdscan`: with clamdscan the *daemon* does the hashing in its own process, so a variable set on the client changes nothing.

```bash
sudo it-clamav                       # what is installed, how old, is the daemon serving it
sudo it-clamav list                  # archives waiting in /opt/it/clamavsigs
sudo it-clamav install               # install the newest one
sudo it-clamav install /path/to.tar.gz
sudo it-clamav rollback              # put the previous set back
```

The archive is extracted to a temp directory and **validated before the live database is touched**. A `.cvd` carries a digital signature from the ClamAV project, and `sigtool --info` verifies it — so a file altered on the media it travelled on is rejected rather than installed. Versions are compared against what is already on disk and a downgrade needs `--force`.

Only then does it back up `/var/lib/clamav` to `/var/backups/clamav/<timestamp>/`, stop the services, install, and restart. It never leaves a `.cvd` and a `.cld` of the same database side by side — clamd loads one of them and not necessarily the newer one.

Two checks decide whether it worked, and both have to pass:

1. The **daemon's own reported version** (`clamdscan --version`, which asks the running process) has to match what was just written to disk. A daemon that did not reload reports the old number.
2. An **EICAR detection test** through the daemon. The database can load cleanly and the engine still not detect; this proves it does.

Either check failing exits non-zero and tells you to roll back. `--no-test` skips the second one.

`it-clamav check` also reports whether `clamav-freshclam` is running — on a connected box it will overwrite manually installed signatures, and on an air-gapped one it just fails on a timer.

### Going classified (`it-goclassified`)

The gate a box passes through before it holds classified data. Run it on the bench, with the box in the state it will be fielded in:

```bash
sudo it-goclassified            # walk the gate, answering the attestations
sudo it-goclassified --report   # machine checks only, no prompts, nothing written
```

Every item lands in one of four states. **PASS** and **FAIL** are machine-verified. **ATTEST** is a step the OS cannot see — a BIOS admin password, whether the LUKS passphrase was actually rotated, whether the notes came off the bench — answered by the operator and recorded against their name and the time. **OPEN** is anything not confirmed, which includes an attestation answered "no" — saying no does not quietly pass.

Exit is 0 only when nothing failed and nothing is open, so it can gate a script.

The record goes to `/opt/ia/goclassified/<host>-<timestamp>.txt`. That file is the artefact for the ISSM: it says which checks passed on this box, on this date, and who attested the rest. It is evidence the steps were done, not a substitute for the SSP.

Two checks are worth calling out because they are the ones a "looks fine" box fails:

- **Antivirus is tested, not polled.** It runs `it-clamav test` rather than asking whether a daemon is up — on a FIPS box the daemon runs happily and detects nothing (see the ClamAV section above).
- **Interactive passwords are compared to the imaging date.** Any account whose last password change is the day the box was imaged is still on its build password, and that fails.

### Data transfers (`dta-log`)

Files move through `/opt/dta`, and every transfer gets a record. The folders are `2770 root:dta`, so only the `dta` group can see or stage anything in them:

| Path | What |
|---|---|
| `/opt/dta/incoming` | files arriving on this box |
| `/opt/dta/outgoing` | files staged to leave |
| `/opt/dta/logs` | one record per transfer + `transfers.tsv` index |

Run it **as the DTA account**, not with sudo — the whole point is that the record names the person who did the transfer:

```bash
dta-log                      # walk through a transfer and write the record
dta-log list                 # the last 15 transfers, one line each
dta-log show last            # the full record for the most recent one
dta-log --dir /media/usb/x   # skip the folder prompt
dta-log --no-hash            # skip the sha256 manifest on a very large transfer
```

Or double-click **Data Transfer Record** in the app menu.

It asks five things in order: whether the low-side form is approved by the AO and the ISSM/ISSO; the DTA's name; the transfer type (**L2H** or **H2H**); which folder is moving; and then it scans that folder.

The folder question is answered for you where it can be: `dta-log` finds the most recently modified file under `incoming` and `outgoing`, shows the parent folder with a file count, size and timestamp, and asks you to confirm. Say no and you can type any path.

The scan uses `clamdscan --fdpass` when `clamav-daemon` is up and falls back to `clamscan`. **`--fdpass` is not optional** — it hands the daemon an already-open descriptor so it reads with the DTA's rights; without it the `clamav` user cannot read anything under a `2770 root:dta` folder and every scan fails with a permission error.

The record captures the answers, both timestamps, the scanner engine, **the signature database date and age**, the full scanner output, and a sha256 manifest of every file. Signature age matters here more than usual: on an air-gapped box `freshclam` cannot reach anything, so the tool prints a warning above the scan and writes the age into the record rather than quietly scanning with year-old signatures.

Two outcomes end the run early. Answering **no** to the approval question writes an `ABORTED` record and stops — the attempt is still on file. A scan that comes back **INFECTED** writes a `BLOCKED` record and exits non-zero.

`/opt/dta/logs` is `3770` — setgid so records inherit the group, and **sticky** so one DTA cannot delete another's record. That is not tamper-proofing against root; the audit rules cover that separately.

### USB device allow-listing (`it-usb`)

USBGuard gates whether the kernel **authorises a device at all**. This is a separate layer from the `dta` controls, which gate **mounting** — both are in force, and both should be cited.

Unknown devices are **blocked** (visible but unusable, so the attempt is auditable). The devices attached when the policy was generated are authorised, which is why the box's own keyboard and trackpad keep working.

```bash
sudo it-usb status                    # daemon + policy summary
sudo it-usb list                      # every device, with its id
sudo it-usb blocked                   # just what is being blocked
sudo it-usb allow 14                  # authorise now (until unplugged)
sudo it-usb allow 14 --permanent      # authorise and add to the policy
sudo it-usb block 14
sudo it-usb policy                    # show the saved allow-list
sudo it-usb regenerate                # re-baseline from attached devices
```

**Adding an approved device — the easy way:**

```bash
sudo it-usb enroll
```

It snapshots the attached devices, waits for you to plug the new one in, diffs, shows exactly what appeared, and authorises it permanently after you confirm. Safer than reading ids by eye — you cannot accidentally authorise a device that was already sitting there.

Manual equivalent: plug it in → `sudo it-usb blocked` for the id → `sudo it-usb allow <id> --permanent`. The policy is backed up before every change.

**External HID is not blanket-allowed, on purpose.** A keystroke-injection device (BadUSB) presents as a keyboard, so allowing the HID class would defeat the control. An external keyboard is authorised once, from the console, using the internal one.

**Profiles:** on everywhere, EMI included. The laptop is the machine most likely to meet an unknown USB device, so it is the strongest case for having this — and `it-usb enroll` makes approving a peripheral a two-step operation.

**On the EMI laptop specifically:** the initial policy is generated from whatever is attached during the build, so the built-in keyboard and trackpad are always authorised — you cannot lose the console. Enrol the approved peripherals once, at imaging time, with the devices to hand. Set `usbguard_enabled: false` in that box's `site.yml` to opt out.

> **Lockout recovery:** boot to recovery/single-user and `systemctl disable --now usbguard`, then `it-usb regenerate` with the right devices attached.

- **Model switching (System 1).** gpt-oss-120b and Granite-4.1-30b are alternates (one at a time). See "Switching System 1's chat model" below.

**Hands-off imaging: normally NOTHING to edit per box.** On the ai profile the stack is enabled automatically and everything per-node auto-derives, so a freshly-imaged, correctly-named box comes up configured with no `site.yml` editing:

- **`ai_node_role` is picked from the hostname:** `dev-ai1`→`system1`, `dev-ai2`→`system2` (plus an `*ai1*`/`*ai2*` pattern fallback). Extend `ai_node_role_by_hostname` in `group_vars` for more nodes.
- **The pgvector password is auto-generated** and persisted root-only (`/etc/stig-build/pgvector.pw`) on first run; used only between two containers on the same box, never by a human, so there's nothing to type and no secret in the repo.
- **System 1 reaches System 2 by the name `dev-ai2`** (`ai_system2_ip` default).

So the imaging workflow is just: **name the box `dev-ai1`/`dev-ai2` → run the pull.** `site.yml` is only for *exceptions*, dropped root-only on the box (out of git):

```yaml
# Only if the box ISN'T named dev-ai1/dev-ai2:
ai_node_role: system1                 # or system2
# Only for an ALREADY-INITIALISED DB (pin its existing password so WebUI still logs in):
ai_pgvector_password: "‹existing db password›"
# oikb data-source secrets (OPT-IN: setting the API key flips COMPOSE_PROFILES=oikb
# in .env so oikb starts; leave it unset and oikb never runs -- no GitLab needed):
ai_oikb_openwebui_api_key: "‹Open WebUI API key›"
ai_oikb_gitlab_url: "https://gitlab.yourlab"    # only if you have a GitLab source
ai_oikb_gitlab_token: "‹GitLab PAT›"            # read_api + read_repository
# Opt in to the heavy steps when ready:
ai_model_fetch: true                  # download gpt-oss into its volume
ai_compose_deploy: true               # start the stack (after the model is staged)
```

Also open **System 2's** cross-node ports **to System 1 only** (`ai_firewall_allow_ports` in `site.yml`): `8002` (embed), `8003` (vision), `5001` (Docling), `9998` (Tika), `4317`/`4318` (OTel), each `from: "‹System 1 IP›"`. Also restrict `3001` (Grafana), `5000` (MLflow), and `8081` (oikb), also on System 2, to an admin CIDR. System 1 opens `3000` (Open WebUI, to users + oikb from System 2).

### Open WebUI RAG / Documents defaults (and the PersistentConfig caveat)

Open WebUI's **Admin -> Settings -> Documents** panel (extraction engine, embeddings, chunking, hybrid search, top-k) is seeded from env vars baked into System 1's compose, so a freshly imaged box comes up with the right RAG config instead of the upstream defaults:

| Setting | Baked value | Env var |
|---|---|---|
| Extraction engine | Docling (`:5001` on System 2) | `CONTENT_EXTRACTION_ENGINE`, `DOCLING_SERVER_URL` |
| Embedding engine / model | OpenAI-compat -> Granite embed (`:8002`) | `RAG_EMBEDDING_ENGINE`, `RAG_EMBEDDING_MODEL`, `RAG_OPENAI_API_BASE_URL` |
| Embedding batch size | 15 | `RAG_EMBEDDING_BATCH_SIZE` |
| Hybrid search + BM25 weight | on, 0.5 | `ENABLE_RAG_HYBRID_SEARCH`, `RAG_HYBRID_BM25_WEIGHT` |
| Top K / Top K reranker | 3 / 3 | `RAG_TOP_K`, `RAG_TOP_K_RERANKER` |
| Chunk size / overlap | 2048 / 200 | `CHUNK_SIZE`, `CHUNK_OVERLAP` |

> **Critical caveat -- these are Open WebUI `PersistentConfig`.** The env var seeds the value into the database **only on first boot (empty DB)**. On a box whose Open WebUI DB already exists, the **stored value wins** and editing the env has no effect -- change it in the UI (Admin -> Settings -> Documents) instead. So: for a **new image** the compose values apply automatically; for an **already-running box** set them in the UI (or reset that config row). The Redis / websocket / `UVICORN_WORKERS` / `CORS_ALLOW_ORIGIN` env vars are *not* PersistentConfig and always apply at start.

Two settings are intentionally left **off** in the baseline and opt-in only: an **external reranker** (a cross-encoder reranker is not the embedding model -- only enable if System 2 actually serves a rerank endpoint) and **`ENABLE_KB_EXEC`** (runs code from knowledge-base content -- a deliberate risk decision on a hardened box). Both are present as commented lines in `system1-compose.yaml`.

### Connecting an IDE (Continue, VS Code) -- client-side

The [Continue](https://continue.dev) VS Code/JetBrains extension is a **developer-laptop** client, not part of the server build, but two ways to point it at this stack are worth recording. Put this in the developer's `~/.continue/config.yaml` (replace the IP with **dev-ai1's real address**; the model name must match the vLLM `--served-model-name`, i.e. `gpt-oss-120b`):

```yaml
models:
  # Option A -- through Open WebUI (audited, same routing/logging as the chat UI):
  - name: gpt-oss-120b (via Open WebUI)
    provider: openai
    model: gpt-oss-120b
    apiBase: http://<dev-ai1-ip>:3000/api      # Open WebUI OpenAI-compatible API
    apiKey: sk-...                              # create in Open WebUI: Settings -> Account -> API Keys
    roles: [chat, edit, apply]
  # Option B -- straight to vLLM (lower overhead, bypasses Open WebUI + its audit log):
  - name: gpt-oss-120b (direct vLLM)
    provider: openai
    model: gpt-oss-120b
    apiBase: http://<dev-ai1-ip>:8000/v1
    apiKey: sk-noauth
    roles: [chat, edit, apply]
    defaultCompletionOptions: { temperature: 1.0, topP: 1.0, maxTokens: 8192, contextLength: 65000 }
```

> **gpt-oss sampling — avoid repetition loops.** gpt-oss is trained for **temperature 1.0 / top_p 1.0**; a low temperature (or `0.0` greedy) with no repetition penalty makes long generations collapse into single-token loops (`ex ex ex…`). The served model ships those defaults + a light `repetition_penalty` (1.1) via vLLM `--override-generation-config`, but **Open WebUI sends its own temperature**, so set it there too: **Admin → Settings → Models → `gpt-oss-120b` → Advanced Params → Temperature 1.0, Top P 1.0** (and optionally Frequency Penalty ~0.4). It's a per-model setting stored in the DB, so set it once in the UI (not via env). Direct IDE clients (above) should likewise send temperature 1.0, not 0.0.

- **Prefer Option A** where the user activity should hit the Open WebUI audit trail (AU controls). Option B is a direct fast path.
- **Firewall:** Option A needs `3000` reachable from the developer subnet (already the users' port). Option B needs `8000` opened to that subnet in `ai_firewall_allow_ports` -- by default `8000` is not published to clients, only used locally by Open WebUI. Open it deliberately if you want direct IDE access.
- The IPs in a handed-over sample config are whatever that author's network used; always substitute this box's real address.

### Switching System 1's chat model (gpt-oss ↔ Granite-4.1-30B)

System 1's two 48 GB (RTX 6000 Ada) GPUs can't hold **gpt-oss-120B** and **Granite-4.1-30B** at once, so they're **alternates, one at a time.**

- They're **separate stacks** (`vllm-gptoss` / `vllm-granite`) that share the `chat-llm` network alias; **gpt-oss auto-starts**, `vllm-granite` sits behind the `granite` profile (nothing runs on a plain `up`).
- Open WebUI points at `http://chat-llm:8000/v1`, so switching needs no UI change; the model just changes in the dropdown.

Swap with **`it-ai model`** (wraps `switch-model.sh`, works from anywhere):

```bash
sudo it-ai model granite     # stop the gpt-oss stack, start the Granite stack
sudo it-ai model gpt-oss     # back to the 120B (default)
sudo it-ai model status      # which one is running
```

Each switch stops the other model's stack first (so only one holds VRAM) and takes a few minutes to load.

**Don't `it-ai up` both vLLM stacks while on Granite**: bringing `vllm-gptoss` up alongside `vllm-granite` would OOM the GPUs; use `it-ai model` to flip between them. (On the already-running dev-ai1, point Open WebUI's connection at `http://chat-llm:8000/v1` and remove the old `http://vllm:8000/v1` one so switching works.)

### Gathering the models (automated + hfcli)

Models live in **external** docker volumes (survive `docker compose down -v`). The served models (`gpt-oss-120b` + `granite-4.1-30b` on System 1) are declared in **`ai_models`** (`group_vars/all.yml`); `ai_compose` creates the volumes, and with **`ai_model_fetch: true`** downloads each into its volume via the `hf` CLI (the vLLM image's Hugging Face downloader; the old `huggingface-cli` entrypoint is deprecated and no longer works). The fetch is **completeness-checked**: it SKIPs only when every shard named in `model.safetensors.index.json` (or a single-file `model.safetensors`) is present and non-empty; otherwise it re-runs `hf download`, which **resumes** and fills just the missing files. (A plain "does `config.json` exist?" check is **not** enough — `config.json` lands early, so an interrupted download leaves it in place and a partial, silently-corrupt model would never get re-pulled. A partial gpt-oss set loads with broken final-layer weights and generates **repeating-token garbage** on older vLLM, or refuses to start on newer vLLM.)

- **No HF token needed.** `openai/gpt-oss-120b` (and the Granite repos) are Apache-2.0 / ungated. Set `ai_hf_token` in `site.yml` **only** to dodge anonymous rate-limits on the big gpt-oss pull.
- **Tiktoken encodings are fetched too.** gpt-oss's *harmony* tokenizer reads `o200k_base.tiktoken` / `cl100k_base.tiktoken` from the `encodings` volume; without them vLLM loads the model fine but crashes building the tokenizer (`invalid tiktoken vocab file`). `ai_model_fetch` downloads them into the `encodings` volume automatically (idempotent) for any node that has that volume. Both the model and the encodings fetch mount `fips_off`; on a FIPS host this image's OpenSSL can't do TLS without it.
- **Size/time.** gpt-oss-120b is ~200 GB; the first fetch is long and runs synchronously during the play. Run it when the box has internet and disk headroom, then flip `ai_compose_deploy: true` (or `up` by hand).

`ai_model_fetch` stages **all** the served models: gpt-oss-120b + Granite-4.1-30b on System 1, and the embedding + vision models on System 2, each into its own volume root (which is what the vLLM services serve, e.g. `--model=/granite-embed`).

**Ad-hoc staging** (an extra model, or a re-download) uses the **`hfcli`** utility container on **System 2** (`tools` profile, doesn't auto-start). It mounts the model volumes, so download to the volume root:

```bash
# on System 2 (it-ai run wraps `docker compose run --rm` in the hfcli stack):
sudo it-ai run hfcli hf download ibm-granite/granite-embedding-small-english-r2 --local-dir /granite-embed
sudo it-ai run hfcli hf download ibm-granite/granite-vision-4.1-4b            --local-dir /granite-vision
```

On **System 1** (no hfcli) use the vLLM image directly, e.g. to re-stage Granite chat into its volume: `sudo docker run --rm -v granite32b:/m -v /opt/stacks/vllm-granite/fips_off:/proc/sys/crypto/fips_enabled:ro --entrypoint hf vllm/vllm-openai:v0.22.1-cu129-ubuntu2404 download ibm-granite/granite-4.1-30b --local-dir /m`.

When ready to serve one, add its vLLM stack under `/opt/stacks/` (or its `ai_models` entry), then `it-ai up <stack>`. The `tiktoken`/harmony encodings gpt-oss expects in the `encodings` volume are fetched on first start when online; for air-gap, pre-stage them into that volume too.

Verify before first `up`: `sudo docker run --rm -v vllm:/m alpine ls /m` should list `config.json` + weight shards. Then `it-ai up` (or flip `ai_compose_deploy`).

### Air-gap: gather models on a USB, install on the fielded box (`it-model-export` / `it-model-import`)

A fielded box has no internet, so the models (and, for a full cold bring-up, the container images) travel on removable media. Two scripts make both sides one command; a **manifest** written to the media carries the volume↔repo mapping, so the air-gapped side needs no repo, no `group_vars`, and no internet.

**On an ONLINE box** (any machine with Docker — a build-room box or a laptop), gather onto the USB:

```bash
sudo it-model-export /mnt/usb                 # all models + tiktoken encodings
sudo it-model-export /mnt/usb --role system1  # just System 1's models (gpt-oss + granite chat)
sudo it-model-export /mnt/usb --images        # ALSO save the container images (full cold bring-up)
```

It runs `hf download` into `/mnt/usb/models/<volume>/`, verifies **every safetensors shard is present** (the same completeness check the build uses — a truncated pull is left off the manifest so you notice), fetches the tiktoken encodings, and writes `/mnt/usb/manifest.txt`. With `--images` it `docker pull`s + `docker save`s the registry images (vLLM, Open WebUI, pgvector, redis, Docling, Tika, LGTM, Dockge). The **custom** images (oikb/hfcli/mlflow/openwiki, built on a box by `ai_compose`) must already exist locally to be saved — build them first (run the `ai_compose` role once online, or `docker build`); the script warns + skips any it can't find rather than building them.

**On the AIR-GAPPED box**, install from the same USB:

```bash
sudo it-model-import /mnt/usb            # models + encodings into their external volumes
sudo it-model-import /mnt/usb --images   # + docker load the saved images (do this first-ever bring-up)
```

It reads the manifest and copies each model **straight into its named Docker volume's host path** (`docker volume inspect` Mountpoint) — no helper image needed, so it works before any image exists — creating volumes as needed, re-verifying completeness, and **skipping a volume that's already complete** (`--force` to overwrite). Then `it-models` to confirm and `it-ai up` (plus `it-ai model gpt-oss` on System 1) to start.

**Updating a model later** (air-gapped): re-run `it-model-export` for just that repo's role on the online box, carry the USB over, `it-model-import --force`, then `it-ai restart <stack>`. Keep the two scripts' pinned versions/repos in step with `group_vars/all.yml` (`ai_models`, `ai_compose_images`, `ai_vllm_image`) — they carry a copy of that list so they can run standalone.

> Alternative to `--images`: mirror the registry images into an **internal registry** and set `ai_compose_build_images: false` to push the custom ones from there, instead of `docker save`/`load` over USB.

### FIPS + inference containers (POA&M)

The ai boxes run with **FIPS enabled on the host** (`fips=1`, `/proc/sys/crypto/fips_enabled=1`). Containers share the host kernel, so a container's OpenSSL sees that flag.

- **vLLM** image ships no FIPS OpenSSL provider (`fips.so` / `fipsmodule.cnf` aren't in it). OpenSSL 3.0.13 then *forces* FIPS for its DRBG, fails to load the missing module, and the container **crash-loops** (`fips.so: cannot open shared object file`, or `FATAL FIPS SELFTEST FAILURE`).
- **docling-serve** hits the same wall via a different library: it bundles OpenCV, whose vendored OpenSSL 1.1.1k (`opencv_python.libs/libcrypto-*.so.1.1.1k`) runs a FIPS selftest and `abort()`s (SIGABRT / exit 134) on the FIPS host.
- Redis, pgvector, Open WebUI, LGTM (Go/Java), and Tika run fine; they don't load a FIPS-forcing OpenSSL.

vLLM / PyTorch / OpenCV are **not FIPS-validated** in the first place, so the fix is to let *those containers* use standard crypto while the **host stays fully FIPS** (kernel + host userspace unchanged, what the STIG assesses).

`ai_compose` drops a `fips_off` file (`0`) in the compose dir and every affected service (the vLLM services **and docling-serve**) bind-mounts it **read-only over `/proc/sys/crypto/fips_enabled`**, so its OpenSSL sees `0` and uses the default provider. Verified: with the mask, `openssl rand` succeeds; without it, it fails.

> **POA&M:** the containerized inference workload runs non-FIPS crypto (localhost/oi-network traffic on a single-tenant, USG-hardened host). The host OS remains FIPS-enabled. Any container whose image bundles a non-FIPS OpenSSL (the vLLM embed/vision services and docling-serve on System 2) needs the **same** `./fips_off:/proc/sys/crypto/fips_enabled:ro` mount; the file is already staged on both nodes; a new such service that crash-loops with a FIPS selftest abort just needs the mount added. Alternative if full container FIPS is ever required: rebuild the image with the Ubuntu Pro FIPS OpenSSL module baked in.

## Windows servers

This repo is Linux-only. STIG automation for Windows uses a different stack (PowerShell DSC / the DISA-provided GPOs / Ansible `ansible.windows` + `microsoft.iis` etc.). Keep that as a separate playbook.
