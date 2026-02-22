#!/bin/bash
set -e

echo "=== AI-Toolkit Setup (Docker Image) ==="
echo "Image: vastai/ostris-ai-toolkit:50664c2-cuda-12.9"
START_TIME=$SECONDS

# ============================================
# Paths — Docker image has ai-toolkit at /app/ai-toolkit
# We symlink to /workspace for convenience
# ============================================
AITK_DIR="/app/ai-toolkit"
WORKSPACE=${WORKSPACE:-/workspace}
mkdir -p "$WORKSPACE"

# Symlink so /workspace/ai-toolkit also works
if [ ! -e "$WORKSPACE/ai-toolkit" ] && [ -d "$AITK_DIR" ]; then
    ln -s "$AITK_DIR" "$WORKSPACE/ai-toolkit"
    echo "Symlinked $AITK_DIR → $WORKSPACE/ai-toolkit"
fi

# ============================================
# B2 Sync Paths — Configurable via env vars
# ============================================
B2_DATASETS_PATH=${B2_DATASETS_PATH:-aitoolkit_datasets}
B2_CONFIGS_PATH=${B2_CONFIGS_PATH:-aitoolkit_configs}
B2_OUTPUTS_PATH=${B2_OUTPUTS_PATH:-aitoolkit_outputs}

# ============================================
# 1. Install rclone & Configure B2
# ============================================
echo ""
echo "=== Installing rclone ==="
curl -s https://rclone.org/install.sh | bash

echo "Configuring rclone for B2..."
mkdir -p ~/.config/rclone
cat > ~/.config/rclone/rclone.conf << EOF
[b2]
type = b2
account = ${B2_APP_KEY_ID:-$B2_KEY_ID}
key = $B2_APP_KEY
hard_delete = true
EOF

# ============================================
# 2. Configure HuggingFace Token
# ============================================
if [ -n "$HF_TOKEN" ]; then
    echo "Configuring HF_TOKEN..."
    # Write to ai-toolkit .env (auto-loaded by python-dotenv)
    cat > "$AITK_DIR/.env" << EOF
HF_TOKEN=$HF_TOKEN
HF_HUB_ENABLE_HF_TRANSFER=1
EOF
    echo "HF_TOKEN configured in $AITK_DIR/.env"
else
    echo "WARNING: HF_TOKEN not set — gated models (FLUX.1-dev, SD3.5, WAN) will fail to download"
fi

# ============================================
# Rclone tuning — optimized for large files over fast datacenter links
# ============================================
RCLONE_FLAGS=(
    --transfers 16              # concurrent file transfers (default: 4)
    --checkers 16               # concurrent file checks (default: 8)
    --multi-thread-streams 8    # streams per large file (default: 4)
    --multi-thread-cutoff 50M   # use multi-thread for files >50MB
    --buffer-size 64M           # read-ahead buffer (default: 16M)
    --fast-list                 # batch directory listings (fewer API calls)
    --b2-download-concurrency 16 # B2-specific parallel chunk downloads
    --ignore-existing           # skip files already present (saves time on restarts)
)

# ============================================
# 3. Sync Datasets & Configs from B2 (parallel)
# ============================================
if [ -n "$B2_BUCKET" ]; then
    echo ""
    echo "=== Syncing Datasets & Configs from B2 (parallel) ==="
    SYNC_START=$SECONDS

    mkdir -p "$AITK_DIR/datasets"
    mkdir -p "$AITK_DIR/config"

    # Sync datasets in background
    (
        echo "[sync:datasets] Starting..."
        echo "[sync:datasets] Source: b2:$B2_BUCKET/$B2_DATASETS_PATH"
        echo "[sync:datasets] Dest:   $AITK_DIR/datasets"
        rclone copy "b2:$B2_BUCKET/$B2_DATASETS_PATH" "$AITK_DIR/datasets" \
            --exclude "archive/**" \
            "${RCLONE_FLAGS[@]}" 2>&1 || true
        echo "[sync:datasets] Done."
    ) &
    PID_DATASETS=$!

    # Sync configs in background
    (
        echo "[sync:configs] Starting..."
        echo "[sync:configs] Source: b2:$B2_BUCKET/$B2_CONFIGS_PATH"
        echo "[sync:configs] Dest:   $AITK_DIR/config"
        rclone copy "b2:$B2_BUCKET/$B2_CONFIGS_PATH" "$AITK_DIR/config" \
            "${RCLONE_FLAGS[@]}" 2>&1 || true
        echo "[sync:configs] Done."
    ) &
    PID_CONFIGS=$!

    echo "Waiting for parallel syncs to finish..."
    SYNC_FAILED=0
    wait "$PID_DATASETS" || ((SYNC_FAILED++))
    wait "$PID_CONFIGS" || ((SYNC_FAILED++))

    SYNC_ELAPSED=$((SECONDS - SYNC_START))
    SYNC_MIN=$((SYNC_ELAPSED / 60))
    SYNC_SEC=$((SYNC_ELAPSED % 60))
    echo "=== Syncs finished in ${SYNC_MIN}m ${SYNC_SEC}s (${SYNC_FAILED} failures) ==="

    # Summary
    echo "Local datasets:"
    ls -lh "$AITK_DIR/datasets" 2>/dev/null || echo "  (empty)"
    echo "Local configs:"
    ls -lh "$AITK_DIR/config"/*.yaml "$AITK_DIR/config"/*.yml 2>/dev/null || echo "  (no custom configs)"
else
    echo "Skipping B2 sync (B2_BUCKET not configured)"
fi

# ============================================
# 5. Generate Helper Scripts
# ============================================
echo ""
echo "Creating helper scripts..."

# train.sh — Run CLI training
cat > "$AITK_DIR/train.sh" << 'SCRIPT'
#!/bin/bash
cd /app/ai-toolkit
if [ -z "$1" ]; then
    echo "Usage: ./train.sh config/your_config.yaml"
    echo ""
    echo "Available configs:"
    ls -1 /app/ai-toolkit/config/*.yaml /app/ai-toolkit/config/*.yml 2>/dev/null || echo "  (none found)"
    echo ""
    echo "Example configs:"
    ls -1 /app/ai-toolkit/config/examples/ 2>/dev/null | head -15
    exit 1
fi
echo "Starting training with: $1"
python run.py "$1"
SCRIPT
chmod +x "$AITK_DIR/train.sh"

# sync_outputs.sh — Push training outputs to B2
cat > "$AITK_DIR/sync_outputs.sh" << 'SCRIPT'
#!/bin/bash
cd /app/ai-toolkit
HOSTNAME=$(hostname)
B2_OUTPUTS_PATH=${B2_OUTPUTS_PATH:-aitoolkit_outputs}
if [ -z "$B2_BUCKET" ]; then
    echo "Error: B2_BUCKET not set"
    exit 1
fi
echo "Syncing outputs to b2:$B2_BUCKET/$B2_OUTPUTS_PATH/$HOSTNAME"
rclone copy output "b2:$B2_BUCKET/$B2_OUTPUTS_PATH/$HOSTNAME" --progress
echo ""
echo "Done! Uploaded to: b2:$B2_BUCKET/$B2_OUTPUTS_PATH/$HOSTNAME"
echo ""
echo "To download from another machine:"
echo "  rclone copy b2:$B2_BUCKET/$B2_OUTPUTS_PATH/$HOSTNAME ./downloaded_outputs --progress"
SCRIPT
chmod +x "$AITK_DIR/sync_outputs.sh"

# sync_lora_to_comfy.sh — Copy finished LoRA to comfy_models bucket path
cat > "$AITK_DIR/sync_lora_to_comfy.sh" << 'SCRIPT'
#!/bin/bash
if [ -z "$1" ]; then
    echo "Usage: ./sync_lora_to_comfy.sh output/my_lora_v1/my_lora_v1.safetensors"
    echo ""
    echo "Copies a trained LoRA .safetensors file to your B2 comfy_models/loras/ path"
    echo "so it's available next time you spin up a ComfyUI instance."
    exit 1
fi
if [ -z "$B2_BUCKET" ]; then
    echo "Error: B2_BUCKET not set"
    exit 1
fi
LORA_FILE="$1"
LORA_NAME=$(basename "$LORA_FILE")
echo "Uploading $LORA_NAME → b2:$B2_BUCKET/comfy_models/loras/$LORA_NAME"
rclone copyto "$LORA_FILE" "b2:$B2_BUCKET/comfy_models/loras/$LORA_NAME" --progress
echo ""
echo "Done! LoRA will be synced to ComfyUI on next instance launch."
SCRIPT
chmod +x "$AITK_DIR/sync_lora_to_comfy.sh"

echo "Helper scripts created: train.sh, sync_outputs.sh, sync_lora_to_comfy.sh"

# ============================================
# 6. Setup Time
# ============================================
ELAPSED=$((SECONDS - START_TIME))
MINUTES=$((ELAPSED / 60))
SECS=$((ELAPSED % 60))

echo ""
echo "============================================"
echo "Setup complete! (took ${MINUTES}m ${SECS}s)"
echo "============================================"
echo "Instance hostname: $(hostname)"
echo ""
echo "============================================"
echo "ACCESS — SSH Tunnel Required"
echo "============================================"
echo "Web UI (already running on port 8675):"
echo "  ssh -p <SSH_PORT> root@<PUBLIC_IP> -L 8675:localhost:8675"
echo "  Then open: http://localhost:8675"
echo ""
echo "============================================"
echo "TRAINING"
echo "============================================"
echo "  CLI:    cd /app/ai-toolkit && python run.py config/my_lora.yaml"
echo "  Helper: ./train.sh config/my_lora.yaml"
echo "  tmux:   tmux new -s train  (detach: Ctrl+B,D  reattach: tmux a -t train)"
echo ""
echo "============================================"
echo "SYNC"
echo "============================================"
echo "  Sync outputs to B2:          ./sync_outputs.sh"
echo "  Copy LoRA to ComfyUI bucket: ./sync_lora_to_comfy.sh output/name/name.safetensors"
echo "  Re-sync datasets:            rclone copy b2:\$B2_BUCKET/$B2_DATASETS_PATH $AITK_DIR/datasets --progress"
echo "  Re-sync configs:             rclone copy b2:\$B2_BUCKET/$B2_CONFIGS_PATH $AITK_DIR/config --progress"
echo ""
echo "============================================"
echo "ENV VARS (set in vast.ai template)"
echo "============================================"
echo "  HF_TOKEN         - HuggingFace token (REQUIRED for gated models)"
echo "  B2_BUCKET         - B2 bucket name"
echo "  B2_APP_KEY_ID     - B2 account ID"
echo "  B2_APP_KEY        - B2 application key"
echo "  B2_DATASETS_PATH  - Datasets path in bucket (default: aitoolkit_datasets)"
echo "  B2_CONFIGS_PATH   - Configs path in bucket (default: aitoolkit_configs)"
echo "  B2_OUTPUTS_PATH   - Outputs path in bucket (default: aitoolkit_outputs)"
