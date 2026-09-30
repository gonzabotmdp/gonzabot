#!/bin/bash
#SBATCH --job-name=vllm-service
#SBATCH --partition=inference
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=16
#SBATCH --gres=gpu:nvidia-a100-80gb-pcie:2
#SBATCH --mem=160G
#SBATCH --time=16:00:00
#SBATCH --output=/mnt/gpu-data/shared/ifimar-ai/logs/vllm-%j.out
#SBATCH --error=/mnt/gpu-data/shared/ifimar-ai/logs/vllm-%j.err

# ── Paths ─────────────────────────────────────────────────────────────────────
# 30/8: migrado de Qwen2.5-72B a GLM-4.5-Air tras comparación sistemática
# (ver README, sección "Comparación de modelos").
CUDA_DIR=/apps/local/spack/spack-2026b/spack/opt/spack/linux-zen4/cuda-12.6.2-okkjtu2zsbs2foyor6iohlanp3lpcfyc
VENV=/mnt/gpu-data/shared/ifimar-ai/venv-glm-test
MODEL_DIR=/mnt/gpu-data/shared/ifimar-ai/models/GLM-4.5-Air-AWQ-4bit
PORT=8000
HOST=0.0.0.0

export PATH=${CUDA_DIR}/bin:${VENV}/bin:$PATH
export CUDA_HOME=${CUDA_DIR}
export LD_LIBRARY_PATH=${CUDA_DIR}/lib64:${CUDA_DIR}/targets/x86_64-linux/lib:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}
export LIBRARY_PATH=${CUDA_DIR}/lib64/stubs:${LIBRARY_PATH}
export VIRTUAL_ENV=${VENV}
export TORCHDYNAMO_DISABLE=1
export VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
export TORCH_COMPILE_DISABLE=1
export TRITON_LIBCUDA_PATH=${CUDA_DIR}/lib64/stubs
export TRITON_PYTHON_INCLUDE_DIR=/mnt/gpu-data/shared/ifimar-ai/pyheaders/usr/include/python3.12
# 15/9: modelo 100% local, nunca necesita chequear huggingface.co. Sin esto,
# HF/transformers puede intentar una llamada de red (version-check/etag) al
# resolver la arquitectura -- candidato fuerte a una demora real que vimos
# (11+ min en "Resolved architecture" vs los ~5s normales). No confirmado al
# 100%, pero es preventivo seguro (no cambia nada del modelo/lógica, solo
# evita la llamada online).
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1

# ── Info ──────────────────────────────────────────────────────────────────────
echo "=== vLLM service start $(date) ==="
echo "Node: $(hostname)"
echo "GPUs: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null)"
echo "vLLM: $(python3 -c 'import vllm; print(vllm.__version__)' 2>/dev/null)"
echo "Model: ${MODEL_DIR}"
echo "Port: ${PORT}"
echo "Job: ${SLURM_JOB_ID}"

# Write job ID so the stop script can cancel it. rm -f + chmod 666 self-heals if
# this file ever ends up owned by another user/root (real bug: it did once, and
# the job silently failed to write its own PID -- Permission denied in the log).
rm -f /mnt/gpu-data/shared/ifimar-ai/vllm.jobid 2>/dev/null
echo "${SLURM_JOB_ID}" > /mnt/gpu-data/shared/ifimar-ai/vllm.jobid
chmod 666 /mnt/gpu-data/shared/ifimar-ai/vllm.jobid 2>/dev/null || true

# ── Idle watchdog ─────────────────────────────────────────────────────────────
HEARTBEAT=/mnt/gpu-data/shared/ifimar-ai/run/.gonzabot-heartbeat
IDLE_MINUTES=30

(
    touch "$HEARTBEAT" && chmod 666 "$HEARTBEAT"
    echo "[watchdog] Esperando que vLLM levante..."
    until curl -sf http://localhost:${PORT}/health > /dev/null 2>&1; do
        sleep 20
    done
    touch "$HEARTBEAT"
    echo "[watchdog] vLLM listo. Monitoreando inactividad (${IDLE_MINUTES} min)..."
    while sleep 60; do
        LAST_MOD=$(stat -c %Y "$HEARTBEAT" 2>/dev/null || echo 0)
        NOW=$(date +%s)
        IDLE=$(( NOW - LAST_MOD ))
        if [ "$IDLE" -ge $(( IDLE_MINUTES * 60 )) ]; then
            echo "[watchdog] $(date) — Sin actividad por ${IDLE}s. Apagando job ${SLURM_JOB_ID}..."
            scancel "$SLURM_JOB_ID"
            break
        fi
    done
) &
WATCHDOG_PID=$!

# ── Launch vLLM (MoE: --enable-expert-parallel obligatorio con TP>1) ──────────
python3 -m vllm.entrypoints.openai.api_server \
    --model "${MODEL_DIR}" \
    --tensor-parallel-size 2 \
    --enable-expert-parallel \
    --host "${HOST}" \
    --port "${PORT}" \
    --max-model-len 131072 \
    --gpu-memory-utilization 0.90 \
    --served-model-name glm45-air \
    --reasoning-parser glm45 \
    --trust-remote-code

echo "=== vLLM service stopped $(date) ==="
kill "$WATCHDOG_PID" 2>/dev/null
rm -f /mnt/gpu-data/shared/ifimar-ai/vllm.jobid
