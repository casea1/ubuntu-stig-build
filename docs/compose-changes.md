# Compose changes from the original hand-written stacks

Why the compose files in this repo differ from the hand-written ones the stack started as (a `docker/` folder with one directory per service). Useful when something looks unfamiliar, when reconciling a box that still runs an older file, or when reviewing what the baseline actually changed.

Everything below is a diff against those originals, checked field by field.

## Cross-cutting changes

These apply to nearly every file and account for most of the difference.

### 1. Secrets left the compose files

The originals carried live credentials in plain text:

| Where | Original | Now |
|---|---|---|
| pgvector / Open WebUI DB | a literal password | `${POSTGRES_PASSWORD:?set in .env}` |
| Open WebUI session key | a literal 64-char key | `${WEBUI_SECRET_KEY:?set in .env}` |
| MLflow DB | a literal password | `${MLFLOW_DB_PASSWORD}` |

These files live in a public git repo, so a committed password is published permanently. Passwords are now **auto-generated on first run** and persisted root-only under `/etc/stig-build/*.pw`, then rendered into each stack's `.env` (mode `0600`). Nothing to type, nothing to leak. The `:?set in .env` form makes compose **fail loudly** if the value is missing rather than starting with an empty password.

> **If you are migrating a box that ran the originals:** Postgres only applies `POSTGRES_PASSWORD` when it initialises an *empty* volume. An existing volume keeps the **original** password, and the new config will fail to authenticate. Either pin the old password in `site.yml` (`ai_pgvector_password`) or reinitialise the volume.

### 2. Hardcoded addresses became variables

The originals pointed at one specific lab: `http://192.168.50.33:4317` for OTel, `https://oi.atolab.cui` for CORS. Those are now `${SYSTEM2_ADDR}` and `${OI_ORIGIN:-*}`, rendered per box from `site.yml`. The same image can be deployed anywhere, and `it-set-ip` can renumber a box without editing compose files.

### 3. One stack per service

The originals were already one directory per service, but each declared its own network and was started independently. Now every stack joins one **external** network (`oi`) created by ansible, and all named volumes are **external** too. Consequences worth knowing:

- Services resolve each other by name across stacks.
- `docker compose down -v` **cannot** delete model weights or databases — external volumes are outside compose's lifecycle. This was the main motivation.
- Volumes are pre-created by ansible, so a stack never silently creates an empty one and starts against it.

### 4. Restart policies and healthchecks

Almost none of the originals set `restart:`. Every long-running service now has `restart: unless-stopped`, so the stack survives a reboot. `pgvector`, `redis`, and `mlflow-db` gained healthchecks so dependent services can wait for readiness rather than crash-looping.

### 5. Explicit networks

`docling`, `tika`, `grafana-otel`, `oikb`, and `hfcli` had **no** `networks:` key, so they landed on their compose project's default network and could not be reached by name from other stacks. All are now explicitly on `oi`.

### 6. On-demand services moved behind profiles

`oikb` and `hfcli` had no `profiles:`, so a plain `up` would start them. `hfcli` is a run-and-exit tool and `oikb` crash-loops without an API key. They are now behind the `tools` and `oikb` profiles, which is why they read **n/a** in Dockge until invoked — by design, not a fault.

### 7. The host FIPS carve-out

New, and not in the originals at all. The host runs a FIPS kernel; the vLLM and Docling images ship no FIPS OpenSSL provider, so they abort at startup. Those services bind-mount a `fips_off` file over `/proc/sys/crypto/fips_enabled`. The **host stays FIPS** — only these containers see the mask.

## Per-service changes

### vllm → `vllm-gptoss` (+ `vllm-granite`)

| Change | Why |
|---|---|
| `--served-model-name=gpt-oss-120b` | Without it vLLM reports the model as its filesystem path (`/gpt120b`). Clients now use a stable name that doesn't change when the weights move. |
| `--override-generation-config=…` | Sets temperature/top_p/repetition_penalty at the server, so every client gets sane sampling defaults. |
| `chat-llm` network alias | Open WebUI points at `chat-llm`, so switching gpt-oss ↔ Granite needs no UI or config change. |
| `fips_off` mount | See above. |
| Granite split into its own stack | Only one chat model fits VRAM; separate stacks make the swap explicit (`it-ai model …`). |

### open-webui

Beyond the secrets and address changes, the original configured **no AI at all** — it had the database, Redis, OTel and worker tuning, but nothing pointing at a model. Added here:

- **Chat models** — local vLLM via `chat-llm`, plus vision on System 2
- **RAG embeddings** — Granite embedding on System 2 (`:8002`)
- **Extraction** — Docling on System 2 (`:5001`), Tika available as a fallback
- **RAG retrieval/chunking** — hybrid search, top-k, chunk 2048/200
- **`AUDIT_LOG_LEVEL`** — user-activity audit trail for the AU controls; `METADATA` logs no prompt text, so the log stays unclassified
- **`extra_hosts`** — lets the container resolve `dev-ai2` when the peer is configured by IP

> The RAG settings are Open WebUI `PersistentConfig`: environment seeds a **fresh** database only. On a box whose DB already exists, the stored value wins and these are ignored — change them in the UI.

### pgvector / redis

Password moved to `.env`; both gained a healthcheck and a restart policy. **Redis's hardening was kept as written** — `cap_drop: ALL` with only `SETGID`/`SETUID`/`DAC_OVERRIDE` added back, plus the log-size caps. That was good and was carried over unchanged.

### docling

Added `networks`, `restart`, and the `fips_off` mount. Later added `DOCLING_SERVE_ENABLE_REMOTE_SERVICES` and `DOCLING_SERVE_ALLOW_CUSTOM_VLM_CONFIG` to allow a network-hosted VLM. No model volume is mounted, deliberately — see [ai-stack.md](ai-stack.md).

### grafana-otel

Added the two bind mounts that pre-provision the "Open WebUI (OTel)" dashboard, so Grafana comes up with the dashboard already loaded instead of requiring a manual import.

### oikb

Gained `container_name`, `extra_hosts` (cross-node name resolution), `networks`, and the `oikb` profile. Its env vars gained defaults (`${OPEN_WEBUI_URL:-http://dev-ai1:3000}`, `${OPEN_WEBUI_API_KEY:-}`) so the stack is valid on a box that has never configured oikb, plus the optional GitLab source variables.

### mlflow

| Change | Why |
|---|---|
| Password → `.env` | As above. |
| DB `mlflow_database` → `mlflow`, host `mlflow_postgres` → `mlflow-db` | Consistent naming with the rest of the stack. **Migration-relevant** if an old volume exists. |
| Removed the `environment:` block | `BACKEND_STORE_URI` / `ARTIFACT_ROOT` were unused — the `command:` passes both as flags, and they win. The env copy also contained a typo (`@:mlflow_postgres`, stray colon) that would have failed had anything read it. |
| `nginx` removed, then **restored** | See below. |

## The one thing that was wrongly removed

The original mlflow compose ran an **nginx** in front of MLflow: nginx published `5000`, and MLflow itself published nothing. During consolidation MLflow was given the host port directly and the proxy was dropped.

That was a real regression. MLflow runs with `--disable-security-middleware` and **no authentication**, and ufw cannot protect it: Docker publishes container ports using its own DNAT rules, which are evaluated *before* ufw's INPUT chain. Confirmed on dev-ai2 — port 5000 was absent from ufw entirely and still reachable from the LAN.

The proxy is back (`mlflow-proxy`), MLflow publishes nothing again, and nginx enforces a source allow-list from `ai_mlflow_allow_cidrs`. One caveat: the original's `nginx.conf` was **not** in the archive it came from, so the current config is newly written — what it does is inferred from the architecture, not restored from the original.

> **This is not fixed for the other services.** Open WebUI `:3000`, docling `:5001`, tika `:9998`, Grafana `:3001`, the vLLM ports, and the wiki's `:4321` rules are all still outside ufw's control for the same reason. The systemic fix is `DOCKER-USER` rules in the `ai_firewall` role.

## Services with no original

These did not exist in the hand-written stacks and were added by this baseline: `vllm-granite`, `vllm-embed`, `vllm-vision`, `openwiki`, `openwiki-view`, and `mlflow-proxy`. See [ai-stack.md](ai-stack.md).
