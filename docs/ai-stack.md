# AI Server Profile (`ai`)

The two-node, self-hosted AI stack: what runs, where, and on which box.

| Looking for | Go to |
|---|---|
| Build steps | [build.md — Track B](build.md#track-b-ai-servers-two-node) |
| Day-to-day ops | [operate.md](operate.md#ai-stack-quick-reference) |
| Hardening / compliance | [compliance.md](compliance.md) |
| Why the compose files differ from the originals | [compose-changes.md](compose-changes.md) |

## What it builds

Ansible does **host prep only**: Docker, the NVIDIA GPU stack, Cockpit, and Dockge, STIG-hardened with USG and with the container ports opened.

The AI services themselves are containers. The `ai_compose` role writes one compose stack per service into `/opt/stacks/<stack>/`, where Dockge manages them.

## The two machines

| Machine | Hostname | Job |
|---|---|---|
| System 1 | `dev-ai1` | Front end + chat model — Open WebUI, vLLM, pgvector, Redis |
| System 2 | `dev-ai2` | Helpers — embedding + vision vLLM, Docling/Tika extraction, Grafana, MLflow, oikb |

The hostname picks the role: `dev-ai1` → system1, `dev-ai2` → system2.

## Open in a browser

| What | URL |
|---|---|
| Chat (Open WebUI) | `http://dev-ai1:3000` |
| Grafana | `http://dev-ai2:3001` — first login `admin`/`admin` |
| MLflow | `http://dev-ai2:5000` |
| Doc wiki | `http://dev-ai2:4321` |
| Dockge / Cockpit | `:9001` / `:9090` on each box |

Service ports (vLLM, Docling, Tika) are in the stack tables below. Firewall openings go in `site.yml` per node — see [`site.yml.example`](site.yml.example).

## Compose stacks

One Dockge stack per service. Each gets `/opt/stacks/<stack>/compose.yaml` plus a root-only `.env`, so you start, stop, and edit services individually. **Each vLLM is its own stack.**

All stacks on a node share:

- one external Docker network, **`oi`**, so services reach each other by name across stacks
- the **external named volumes**, so `docker compose down -v` never destroys model weights or databases

### System 1 (`dev-ai1`)

| Stack | Port | Profile | Job |
|---|---|---|---|
| `vllm-gptoss` | `:8000` | default | Chat model (gpt-oss-120B) |
| `vllm-granite` | `:8001` | `granite` | Alternate chat model (Granite-4.1-30B) |
| `pgvector` | internal | default | Accounts, chats, settings + vector index |
| `redis` | internal | default | Websocket coordination + cache |
| `open-webui` | `:3000` | default | The chat website |

### System 2 (`dev-ai2`)

| Stack | Port | Profile | Job |
|---|---|---|---|
| `vllm-embed` | `:8002` | default | RAG embeddings |
| `vllm-vision` | `:8003` | default | Vision / image understanding |
| `docling` | `:5001` | default | Document structure + OCR extraction |
| `tika` | `:9998` | default | Text extraction (other file types) |
| `grafana-otel` | `:3001` `:4317` `:4318` | default | Grafana + OTel monitoring |
| `mlflow` | `:5000` | default | Experiment tracking + model registry (nginx-fronted; MLflow itself publishes nothing) |
| `openwiki-view` | `:4321` | default | Browse the generated doc wiki |
| `oikb` | `:8081` | `oikb` | Knowledge-base sync → System 1 |
| `hfcli` | — | `tools` | Download models into volumes |
| `openwiki` | — | `tools` | Generate a doc wiki from a repo |

Most stacks run a container of the same name. The exceptions, for `docker logs`:

| Stack | Container(s) |
|---|---|
| `vllm-gptoss` | `vllm-server` |
| `docling` | `docling-serve` |
| `grafana-otel` | `open-webui-lgtm` |
| `mlflow` | `mlflow` + `mlflow-db` + `mlflow-proxy` |
| `openwiki-view` | `openwiki-view` + `openwiki-view-proxy` |

### Why some stacks show "n/a"

A service behind a `profiles:` tag is **excluded** from a plain `docker compose up`. Those stacks read **n/a** in Dockge until you invoke them. That is by design, not a failure.

| Profile | Starts with | Stacks |
|---|---|---|
| *(default)* | `it-ai up` | the always-on services |
| `granite` | `it-ai model granite` | `vllm-granite` — only one chat model fits VRAM |
| `oikb` | automatic once an Open WebUI API key is set, else `it-ai oikb` | `oikb` |
| `tools` | `it-ai run <stack> …` | `hfcli`, `openwiki` — run-and-exit, no daemon |

### Controlling the stacks

```bash
it-ai up                     # every default stack, in dependency order
it-ai up open-webui          # just one
it-ai down | stop | restart [STACK]
it-ai status | logs <STACK> | pull [STACK]
it-ai stacks                 # list this node's stacks
it-ai oikb                   # start the opt-in sync
it-ai model gpt-oss | granite | status      # System 1: swap chat model
it-ai run hfcli hf download <repo> --local-dir /granite-embed
it-ai run openwiki openwiki --init          # generate a wiki -> browse at :4321
```

Without `it-ai`, the equivalent from scratch is:

```bash
docker network create oi 2>/dev/null || true
for d in /opt/stacks/*/; do (cd "$d" && docker compose up -d); done
```

**Start order matters.** `open-webui` is a separate stack from `pgvector`/`redis`, so it can't `depends_on` them. `it-ai up` handles the ordering; if you start `open-webui` first anyway, it retries the DB connection until `pgvector` appears.

**Break-glass fallback.** The pre-split single-file compose stays on the box at `/opt/it/docker/docker-compose.consolidated.yaml` — not deployed, and deliberately not named `docker-compose.yaml` so nothing picks it up. It uses the same volumes, so `docker compose -f docker-compose.consolidated.yaml up -d` brings the whole node up as one project with no data move.

## How the two nodes talk

Containers can't resolve the peer's hostname on their own, so cross-node addressing comes from `site.yml` IPs rendered into each stack's `.env`.

- **System 1 → System 2** (`ai_system2_addr`): embeddings `:8002`, vision `:8003`, Docling `:5001`, OTel telemetry `:4317`.
- **System 2 → System 1** (`ai_system1_addr`): oikb calls Open WebUI's API on `:3000` using `ai_oikb_openwebui_api_key`. oikb is opt-in — no key, no oikb.
- **Secrets** live only in the on-box root-only `site.yml` / `.env`. Never in git.

If the hostnames don't resolve between boxes, set the peer's IP in `site.yml`; the build then maps the name in both the host `/etc/hosts` and the containers' `extra_hosts`.

Renumbering out of the lab? Run `sudo it-set-ip` on each box. Details: [operate.md](operate.md).

## Where everything lives

### Files on each box

| Path | What |
|---|---|
| `/opt/stacks/<stack>/compose.yaml` | The per-service stacks (Dockge watches this dir) |
| `/opt/stacks/<stack>/.env` | Per-stack env — secrets + site values, root-only `0600` |
| `/opt/stacks/<stack>/fips_off` | Host-FIPS carve-out; only in `vllm-*` and `docling` |
| `/opt/stacks/switch-model.sh` | Backs `it-ai model …` |
| `/opt/it/docker/` | The dormant consolidated compose + its assets |
| `/etc/stig-build/site.yml` | Per-box overrides — out of git, root-only |
| `/etc/stig-build/*.pw` | Auto-generated DB passwords (pgvector, MLflow) |
| `/var/lib/docker/volumes/<name>/_data` | Where the volumes below physically sit on disk |

### Volumes — System 1

| Volume | Contents | Container path |
|---|---|---|
| `vllm` | gpt-oss-120b weights (~61 GB) | `/gpt120b` |
| `granite32b` | granite-4.1-30b weights | `/granite30b` |
| `encodings` | tiktoken vocab for gpt-oss | `/etc/encodings` |
| `pgvector-data` | Postgres + vector store | `/var/lib/postgresql/data` |
| `open-webui` | App data — users, chats, uploads | `/app/backend/data` |
| `redis-data` | Redis persistence | `/data` |

### Volumes — System 2

| Volume | Contents | Container path |
|---|---|---|
| `granite-embed` | granite-embedding-small-english-r2 weights | `/granite-embed` |
| `granite-vision` | granite-vision-4.1-4b weights | `/granite-vision` |
| `lgtm-data` | Grafana state — dashboards, TSDB | `/data` |
| `mlflow-artifacts` | MLflow artifact store | `/mlflow/artifacts` |
| `postgres_mlflow_data` | MLflow's internal Postgres | `/var/lib/postgresql/data` |
| `openwiki-out` | Generated wiki (markdown pages) | `/work` |

> **Docling has no volume.** Its image ships the OCR/layout/tableformer models baked in (`--artifacts-path`, runtime downloads disabled), so the models travel with the image. Nothing to back up or stage — `it-model-export --images` covers it.

### Model API names

What to send as `model` when calling the OpenAI-compatible endpoints:

| Model | Node | Port | API model name |
|---|---|---|---|
| gpt-oss-120b | S1 | `:8000` | `gpt-oss-120b` |
| granite-4.1-30b | S1 | `:8001` | `granite-4.1-30b` |
| granite-embedding-small-english-r2 | S2 | `:8002` | `granite-embedding-small-english-r2` |
| granite-vision-4.1-4b | S2 | `:8003` | `granite-vision-4.1-4b` |

This is vLLM's `--served-model-name`, **not** the Hugging Face repo path.

### Working with volumes

```bash
sudo docker volume inspect vllm                  # find its Mountpoint
sudo du -sh /var/lib/docker/volumes/vllm/_data   # size on disk
```

Weights arrive either from the opt-in fetch (`ai_model_fetch`) or on demand via `it-ai run hfcli hf download <repo> --local-dir /<mount>`. To carry them to an air-gapped box, use `it-model-export` / `it-model-import` — see [operate.md](operate.md#air-gap-gather-models-on-a-usb-install-on-the-fielded-box-it-model-export--it-model-import).

## Other reference

- **Monitoring.** Grafana ships a pre-provisioned "Open WebUI (OTel)" dashboard — request rate, latency percentiles, error rate, logs — fed from System 1.
- **Admin scripts.** `it-status`, `it-docker`, `it-models`, `it-luks`, `it-restart`, `it-set-ip`, `it-inventory`. Full table: [operate.md](operate.md#admin-scripts-it-).
- **RAG / Documents settings** are seeded from env vars, but they're `PersistentConfig` — env only seeds a *fresh* database, so on an existing box you change them in the UI. See [operate.md](operate.md#open-webui-rag--documents-defaults-and-the-persistentconfig-caveat).
- **IDE clients.** Pointing Continue (VS Code) at the stack is client-side setup: [operate.md](operate.md#connecting-an-ide-continue-vs-code----client-side).

## Software list

IA / DCSA inventory. Versions are pinned in `group_vars/all.yml`, the compose files, and the image Dockerfiles. **S1** = `dev-ai1`, **S2** = `dev-ai2`.

### Operating system & host tooling

| Software/Tool | Version | Publisher | Purpose |
|---|---|---|---|
| Ubuntu | 24.04 LTS (Noble Numbat) | Canonical | Host operating system |
| git | distro | Git project | Version control |
| cifs-utils | distro | Samba team | Mount SMB/CIFS shares |
| net-tools | distro | net-tools project | `ifconfig`/`route`/`netstat` |
| unzip | distro | Info-ZIP | Extract .zip archives |
| PowerShell | 7.4.16 LTS | Microsoft | `pwsh`; required by PowerStrux auditing |
| NVIDIA GPU driver | ≥ 595.71.05 | NVIDIA | GPU driver |
| NVIDIA Container Toolkit | ≥ 1.19.1 | NVIDIA | GPU access inside containers |

### Docker engine & plugins

| Software/Tool | Version | Publisher | Purpose |
|---|---|---|---|
| docker-ce | 29.6.1 (floor 29.5.2) | Docker Inc. | Container engine |
| docker-ce-cli | 29.6.1 | Docker Inc. | Docker CLI |
| containerd.io | 2.2.6 | CNCF / Docker Inc. | Container runtime |
| docker-buildx-plugin | 0.35.0 | Docker Inc. | Image builder |
| docker-compose-plugin | 5.3.1 | Docker Inc. | Compose v2 |
| docker-model-plugin | 1.2.6 | Docker Inc. | Model runner plugin |
| docker-sbx | 0.35.0 | Docker Inc. | Sandbox plugin |

### Container images (pulled)

| Software/Tool | Version | Publisher | Purpose |
|---|---|---|---|
| vllm/vllm-openai | v0.22.1-cu129-ubuntu2404 | vLLM project | LLM inference server (S1, S2) |
| open-webui | v0.10.2 | Open WebUI | Chat web UI (S1) |
| pgvector/pgvector | pg16-trixie | pgvector project | Database + vector store (S1) |
| redis | 7.2.14-bookworm | Redis | Websocket coordination + cache (S1) |
| apache/tika | 3.3.1.0 | Apache Software Foundation | Text/metadata extraction (S2) |
| docling-serve | v1.24.0 (cu128) | IBM / Docling project | Document structure + OCR (S2) |
| grafana/otel-lgtm | 0.29.0 | Grafana Labs | Monitoring / telemetry (S2) |
| nginx | 1.30.4-alpine | nginx / F5 | Base for the wiki viewer front-end (S2) |

### Container images (built on the box)

| Software/Tool | Version | Publisher | Purpose |
|---|---|---|---|
| oikb | latest (base oikb 0.3.6) | Open WebUI (oikb) | Sync data sources into Open WebUI KBs (S2) |
| hfcli | latest (Python 3.12) | Hugging Face (`huggingface_hub`) | Download models into volumes (S2) |
| repomix | latest (Node 22.23.1) | repomix project | Pack a repo into one file for the LLM (S2) |
| mlflow | v3.15.1 (+psycopg2) | MLflow / LF AI & Data | Experiment tracking + registry (S2) |
| openwiki | 0.3.3 (Node 22.23.1) | openwiki project | Generate a doc wiki from a repo (S2) |
| openwiki-view | latest (nginx 1.30.4) | this repo | LAN front-end for the wiki viewer; vendors its JS so it renders offline (S2) |

### AI models (Hugging Face, all Apache-2.0)

| Software/Tool | Version | Publisher | Purpose |
|---|---|---|---|
| gpt-oss-120b | repo main | OpenAI | Primary text generation (S1) |
| granite-4.1-30b | repo main | IBM | Secondary text generation, switchable (S1) |
| granite-embedding-small-english-r2 | repo main | IBM | Text embeddings / RAG (S2) |
| granite-vision-4.1-4b | repo main | IBM | Vision / document understanding (S2) |

> **System 1's chat models are alternates — one at a time.** Both are served across System 1's two 48 GB GPUs (tensor-parallel), and only one fits. Switch with `it-ai model gpt-oss|granite`. See [operate.md](operate.md#switching-system-1s-chat-model-gpt-oss--granite-41-30b).

> **granite-docling-258M is not deployed.** The docling image disables runtime downloads and ships its models baked in, so mounting a volume to add the VLM hides the built-in OCR/layout models and docling crash-loops. Adding it would need a custom docling image with the weights baked in — a future task. Structure and OCR work fine on the baked-in models.

### Tiktoken encodings

| Software/Tool | Version | Publisher | Purpose |
|---|---|---|---|
| `o200k_base.tiktoken`, `cl100k_base.tiktoken` | n/a | OpenAI | Vocab for the gpt-oss harmony tokenizer (S1) |

External sources read by oikb (GitLab, Confluence, S3 — per `site.yml`) are org services, not installed software. Everything above is pinned, reproducible from this baseline, and can be mirrored to an internal registry or staged offline for air-gap.
