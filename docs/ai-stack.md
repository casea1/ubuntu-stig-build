# AI Server Profile (`ai`)

Profile page for the two-node, self-hosted AI stack. Overview, key endpoints, and the software list. Build steps are [build.md Track B](build.md#track-b-ai-servers-two-node); day-to-day ops and the deep reference are in [operate.md](operate.md#ai-stack-quick-reference); hardening/compliance is [compliance.md](compliance.md).

## What it builds

`ansible` does host prep only: Docker + the NVIDIA GPU stack + Cockpit + Portainer, STIG-hardened with USG, with the container ports opened. You deploy the AI tools from prebuilt images + compose files (baked into `/opt/it/docker` by `ai_compose`).

## The two machines

| Machine | Hostname | Job |
|---|---|---|
| System 1 | `dev-ai1` | Front end + chat model. Open WebUI + vLLM + Postgres/pgvector + Redis. |
| System 2 | `dev-ai2` | Helpers. Embedding + vision vLLM, Docling + Tika extraction, LGTM/Grafana, oikb sync. |

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
| Portainer / Cockpit | `:9443` / `:9090` | each box |

Firewall openings for these ports go in `site.yml` per node. See [`site.yml.example`](site.yml.example).

## How the two nodes talk (interconnect)

Containers don't resolve the peer's hostname, so cross-node addressing goes through `site.yml` IPs + the rendered root-only `.env`:

- **System 1 → System 2:** Open WebUI reaches embeddings (`:8002`), vision (`:8003`), Docling (`:5001`), and ships OTel telemetry to LGTM (`:4317`) at **`ai_system2_addr`**. Set it to dev-ai2's IP in `site.yml` if the name doesn't resolve; the build then maps the name in both the host `/etc/hosts` and the containers' `extra_hosts` automatically.
- **System 2 → System 1:** oikb reaches Open WebUI's API (`:3000`) at **`ai_system1_addr`**, authenticating with **`ai_oikb_openwebui_api_key`** (an API key you create in the Open WebUI UI). oikb is **opt-in** — it only starts when that key is set (see [build.md Step 6](build.md#step-6-optional-oikb-knowledge-sync)); no GitLab is required.
- **Secrets** (`ai_oikb_openwebui_api_key`, GitLab token, DB password) live only in the on-box root-only `site.yml`/`.env`, never in git.

Full walkthrough: [build.md — Track B](build.md#track-b-ai-servers-two-node) and [operate.md — Cross-node wiring](operate.md). Per-node reference: [`site.yml.example`](site.yml.example).

**Monitoring.** Grafana (`http://dev-ai2:3001`, first login `admin`/`admin`) ships a pre-provisioned **"Open WebUI (OTel)"** dashboard: request rate, latency percentiles, error rate, and logs, fed by the OTel export from System 1.

**RAG / Documents config + IDE clients.** The Open WebUI Documents panel (Docling extraction, Granite embeddings, hybrid search, chunk 2048/200) is seeded from env vars in System 1's compose — with the caveat that they're `PersistentConfig` (env seeds a fresh DB only; change in the UI on an existing box). Pointing the Continue VS Code extension at the stack (via Open WebUI's API or direct to vLLM) is a client-side setup. Both are documented in [operate.md — Open WebUI RAG defaults](operate.md#open-webui-rag--documents-defaults-and-the-persistentconfig-caveat) and [Connecting an IDE (Continue)](operate.md#connecting-an-ide-continue-vs-code----client-side).

## Software list

Software inventory for the two-node AI platform (IA / DCSA reference). Versions are pinned in the build (`group_vars/all.yml`, the compose files, the image Dockerfiles). Nodes: **S1** = System 1 (`dev-ai1`), **S2** = System 2 (`dev-ai2`).

### Operating system & host tooling

| Software/Tool | Version | Publisher | Purpose |
|---|---|---|---|
| Ubuntu | 24.04 LTS (Noble Numbat) | Canonical | Host operating system |
| git | distro | Git project | Version control |
| cifs-utils | distro | Samba team | Mount SMB/CIFS shares |
| net-tools | distro | net-tools project | `ifconfig`/`route`/`netstat` network admin |
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
| redis | 7.2.14-bookworm | Redis | Sessions / websockets (S1) |
| apache/tika | 3.3.1.0 | Apache Software Foundation | Document text/metadata extraction (S2) |
| docling-serve | v1.24.0 (cu128) | IBM / Docling project | Document structure/OCR extraction (S2) |
| grafana/otel-lgtm | 0.29.0 | Grafana Labs | Monitoring / telemetry (S2) |

### Container images (built on the box)

| Software/Tool | Version | Publisher | Purpose |
|---|---|---|---|
| oikb | latest (base oikb 0.3.6) | Open WebUI (oikb) | Sync data sources into Open WebUI KBs (S2) |
| hfcli | latest (Python 3.12) | Hugging Face (`huggingface_hub`) | Download models/encodings into volumes (S1, S2) |
| repomix | latest (Node 22.23.1) | repomix project | Pack a code repo into one file for the LLM (S2) |

### AI models (Hugging Face, all Apache-2.0)

| Software/Tool | Version | Publisher | Purpose |
|---|---|---|---|
| gpt-oss-120b | repo main | OpenAI | Primary text generation (S1) |
| granite-4.1-30b | repo main | IBM | Secondary text generation, 96 GB GPUs (S1) |
| granite-4.1-8b | repo main | IBM | Secondary text generation, 48 GB GPUs (S1) |
| granite-embedding-small-english-r2 | repo main | IBM | Text embeddings / RAG (S2) |
| granite-vision-4.1-4b | repo main | IBM | Vision / document understanding (S2) |

> **System 1 companion model depends on GPU VRAM:** 48 GB cards run gpt-oss-120b + Granite-4.1-**8b**; 96 GB cards run Granite-4.1-**30b**. Check `nvidia-smi --query-gpu=name,memory.total --format=csv` and keep the one that fits.

### Tiktoken encodings (gpt-oss harmony tokenizer)

| Software/Tool | Version | Publisher | Purpose |
|---|---|---|---|
| o200k_base.tiktoken, cl100k_base.tiktoken | n/a | OpenAI | Tokenizer vocab for the gpt-oss harmony tokenizer (S1) |

External data sources read by oikb (GitLab / Confluence / S3, per `site.yml`) are org services, not installed software. Everything above is pinned and reproducible via the `ubuntu-stig-build` baseline, and can be mirrored to an internal registry / staged offline for air-gap.
