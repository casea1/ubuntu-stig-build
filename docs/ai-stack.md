# AI Server Profile (`ai`)

Profile page for the two-node, self-hosted AI stack. Overview, key endpoints, and the software list. Build steps are [build.md Track B](build.md#track-b-ai-servers-two-node); day-to-day ops and the deep reference are in [operate.md](operate.md#ai-stack-quick-reference); hardening/compliance is [compliance.md](compliance.md).

## What it builds

`ansible` does host prep only: Docker + the NVIDIA GPU stack + Cockpit + Dockge, STIG-hardened with USG, with the container ports opened. You deploy the AI tools from prebuilt images + per-service compose stacks (baked into `/opt/stacks/<stack>/` by `ai_compose`, managed in Dockge).

## The two machines

| Machine | Hostname | Job |
|---|---|---|
| System 1 | `dev-ai1` | Front end + chat model. Open WebUI + vLLM + Postgres/pgvector + Redis. |
| System 2 | `dev-ai2` | Helpers. Embedding + vision vLLM, Docling + Tika extraction, LGTM/Grafana, MLflow tracking/registry, oikb sync. |

The hostname sets the role (`dev-ai1` -> system1, `dev-ai2` -> system2). Full architecture diagram, per-service table, and handy commands: [operate.md -> AI stack quick reference](operate.md#ai-stack-quick-reference).

## Key endpoints

| Service | URL / port | Node |
|---|---|---|
| Chat (Open WebUI) | `http://dev-ai1:3000` | S1 |
| Chat model (vLLM) | `:8000` | S1 |
| Embeddings (vLLM) | `:8002` | S2 |
| Vision (vLLM) | `:8003` | S2 |
| Docling | `:5001` | S2 |
| Tika | `:9998` | S2 |
| Grafana | `http://dev-ai2:3001` | S2 |
| MLflow | `http://dev-ai2:5000` | S2 |
| Dockge / Cockpit | `:9001` / `:9090` | each box |

Firewall openings for these ports go in `site.yml` per node. See [`site.yml.example`](site.yml.example).

## How the two nodes talk (interconnect)

Containers don't resolve the peer's hostname, so cross-node addressing goes through `site.yml` IPs + the rendered root-only `.env`:

- **System 1 → System 2:** Open WebUI reaches embeddings (`:8002`), vision (`:8003`), Docling (`:5001`), and ships OTel telemetry to LGTM (`:4317`) at **`ai_system2_addr`**. Set it to dev-ai2's IP in `site.yml` if the name doesn't resolve; the build then maps the name in both the host `/etc/hosts` and the containers' `extra_hosts` automatically.
- **System 2 → System 1:** oikb reaches Open WebUI's API (`:3000`) at **`ai_system1_addr`**, authenticating with **`ai_oikb_openwebui_api_key`** (an API key you create in the Open WebUI UI). oikb is **opt-in** — it only starts when that key is set (see [build.md Step 6](build.md#step-6-optional-oikb-knowledge-sync)); no GitLab is required.
- **Secrets** (`ai_oikb_openwebui_api_key`, GitLab token, DB password) live only in the on-box root-only `site.yml`/`.env`, never in git.

Full walkthrough: [build.md — Track B](build.md#track-b-ai-servers-two-node) and [operate.md — Cross-node wiring](operate.md). Per-node reference: [`site.yml.example`](site.yml.example).

**Monitoring.** Grafana (`http://dev-ai2:3001`, first login `admin`/`admin`) ships a pre-provisioned **"Open WebUI (OTel)"** dashboard: request rate, latency percentiles, error rate, and logs, fed by the OTel export from System 1.

**Admin scripts.** Short `it-*` commands (self-elevating) cover day-to-day ops: `it-status` (rollup), `it-docker`, `it-models`, `it-luks` / `it-luks-rebind`, `it-restart`, `it-set-ip` (renumber out of the lab), `it-inventory`. Full table: [operate.md — Admin scripts](operate.md#admin-scripts-it-).

**RAG / Documents config + IDE clients.** The Open WebUI Documents panel (Docling extraction, Granite embeddings, hybrid search, chunk 2048/200) is seeded from env vars in System 1's compose — with the caveat that they're `PersistentConfig` (env seeds a fresh DB only; change in the UI on an existing box). Pointing the Continue VS Code extension at the stack (via Open WebUI's API or direct to vLLM) is a client-side setup. Both are documented in [operate.md — Open WebUI RAG defaults](operate.md#open-webui-rag--documents-defaults-and-the-persistentconfig-caveat) and [Connecting an IDE (Continue)](operate.md#connecting-an-ide-continue-vs-code----client-side).

## Compose stacks — what runs, and how

The stack is split into **one Dockge stack per service**. The `ai_compose` role writes each service's compose to **`/opt/stacks/<stack>/compose.yaml`** with a root-only `.env` (secrets/site values) beside it, so each shows up as its own start/stop/edit-able stack in Dockge. **Each vLLM is its own stack.** All stacks on a node share one **external Docker network `oi`** (created by the role) and the **external named volumes**, so services resolve each other by name across stacks (`pgvector`, `redis`, `chat-llm`, `dev-ai1`/`dev-ai2`). Named volumes are pre-created by the role; model-weight volumes are populated *before* first `up`.

> The pre-split single-file compose is kept as a **dormant fallback** at `/opt/it/docker/docker-compose.consolidated.yaml` (not deployed, not named `docker-compose.yaml`, so nothing auto-picks it up). It uses the same external volumes, so a break-glass `cd /opt/it/docker && docker compose -f docker-compose.consolidated.yaml up -d` brings the whole node up as one project with no data move.

**Compose profiles decide what auto-starts.** Within a stack, a service tagged with `profiles:` is **excluded** from a plain `docker compose up` — it only runs when that profile is active. So the alternate/opt-in/on-demand stacks read **n/a** (nothing running) until you invoke them; that's by design, not a failure.

| Profile | Starts with | Stack(s) | Notes |
|---|---|---|---|
| *(default)* | `docker compose up -d` (per stack) | the daemon stacks below | the always-on services |
| `granite` (S1) | `it-ai model granite` (`switch-model.sh`) | `vllm-granite` | the alternate chat model; only one chat model fits VRAM |
| `oikb` (S2) | auto when an Open WebUI API key is set, else `it-ai oikb` | `oikb` | opt-in knowledge-base sync |
| `tools` (S2) | `it-ai run <stack> …` | `hfcli`, `openwiki` | **on-demand utilities** — no daemon process; run-and-exit |

### System 1 (`dev-ai1`) — stacks under `/opt/stacks/`
| Stack | Service | Port | Profile | Job |
|---|---|---|---|---|
| `vllm-gptoss` | `vllm` | `:8000` | default | Chat model (gpt-oss-120B) |
| `vllm-granite` | `vllm-granite` | `:8001` | `granite` | Alternate chat model (Granite-4.1-30B); via `it-ai model` |
| `pgvector` | `pgvector` | internal | default | Accounts/chats/settings + vector index |
| `redis` | `redis` | internal | default | Websocket coordination + cache |
| `open-webui` | `open-webui` | `:3000` | default | The chat website |

### System 2 (`dev-ai2`) — stacks under `/opt/stacks/`
| Stack | Service | Port | Profile | Job |
|---|---|---|---|---|
| `vllm-embed` | `vllm-embed` | `:8002` | default | RAG embeddings |
| `vllm-vision` | `vllm-vision` | `:8003` | default | Vision / image understanding |
| `docling` | `docling-serve` | `:5001` | default | Document structure/OCR extraction. Uses the image's baked-in models (`--artifacts-path`, runtime downloads disabled); no model volume is mounted. The granite-docling VLM is **not** wired in — it would need a custom docling image with the weights baked in (see note below). |
| `tika` | `tika` | `:9998` | default | Text extraction (other file types) |
| `grafana-otel` | `lgtm` | `:3001` `:4317` `:4318` | default | Grafana + OTel monitoring |
| `mlflow` | `mlflow-db` + `mlflow` | `:5000` | default | Experiment tracking + model registry (+ its Postgres) |
| `oikb` | `oikb` | `:8081` | `oikb` | Knowledge-base sync → System 1's Open WebUI |
| `hfcli` | `hfcli` | — | `tools` | Download models/encodings into volumes |
| `openwiki` | `openwiki` | — | `tools` | **Generate** a documentation wiki from a repo (writes to `openwiki-out`) |
| `openwiki-view` | `openwiki-view` + `openwiki-view-proxy` | `:4321` | default | **Browse** the generated wiki on the LAN (`openwiki visualize` + nginx; viewer libraries vendored, so it renders air-gapped) |

> **Cross-stack startup:** `open-webui` no longer `depends_on` `pgvector`/`redis` (they're separate stacks now), so bring the DB/cache up first. `it-ai up` and the recreate loop below start the stacks in a sane order; if you start `open-webui` alone before `pgvector`, it simply retries the DB connection until `pgvector` is up.

### Recreate / control the stacks
```bash
# Recreate every stack on a node (plain docker; from scratch):
docker network create oi 2>/dev/null || true
for d in /opt/stacks/*/; do (cd "$d" && docker compose up -d); done

# ...or the it-ai shortcut (from anywhere, no cd — this is the easy button):
it-ai up                       # bring every default stack up (right order)
it-ai up open-webui            # just one stack
it-ai down | stop | restart [STACK]
it-ai status | logs <STACK> | pull [STACK]
it-ai stacks                   # list the stacks on this node
it-ai oikb                     # start the opt-in oikb sync
it-ai model gpt-oss | granite | status   # System 1: swap the chat model
it-ai run hfcli hf download <repo> --local-dir /granite-embed   # on-demand tool
it-ai run openwiki openwiki --init       # on-demand: build a doc wiki
#   ...then browse it at http://<dev-ai2>:4321  (openwiki-view stack, always on)
```
The `tools` stacks (`hfcli`, `openwiki`) always read **n/a** in Dockge — they hold no long-running container; that is expected. See [operate.md — Admin scripts](operate.md#admin-scripts-it-).

## Where everything lives (paths, volumes & models)

A single map of what's stored where — useful for backups, disk sizing, moving weights, and air-gap staging.

### Filesystem layout (on each box)

| Path | What | Notes |
|---|---|---|
| `/opt/stacks/<stack>/compose.yaml` | The per-service Dockge stacks (one dir per service) | Dockge watches `/opt/stacks`; edit/start/stop per stack |
| `/opt/stacks/<stack>/.env` | Per-stack env (secrets + site values) | Root-only `0600`; same node-aware `.env` in every stack dir |
| `/opt/stacks/<stack>/fips_off` | Host-FIPS carve-out file (content `0`) | Only in stacks that bind-mount it (`vllm-*`, `docling`) |
| `/opt/stacks/switch-model.sh` | System 1 chat-model switch script | Backs `it-ai model …` |
| `/opt/it/docker/docker-compose.consolidated.yaml` | Dormant single-file fallback (whole node in one project) | Break-glass only; shares the same volumes |
| `/opt/it/docker/{.env,fips_off,grafana/,.oikb.yaml}` | Assets for the fallback compose | Mirrors the per-stack assets |
| `/etc/stig-build/site.yml` | Per-box overrides (out of git, root-only) | IPs, oikb keys, pinned DB password |
| `/etc/stig-build/pgvector.pw` | Auto-generated pgvector password (System 1) | `0600` root; generated on first run |
| `/etc/stig-build/mlflow_db.pw` | Auto-generated MLflow DB password (System 2) | `0600` root; generated on first run |
| `/var/lib/docker/volumes/<name>/_data` | Physical location of every named volume below | Default `local` driver; this is where the model weights + DBs actually sit on disk |

### Named volumes — System 1 (`dev-ai1`)

| Volume | Contents | Mounted in | Container path |
|---|---|---|---|
| `vllm` | **gpt-oss-120b** weights (default chat model, ~61 GB) | `vllm-gptoss` | `/gpt120b` |
| `granite32b` | **granite-4.1-30b** weights (switchable alternate) | `vllm-granite` | `/granite30b` |
| `encodings` | tiktoken vocab (`o200k_base`, `cl100k_base`) for gpt-oss | `vllm-gptoss` | `/etc/encodings` |
| `pgvector-data` | Postgres + pgvector data (RAG vector store) | `pgvector` | `/var/lib/postgresql/data` |
| `open-webui` | Open WebUI app data (users, chats, uploads, settings) | `open-webui` | `/app/backend/data` |
| `redis-data` | Redis persistence (websocket/cache coordination) | `redis` | `/data` |

### Named volumes — System 2 (`dev-ai2`)

| Volume | Contents | Mounted in | Container path |
|---|---|---|---|
| `granite-embed` | **granite-embedding-small-english-r2** weights | `vllm-embed`, `hfcli` | `/granite-embed` |
| `granite-vision` | **granite-vision-4.1-4b** weights | `vllm-vision`, `hfcli` | `/granite-vision` |
| `lgtm-data` | Grafana/LGTM state (dashboards, TSDB) | `grafana-otel` | `/data` |
| `mlflow-artifacts` | MLflow artifact store | `mlflow` | `/mlflow/artifacts` |
| `postgres_mlflow_data` | MLflow's internal Postgres data | `mlflow` (`mlflow-db`) | `/var/lib/postgresql/data` |
| `openwiki-out` | OpenWiki generated wiki (markdown pages) | `openwiki`, `openwiki-view` | `/work` |

> **docling has no named volume.** The `docling-serve` image ships its OCR/layout/tableformer models **baked in** (`--artifacts-path`, runtime downloads disabled), so the models live inside the image at `/opt/app-root/src/.cache/docling/models` and travel **with the image** — nothing to back up or stage separately (bring it across air-gap with `it-model-export --images`).

### Model → volume → served-name (vLLM services)

| Model | Volume | Container path | vLLM `--served-model-name` | Host port |
|---|---|---|---|---|
| gpt-oss-120b | `vllm` | `/gpt120b` | `gpt-oss-120b` | `:8000` (S1) |
| granite-4.1-30b | `granite32b` | `/granite30b` | `granite-4.1-30b` | `:8001` (S1, alternate) |
| granite-embedding-small-english-r2 | `granite-embed` | `/granite-embed` | `granite-embedding-small-english-r2` | `:8002` (S2) |
| granite-vision-4.1-4b | `granite-vision` | `/granite-vision` | `granite-vision-4.1-4b` | `:8003` (S2) |

Weights are downloaded into these volumes by the opt-in fetch (`ai_model_fetch`) or on demand with `hfcli` (`it-ai run hfcli hf download <repo> --local-dir /<mount>`). Because the volumes are **external** (declared `external: true`), `docker compose down -v` never deletes them — the weights and DBs survive teardown/recreate. To inspect or copy a volume on the box:

```bash
sudo docker volume inspect vllm                       # shows Mountpoint (…/vllm/_data)
sudo du -sh /var/lib/docker/volumes/vllm/_data        # size on disk
sudo ls /var/lib/docker/volumes/granite32b/_data      # peek at the weights
```

For carrying weights to an air-gapped box, use `it-model-export` / `it-model-import` (they read/write these same volumes) — see [operate.md — Air-gap model transfer](operate.md#air-gap-gather-models-on-a-usb-install-on-the-fielded-box-it-model-export--it-model-import).

## Software list

Software inventory for the two-node AI platform (IA / DCSA reference). Versions are pinned in the build (`group_vars/all.yml`, the compose files, the image Dockerfiles). Nodes: **S1** = System 1 (`dev-ai1`), **S2** = System 2 (`dev-ai2`).

### Operating system & host tooling

| Software/Tool | Version | Publisher | Purpose |
|---|---|---|---|
| Ubuntu | 24.04 LTS (Noble Numbat) | Canonical | Host operating system |
| git | distro | Git project | Version control |
| cifs-utils | distro | Samba team | Mount SMB/CIFS shares |
| net-tools | distro | net-tools project | `ifconfig`/`route`/`netstat` network admin |
| unzip | distro | Info-ZIP | Extract .zip archives |
| PowerShell | 7.4.16 LTS | Microsoft | `pwsh`; required by the PowerStrux auditing tool |
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
| redis | 7.2.14-bookworm | Redis | Websocket coordination + cache across the uvicorn workers (S1) |
| apache/tika | 3.3.1.0 | Apache Software Foundation | Document text/metadata extraction (S2) |
| docling-serve | v1.24.0 (cu128) | IBM / Docling project | Document structure/OCR extraction (S2) |
| grafana/otel-lgtm | 0.29.0 | Grafana Labs | Monitoring / telemetry (S2) |

### Container images (built on the box)

| Software/Tool | Version | Publisher | Purpose |
|---|---|---|---|
| oikb | latest (base oikb 0.3.6) | Open WebUI (oikb) | Sync data sources into Open WebUI KBs (S2) |
| hfcli | latest (Python 3.12) | Hugging Face (`huggingface_hub`) | Download models/encodings into volumes (S2) |
| repomix | latest (Node 22.23.1) | repomix project | Pack a code repo into one file for the LLM (S2) |
| mlflow | v3.15.1 (+psycopg2) | MLflow / LF AI & Data | Experiment tracking + model registry, UI `:5000`; Postgres-backed (S2) |
| openwiki | latest (Node 22.23.1) | openwiki project | Generate a documentation wiki from a repo (S2 utility) |

### AI models (Hugging Face, all Apache-2.0)

| Software/Tool | Version | Publisher | Purpose |
|---|---|---|---|
| gpt-oss-120b | repo main | OpenAI | Primary text generation (S1) |
| granite-4.1-30b | repo main | IBM | Secondary text generation, switchable alternate (S1) |
| granite-embedding-small-english-r2 | repo main | IBM | Text embeddings / RAG (S2) |
| granite-vision-4.1-4b | repo main | IBM | Vision / document understanding (S2) |

> **granite-docling-258M (docling VLM) is not deployed.** The `-cu128` docling
> image runs with `--artifacts-path` (runtime downloads disabled) and ships its
> models baked in; mounting an external volume to add granite-docling hides the
> image's built-in OCR/layout models and docling crash-loops. Adding the VLM
> would require building a custom docling image with the weights baked in — a
> future task. docling runs fine on its baked-in models for structure/OCR.

> **System 1 chat models are alternates, one at a time:** gpt-oss-120B (default) or Granite-4.1-30B, served across System 1's two 48 GB GPUs (tensor-parallel). Switch with `it-ai model gpt-oss|granite`. See [operate.md](operate.md#switching-system-1s-chat-model-gpt-oss--granite-41-30b).

### Tiktoken encodings (gpt-oss harmony tokenizer)

| Software/Tool | Version | Publisher | Purpose |
|---|---|---|---|
| o200k_base.tiktoken, cl100k_base.tiktoken | n/a | OpenAI | Tokenizer vocab for the gpt-oss harmony tokenizer (S1) |

External data sources read by oikb (GitLab / Confluence / S3, per `site.yml`) are org services, not installed software. Everything above is pinned and reproducible via the `ubuntu-stig-build` baseline, and can be mirrored to an internal registry / staged offline for air-gap.
