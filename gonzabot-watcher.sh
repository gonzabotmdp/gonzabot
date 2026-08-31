#!/bin/bash
REQ=/data/gpu/shared/ifimar-ai/run/.gonzabot-start-request
STATS=/data/gpu/shared/ifimar-ai/stats/usage.log
[ -f "$REQ" ] || exit 0
REQUESTER=$(cat "$REQ" 2>/dev/null | tr -d '\n' || echo "unknown")
curl -sf http://gpu-01:8000/health >/dev/null 2>&1 && rm -f "$REQ" && exit 0
# Bug real 30/8: un modelo grande puede tardar varios minutos en levantar. Mientras
# tanto el health-check de arriba falla en cada tick del cron, y sin este chequeo el
# watcher sometía OTRO sbatch cada minuto -- terminamos con 2 jobs vllm-service
# duplicados ocupando las 4 GPUs del nodo entre los dos. No relanzar si ya hay uno
# corriendo o pendiente.
if squeue -h -n vllm-service -u "$(whoami)" -t RUNNING,PENDING | grep -q .; then
    exit 0
fi
JID=$(sbatch /data/gpu/shared/ifimar-ai/vllm-service.sbatch 2>/dev/null | awk '{print $NF}')
if [ -n "$JID" ]; then
    echo "{\"ts\":\"$(date -Is)\",\"user\":\"$REQUESTER\",\"event\":\"service_started\",\"job_id\":$JID}" >> "$STATS"
    rm -f "$REQ"
fi
