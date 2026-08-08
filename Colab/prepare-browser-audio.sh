#!/usr/bin/env bash
# Build a small browser-only audio cache.  Main continues to load the original
# WAV files, while the Colab bridge serves these Ogg/Opus copies to Chrome.
set -euo pipefail

ROOT_DIR="${1:?repository root is required}"
CACHE_DIR="${2:?audio cache directory is required}"

AUDIO_ASSETS=(
  BGM/bgm0.wav
  BGM/bgm1.wav
  BGM/bgm2.wav
  BGM/bgm3.wav
  BGM/bgm4.wav
  SE/start.wav
  SE/shot.wav
  SE/laser.wav
  SE/crash.wav
  SE/hatchCrash.wav
  SE/damageHatch.wav
  SE/damageShield.wav
  SE/getCapsule.wav
  SE/speedupVoice.wav
  SE/missileVoice.wav
  SE/doubleVoice.wav
  SE/laserVoice.wav
  SE/optionVoice.wav
  SE/shieldVoice.wav
  SE/destroy.wav
  SE/launcher3.wav
  SE/launchers.wav
  SE/EfTsuki.wav
  SE/EfAtchi.wav
  SE/EfWarero.wav
  SE/EfIcchimae.wav
  SE/EfKaze.wav
  SE/EfOpen.wav
)

converted=0
for relative in "${AUDIO_ASSETS[@]}"; do
  source_file="$ROOT_DIR/$relative"
  output_file="$CACHE_DIR/${relative%.wav}.ogg"
  temporary_file="$output_file.tmp.ogg"
  if [[ ! -f "$source_file" ]]; then
    echo "Browser audio source is missing: $source_file" >&2
    exit 1
  fi
  if [[ -f "$output_file" && "$output_file" -nt "$source_file" ]]; then
    continue
  fi
  mkdir -p "$(dirname -- "$output_file")"
  if ! ffmpeg -nostdin -loglevel error -y -i "$source_file" -map_metadata -1 \
      -vn -c:a libopus -b:a 96k -vbr on "$temporary_file"; then
    rm -f -- "$temporary_file"
    exit 1
  fi
  mv -f -- "$temporary_file" "$output_file"
  converted=$((converted + 1))
done

if (( converted > 0 )); then
  echo "Prepared $converted browser audio assets in $CACHE_DIR"
fi
