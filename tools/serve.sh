#!/bin/zsh
# strata-lite: startet einen lokalen, OpenAI-/Anthropic-kompatiblen Server auf :8000.
#   ./serve.sh            oMLX (Multi-Modell, SSD-KV-Cache, Admin-UI unter /admin)
#   ./serve.sh dflash M   dflash-mlx mit spekulativem Dekodieren für Modell M (Ordnername)
set -euo pipefail

BASE=~/.strata-lite
MODELS=$BASE/models
mode=${1:-omlx}

case $mode in
  omlx)
    # Feste Guard-Grenze knapp unter dem Metal-Limit (24-GB-Mac: 17,76 GiB). "aggressive" richtet sich
    # nach dem freien RAM und lehnt das Modell ab, wenn andere Apps viel belegen.
    # SSD-KV-Cache: lange Agent-Prompts müssen nicht jedes Mal neu verarbeitet werden.
    exec $BASE/omlx-venv/bin/omlx serve \
      --model-dir $MODELS --port 8000 --host 127.0.0.1 \
      --memory-guard-gb ${OMLX_GUARD_GB:-17.7} \
      --paged-ssd-cache-dir $BASE/kv-cache --paged-ssd-cache-max-size 10GB
    ;;
  dflash)
    model=${2:?Modellordner angeben, z.B. Qwen3.6-35B-A3B-UD-MLX-3bit}
    exec $BASE/venv/bin/dflash serve \
      --model $MODELS/$model \
      --draft-model $MODELS/Qwen3.6-35B-A3B-DFlash \
      --port 8000 --dflash-max-ctx 16384 --prefill-step-size 512
    ;;
  *)
    echo "Unbekannter Modus: $mode (omlx | dflash)" >&2; exit 1 ;;
esac
