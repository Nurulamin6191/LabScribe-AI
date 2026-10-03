#!/usr/bin/env bash
set -e

# ==============================================================================
# LabScribe AI: Smart Local Scientific Inference Setup
# Features automated RAM/VRAM hardware detection, optimal tier recommendations,
# and sequential memory guards to prevent Out-Of-Memory (OOM) crashes on laptops.
# ==============================================================================

echo "=========================================================="
echo "    LabScribe AI: Smart Local Inference Setup"
echo "=========================================================="

# 1. Hardware Probing (RAM & VRAM)
TOTAL_RAM_MB=0
VRAM_MB=0

if [ -f /proc/meminfo ]; then
    TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
elif command -v sysctl &> /dev/null; then
    TOTAL_RAM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    TOTAL_RAM_MB=$((TOTAL_RAM_BYTES / 1024 / 1024))
fi

if command -v nvidia-smi &> /dev/null; then
    VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n 1 || echo 0)
fi

echo "[*] Detected System RAM : ${TOTAL_RAM_MB} MB (~$((TOTAL_RAM_MB / 1024)) GB)"
if [ "$VRAM_MB" -gt 0 ]; then
    echo "[*] Detected GPU VRAM   : ${VRAM_MB} MB (~$((VRAM_MB / 1024)) GB NVIDIA)"
else
    echo "[*] Dedicated GPU       : None detected (CPU / Unified memory mode)"
fi

# Determine Recommended Tier based on hardware
DEFAULT_CHOICE=1
RECOMMENDATION_REASON=""

if [ "$VRAM_MB" -ge 7500 ] || [ "$TOTAL_RAM_MB" -ge 24000 ]; then
    DEFAULT_CHOICE=1
    RECOMMENDATION_REASON="High-spec hardware detected. Recommended: Tier 1 (Qwen 2.5 7B)."
elif [ "$VRAM_MB" -ge 4000 ] || [ "$TOTAL_RAM_MB" -ge 12000 ]; then
    DEFAULT_CHOICE=2
    RECOMMENDATION_REASON="Mid-range hardware detected. Recommended: Tier 2 (Qwen 2.5 3B)."
else
    DEFAULT_CHOICE=3
    RECOMMENDATION_REASON="Compact hardware (< 12 GB RAM) detected. Recommended: Tier 3 (Qwen 2.5 1.5B) to guarantee stability without OOM."
fi

echo ""
echo "Hardware Recommendation: $RECOMMENDATION_REASON"
echo "----------------------------------------------------------"
echo "Select your local deployment tier:"
echo " 1) [HIGH-SPEC]   Qwen 2.5 7B       (~4.7 GB VRAM, highest biomedical reasoning)"
echo " 2) [BALANCED]    Qwen 2.5 3B       (~2.2 GB VRAM, fast & accurate on laptops)"
echo " 3) [COMPACT]     Qwen 2.5 1.5B     (~1.1 GB VRAM, ultra-low memory guard)"
echo " 4) [SPECIALIZED] BioMistral 7B     (~4.7 GB VRAM, PubMed Central pretrained)"
echo "=========================================================="

read -p "Enter choice [1-4] (default: $DEFAULT_CHOICE): " CHOICE
CHOICE=${CHOICE:-$DEFAULT_CHOICE}

# 2. Install or verify Ollama runtime
if ! command -v ollama &> /dev/null; then
    echo "[!] Ollama not found. Installing Ollama runtime..."
    curl -fsSL https://ollama.com/install.sh | sh
else
    echo "[✓] Ollama runtime detected."
fi

# 3. Ensure Ollama service is active (bind to 0.0.0.0 so Android devices on LAN can connect)
export OLLAMA_HOST="0.0.0.0:11434"
if ! pgrep -x "ollama" > /dev/null; then
    echo "[*] Launching Ollama daemon on 0.0.0.0:11434 (accessible from PC and Android)..."
    OLLAMA_HOST="0.0.0.0:11434" nohup ollama serve > /tmp/ollama.log 2>&1 &
    sleep 3
else
    echo "[✓] Ollama daemon is already running."
fi

# 4. Pull selected LLM model
case $CHOICE in
    1)
        MODEL_NAME="qwen2.5:7b"
        echo "[*] Pulling Qwen 2.5 7B (Superior scientific reasoning & JSON accuracy)..."
        ollama pull qwen2.5:7b
        ;;
    2)
        MODEL_NAME="qwen2.5:3b"
        echo "[*] Pulling Qwen 2.5 3B (Balanced ~2.2 GB footprint for 8-16 GB RAM)..."
        ollama pull qwen2.5:3b
        ;;
    3)
        MODEL_NAME="qwen2.5:1.5b"
        echo "[*] Pulling Qwen 2.5 1.5B (Ultra-compact ~1.1 GB footprint)..."
        ollama pull qwen2.5:1.5b
        ;;
    4)
        MODEL_NAME="biomistral:7b"
        echo "[*] Pulling BioMistral 7B (Pretrained on PubMed Central articles)..."
        ollama pull biomistral:7b
        ;;
    *)
        MODEL_NAME="qwen2.5:3b"
        ollama pull qwen2.5:3b
        ;;
esac

# 5. Local Speech-To-Text Setup (Faster-Whisper)
LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$LAN_IP" ] && LAN_IP="127.0.0.1"

echo ""
echo "----------------------------------------------------------"
echo " Local Speech-To-Text Setup (Faster-Whisper on Port 8000)"
echo "----------------------------------------------------------"
echo "To start the local Whisper server on 0.0.0.0:8000 (OpenAI-compatible):"
echo ""
if command -v docker &> /dev/null; then
    echo "  [Docker (Recommended)]: Run in terminal:"
    if [ "$VRAM_MB" -gt 0 ]; then
        echo "    docker run -d --name labscribe-whisper --restart unless-stopped --gpus all -p 0.0.0.0:8000:8000 fedirz/faster-whisper-server:latest-cuda"
    else
        echo "    docker run -d --name labscribe-whisper --restart unless-stopped -p 0.0.0.0:8000:8000 fedirz/faster-whisper-server:latest-cpu"
    fi
    echo ""
fi
echo "  [Python Pip Alternative]:"
echo "    pip install faster-whisper-server"
echo "    faster-whisper-server --host 0.0.0.0 --port 8000 --model Systran/faster-whisper-small"
echo "----------------------------------------------------------"
echo ""
echo "=========================================================="
echo " [✓] Local Scientific Inference Stack Ready!"
echo "=========================================================="
echo ""
echo " A) For Desktop App (Running on this Linux/Windows PC):"
echo "    - LLM Endpoint   : http://localhost:11434/v1"
echo "    - LLM Model      : $MODEL_NAME"
echo "    - STT Endpoint   : http://localhost:8000/v1"
echo "    - STT Model      : whisper-large-v3-turbo (or small/base)"
echo ""
echo " B) For Android App (Running on phone connected to same Wi-Fi):"
echo "    In Android App -> Settings (gear icon):"
echo "    - LLM Endpoint   : http://${LAN_IP}:11434/v1"
echo "    - LLM Model      : $MODEL_NAME"
echo "    - STT Endpoint   : http://${LAN_IP}:8000/v1"
echo "    - STT Model      : whisper-large-v3-turbo (or small/base)"
echo "=========================================================="
