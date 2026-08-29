#!/bin/bash
REQ=/data/gpu/shared/ifimar-ai/run/.gonzabot-start-request
STATS=/data/gpu/shared/ifimar-ai/stats/usage.log
[ -f "$REQ" ] || exit 0
REQUESTER=$(cat "$REQ" 2>/dev/null | tr -d '\n' || echo "unknown")
curl -sf http://gpu-01:8000/health >/dev/null 2>&1 && rm -f "$REQ" && exit 0
JID=$(sbatch /data/gpu/shared/ifimar-ai/vllm-service.sbatch 2>/dev/null | awk '{print $NF}')
if [ -n "$JID" ]; then
    echo "{\"ts\":\"$(date -Is)\",\"user\":\"$REQUESTER\",\"event\":\"service_started\",\"job_id\":$JID}" >> "$STATS"
    rm -f "$REQ"
fi
