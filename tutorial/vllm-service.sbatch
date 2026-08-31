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
CUDA_DIR=/usr/share/spack/root/opt/spack/linux-ubuntu24.04-zen4/gcc-14.2.0/cuda-12.6.2-6wkrlaxd5q7zyvxge7vmp6gkhwa7gtno
VENV=/mnt/gpu-data/shared/ifimar-ai/venv-020
MODEL_DIR=/mnt/gpu-data/shared/models/Qwen2.5-72B-Instruct-AWQ
PORT=8000
HOST=0.0.0.0

export PATH=${CUDA_DIR}/bin:${VENV}/bin:$PATH
export LD_LIBRARY_PATH=${CUDA_DIR}/lib64:${CUDA_DIR}/targets/x86_64-linux/lib:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}
export LIBRARY_PATH=${CUDA_DIR}/lib64/stubs:${LIBRARY_PATH}
export VIRTUAL_ENV=${VENV}
export TORCHDYNAMO_DISABLE=1
export VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
export TORCH_COMPILE_DISABLE=1
export TRITON_LIBCUDA_PATH=${CUDA_DIR}/lib64/stubs
export TRITON_PYTHON_INCLUDE_DIR=/mnt/gpu-data/shared/ifimar-ai/pyheaders/usr/include/python3.12

# ── Info ──────────────────────────────────────────────────────────────────────
echo "=== vLLM service start $(date) ==="
echo "Node: $(hostname)"
echo "GPUs: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null)"
echo "vLLM: $(python3 -c 'import vllm; print(vllm.__version__)' 2>/dev/null)"
echo "Model: ${MODEL_DIR}"
echo "Port: ${PORT}"
echo "Job: ${SLURM_JOB_ID}"

# Write job ID so the stop script can cancel it
echo "${SLURM_JOB_ID}" > /mnt/gpu-data/shared/ifimar-ai/vllm.jobid

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

# ── Launch vLLM ───────────────────────────────────────────────────────────────
python3 -m vllm.entrypoints.openai.api_server \
    --model "${MODEL_DIR}" \
    --tensor-parallel-size 2 \
    --host "${HOST}" \
    --port "${PORT}" \
    --max-model-len 131072 \
    --gpu-memory-utilization 0.95 \
    --served-model-name qwen25-72b \
    --quantization awq \
    --enable-chunked-prefill \
    --max-num-batched-tokens 16384 \
    --enforce-eager \
    --trust-remote-code

echo "=== vLLM service stopped $(date) ==="
kill "$WATCHDOG_PID" 2>/dev/null
rm -f /mnt/gpu-data/shared/ifimar-ai/vllm.jobid
