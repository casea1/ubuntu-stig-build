# Project context for Claude Code

Ansible baseline that builds and STIG-hardens Ubuntu 24.04 boxes. Two deployment
profiles matter most: `development` (engineering workstation) and `ai` (a
two-node self-hosted AI stack). Boxes provision themselves via `ansible-pull`
from this repo — there is no control node.

Start with `README.md`, then `docs/`. Do not duplicate those here.

## Layout

| Path | What |
|---|---|
| `local.yml` | the playbook `ansible-pull` runs |
| `bootstrap.sh` | what an operator runs on a fresh box |
| `group_vars/all.yml` | nearly all configuration and profile gating |
| `roles/` | one role per concern (`ai_compose`, `ai_stack`, `usg_harden`, `local_accounts`, …) |
| `roles/ai_compose/files/stacks/<stack>/compose.yaml` | the per-service Docker stacks, deployed to `/opt/stacks/<stack>/` |
| `docs/` | operator + IA documentation |

## Working conventions

- **Push to `main` immediately** unless there's a real reason not to. That is the
  owner's standing instruction, not an assumption.
- **Never commit secrets.** Passwords are auto-generated per box into
  `/etc/stig-build/*.pw` and rendered into each stack's root-only `.env`. Compose
  files use `${VAR:?set in .env}` so a missing value fails loudly. This repo was
  public until recently — treat anything ever committed as compromised.
- **Comments earn their place.** Compose files were deliberately trimmed to ~9%
  comments. Keep a comment only if removing it would let someone break something
  (the FIPS carve-out, the docling mount trap, PersistentConfig). Do not restate
  the YAML or narrate history.
- **Verify before asserting.** Several bugs here came from plausible-sounding
  assumptions. Check the actual file, the actual package, the actual box.
- **Profile gating** is computed in `group_vars` (`is_ai`, `is_emi`,
  `emi_classified`, …). "All profiles except emi-unclass" is a real pattern — see
  `local_auto_audit_enabled`.

## Gotchas that have already caused outages

1. **Docker bypasses ufw.** Published container ports are DNAT'd before ufw's
   INPUT chain, so ufw rules do **not** filter them. Confirmed on dev-ai2:
   port 5000 was absent from ufw and still reachable from the LAN. `DOCKER-USER`
   is empty. MLflow is protected by an nginx allow-list instead; every other
   published port is still effectively open on the LAN.
2. **Ansible overwrites on-box edits.** Every file `ai_compose` places is a plain
   `copy`/`template` — `compose.yaml`, `.env`, `fips_off`, dashboards. Only
   `.oikb.yaml` is preserved (`force: false`). A hand-edit on a box is lost on the
   next pull, and if `ai_compose_deploy` is true the container is recreated too.
   For a genuine per-box exception use `compose.override.yaml`, which nothing
   manages.
3. **The FIPS carve-out.** The host runs a FIPS kernel; vLLM and Docling images
   have no FIPS OpenSSL provider and abort at startup. They bind-mount a
   `fips_off` file over `/proc/sys/crypto/fips_enabled`. The host stays FIPS.
4. **Docling's models are baked into its image**, with runtime downloads
   disabled. Mounting a volume over its model cache **hides** them and docling
   crash-loops. To add a model, mount its own subdirectory, never the parent.
5. **Image tags are pinned**, so `docker compose pull` is not an update. Patching
   a container means editing the tag in this repo. See `docs/patching.md`.
6. **Volumes are external**, so `docker compose down -v` cannot delete model
   weights or databases. Also means Postgres keeps its original password on an
   existing volume regardless of the env var.
7. **Open WebUI RAG settings are `PersistentConfig`** — env seeds a *fresh*
   database only. On an existing box they must be changed in the UI.
8. **Stacks behind a `profiles:` tag read "n/a" in Dockge.** That is correct
   behaviour for the run-and-exit tools, not a fault.

## Open threads

- **Rotate the leaked credentials.** The old pgvector password, Open WebUI
  session key, and MLflow password were committed while the repo was public.
  Scrubbed from the working tree, still in history. An `it-rotate-secrets`
  script (new password + `ALTER USER` on the live DB + `.env` + recreate) was
  proposed and not written.
- **`DOCKER-USER` firewall rules** in `ai_firewall`, so the ufw policy actually
  applies to published ports. This is the systemic fix for gotcha 1.
- **Unpinned custom images.** `hfcli` (pip `--upgrade`), `repomix` (npm latest)
  and `oikb` (`git clone` with no ref, plus `sed` patches against specific
  upstream lines) are not reproducible. `openwiki` is pinned via
  `ARG OPENWIKI_VERSION` and is the pattern to follow.
- **Models track HF `main`** with no revision pin; a re-fetch can change weights
  silently. An incomplete gpt-oss download already caused a garbage-output bug.
- **`auto_audit` has no job.** The scheduled OpenSCAP scan runs as **root** (via
  `it-oscap` + a systemd timer) precisely because `auto_audit` is locked and
  cannot sudo unattended. If nothing else needs the account, dropping it from
  `sudo` is the least-privilege end state.
- **USBGuard is on for every profile including EMI.** The initial policy is
  generated from attached devices, so the built-in keyboard is always
  authorised; peripherals are enrolled with `it-usb enroll`.
- **GRUB password is inert until a hash is vaulted** — `grub_password_pbkdf2` is
  still the CHANGEME sentinel, so the role skips. Activate with `it-grub hash`
  (fleet) or `it-grub set` (one box); check with `it-grub status`. This matters
  more here than usual: LUKS is TPM-sealed to PCR 7 only, which does not measure
  the kernel command line, so without the GRUB password physical access → root
  shell on decrypted data.
- **openwiki generation** is wired to System 1's vLLM but has never produced a
  real wiki. Getting the repo into `/work` and publishing output where the viewer
  reads it is still a manual three-step.
- **granite-docling VLM** is not deployed; it needs a custom docling image with
  the weights baked in. `external_granite_vision` is not a valid preset name.
- **No offline apt path.** Images and models have a USB workflow; OS packages
  do not.

## Docs

| Doc | For |
|---|---|
| `docs/ai-stack.md` | what runs where, ports, volumes, software inventory |
| `docs/operate.md` | day-to-day ops, accounts, deep reference |
| `docs/build.md` | bare-metal build steps |
| `docs/compliance.md` | IA / DCSA posture, POA&M |
| `docs/patching.md` | where updates come from, cadence, known gaps |
| `docs/compose-changes.md` | why the compose files differ from the originals |
