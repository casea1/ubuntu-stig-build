# Ubuntu Pro AI Server Profile — Design

Status: **superseded in part** · Date: 2026-07-14 · Target: Ubuntu Pro 24.04 LTS Server

> **UPDATE — the `ai_stack` role is now HOST PREP ONLY.** The AI containers ship as
> the operator's own **prebuilt images + compose files**, so `ai_stack` no longer renders a
> compose file, generates secrets, pulls images, or starts containers. It now installs only
> **Docker + the NVIDIA GPU stack**; USG hardens the host; and a new **`ai_firewall`** role opens
> the containers' inbound ports (`ai_firewall_allow_ports`) after USG's default-deny. The
> Compose-orchestration design below (server_tools selection, rendered compose, cross-host wiring,
> secrets) is **retained for historical context only** — that logic was removed.

## Contents

- [Context & goal](#context--goal)
- [Scope](#scope)
- [Decisions (recorded from requirements)](#decisions-recorded-from-requirements)
- [Architecture](#architecture)
- [Version pins (bump deliberately, re-test)](#version-pins-bump-deliberately-re-test)
- [STIG impact & documented exceptions (POA&M)](#stig-impact--documented-exceptions-poam)
- [Verification plan (on a throwaway GPU VM)](#verification-plan-on-a-throwaway-gpu-vm)

## Context & goal

The project began as a single-purpose imager: turn a fresh Ubuntu 24.04 **Desktop**
into a DISA-STIG-hardened GNOME engineering workstation. This change adds a second,
selectable **server** profile that targets **Ubuntu Pro Server** and does two new
things:

1. **Hardens with Canonical's Ubuntu Security Guide (USG)** — `usg fix disa_stig` —
   instead of the community `ansible-lockdown/UBUNTU24-STIG` role. USG is Canonical's
   *officially supported* DISA-STIG implementation, ships with Ubuntu Pro, and produces
   its own compliance report (`usg audit`). It is the right hardening backend for a
   server; the lockdown role stays on the desktop (where USG's server-only DISA content
   isn't validated against GNOME/GDM).
2. **Installs a selectable, container-based local-AI inference stack** — vLLM,
   Open WebUI, PostgreSQL 16 + pgvector, and Docling — so the same one-command flow can
   stand up a "sovereign AI" box. Each tool is opt-in per server.

The two profiles share the same `ansible-pull` entrypoint and the same
install-then-harden ordering; a single `deployment_profile` var selects which role set
runs.

## Scope

**In:** a `deployment_profile: development | ai` switch; a lean AI-server baseline; the
`ai_stack` role (docker-ce ≥ 29.5.2, NVIDIA driver + container toolkit, a rendered
Docker Compose stack with only the selected services); the `usg_harden` role (Ubuntu
Pro attach, USG install, `usg fix`, `usg audit`); bootstrap + docs.

**Out:** multi-node/orchestrated inference (single-host Compose only); model
lifecycle management (vLLM serves one configured model); Kubernetes; non-NVIDIA
accelerators; converting the development profile to USG.

**Naming:** this doc predates the `development`/`ai` profile names — the first release
called them `desktop`/`server` (still accepted as aliases). Read `desktop`→`development`,
`server`→`ai`, `is_desktop`→`is_development`, `is_server`→`is_ai` throughout. The
development path is unchanged; `deployment_profile` defaults to `development`, and the
development roles are gated `when: is_development`.

## Decisions (recorded from requirements)

| Decision | Choice |
|---|---|
| Desktop vs server | **Additive** — one repo, `deployment_profile` selects the role set |
| Server hardening | **Canonical USG** (`usg fix disa_stig`); lockdown role stays desktop-only |
| AI tool deploy | **Docker Compose** with official pinned images (not native pip/systemd) |
| Tool selection | **`server_tools` list** — render only the selected services, per server |
| GPU | **Install the NVIDIA stack** (driver + `nvidia-container-toolkit`) for vLLM |
| Docker | **docker-ce** from Docker's apt repo (not `docker.io`), floor asserted ≥ 29.5.2 |
| Secrets | **Out-of-band**, exactly like the LUKS passphrase — never in the public repo |

## Architecture

`local.yml` derives `is_desktop` / `is_server` from `deployment_profile` and gates roles:

```
desktop:  base_packages → app_config → local_accounts → dev_tools →
          classification_banner → stig_harden → desktop_branding → [tpm] → scap_scan
server:   base_packages(lean) → ai_stack → usg_harden → [tpm]
```

Same rule as the desktop: **install while online, harden last.** `ai_stack` pulls
images and starts containers before `usg_harden` tightens the box (USG can enable ufw
and swap the kernel).

### A. Tool selection — `server_tools`

A list in `group_vars` (default: all five). The `ai_stack` role computes:

- `_ai_container_services` = the selection ∩ `{vllm, open_webui, pgvector, docling}`
- `_ai_need_docker` = any container service selected, or `docker` listed explicitly
- `_ai_need_gpu` = `gpu_enabled` **and** a GPU-consuming service (`vllm`/`docling`) selected

and installs exactly what those imply. Override per server without editing the repo:

```bash
ansible-pull ... -e '{"server_tools":["docker","pgvector","open_webui"]}'
# or:  bootstrap.sh  →  TOOLS=docker,pgvector,open_webui
```

### B. `ai_stack` role

| Task file | Responsibility |
|---|---|
| `docker.yml` | Add Docker's official apt repo; install `docker-ce`/`cli`/`containerd.io`/`buildx`/`compose-plugin`; **assert** installed version ≥ `docker_ce_min_version` (29.5.2); enable service; add `ai_stack_user` to `docker`. |
| `gpu.yml` | (optional) autoinstall the NVIDIA driver via `ubuntu-drivers`; add NVIDIA's apt repo; install `nvidia-container-toolkit`; `nvidia-ctk runtime configure` + restart Docker. Runs **before** compose, so the restart bounces nothing. |
| `compose.yml` | Generate stable secrets (ansible `password` lookup, persisted 0700); render `docker-compose.yml` (0644, non-secret) + `.env` (0600, secrets); `docker compose up -d` via `community.docker.docker_compose_v2`. |

The compose file is **rendered from `server_tools`** — only selected services appear.
Wiring (all over the internal Compose network, by service name):

- Open WebUI → vLLM: `OPENAI_API_BASE_URL=http://vllm:8000/v1`
- Open WebUI → pgvector: `VECTOR_DB=pgvector`, `PGVECTOR_DB_URL`, `DATABASE_URL` → `db:5432`
- Open WebUI → Docling: `CONTENT_EXTRACTION_ENGINE=docling`, `DOCLING_SERVER_URL=http://docling:5001`

Only Open WebUI's port is published on all interfaces (it's the UI users reach); vLLM,
Postgres and Docling are bound to `127.0.0.1` and reached container-to-container.

### C. `usg_harden` role

`ubuntu-pro-client` → resolve token (inline var / out-of-band `ubuntu_pro_token_file`)
→ `pro attach` → `pro enable usg` + `apt install usg` (+ optional `fips-updates`) →
`usg fix <profile>` → `usg audit <profile>` → report into `/var/log/stig-scan/`.

**Safety rails (mirror the desktop's `disruption_high` philosophy):**

- Not attachable (no token / offline) → the whole role **self-skips** with a POA&M
  warning; the build never fails on a missing subscription.
- `usg fix` **refuses to run** unless a `sudo`/`admin` account has a usable (hashed)
  password — the DISA profile locks password-less admins out.
- The fix is **stamped** (`/var/lib/usg-harden/applied-profile`) so it runs once per
  image, not on every `ansible-pull` (re-force with `usg_force_fix`).
- `usg_fix_enabled: false` (or `HARDEN=0`) → install + **audit only**, no fix. Use this
  to validate on a throwaway VM first.

## Version pins (bump deliberately, re-test)

| Tool | Pin | Source |
|---|---|---|
| docker-ce | ≥ **29.5.2** (asserted) | Docker official apt repo |
| vLLM | **v0.22.1** | `vllm/vllm-openai` (Docker Hub) |
| Open WebUI | **0.9.6** | `ghcr.io/open-webui/open-webui` |
| PostgreSQL + pgvector | **pg16** | `pgvector/pgvector:pg16` |
| Docling | latest (pin per image) | `ghcr.io/docling-project/docling-serve[-cu128|-cpu]` |

## STIG impact & documented exceptions (POA&M)

- **Docker engine + `docker` group** — root-equivalent; required to run the stack.
- **Open WebUI inbound port** (`3000/tcp`) — USG's ufw policy must be opened for it;
  track the exposure + put the UI behind a reverse proxy / auth on a real deployment.
- **Container images from external registries** — pinned + pulled while online; mirror
  them internally for a truly air-gapped rebuild.
- **FIPS** — off by default (kernel swap); enable via `usg_enable_fips` or accept as POA&M.
- **GPU driver** — third-party (NVIDIA) kernel module; documented mission-need exception.

## Verification plan (on a throwaway GPU VM)

- `deployment_profile=server`, `HARDEN=0` first run → stack up, `usg audit` report only.
- `docker --version` ≥ 29.5.2; `docker compose -p ai-stack ps` shows only selected services.
- `curl localhost:8000/v1/models` (vLLM), `curl localhost:5001/health` (Docling),
  `pg_isready` (db), Open WebUI reachable on `:3000` and can chat + ingest a PDF.
- Re-run with a subset (`TOOLS=docker,pgvector,open_webui`) → compose file omits vLLM/Docling.
- Flip `HARDEN=1`, re-run, reboot → `usg audit` post-reboot; confirm SSH admin still works.
