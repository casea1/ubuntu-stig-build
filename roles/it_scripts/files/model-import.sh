#!/usr/bin/env bash
# it-model-import -- INSTALL side of the air-gap model workflow.
# Runs on the AIR-GAPPED box. Reads the manifest written by `it-model-export`
# and loads the models (+ tiktoken encodings, and optionally the container
# images) from the USB/staging dir into the external Docker volumes the AI
# stacks serve from. No internet, no repo, no helper image needed -- it copies
# straight into each volume's host path (docker volume Mountpoint).
#
# Usage:
#   it-model-import SRC [--images] [--force]
#     SRC        mount path of the USB / staging dir (same one it-model-export wrote)
#     --images   also `docker load` the saved container images
#     --force    overwrite a volume that already looks complete (default: skip it)
#
# Examples:
#   sudo it-model-import /mnt/usb            # models + encodings into their volumes
#   sudo it-model-import /mnt/usb --images   # + load the container images
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -- "$0" "$@"

SRC=""; IMAGES=0; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --images) IMAGES=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1"; exit 2 ;;
    *) [ -z "$SRC" ] && SRC="$1" || { echo "unexpected arg: $1"; exit 2; }; shift ;;
  esac
done
[ -n "$SRC" ] || { echo "usage: it-model-import SRC [--images] [--force]"; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "docker not installed"; exit 1; }
MAN="$SRC/manifest.txt"
[ -f "$MAN" ] || { echo "no manifest at $MAN (run it-model-export onto this media first)"; exit 1; }

# Host path of a named volume (creating it if needed).
vol_path() { # $1 = volume
  docker volume inspect -f '{{.Mountpoint}}' "$1" >/dev/null 2>&1 || docker volume create "$1" >/dev/null
  docker volume inspect -f '{{.Mountpoint}}' "$1"
}
# Is a model volume already complete? (same shard check as the fetch role)
complete() { # $1 = dir
  local m="$1" idx="$1/model.safetensors.index.json" ok=0 f
  if [ -f "$m/config.json" ]; then
    if [ -f "$idx" ]; then
      ok=1
      for f in $(grep -o '[A-Za-z0-9_.-]*\.safetensors' "$idx" | sort -u); do [ -s "$m/$f" ] || ok=0; done
    elif [ -s "$m/model.safetensors" ]; then ok=1; fi
  fi
  [ "$ok" = 1 ]
}

# ---- Images first: so the stacks have something to run once weights land ----
if [ "$IMAGES" = 1 ]; then
  echo ">> Loading container images"
  grep -E '^IMAGE	' "$MAN" | while IFS=$'\t' read -r _ tag rel; do
    f="$SRC/$rel"
    [ -f "$f" ] || { echo "   MISSING archive for $tag ($rel)"; continue; }
    echo "   -- load $tag"
    gunzip -c "$f" | docker load >/dev/null 2>&1 && echo "      ok" || echo "      load failed: $tag"
  done
fi

# ---- Models into their volumes ----
echo ">> Loading models into their volumes"
grep -E '^MODEL	' "$MAN" | while IFS=$'\t' read -r _ vol repo; do
  srcd="$SRC/models/$vol"
  [ -d "$srcd" ] || { echo "   MISSING model dir on media: models/$vol ($repo)"; continue; }
  mp="$(vol_path "$vol")"
  if [ "$FORCE" != 1 ] && complete "$mp"; then
    echo "   -- $vol already complete in volume, skipping ($repo).  --force to overwrite"
    continue
  fi
  echo "   -- $repo -> volume '$vol' ($mp)"
  cp -a "$srcd/." "$mp"/ || { echo "      copy failed: $vol"; continue; }
  if complete "$mp"; then echo "      ok ($(du -sh "$mp" 2>/dev/null | cut -f1))"
  else echo "      WARNING: '$vol' still incomplete after copy -- media may be truncated"; fi
done

# ---- Encodings into the `encodings` volume ----
enc_line="$(grep -E '^ENCODINGS	' "$MAN" | head -1 || true)"
if [ -n "$enc_line" ]; then
  echo ">> Loading tiktoken encodings into the 'encodings' volume"
  mp="$(vol_path encodings)"
  files="$(printf '%s' "$enc_line" | cut -f2-)"
  for f in $files; do
    if [ -s "$SRC/encodings/$f" ]; then cp -a "$SRC/encodings/$f" "$mp"/ && echo "   -- $f";
    else echo "   MISSING encoding on media: $f"; fi
  done
fi

echo
echo ">> Done. Verify + start:"
echo "   it-models          # volumes populated? endpoints up?"
echo "   it-ai up           # bring the stacks up (it-ai model gpt-oss on System 1)"
