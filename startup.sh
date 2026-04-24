#!/bin/bash
# Phase 3 — Pod startup script (v2 — fixed)
# RunPod pod settings:
#   Image:         runpod/base:0.6.1-cuda12.2.0
#   Start Command: bash /workspace/startup.sh
#   HTTP Port:     8000
#   Network Vol:   grim_white_guineafowl  →  /workspace

LOG=/workspace/startup.log
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Pod startup began" | tee -a "$LOG"

# Fix DNS (RunPod pods sometimes start without name resolution)
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 8.8.4.4" >> /etc/resolv.conf

# Link network volume model store → Ollama default path
mkdir -p /root/.ollama
if [ ! -L /root/.ollama/models ]; then
    rm -rf /root/.ollama/models
    ln -s /workspace/ollama /root/.ollama/models
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Linked /root/.ollama/models -> /workspace/ollama" | tee -a "$LOG"
fi

# Use cached Ollama binary from network volume (fast, no DNS needed)
mkdir -p /workspace/bin
if [ -f /workspace/bin/ollama ]; then
    cp /workspace/bin/ollama /usr/local/bin/ollama
    chmod +x /usr/local/bin/ollama
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Ollama loaded from /workspace/bin cache" | tee -a "$LOG"
elif ! which ollama > /dev/null 2>&1; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Installing Ollama from internet..." | tee -a "$LOG"
    curl -fsSL https://ollama.com/install.sh | sh >> "$LOG" 2>&1
    # Cache to network volume — all future pods skip this step
    cp /usr/local/bin/ollama /workspace/bin/ollama
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Ollama binary cached to /workspace/bin/" | tee -a "$LOG"
fi

# Kill any stale Ollama processes from previous runs
pkill -f "ollama serve" 2>/dev/null || true
sleep 2

# Start Ollama on port 8000
# KEEP_ALIVE=-1 → model stays in VRAM forever (never unloads during session)
OLLAMA_HOST=0.0.0.0:8000 \
OLLAMA_FLASH_ATTENTION=1 \
OLLAMA_KV_CACHE_TYPE=q8_0 \
OLLAMA_NUM_PARALLEL=1 \
OLLAMA_KEEP_ALIVE=-1 \
nohup ollama serve >> "$LOG" 2>&1 &

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Ollama server starting on :8000" | tee -a "$LOG"

# Wait until Ollama is ready (max 120s)
for i in $(seq 1 120); do
    if curl -s http://localhost:8000/api/tags > /dev/null 2>&1; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Ollama ready after ${i}s — endpoint: http://0.0.0.0:8000" | tee -a "$LOG"
        break
    fi
    sleep 1
done

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Startup complete. READY." | tee -a "$LOG"

# Keep container alive — without this the container exits and pod restarts in a loop
sleep infinity
