#!/usr/bin/env bash
# it-model-export -- GATHER side of the air-gap model workflow.
# Runs on an ONLINE box. Downloads the AI models (+ tiktoken encodings, and
# optionally the container images) to a USB/removable dir, with a manifest the
# air-gapped box's `it-model-import` reads back. No repo/group_vars needed on
# either side -- the manifest travels with the data.
#
# Usage:
#   it-model-export DEST [--role all|system1|system2] [--images] [--token TOK]
#     DEST        mount path of the USB / staging dir (e.g. /mnt/usb)
#     --role      which node's models to gather (default: all -- one USB for both)
#     --images    also `docker save` the container images (see note below)
#     --token     HF token (only to dodge anonymous rate-limits; repos are ungated)
#
# Examples:
#   sudo it-model-export /mnt/usb                 # all models + encodings
#   sudo it-model-export /mnt/usb --role system1  # just System 1's models
#   sudo it-model-export /mnt/usb --images        # models + images (full bring-up)
#
# NOTE (--images): registry images are pulled + saved automatically. The CUSTOM
# images (oikb/hfcli/mlflow/openwiki, built on a box by ai_compose) must already
# exist locally (build them first: run the ai_compose role, or `docker build`);
# this script warns + skips any custom tag it can't find rather than build it.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

# ---- keep in sync with group_vars/all.yml (ai_models / ai_encodings / images) --
VLLM_IMAGE="vllm/vllm-openai:v0.22.1-cu129-ubuntu2404"
ENC_BASE="https://openaipublic.blob.core.windows.net/encodings"
ENC_FILES="o200k_base.tiktoken cl100k_base.tiktoken"
# volume<TAB>repo<TAB>role
MODELS="$(printf '%s\n' \
  'vllm	openai/gpt-oss-120b	system1' \
  'granite32b	ibm-granite/granite-4.1-30b	system1' \
  'granite-embed	ibm-granite/granite-embedding-small-english-r2	system2' \
  'granite-vision	ibm-granite/granite-vision-4.1-4b	system2')"
# Docling ships its models baked into the image (--artifacts-path, downloads
# disabled), so nothing to stage separately -- the docling image (below) carries
# the models. Bring it across with --images.
REGISTRY_IMAGES="$VLLM_IMAGE
ghcr.io/open-webui/open-webui:v0.10.2
pgvector/pgvector:pg16-trixie
redis:7.2.14-bookworm
ghcr.io/docling-project/docling-serve-cu128:v1.24.0
apache/tika:3.3.1.0
grafana/otel-lgtm:0.29.0
louislam/dockge:1"
CUSTOM_IMAGES="oikb:latest
hfcli:latest
mlflow:v3.15.1-psycopg2
openwiki:latest
openwiki-view:latest"
# --------------------------------------------------------------------------------

DEST=""; ROLE="all"; IMAGES=0; TOKEN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="${2:-all}"; shift 2 ;;
    --images) IMAGES=1; shift ;;
    --token) TOKEN="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1"; exit 2 ;;
    *) [ -z "$DEST" ] && DEST="$1" || { echo "unexpected arg: $1"; exit 2; }; shift ;;
  esac
done
[ -n "$DEST" ] || { echo "usage: it-model-export DEST [--role all|system1|system2] [--images] [--token TOK]"; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "docker required (this is the online gather side)"; exit 1; }
mkdir -p "$DEST/models" "$DEST/encodings" || { echo "cannot write to $DEST"; exit 1; }
MAN="$DEST/manifest.txt"; : > "$MAN"

# FIPS host? the vLLM image's OpenSSL needs the fips_off mask to do TLS.
FIPS_MNT=""
if [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo 0)" = "1" ]; then
  printf '0\n' > "$DEST/.fips_off"
  FIPS_MNT="-v $DEST/.fips_off:/proc/sys/crypto/fips_enabled:ro"
fi

echo ">> Ensuring the downloader image is present ($VLLM_IMAGE)"
docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1 || docker pull "$VLLM_IMAGE" || {
  echo "could not pull $VLLM_IMAGE"; exit 1; }

# Verify every shard in a downloaded model dir is present + non-empty.
complete() { # $1 = model dir
  local m="$1" idx="$1/model.safetensors.index.json" ok=0 f
  if [ -f "$m/config.json" ]; then
    if [ -f "$idx" ]; then
      ok=1
      for f in $(grep -o '[A-Za-z0-9_.-]*\.safetensors' "$idx" | sort -u); do
        [ -s "$m/$f" ] || ok=0
      done
    elif [ -s "$m/model.safetensors" ]; then ok=1; fi
  fi
  [ "$ok" = 1 ]
}

echo ">> Downloading models to $DEST/models  (role: $ROLE)"
printf '%s\n' "$MODELS" | while IFS=$'\t' read -r vol repo mrole; do
  [ -n "$vol" ] || continue
  [ "$ROLE" = all ] || [ "$ROLE" = "$mrole" ] || continue
  d="$DEST/models/$vol"; mkdir -p "$d"
  echo "   -- $repo -> models/$vol"
  docker run --rm ${TOKEN:+-e HF_TOKEN=$TOKEN} $FIPS_MNT \
    -v "$d":/model --entrypoint hf "$VLLM_IMAGE" \
    download "$repo" --local-dir /model || { echo "   FETCH FAILED: $repo"; continue; }
  if complete "$d"; then
    echo "MODEL	$vol	$repo" >> "$MAN"
    echo "   ok ($(du -sh "$d" 2>/dev/null | cut -f1))"
  else
    echo "   INCOMPLETE after download: $repo (left off the manifest; re-run to resume)"
  fi
done

# Docling: no separate model staging. The docling image ships its models baked
# in (--artifacts-path, runtime downloads disabled), so the models travel WITH
# the image -- bring docling across with --images (it's in REGISTRY_IMAGES).

# Encodings (only needed by nodes that run gpt-oss, i.e. System 1 / all)
if [ "$ROLE" = all ] || [ "$ROLE" = system1 ]; then
  echo ">> Fetching tiktoken encodings to $DEST/encodings"
  got=""
  for f in $ENC_FILES; do
    if [ -s "$DEST/encodings/$f" ] || curl -fsSL "$ENC_BASE/$f" -o "$DEST/encodings/$f"; then
      got="$got $f"; echo "   -- $f"
    else echo "   encoding fetch failed: $f"; fi
  done
  [ -n "$got" ] && echo "ENCODINGS	$got" >> "$MAN"
fi

# Container images (optional)
if [ "$IMAGES" = 1 ]; then
  mkdir -p "$DEST/images"
  echo ">> Saving container images to $DEST/images"
  for tag in $REGISTRY_IMAGES; do
    echo "   -- pull $tag"; docker pull "$tag" >/dev/null 2>&1 || { echo "      pull failed: $tag (skipped)"; continue; }
  done
  for tag in $CUSTOM_IMAGES; do
    docker image inspect "$tag" >/dev/null 2>&1 || echo "   NOTE custom image not built locally, skipping: $tag  (build it first)"
  done
  # Save every tag that exists locally.
  for tag in $REGISTRY_IMAGES $CUSTOM_IMAGES; do
    docker image inspect "$tag" >/dev/null 2>&1 || continue
    safe=$(printf '%s' "$tag" | tr '/:' '__')
    echo "   -- save $tag"
    if docker save "$tag" | gzip > "$DEST/images/$safe.tar.gz"; then
      echo "IMAGE	$tag	images/$safe.tar.gz" >> "$MAN"
    else echo "      save failed: $tag"; fi
  done
fi

rm -f "$DEST/.fips_off" 2>/dev/null || true
echo
echo ">> Done. Wrote $MAN"
sync
echo "   Total on media: $(du -sh "$DEST" 2>/dev/null | cut -f1). Safe to unmount."
echo "   On the air-gapped box:  sudo it-model-import $DEST${IMAGES:+ --images}"
