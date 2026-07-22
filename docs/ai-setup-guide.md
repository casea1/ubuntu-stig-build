# AI Stack — Setup & Configuration Guide

Step-by-step for a technician to build and configure the two AI servers from bare metal to a working chat
system. Assumes the `ubuntu-stig-build` repo. For the design see [`ai-architecture.md`](ai-architecture.md);
for subsystem detail see [`../OPERATIONS.md`](../OPERATIONS.md).

## Contents

- [Before you start](#before-you-start)
- [Step 1 — Install Ubuntu 24.04](#step-1--install-ubuntu-2404)
- [Step 2 — Per-node config (site.yml, only if needed)](#step-2--per-node-config-siteyml-only-if-needed)
- [Step 3 — Run the build](#step-3--run-the-build)
- [Step 4 — Fetch models & start the stack](#step-4--fetch-models--start-the-stack)
- [Step 5 — Connect & verify](#step-5--connect--verify)
- [Step 6 — Optional: oikb knowledge sync](#step-6--optional-oikb-knowledge-sync)
- [Switching the System 1 chat model](#switching-the-system-1-chat-model)
- [Collect the compliance report](#collect-the-compliance-report)
- [Troubleshooting](#troubleshooting)

## Before you start

- **Hardware:** 2× Dell Precision 7960. System 1 (`dev-ai1`) = 2× RTX 6000 Ada (48 GB). System 2 (`dev-ai2`) = 1 GPU.
- **Network:** the two boxes must reach each other; know their IPs (e.g. `192.168.1.102` / `.106`). An Ubuntu Pro token (for USG/FIPS). Internet during the build (or an internal mirror).
- **The hostname sets the role:** name the box **`dev-ai1`** or **`dev-ai2`** — everything else auto-derives.

## Step 1 — Install Ubuntu 24.04

Install **Ubuntu 24.04 LTS Server** with the standard **LVM + LUKS full-disk encryption** option. Set the
hostname to `dev-ai1` or `dev-ai2`. Create the operator/admin account (e.g. `austin_case_adm`). Reboot into the OS.

Optional but recommended — patch the base first:
```bash
sudo apt update && sudo apt full-upgrade -y && sudo reboot
```

## Step 2 — Per-node config (site.yml, only if needed)

A correctly-named box usually needs **nothing** here. Add `/etc/stig-build/site.yml` only for exceptions —
IPs (if hostnames don't resolve between the boxes), an existing DB password, oikb secrets, model fetch/deploy:

```bash
sudo install -d -m 0755 /etc/stig-build
sudo tee /etc/stig-build/site.yml >/dev/null <<'EOF'
# --- System 1 example ---
ai_system2_addr: "192.168.1.106"     # if dev-ai2 doesn't resolve by name
ai_pgvector_password: "gelab_24"     # ONLY if reusing an already-initialised DB
ai_model_fetch: true                 # download the models during the build
ai_compose_deploy: true              # start the stack during the build
# firewall: open the ports this node serves (see docs/site.yml.example)
EOF
```
Full reference: [`site.yml.example`](site.yml.example). On **System 2**, set the cross-node firewall + oikb secrets there.

## Step 3 — Run the build

```bash
curl -fsSL https://raw.githubusercontent.com/casea1/ubuntu-stig-build/main/bootstrap.sh | PROFILE=ai bash
```
This: grows the disk, installs Docker + NVIDIA + hardens Docker, attaches Ubuntu Pro and STIG-hardens with
FIPS (**a reboot is required for FIPS** — the build flags it), bakes the node's compose into `/opt/it/docker`,
builds the custom images (System 2), and — if you set the toggles — fetches models and starts the stack.
Watch: `sudo journalctl -u stig-build -f`. **Reboot** when it finishes.

## Step 4 — Fetch models & start the stack

If you didn't set `ai_model_fetch`/`ai_compose_deploy` in `site.yml`, do it now on each box:

```bash
cd /opt/it/docker
# (models auto-fetch on the build if ai_model_fetch: true; otherwise the build placed the empty volumes)
sudo docker compose up -d          # start the node's services
sudo ./switch-model.sh gpt-oss     # System 1 only: load the default chat model
```
gpt-oss-120B is ~200 GB — the first fetch is long. System 2's embedding/vision models are small.

## Step 5 — Connect & verify

- **System 2 first** (System 1 depends on it): `docker compose ps` — embed/vision/docling/tika/lgtm/oikb healthy.
- **System 1:** `docker compose ps` — vllm/open-webui/redis/pgvector healthy; `curl -s http://localhost:8000/v1/models` lists the chat model.
- **Browse:** Open WebUI at `http://dev-ai1:3000`. Create the first (admin) account. The chat model appears in the dropdown; embeddings/vision/Docling are wired to System 2 via env (or set them in **Admin → Settings → Connections/Documents** if you blanked the env).
- **Monitoring:** Grafana at `http://dev-ai2:3001` (admins).

## Step 6 — Optional: oikb knowledge sync

oikb (System 2) syncs data sources into Open WebUI knowledge bases. To enable: create an **API key** in Open
WebUI (Settings → Account), put it + your GitLab URL/token in System 2's `site.yml`
(`ai_oikb_openwebui_api_key`, `ai_oikb_gitlab_url`, `ai_oikb_gitlab_token`), edit `/opt/it/docker/.oikb.yaml`
to map sources → KBs, re-run the build (or `docker compose up -d`), then `docker compose restart oikb`.

## Switching the System 1 chat model

gpt-oss-120B and Granite-4.1-30B are **alternates** (only one fits in VRAM):
```bash
cd /opt/it/docker
sudo ./switch-model.sh granite    # or gpt-oss ; or status
```
Don't run a bare `docker compose up -d` while on Granite — it would also start gpt-oss and OOM the GPUs.

## Collect the compliance report

After the build, the USG/SCAP report is in **`/opt/ia/`** (`usg-report-*.html` + XCCDF `.xml`). Grab it while
online. Re-run on demand: `sudo usg audit --tailoring-file /etc/usg/managed-tailoring.xml`. See OPERATIONS.md →
"Running a USG / SCAP compliance scan."

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Disk fills mid-build | `disk_expand` grows root automatically; if it didn't, check it's LVM (`docs` note). |
| A vLLM container crash-loops on `fips.so` / `FIPS SELFTEST` | Host FIPS vs the image's OpenSSL — the `fips_off` mount handles it; ensure it's present (`grep fips_off docker-compose.yaml`). |
| Model loads but no model in Open WebUI | tiktoken/harmony encodings missing (auto-fetched now) **and/or** add the `http://chat-llm:8000/v1` connection. |
| vLLM `Up` seconds then restarts | still loading (120B takes minutes) or OOM — check `docker logs vllm-server` + `nvidia-smi`. |
| Open WebUI can't reach System 2 (embed/vision/Docling) | set `ai_system2_addr` to dev-ai2's **IP** in `site.yml` (containers use their own DNS, not the host's `/etc/hosts`). With an IP set, the build auto-maps the name in the host `/etc/hosts` **and** the containers' `extra_hosts` — no manual editing. Also confirm the System 2 firewall opened 8002/8003/5001 from System 1. |

More detail for every subsystem: [`../OPERATIONS.md`](../OPERATIONS.md).
