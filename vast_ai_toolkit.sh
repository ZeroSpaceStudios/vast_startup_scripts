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
MODELS_DIR="$AITK_DIR/models"
WORKSPACE=${WORKSPACE:-/workspace}
mkdir -p "$WORKSPACE"

# Symlink so /workspace/ai-toolkit also works
if [ ! -e "$WORKSPACE/ai-toolkit" ] && [ -d "$AITK_DIR" ]; then
    ln -s "$AITK_DIR" "$WORKSPACE/ai-toolkit"
    echo "Symlinked $AITK_DIR → $WORKSPACE/ai-toolkit"
fi

# ============================================
# Two-bucket B2 layout:
#   B2_MODELS_BUCKET — diffusers-format base models (large, rarely change)
#   B2_DATA_BUCKET   — datasets, configs, training outputs (smaller, change often)
#
# Both buckets use the same B2 account credentials.
# ============================================
B2_MODELS_PATH=${B2_MODELS_PATH:-models}
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
# 2. Configure HuggingFace Token (optional fallback)
# ============================================
# Models are synced from B2, but HF_TOKEN is still useful if a config
# references a HuggingFace repo ID instead of a local path.
if [ -n "$HF_TOKEN" ]; then
    echo "Configuring HF_TOKEN (optional fallback for HF downloads)..."
    cat > "$AITK_DIR/.env" << EOF
HF_TOKEN=$HF_TOKEN
HF_HUB_ENABLE_HF_TRANSFER=1
EOF
    echo "HF_TOKEN configured in $AITK_DIR/.env"
else
    echo "HF_TOKEN not set (OK — models sync from B2. Set HF_TOKEN if you need HF downloads as fallback)"
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
# 3. Sync Base Models from B2_MODELS_BUCKET
# ============================================
# Models must be in diffusers format (not single .safetensors checkpoints).
# Example bucket layout:
#   models-bucket/models/FLUX.1-dev/
#     ├── model_index.json
#     ├── transformer/
#     ├── vae/
#     ├── text_encoder/
#     └── ...
#
# Training configs then reference: models/FLUX.1-dev (relative to AITK_DIR)
# ============================================
if [ -n "$B2_MODELS_BUCKET" ]; then
    echo ""
    echo "=== Syncing Base Models from B2 ==="
    echo "Source: b2:$B2_MODELS_BUCKET/$B2_MODELS_PATH"
    echo "Dest:   $MODELS_DIR"
    MODELS_SYNC_START=$SECONDS

    mkdir -p "$MODELS_DIR"

    rclone copy "b2:$B2_MODELS_BUCKET/$B2_MODELS_PATH" "$MODELS_DIR" \
        --exclude "archive/**" \
        "${RCLONE_FLAGS[@]}" 2>&1

    MODELS_SYNC_ELAPSED=$((SECONDS - MODELS_SYNC_START))
    MODELS_SYNC_MIN=$((MODELS_SYNC_ELAPSED / 60))
    MODELS_SYNC_SEC=$((MODELS_SYNC_ELAPSED % 60))
    echo "=== Models sync finished in ${MODELS_SYNC_MIN}m ${MODELS_SYNC_SEC}s ==="

    echo "Local models:"
    ls -1d "$MODELS_DIR"/*/ 2>/dev/null | while read -r d; do
        echo "  $(basename "$d")"
    done || echo "  (none)"
else
    echo ""
    echo "Skipping model sync (B2_MODELS_BUCKET not configured)"
fi

# ============================================
# 4. Sync Datasets & Configs from B2_DATA_BUCKET (parallel)
# ============================================
if [ -n "$B2_DATA_BUCKET" ]; then
    echo ""
    echo "=== Syncing Datasets & Configs from B2 (parallel) ==="
    DATA_SYNC_START=$SECONDS

    mkdir -p "$AITK_DIR/datasets"
    mkdir -p "$AITK_DIR/config"

    # Sync datasets in background
    (
        echo "[sync:datasets] Starting..."
        echo "[sync:datasets] Source: b2:$B2_DATA_BUCKET/$B2_DATASETS_PATH"
        echo "[sync:datasets] Dest:   $AITK_DIR/datasets"
        rclone copy "b2:$B2_DATA_BUCKET/$B2_DATASETS_PATH" "$AITK_DIR/datasets" \
            --exclude "archive/**" \
            "${RCLONE_FLAGS[@]}" 2>&1 || true
        echo "[sync:datasets] Done."
    ) &
    PID_DATASETS=$!

    # Sync configs in background
    (
        echo "[sync:configs] Starting..."
        echo "[sync:configs] Source: b2:$B2_DATA_BUCKET/$B2_CONFIGS_PATH"
        echo "[sync:configs] Dest:   $AITK_DIR/config"
        rclone copy "b2:$B2_DATA_BUCKET/$B2_CONFIGS_PATH" "$AITK_DIR/config" \
            "${RCLONE_FLAGS[@]}" 2>&1 || true
        echo "[sync:configs] Done."
    ) &
    PID_CONFIGS=$!

    echo "Waiting for parallel syncs to finish..."
    SYNC_FAILED=0
    wait "$PID_DATASETS" || ((SYNC_FAILED++))
    wait "$PID_CONFIGS" || ((SYNC_FAILED++))

    DATA_SYNC_ELAPSED=$((SECONDS - DATA_SYNC_START))
    DATA_SYNC_MIN=$((DATA_SYNC_ELAPSED / 60))
    DATA_SYNC_SEC=$((DATA_SYNC_ELAPSED % 60))
    echo "=== Data syncs finished in ${DATA_SYNC_MIN}m ${DATA_SYNC_SEC}s (${SYNC_FAILED} failures) ==="

    # Summary
    echo "Local datasets:"
    ls -lh "$AITK_DIR/datasets" 2>/dev/null || echo "  (empty)"
    echo "Local configs:"
    ls -lh "$AITK_DIR/config"/*.yaml "$AITK_DIR/config"/*.yml 2>/dev/null || echo "  (no custom configs)"
else
    echo ""
    echo "Skipping data sync (B2_DATA_BUCKET not configured)"
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
    echo ""
    echo "Local models:"
    ls -1d /app/ai-toolkit/models/*/ 2>/dev/null | xargs -I{} basename {} || echo "  (none)"
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
if [ -z "$B2_DATA_BUCKET" ]; then
    echo "Error: B2_DATA_BUCKET not set"
    exit 1
fi
echo "Syncing outputs to b2:$B2_DATA_BUCKET/$B2_OUTPUTS_PATH/$HOSTNAME"
rclone copy output "b2:$B2_DATA_BUCKET/$B2_OUTPUTS_PATH/$HOSTNAME" --progress
echo ""
echo "Done! Uploaded to: b2:$B2_DATA_BUCKET/$B2_OUTPUTS_PATH/$HOSTNAME"
echo ""
echo "To download from another machine:"
echo "  rclone copy b2:$B2_DATA_BUCKET/$B2_OUTPUTS_PATH/$HOSTNAME ./downloaded_outputs --progress"
SCRIPT
chmod +x "$AITK_DIR/sync_outputs.sh"

# sync_lora_to_comfy.sh — Copy finished LoRA to ComfyUI models bucket
# Note: This uploads to B2_MODELS_BUCKET (the models bucket), not B2_DATA_BUCKET
cat > "$AITK_DIR/sync_lora_to_comfy.sh" << 'SCRIPT'
#!/bin/bash
if [ -z "$1" ]; then
    echo "Usage: ./sync_lora_to_comfy.sh output/my_lora_v1/my_lora_v1.safetensors"
    echo ""
    echo "Copies a trained LoRA .safetensors file to your B2 models bucket"
    echo "so it's available next time you spin up a ComfyUI instance."
    exit 1
fi
if [ -z "$B2_MODELS_BUCKET" ]; then
    echo "Error: B2_MODELS_BUCKET not set"
    exit 1
fi
LORA_FILE="$1"
LORA_NAME=$(basename "$LORA_FILE")
echo "Uploading $LORA_NAME → b2:$B2_MODELS_BUCKET/comfy_models/loras/$LORA_NAME"
rclone copyto "$LORA_FILE" "b2:$B2_MODELS_BUCKET/comfy_models/loras/$LORA_NAME" --progress
echo ""
echo "Done! LoRA will be synced to ComfyUI on next instance launch."
SCRIPT
chmod +x "$AITK_DIR/sync_lora_to_comfy.sh"

echo "Helper scripts created: train.sh, sync_outputs.sh, sync_lora_to_comfy.sh"

# ============================================
# 6. Setup Summary
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
echo "LOCAL MODELS (for training config name_or_path)"
echo "============================================"
if [ -d "$MODELS_DIR" ] && ls -1d "$MODELS_DIR"/*/ >/dev/null 2>&1; then
    ls -1d "$MODELS_DIR"/*/ 2>/dev/null | while read -r d; do
        echo "  models/$(basename "$d")"
    done
    echo ""
    echo "Use in your config YAML:"
    echo "  model:"
    echo "    name_or_path: \"models/$(basename "$(ls -1d "$MODELS_DIR"/*/ 2>/dev/null | head -1)")\""
else
    echo "  (no models synced — set B2_MODELS_BUCKET)"
fi
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
echo "  Re-sync datasets:            rclone copy b2:\$B2_DATA_BUCKET/$B2_DATASETS_PATH $AITK_DIR/datasets --progress"
echo "  Re-sync configs:             rclone copy b2:\$B2_DATA_BUCKET/$B2_CONFIGS_PATH $AITK_DIR/config --progress"
echo "  Re-sync models:              rclone copy b2:\$B2_MODELS_BUCKET/$B2_MODELS_PATH $MODELS_DIR --progress"
echo ""
echo "============================================"
echo "ENV VARS (set in vast.ai template)"
echo "============================================"
echo "  B2_MODELS_BUCKET  - B2 bucket for base models (diffusers format)"
echo "  B2_DATA_BUCKET    - B2 bucket for datasets, configs, outputs"
echo "  B2_APP_KEY_ID     - B2 account ID"
echo "  B2_APP_KEY        - B2 application key"
echo "  HF_TOKEN          - HuggingFace token (optional fallback)"
echo ""
echo "  B2_MODELS_PATH    - Models path in bucket (default: models)"
echo "  B2_DATASETS_PATH  - Datasets path in bucket (default: aitoolkit_datasets)"
echo "  B2_CONFIGS_PATH   - Configs path in bucket (default: aitoolkit_configs)"
echo "  B2_OUTPUTS_PATH   - Outputs path in bucket (default: aitoolkit_outputs)"
