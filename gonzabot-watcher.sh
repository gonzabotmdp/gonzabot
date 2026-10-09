#!/bin/bash
REQ=/data/gpu/shared/ifimar-ai/run/.gonzabot-start-request
STATS=/data/gpu/shared/ifimar-ai/stats/usage.log
[ -f "$REQ" ] || exit 0
REQUESTER=$(cat "$REQ" 2>/dev/null | tr -d '\n' || echo "unknown")
curl -sf http://gpu-01:8000/health >/dev/null 2>&1 && rm -f "$REQ" && exit 0
# No duplicar: si ya hay un vllm-service PENDING/RUNNING (aunque todavia no
# conteste /health porque esta cargando el modelo), no someter otro -- evita
# que varios "s" concurrentes mientras carga terminen pidiendo 2+ GPUs cada
# uno y compitiendo por el mismo NFS lento (bug real 15/9).
if squeue -h -n vllm-service -t PENDING,RUNNING -o "%i" 2>/dev/null | grep -q .; then
    rm -f "$REQ"
    exit 0
fi
JID=$(sbatch /data/gpu/shared/ifimar-ai/vllm-service.sbatch 2>/dev/null | awk '{print $NF}')
if [ -n "$JID" ]; then
    echo "{\"ts\":\"$(date -Is)\",\"user\":\"$REQUESTER\",\"event\":\"service_started\",\"job_id\":$JID}" >> "$STATS"
    rm -f "$REQ"
fi
