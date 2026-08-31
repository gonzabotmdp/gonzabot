#!/bin/bash
# Descarga Llama 3.3 70B Instruct desde HuggingFace
# Uso: bash download-llama.sh <HF_TOKEN>

set -e

HF_TOKEN="${1:-$HF_TOKEN}"
MODEL="meta-llama/Llama-3.3-70B-Instruct"
DEST="/data/gpu/shared/models/Meta-Llama-3.3-70B-Instruct"

if [ -z "$HF_TOKEN" ]; then
    echo "ERROR: falta token. Uso: bash download-llama.sh hf_xxxx"
    exit 1
fi

echo "=== Descarga Llama 3.3 70B ==="
echo "Destino: $DEST"
echo "Inicio:  $(date)"
echo ""

mkdir -p "$DEST"

# Instalar huggingface_hub si no está
python3 -c "import huggingface_hub" 2>/dev/null || {
    echo "Instalando huggingface_hub..."
    python3 -m pip install -q huggingface_hub
}

python3 - <<EOF
from huggingface_hub import snapshot_download
import sys

print("Conectando a HuggingFace...")
snapshot_download(
    repo_id="$MODEL",
    local_dir="$DEST",
    token="$HF_TOKEN",
    ignore_patterns=["*.pt", "original/*"],  # saltear checkpoints pytorch legacy
)
print("Descarga completa:", "$DEST")
EOF

echo ""
echo "=== Fin: $(date) ==="
echo "Tamaño total:"
du -sh "$DEST"
