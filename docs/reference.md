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

**12. A passing benchmark is not a compliant box.** `usg fix` leaves `PermitRootLogin prohibit-password`, which satisfies the STIG rule (it only forbids a root *password* login) while still allowing root in **by SSH key** — which the org checklist forbids outright. Found on ASP-2 with a 96.41 % scan. Check what the rule actually asserts, not just its colour.

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

### Every profile

| Command | Does |
|---|---|
| `it-status` | Everything at a glance |
| `it-host` | OS, kernel, FIPS, uptime, disks |
| `it-luks` | Encryption state + TPM binding |
| `it-luks-rebind` | Re-bind LUKS to the current PCRs after a firmware change |
| `it-grub` | `status` / `hash` (fleet) / `set` (one box) — GRUB password |
| `it-usb` | USBGuard: `status`, `list`, `blocked`, `enroll`, `allow`, `trust` |
| `it-checklist` | The org checklist, one line per item. `--fail-only`, `--out FILE`, and **`--fix`** — prints how to close every FAIL and what each MANUAL item needs from a human. Prints steps, changes nothing |
| `it-oscap` | Run an OpenSCAP DISA-STIG scan now |
| `it-ckl` | Build the DISA `.cklb`/`.ckl` from the scan + `answers.yml` |
| `it-stig` | `status` / `run` / `scan` / `checklist` / `archive` — wraps the two above |
| `it-clamav` | `check`, `list`, `install`, `test`, `sync`, `rollback`, `revert`, `image-save`, `image-load` |
| `it-goclassified` | Pre-classification gate. `--report` for machine checks only |
| `it-offline-repo` | `load` / `enable` / `disable` / `verify` — run apt off a local repo |
| `it-adduser` | Create a local account. Asks the type (standard/dta/admin/audit) and derives both the username suffix and the group set from it |
| `it-passwd` | Reset a password, unlock the account, and clear its faillock counter. `--list` shows every account's state and expiry; `--unlock-only` skips the password |
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
| `/opt/ia/audit-offload/` | Weekly staged audit logs |
| `/opt/it/` | IT admin area, same ownership |
| `/opt/it/scripts/` | The `it-*` scripts |
| `/opt/it/site.yml` | **Per-node overrides. Beats `group_vars`.** Never in git |
| `/opt/it/clamavsigs/` | Drop ClamAV signature archives here |
| `/opt/it/apt-sources-backup/` | Online apt sources parked by `it-offline-repo enable` |
| `/opt/dta/incoming,outgoing,logs/` | Data-transfer staging and records (EMI) |
| `/opt/stacks/<stack>/` | AI compose stacks — Dockge watches this dir |
| `/srv/repo/` | The carried offline apt repo. `root:root 0755` |
| `/etc/stig-build/` | Root-only. Generated `*.pw`, the GRUB hash, and `profile` — which records the deployment profile and the **baseline revision** this box last pulled |
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
| `grub_password_pbkdf2` | `CHANGEME` | The role skips until a real hash is vaulted |
| `tpm_luks_enabled` | true except `emi-unclass` | Binds LUKS to PCR 7 |
| `offline_repo_enabled` | false | Switch apt to `/srv/repo`. Set by `it-offline-repo enable` |
| `base_packages_full_upgrade` | false | `apt full-upgrade` early in the build |
| `scap_stig_manual_xccdf` | `U_CAN_…_V1R6_Manual-xccdf.xml` | DISA's manual STIG, shipped in `roles/scap_scan/files/`. Update on a new STIG release |
| `scap_ckl_on_pull` | true | Build the `.cklb` at the end of every pull, from the scan that just ran |
| `local_accounts_enabled` | true | Org users/groups/ACL'd folders |
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
