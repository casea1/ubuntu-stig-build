# AI Inference Stack — Quick Reference (KB)

A self-hosted, on-prem AI chat system. Users open a browser, chat with a large
language model, and can ask questions about their own documents. It runs on two
STIG-hardened Ubuntu machines and needs no internet once it's set up.

---

## The two machines

| Machine | Hostname | Job |
|---------|----------|-----|
| **System 1** | `dev-ai1` | The **front end + brain** — the chat website and the language model. |
| **System 2** | `dev-ai2` | The **document reader** — turns PDFs/Office files into clean text for the model. |

```
                 users (browser)
                       │
                       ▼
   ┌──────────── SYSTEM 1 · dev-ai1 ────────────┐
   │  Open WebUI  ──►  vLLM (the AI model)       │
   │      ├─► Postgres (chats + search)          │
   │      ├─► Redis    (logins/live updates)     │
   │      └─► LGTM     (monitoring dashboards)   │
   └───────────────────┬─────────────────────────┘
                       │  reads documents from
                       ▼
   ┌──────────── SYSTEM 2 · dev-ai2 ────────────┐
   │  Docling + Tika  (extract text from files) │
   └─────────────────────────────────────────────┘
```

## What each piece does

| Piece | Where | Plain-English job |
|-------|-------|-------------------|
| **vLLM** | 1 | Runs the AI model (gpt-oss-120B) and answers questions. |
| **Open WebUI** | 1 | The chat website people actually use. |
| **Postgres (pgvector)** | 1 | Stores chats and the searchable index of your documents. |
| **Redis** | 1 | Keeps logins and live updates working smoothly. |
| **LGTM / Grafana** | 1 | Health dashboards and logs for the stack. |
| **oikb** | 1 | Auto-syncs documents from sources (e.g. GitLab) into the AI's knowledge. |
| **Docling** | 2 | High-quality text/table extraction from PDFs and Office files. |
| **Tika** | 2 | Extracts text from a wide range of other file types. |
| **hfcli / repomix** | 1 & 2 | Helper tools (download models; pack a code repo for the AI). |

---

## How to set up a machine (same steps for either)

1. **Install Ubuntu 24.04** using the standard encrypted-disk installer, and
   **name the machine `dev-ai1` or `dev-ai2`.** The name decides its job.
2. **Run the build** (one command, needs internet):
   ```bash
   curl -fsSL https://raw.githubusercontent.com/casea1/ubuntu-stig-build/main/bootstrap.sh | PROFILE=ai bash
   ```
   This hardens the box, installs Docker + the GPU stack, and drops the AI stack
   into **`/opt/it/docker`**. It auto-grows the disk and builds the helper images.
3. **(Optional) per-machine settings** go in `/etc/stig-build/site.yml` — only for
   exceptions (a different hostname, an existing database password, secrets for
   oikb). A correctly-named box usually needs nothing here.
4. **Download the model + start the stack.** Add to that machine's `site.yml`:
   ```yaml
   ai_model_fetch: true      # download the model (~200 GB, one time)
   ai_compose_deploy: true   # start the containers
   ```
   Re-run the build. (Or do it by hand: `cd /opt/it/docker && sudo docker compose up -d`.)
5. **Connect the chat UI to the model** (System 1, one time): Open WebUI →
   **Admin → Settings → Connections** → add an OpenAI connection:
   URL `http://vllm:8000/v1`, key `sk-noauth`. The model then appears in the chat.

---

## Where to go

| Thing | Address |
|-------|---------|
| Chat (Open WebUI) | `http://dev-ai1:3000` |
| Monitoring (Grafana) | `http://dev-ai1:3001` |
| Container manager (Portainer) | `https://dev-ai1:9443` |
| Server console (Cockpit) | `https://dev-ai1:9090` |

## Handy commands (run on the machine)

```bash
cd /opt/it/docker
sudo docker compose ps                 # what's running / healthy
sudo docker compose up -d              # start everything
sudo docker compose restart <name>     # restart one service (e.g. vllm)
sudo docker logs -f vllm-server        # watch the model start up
# download an extra model on demand:
sudo docker compose run --rm hfcli hf download <repo> --local-dir /llm/<name>
```

---

## If something's wrong (things we've already handled in the tool)

- **Disk fills up** — the build now grows the root disk to the full drive automatically.
- **The model container keeps restarting** — on a FIPS machine the model container
  gets a small compatibility file (`fips_off`) so its encryption works; this is
  automatic. The *host* stays fully FIPS-compliant.
- **Model loads but chat shows no model** — the tokenizer files (encodings) are now
  downloaded automatically alongside the model; and remember to add the Open WebUI
  connection (step 5).

> Full detail for admins lives in **[OPERATIONS.md](../OPERATIONS.md)**
> (see "Baking in the AI stack", "Gathering the models", and "FIPS + inference containers").
