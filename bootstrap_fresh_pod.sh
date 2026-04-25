#!/bin/bash
# bootstrap_fresh_pod.sh — RTX PRO 4500 Blackwell + Qwen3.6 35b-a3b
# Run ONCE on a brand-new pod with fresh/empty network volume.
# Takes ~15-20 min (model download). Do NOT interrupt.
#
# Pod requirements:
#   Image:         runpod/base:0.6.1-cuda12.2.0
#   Container disk: 20GB
#   Network volume: 50GB mounted at /workspace
#   HTTP port:     8000 exposed
#   Start command: bash /workspace/bootstrap_fresh_pod.sh

set -e
LOG=/workspace/bootstrap.log
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Bootstrap started — RTX PRO 4500 + Qwen3.6 35b-a3b" | tee "$LOG"

# 1. Fix DNS
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 8.8.4.4" >> /etc/resolv.conf
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] DNS fixed" | tee -a "$LOG"

# 2. Create directory structure on network volume
mkdir -p /workspace/ollama \
         /workspace/bin \
         /workspace/content_output \
         /workspace/phase3 \
         /workspace/logs
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Directory structure created" | tee -a "$LOG"

# 3. Link network volume model store to Ollama default path
mkdir -p /root/.ollama
rm -rf /root/.ollama/models
ln -s /workspace/ollama /root/.ollama/models
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Linked /root/.ollama/models -> /workspace/ollama" | tee -a "$LOG"

# 4. Install Ollama
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Installing Ollama..." | tee -a "$LOG"
curl -fsSL https://ollama.com/install.sh | sh >> "$LOG" 2>&1
# Cache binary to network volume — future pods load from here, no internet needed
cp /usr/local/bin/ollama /workspace/bin/ollama
chmod +x /workspace/bin/ollama
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Ollama installed + cached to /workspace/bin/" | tee -a "$LOG"

# 5. Start Ollama on port 8000
OLLAMA_HOST=0.0.0.0:8000 OLLAMA_KEEP_ALIVE=-1 nohup ollama serve >> "$LOG" 2>&1 &
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Waiting for Ollama to be ready..." | tee -a "$LOG"
for i in $(seq 1 60); do
    curl -s http://localhost:8000/api/tags > /dev/null 2>&1 && break
    sleep 1
done
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Ollama ready on :8000" | tee -a "$LOG"

# 6. Pull Qwen3.6 35b-a3b (MoE — 22GB on disk, fast inference)
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Pulling qwen3.6:35b-a3b — ~22GB, takes 15-20 min..." | tee -a "$LOG"
OLLAMA_HOST=http://localhost:8000 ollama pull qwen3.6:35b-a3b 2>&1 | tee -a "$LOG"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Model pull complete" | tee -a "$LOG"

# 7. Verify
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Installed models:" | tee -a "$LOG"
OLLAMA_HOST=http://localhost:8000 ollama list | tee -a "$LOG"

# 8. Quick inference test
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Running inference test..." | tee -a "$LOG"
curl -s http://localhost:8000/api/chat \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3.6:35b-a3b","messages":[{"role":"user","content":"Say OK"}],"stream":false,"think":false,"options":{"num_predict":10}}' \
  >> "$LOG" 2>&1 && echo "" >> "$LOG"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Inference test done" | tee -a "$LOG"

# 9. Write final startup.sh to network volume
cat > /workspace/startup.sh << 'STARTUP_EOF'
#!/bin/bash
# startup.sh — RTX PRO 4500 pod start script (v2)
# RunPod pod settings:
#   Image:         runpod/base:0.6.1-cuda12.2.0
#   Start Command: bash /workspace/startup.sh
#   HTTP Port:     8000
#   Network Vol:   50GB -> /workspace

LOG=/workspace/startup.log
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Pod startup began" | tee -a "$LOG"

# Fix DNS
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 8.8.4.4" >> /etc/resolv.conf

# Link model store
mkdir -p /root/.ollama
if [ ! -L /root/.ollama/models ]; then
    rm -rf /root/.ollama/models
    ln -s /workspace/ollama /root/.ollama/models
fi

# Load Ollama binary from network volume cache (fast, no DNS needed)
mkdir -p /workspace/bin
if [ -f /workspace/bin/ollama ]; then
    cp /workspace/bin/ollama /usr/local/bin/ollama
    chmod +x /usr/local/bin/ollama
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Ollama loaded from /workspace/bin cache" | tee -a "$LOG"
elif ! which ollama > /dev/null 2>&1; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Installing Ollama from internet (fallback)..." | tee -a "$LOG"
    curl -fsSL https://ollama.com/install.sh | sh >> "$LOG" 2>&1
    cp /usr/local/bin/ollama /workspace/bin/ollama
fi

# Kill stale Ollama processes
pkill -f "ollama serve" 2>/dev/null || true
sleep 2

# Start Ollama on port 8000
# KEEP_ALIVE=-1: model stays in VRAM for entire session, never unloads
OLLAMA_HOST=0.0.0.0:8000 \
OLLAMA_FLASH_ATTENTION=1 \
OLLAMA_KV_CACHE_TYPE=q8_0 \
OLLAMA_NUM_PARALLEL=1 \
OLLAMA_KEEP_ALIVE=-1 \
nohup ollama serve >> "$LOG" 2>&1 &

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Ollama starting on :8000" | tee -a "$LOG"

# Wait until ready (max 120s)
for i in $(seq 1 120); do
    curl -s http://localhost:8000/api/tags > /dev/null 2>&1 && break
    sleep 1
done

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Startup complete. READY." | tee -a "$LOG"

# Keep container alive — critical, without this pod restarts in a loop
sleep infinity
STARTUP_EOF

chmod +x /workspace/startup.sh
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] startup.sh written to /workspace/" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ========== BOOTSTRAP COMPLETE ==========" | tee -a "$LOG"
echo "Network volume contents:" | tee -a "$LOG"
du -sh /workspace/* 2>/dev/null | tee -a "$LOG"
echo "" | tee -a "$LOG"
echo "Next time: deploy pod with 'bash /workspace/startup.sh' as start command." | tee -a "$LOG"
echo "Pod boots in ~2 min. Ollama serves qwen3.6:35b-a3b on port 8000." | tee -a "$LOG"

# Keep container alive — without this the bootstrap exits, pod restarts, and bootstrap runs again
sleep infinity
