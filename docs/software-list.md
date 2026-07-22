# Software List / Bill of Materials — AI Inference Stack

Component inventory for the two-node AI platform (IA / DCSA reference). Versions are
pinned in the build (`group_vars/all.yml`, the compose files, and the image
Dockerfiles). **Licenses are listed for convenience and should be confirmed by the
IA/legal team before authorization.**

Nodes: **S1** = System 1 (`dev-ai1`), **S2** = System 2 (`dev-ai2`).

---

## Hardware

| Item | Detail |
|------|--------|
| Workstation | Dell Precision 7960 × 2 |
| GPU | NVIDIA RTX 6000 (×2 per node) — *VRAM to be confirmed (48 GB Ada vs 96 GB Blackwell); see below* |

## Operating system & host tooling

| Component | Version | License |
|-----------|---------|---------|
| Ubuntu | 24.04 LTS (Noble Numbat) | Various (main/universe) |
| git | distro | GPL-2.0 |
| NVIDIA GPU driver | ≥ 595.71.05 (proprietary) | NVIDIA proprietary EULA |
| NVIDIA Container Toolkit | ≥ 1.19.1 | Apache-2.0 |

## Docker engine & plugins

| Package | Version | License |
|---------|---------|---------|
| docker-ce | 29.6.1 (build floor 29.5.2) | Apache-2.0 |
| docker-ce-cli | 29.6.1 | Apache-2.0 |
| containerd.io | 2.2.6 | Apache-2.0 |
| docker-buildx-plugin | 0.35.0 | Apache-2.0 |
| docker-compose-plugin | 5.3.1 | Apache-2.0 |
| docker-model-plugin | 1.2.6 | Apache-2.0 |
| docker-sbx | 0.35.0 | Apache-2.0 |

## Container images (pulled)

| Image | Version | License | Node | Role |
|-------|---------|---------|------|------|
| `vllm/vllm-openai` | v0.22.1-cu129-ubuntu2404 | Apache-2.0 | S1, S2 | LLM inference server |
| `ghcr.io/open-webui/open-webui` | v0.10.2 | Open WebUI License | S1 | Chat web UI |
| `pgvector/pgvector` | pg16-trixie | PostgreSQL License | S1 | Database + vector store |
| `redis` | 7.2.14-bookworm | BSD-3-Clause | S1 | Sessions / websockets |
| `apache/tika` | 3.3.1.0 | Apache-2.0 | S2 | Document text/metadata extraction |
| `ghcr.io/docling-project/docling-serve-cu128` | v1.24.0 | MIT | S2 | Document structure/OCR extraction |
| `grafana/otel-lgtm` | 0.29.0 | AGPL-3.0 (Grafana) + Apache-2.0 (Loki/Tempo/Mimir/OTel) | S2 | Monitoring / telemetry |

> Note: `docling-serve` (not `docling-server`) is the correct image name.

## Container images (built on the box)

| Image (tag) | Base image | Adds | License | Node | Role |
|-------------|-----------|------|---------|------|------|
| `oikb:latest` | `ghcr.io/open-webui/oikb:0.3.6` (Python 3.12) | git + patched oikb | Open WebUI / oikb project | S2 | Sync data sources → Open WebUI knowledge bases |
| `hfcli:latest` | `python:3.12-bookworm` | `huggingface_hub` | PSF / Apache-2.0 | S1, S2 | Download models/encodings into volumes |
| `repomix:latest` | `node:22.23.1-trixie` | `repomix` | MIT | S2 | Pack a code repo into one file for the LLM |

## AI models (HuggingFace — all Apache-2.0)

| Repo ID | Node | Role |
|---------|------|------|
| `openai/gpt-oss-120b` | S1 | Primary text generation |
| `ibm-granite/granite-4.1-30b` | S1 | Secondary text generation *(if 96 GB GPUs)* |
| `ibm-granite/granite-4.1-8b` | S1 | Secondary text generation *(if 48 GB GPUs — fits alongside gpt-oss)* |
| `ibm-granite/granite-embedding-small-english-r2` | S2 | Text embeddings (RAG) |
| `ibm-granite/granite-vision-4.1-4b` | S2 | Vision / document understanding |

> **System 1 companion model depends on GPU VRAM:** on 48 GB cards gpt-oss-120b + Granite-4.1-**8b**
> co-reside; on 96 GB cards, Granite-4.1-**30b**. Confirm with
> `nvidia-smi --query-gpu=name,memory.total --format=csv` and keep the one that fits.

## Tiktoken encodings (staged for gpt-oss harmony tokenizer)

| File | Source |
|------|--------|
| `o200k_base.tiktoken`, `cl100k_base.tiktoken` | `openaipublic.blob.core.windows.net/encodings` |

## External data sources (read by oikb, per site config)

| Source | Notes |
|--------|-------|
| GitLab / Confluence / S3 storage | Project data synced into Open WebUI knowledge bases; credentials set out-of-band in `site.yml` |

---
*Everything above is pinned/reproducible via the `ubuntu-stig-build` Ansible baseline. Air-gap:
all images and model weights can be mirrored to an internal registry / staged offline.*
