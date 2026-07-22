# AI Inference Stack — Architecture & Reference (in-depth)

The detailed design of the two-node, self-hosted AI platform: topology, services, data flows,
ports, storage, model serving, secrets, and the build/deploy pipeline. For a plain-English
overview see [`ai-stack-kb.md`](ai-stack-kb.md); for the operator runbook see
[`ai-setup-guide.md`](ai-setup-guide.md); for compliance see [`dcsa-compliance.md`](dcsa-compliance.md).

## Contents

- [Design goals](#design-goals)
- [Topology](#topology)
- [Service inventory](#service-inventory)
- [Data flows](#data-flows)
- [Networking & ports](#networking--ports)
- [Model serving & switching](#model-serving--switching)
- [Storage & volumes](#storage--volumes)
- [Secrets & configuration](#secrets--configuration)
- [Build & deploy pipeline](#build--deploy-pipeline)
- [Hardening summary](#hardening-summary)

## Design goals

- **On-prem, air-gap-capable.** All inference is local; no cloud/AI calls at runtime. Data stays in the boundary.
- **Reproducible & hardened.** One Ansible baseline (`ubuntu-stig-build`) images every box identically: STIG (USG) + FIPS + LUKS/TPM + Docker hardening.
- **Two roles, one image set.** `dev-ai1` (UI/text-gen) and `dev-ai2` (extraction/embeddings/monitoring/sync); each box's role is auto-picked from its hostname.

## Topology

```
                    users (browser, https)
                            │  :3000
        ┌──────────────── SYSTEM 1 · dev-ai1 (UI / text-gen) ────────────────┐
        │  Open WebUI ─┬─► vLLM  gpt-oss-120B | Granite-4.1-30B  (chat-llm:8000)
        │              ├─► pgvector   (chats + RAG vectors)                   │
        │              └─► redis      (sessions / websockets)                 │
        └───────┬──────────────────────────────────────────────────┬─────────┘
   embeddings :8002 · vision :8003 · Docling :5001 · OTel :4317     │ oikb :3000
                │  (Open WebUI → System 2)                          │ (System 2 → System 1)
                ▼                                                   │
        ┌──────────────── SYSTEM 2 · dev-ai2 (extraction/embed/mon/sync) ─────┐
        │  vLLM embedding (:8002)   vLLM vision (:8003)                       │
        │  Docling (:5001)          Tika (:9998)                             │
        │  LGTM/Grafana (:3001, OTLP :4317/:4318)   oikb (:8081) ◄── GitLab/Confluence/S3
        │  hfcli / repomix (utilities)                                        │
        └─────────────────────────────────────────────────────────────────────┘
```

## Service inventory

| Node | Service | Image | Port(s) | Purpose | Volume |
|------|---------|-------|---------|---------|--------|
| S1 | vllm (gpt-oss) | `vllm/vllm-openai:v0.22.1-cu129-ubuntu2404` | 8000 | Primary chat model (default) | `vllm`, `encodings` |
| S1 | vllm-granite | same | 8001→8000 | Alt chat model (`granite` profile) | `granite32b` |
| S1 | open-webui | `ghcr.io/open-webui/open-webui:v0.10.2` | 3000→8080 | Chat UI | `open-webui` |
| S1 | pgvector | `pgvector/pgvector:pg16-trixie` | 5432 (internal) | DB + vector store | `pgvector-data` |
| S1 | redis | `redis:7.2.14-bookworm` | 6379 (internal) | Sessions / websockets | `redis-data` |
| S2 | vllm-embed | `vllm/vllm-openai:…` | 8002 | RAG embeddings (`--runner pooling`) | `granite-embed` |
| S2 | vllm-vision | `vllm/vllm-openai:…` | 8003 | Vision / doc understanding | `granite-vision` |
| S2 | docling-serve | `ghcr.io/docling-project/docling-serve-cu128:v1.24.0` | 5001 | PDF/office structured extraction | — |
| S2 | tika | `apache/tika:3.3.1.0` | 9998 | Broad text/metadata extraction | — |
| S2 | lgtm | `grafana/otel-lgtm:0.29.0` | 3001, 4317, 4318 | Monitoring (Grafana + OTel) | `lgtm-data` |
| S2 | oikb | `oikb:latest` (built) | 8081→8080 | Sync data sources → Open WebUI KBs | (`.oikb.yaml`) |
| S2 | hfcli / repomix | built (`tools`) | — | Model downloads / repo packing | model vols |

## Data flows

- **Chat** — browser → Open WebUI (S1) → `chat-llm:8000` (the running vLLM). Tool-calling enabled.
- **RAG / documents** — upload → Open WebUI → Docling/Tika (S2) extract text → vLLM embedding (S2) → vectors stored in pgvector (S1) → retrieved at query time.
- **Vision** — image prompt → Open WebUI → vLLM vision (S2) as a second OpenAI endpoint.
- **Knowledge sync** — oikb (S2) pulls from GitLab/Confluence/S3 → Open WebUI KB API (S1 :3000).
- **Monitoring** — Open WebUI (S1) emits OTel traces/metrics/logs → LGTM (S2 :4317) → Grafana (S2 :3001, admins).

## Networking & ports

All services share a user-defined bridge (`oi`) per node; only the ports below are published. USG's ufw is
default-deny inbound; `ai_firewall` opens exactly these (cross-node restricted to the peer's IP).

| Port | Node | Exposed to | Notes |
|------|------|-----------|-------|
| 3000 | S1 | users + oikb (S2) | Open WebUI |
| 8000 / 8001 | S1 | localhost/admin | vLLM debug (chat via `chat-llm` alias internally) |
| 8002 / 8003 | S2 | System 1 | embeddings / vision |
| 5001 / 9998 | S2 | System 1 | Docling / Tika |
| 4317 / 4318 | S2 | System 1 | OTel gRPC / HTTP → LGTM |
| 3001 | S2 | admins | Grafana UI |
| 8081 | S2 | admins | oikb |
| 9443 / 9090 | both | admins | Portainer / Cockpit (management) |

Cross-node addresses come from `ai_system1_addr` / `ai_system2_addr` (default hostnames; IP-overridable in `site.yml`).

## Model serving & switching

vLLM serves **one model per container**, OpenAI-compatible. On **System 1** (2× 48 GB RTX 6000 Ada) gpt-oss-120B
and Granite-4.1-30B **can't co-reside**, so they're **alternates** sharing the `chat-llm` network alias; gpt-oss is
the default, Granite is under the `granite` compose profile. Switch with `switch-model.sh gpt-oss|granite|status`
(stops one, starts the other). Open WebUI points at `http://chat-llm:8000/v1`, so the model just changes in the
dropdown. **System 2** (1 GPU) runs the small embedding + vision models alongside Docling. Models auto-fetch into
their volumes with `ai_model_fetch: true`; gpt-oss also needs the tiktoken/harmony encodings (auto-staged).

## Storage & volumes

Model weights and data live in **external** named volumes (survive `docker compose down -v`), created by
`ai_compose`. S1: `vllm`, `granite32b`, `encodings`, `pgvector-data`, `open-webui`, `redis-data`. S2:
`granite-embed`, `granite-vision`, `lgtm-data`. The whole disk is LUKS-encrypted; `disk_expand` grows the root LV
to the full drive so `/var/lib/docker` doesn't fill.

## Secrets & configuration

- **No secrets in the repo.** The compose files use `${VAR}` refs resolved from a **root-only `.env`** rendered
  per node (`env.j2`). The DB password + Open WebUI signing key are **auto-generated and persisted** on System 1;
  oikb's API key / GitLab token and any pinned values come from **`/etc/stig-build/site.yml`** (out of git).
- **Per-node config** is auto-derived (role from hostname, peer addresses default to hostnames); `site.yml` is
  exceptions-only. See [`site.yml.example`](site.yml.example).
- **Open WebUI** wires chat/vision/embedding/Docling/OTel via env to System 2 (override/blank to configure in the UI).

## Build & deploy pipeline

`ansible-pull` (or `bootstrap.sh PROFILE=ai`) runs `local.yml` roles in order: `disk_expand` → `base_packages` →
shared provisioning (`local_accounts`, `managed_dirs`, `cockpit`, …) → `ai_stack` (Docker + NVIDIA) →
`docker_hardening` → `usg_harden` (STIG + FIPS) → `gpu_fips_module` → `ai_firewall` → **`ai_compose`** (places the
node's compose + `.env`, builds custom images, creates volumes, opt-in model fetch + `up -d`) → `usg_remediate`
(residual fixes + re-audit → report to `/opt/ia`).

## Hardening summary

Host: DISA STIG via USG, FIPS 140-validated crypto, LUKS + TPM2 auto-unlock, ufw default-deny, auditd, DCSA banner.
Containers: CIS-aligned Docker daemon (`docker_hardening`), unprivileged, network-isolated, least-cap where practical.
Full detail + POA&Ms: [`dcsa-compliance.md`](dcsa-compliance.md) and [`docker-compliance.md`](docker-compliance.md).
