# Patching & update management

Where every component comes from, how it is version-controlled, and how it actually gets patched — connected (lab) and air-gapped (fielded). Written for SI-2 / flaw-remediation evidence as much as for day-to-day ops.

## The honest summary

**Almost nothing patches itself.** By design, this baseline is reproducible rather than self-updating:

- `base_packages_full_upgrade` is **`false`** — a build does **not** apt-upgrade the OS.
- Container images are **pinned by tag**, so `docker compose pull` re-fetches the *same* image. It is not an update.
- `ansible-pull` runs **only when a human runs `bootstrap.sh`** — there is no timer or cron.

The one thing that *is* automatic is Ubuntu Pro: ESM and livepatch deliver kernel/userspace security fixes without a build. Everything else is a deliberate, reviewed change: **edit the version in this repo → commit → re-run the pull on each box.**

That is a reasonable posture for an air-gapped, accredited system, but it means **patching is a scheduled human activity**. This document is the schedule.

## What comes from where

| Layer | Source | Pinned? | Patch by |
|---|---|---|---|
| Ubuntu OS + kernel | Ubuntu archive + **Ubuntu Pro** (ESM infra/apps) | rolling | `apt upgrade`, or `base_packages_full_upgrade: true` |
| Kernel live fixes | **canonical-livepatch** (Pro) | rolling | automatic, no reboot |
| FIPS kernel/modules | **Ubuntu Pro** `fips-updates` | rolling | `apt upgrade` + reboot |
| STIG profile (`usg`) | **Ubuntu Pro** `usg` package | rolling | `apt upgrade` then re-run `usg fix`/`audit` |
| Docker engine | Docker's official apt repo | floor only (`docker_ce_min_version`) | `apt upgrade` |
| NVIDIA driver + container toolkit | NVIDIA apt repos | floor only (`nvidia_driver_min_version`) | `apt upgrade` (driver change ⇒ reboot) |
| PowerShell | pinned `.deb` from GitHub releases | **yes** (`powershell_version`) | bump the var, re-run the pull |
| Registry container images | Docker Hub / ghcr.io | **yes**, by tag | edit the tag in the compose file, re-run the pull |
| Custom container images | built on the box | **partly** — see gaps | rebuild (`ai_compose_build_force: true`) |
| AI models | Hugging Face | **no** — tracks repo `main` | re-fetch deliberately |
| Tiktoken encodings | `openaipublic.blob.core.windows.net` | n/a (static) | re-fetch if lost |

## Patching a connected box

### 1. OS, kernel, FIPS, USG, Docker, NVIDIA (apt layer)

```bash
sudo apt update && sudo apt upgrade          # or: sudo apt full-upgrade
sudo pro security-status                     # what ESM is covering
sudo canonical-livepatch status
```

Reboot if the kernel, FIPS packages, or the NVIDIA driver changed. After a **kernel or NVIDIA** change, re-verify the two things that silently break:

```bash
cat /proc/sys/crypto/fips_enabled      # want 1
nvidia-smi                             # driver still loaded?
sudo it-ai status                      # GPU containers still healthy?
```

To have the build do it instead, set `base_packages_full_upgrade: true` in `site.yml`. It is off by default because a full upgrade can pull a kernel that breaks the pinned NVIDIA driver mid-build.

After a `usg` package update, re-assert and re-evidence the STIG baseline:

```bash
sudo usg fix disa_stig     # disruptive — read docs/compliance.md first
sudo usg audit disa_stig
```

### 2. Container images (the pinned layer)

`it-ai pull` **will not** update a pinned image. Patching a container is a repo change:

1. Find the new tag upstream (release notes / registry).
2. Edit `image:` in `roles/ai_compose/files/stacks/<stack>/compose.yaml` **and** the matching consolidated fallback.
3. Commit, then on each box re-run the pull, or apply directly:

```bash
sudo it-ai pull <stack> && sudo it-ai up <stack>
sudo it-ai logs <stack>
```

Keep `docs/ai-stack.md`'s software inventory in step with the tag — that table is the IA-facing evidence.

### 3. Custom images (built on the box)

```bash
# rebuild everything the node owns
sudo ansible-pull ... -e ai_compose_build_force=true
# or one image by hand
sudo docker build -t openwiki:latest /opt/it/docker/build/openwiki
sudo it-ai up openwiki-view
```

Rebuilding requires **internet** — these Dockerfiles fetch from npm/PyPI/GitHub at build time. An air-gapped box cannot rebuild them; it receives them as saved images (below).

### 4. Models

Models are not patched, they are *replaced*. They track the HF repo's `main` at fetch time, so a re-fetch can silently change weights. Re-fetch deliberately:

```bash
sudo it-ai run hfcli hf download <repo> --local-dir /<mount>
sudo it-ai restart <vllm-stack>
```

## Patching an air-gapped box

The fielded boxes never reach the internet, so patches arrive on removable media. Everything is staged on a **connected** box that mirrors the fielded baseline.

**On the connected box** — build/pull first so the custom images exist locally, then export:

```bash
sudo it-model-export /mnt/usb --images        # models + encodings + all container images
```

**On the fielded box:**

```bash
sudo it-model-import /mnt/usb --images        # docker load + populate volumes
sudo it-ai up
```

For the **apt layer** air-gapped, you need an internal Ubuntu Pro/ESM mirror or a `.deb` bundle — this repo does not ship a mechanism for that, and it is the largest open gap in the offline patch story.

## Suggested cadence

Align with your organisation's IAVM / SI-2 policy; these are defaults, not authority.

| Activity | Cadence |
|---|---|
| `pro security-status` + `apt upgrade` on connected boxes | monthly |
| Review pinned image tags for new upstream releases | monthly |
| Rebuild custom images (picks up npm/PyPI security fixes) | quarterly, or on advisory |
| `usg audit disa_stig` + archive the report | monthly, and after any change |
| Air-gap patch run (USB cycle) | quarterly, or on critical advisory |
| Out-of-cycle | on any applicable critical/IAVA advisory |

## Known gaps

Recorded deliberately — these are real and unresolved.

1. **No scheduled convergence.** `ansible-pull` runs only when someone runs `bootstrap.sh`. A box can drift from the repo indefinitely and nothing reports it. A systemd timer running `ansible-pull` in check mode would at least surface drift.
2. **The pinning is inverted in places.** Registry images are pinned (good, reproducible — but no automatic CVE pickup), while several custom images are **unpinned**:
   - `hfcli` — `pip install --upgrade huggingface_hub`
   - `repomix` — `npm install -g repomix`
   - `oikb` — `git clone` of the upstream default branch with **no ref**, then `sed` patches applied to specific source lines
   
   Two consequences: rebuilding the same Dockerfile on two days produces different artifacts, and oikb's `sed` patches will silently no-op if upstream moves those lines. `openwiki` and `openwiki-view` are pinned and are the pattern the others should follow.
3. **Models track `main`.** No revision/commit pin, so a re-fetch can change weights without any record. Pinning `--revision` would make model provenance auditable.
4. **No offline apt path.** Container images and models have a USB workflow; OS packages do not.
5. **No CVE-to-component mapping.** Nothing correlates an advisory to "which of our images/packages is affected." The inventory in `docs/ai-stack.md` is the manual starting point.

## After any patch — verify

```bash
sudo it-status                 # host rollup
sudo it-ai status              # every stack
sudo it-models                 # model endpoints answering
cat /proc/sys/crypto/fips_enabled
nvidia-smi
sudo usg audit disa_stig       # compliance did not regress
```

Keep the `usg audit` output — it is the evidence that patching did not break the accredited baseline.
