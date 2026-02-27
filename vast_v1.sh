#!/bin/bash
set -e

echo "=== Custom ComfyUI Setup ==="
START_TIME=$SECONDS

# Initialize conda environment
echo "Initializing conda..."
source /opt/miniforge3/etc/profile.d/conda.sh
conda activate main
echo "Conda environment: $CONDA_DEFAULT_ENV"
echo "Python path: $(which python)"
echo "Pip path: $(which pip)"

# Use WORKSPACE if set, otherwise default to /workspace
WORKSPACE=${WORKSPACE:-/workspace}
mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

# ============================================
# CUSTOM NODES - Add your GitHub URLs here
# ============================================
CUSTOM_NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
    "https://github.com/rgthree/rgthree-comfy.git"
    "https://github.com/kijai/ComfyUI-KJNodes.git"
    "https://github.com/ShmuelRonen/ComfyUI-VideoUpscale_WithModel.git"
    "https://github.com/neonvoid/ComfyUI-GIMM-VFI_nvFork.git"
    "https://github.com/neonvoid/ComfyUI-SAM3_nvFork.git"
    "https://github.com/kijai/ComfyUI-WanVideoWrapper.git"
    "https://github.com/neonvoid/NV_Comfy_Utils.git"
    "https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git"
    "https://github.com/yolain/ComfyUI-Easy-Use.git"
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
    "https://github.com/BadCafeCode/masquerade-nodes-comfyui.git"
    "https://github.com/evanspearman/ComfyMath.git"
    "https://github.com/munkyfoot/ComfyUI-TextOverlay.git"
    "https://github.com/chflame163/ComfyUI_LayerStyle.git"
    "https://github.com/ltdrdata/was-node-suite-comfyui.git"
    "https://github.com/crystian/ComfyUI-Crystools.git"
)

# ============================================
# B2 MODEL SYNC - Set your bucket path here
# ============================================
# Bucket structure should mirror ComfyUI models folder:
#   bucket-name/comfy_models/diffusion_models/
#   bucket-name/comfy_models/controlnet/
#   bucket-name/comfy_models/clip/
#   bucket-name/comfy_models/clip_vision/
#   bucket-name/comfy_models/loras/
#   bucket-name/comfy_models/text_encoders/
#   bucket-name/comfy_models/vae/
#   bucket-name/comfy_models/upscale_models/
# B2_BUCKET is set via vast.ai environment variables
B2_MODELS_PATH="comfy_models"
B2_WORKFLOWS_PATH="comfy_workflows"

# Install rclone
echo "Installing rclone..."
curl -s https://rclone.org/install.sh | bash

# Configure rclone for B2 (non-interactive)
echo "Configuring rclone for B2..."
mkdir -p ~/.config/rclone
cat > ~/.config/rclone/rclone.conf << EOF
[b2]
type = b2
account = ${B2_APP_KEY_ID:-$B2_KEY_ID}
key = $B2_APP_KEY
hard_delete = true
EOF

# Clone ComfyUI if not present
echo "Setting up ComfyUI..."
if [ ! -d "$WORKSPACE/ComfyUI" ]; then
    git clone https://github.com/comfyanonymous/ComfyUI.git
fi

cd "$WORKSPACE/ComfyUI"

# Install ComfyUI requirements
echo "Installing ComfyUI dependencies..."
echo "Using pip at: $(which pip)"
pip install -r requirements.txt --no-cache-dir
echo "Verifying install - safetensors location: $(python -c 'import safetensors; print(safetensors.__file__)' 2>&1)"

# ============================================
# Install Custom Nodes
# ============================================
echo "=== Installing Custom Nodes ==="
mkdir -p "$WORKSPACE/ComfyUI/custom_nodes"
cd "$WORKSPACE/ComfyUI/custom_nodes"

for repo_url in "${CUSTOM_NODES[@]}"; do
    # Skip empty lines and comments
    [[ -z "$repo_url" || "$repo_url" =~ ^# ]] && continue

    # Extract repo name from URL
    repo_name=$(basename "$repo_url" .git)

    echo "--- Cloning $repo_name ---"
    git clone "$repo_url"

    # Install requirements if they exist
    if [ -f "$repo_name/requirements.txt" ]; then
        echo "Installing dependencies for $repo_name..."
        pip install -r "$repo_name/requirements.txt" --no-cache-dir
    fi

    # Run install.py if it exists (some nodes use this)
    if [ -f "$repo_name/install.py" ]; then
        echo "Running install.py for $repo_name..."
        cd "$repo_name"
        python install.py
        cd ..
    fi
done

echo "=== Custom Nodes Installation Complete ==="
cd "$WORKSPACE/ComfyUI"

# ===========================================
# Configure NV_Comfy_Utils .env (Slack Integration)
# ===========================================
NV_UTILS_DIR="$WORKSPACE/ComfyUI/custom_nodes/NV_Comfy_Utils"
if [ -n "$SLACK_BOT_TOKEN" ] && [ -d "$NV_UTILS_DIR" ]; then
    echo "Creating NV_Comfy_Utils .env file..."
    cat > "$NV_UTILS_DIR/.env" << EOF
# NV_Comfy_Utils - Slack Integration Config
SLACK_BOT_TOKEN=$SLACK_BOT_TOKEN
SLACK_ERROR_CHANNEL=${SLACK_ERROR_CHANNEL:-}
EOF
    echo "NV_Comfy_Utils .env configured"
elif [ -n "$SLACK_BOT_TOKEN" ]; then
    echo "Warning: SLACK_BOT_TOKEN set but NV_Comfy_Utils directory not found"
else
    echo "Skipping NV_Comfy_Utils .env (SLACK_BOT_TOKEN not configured)"
fi

# ============================================
# Install SageAttention V2 (CUDA kernel build)
# ============================================
# SageAttention V2 provides ~35% faster attention for WAN/Flux/etc.
# Must be built from source — PyPI only has V1 (Triton-only, slower).
# Built wheel is cached in /workspace/wheels/ so restarts don't rebuild.
#
# IMPORTANT: Do NOT use --use-sage-attention CLI flag with ComfyUI.
# It causes black output with WAN/Qwen models (Triton backend issue).
# Instead use KJNodes "Patch Sage Attention" node in workflows with
# backend = sageattn_qk_int8_pv_fp16_cuda
# ============================================
install_sageattention() {
    echo "=== SageAttention V2 Setup ==="
    local SA_START=$SECONDS

    # --- Already installed? (handles instance restart with persistent env) ---
    if python -c "from sageattention import sageattn; print('SageAttention already installed')" 2>/dev/null; then
        echo "SageAttention already available, skipping build."
        return 0
    fi

    # --- nvcc available? (needs devel Docker image with CUDA toolkit) ---
    export CUDA_HOME=${CUDA_HOME:-/usr/local/cuda}
    export PATH="$CUDA_HOME/bin:$PATH"
    export LD_LIBRARY_PATH="$CUDA_HOME/lib64:${LD_LIBRARY_PATH:-}"

    if ! command -v nvcc &>/dev/null; then
        echo "WARNING: nvcc not found. SageAttention requires CUDA toolkit (devel Docker image)."
        echo "Skipping SageAttention — ComfyUI will work without it."
        return 0
    fi
    echo "CUDA_HOME=$CUDA_HOME"
    echo "nvcc: $(nvcc --version | tail -1)"

    # --- Detect GPU compute capability ---
    local GPU_CC
    GPU_CC=$(python -c "
import torch
if torch.cuda.is_available():
    major, minor = torch.cuda.get_device_capability(0)
    print(f'{major}.{minor}')
else:
    print('none')
" 2>/dev/null)

    if [ -z "$GPU_CC" ] || [ "$GPU_CC" = "none" ]; then
        echo "WARNING: Could not detect GPU compute capability. Skipping SageAttention."
        return 0
    fi

    local GPU_NAME
    GPU_NAME=$(python -c "import torch; print(torch.cuda.get_device_name(0))" 2>/dev/null || echo "unknown")
    local SM_TAG="sm${GPU_CC//./}"
    echo "Detected GPU: $GPU_NAME (compute $GPU_CC, $SM_TAG)"

    export TORCH_CUDA_ARCH_LIST="${GPU_CC}+PTX"
    echo "TORCH_CUDA_ARCH_LIST=$TORCH_CUDA_ARCH_LIST"

    # --- Cached wheel available? ---
    local WHEEL_DIR="$WORKSPACE/wheels"
    mkdir -p "$WHEEL_DIR"

    local CACHED_WHEEL
    CACHED_WHEEL=$(ls "$WHEEL_DIR"/sageattention-*-"$SM_TAG".whl 2>/dev/null | head -1)

    if [ -n "$CACHED_WHEEL" ]; then
        echo "Found cached wheel: $(basename "$CACHED_WHEEL")"
        if pip install "$CACHED_WHEEL" 2>&1; then
            echo "Installed SageAttention from cached wheel."
            local SA_ELAPSED=$((SECONDS - SA_START))
            echo "=== SageAttention setup done in ${SA_ELAPSED}s ==="
            return 0
        fi
        echo "WARNING: Cached wheel install failed, rebuilding from source..."
        rm -f "$CACHED_WHEEL"
    fi

    # --- Install triton dependency ---
    echo "Installing triton..."
    pip install triton 2>&1

    # --- Build from source (try main repo, then woct0rdho fork) ---
    local BUILD_DIR="/tmp/sageattention_build"
    local REPOS=(
        "https://github.com/thu-ml/SageAttention.git"
        "https://github.com/woct0rdho/SageAttention.git"
    )

    export MAX_JOBS=$(nproc)
    local BUILD_SUCCESS=false

    for repo_url in "${REPOS[@]}"; do
        echo ""
        echo "--- Building SageAttention from: $repo_url ---"
        echo "    MAX_JOBS=$MAX_JOBS, TORCH_CUDA_ARCH_LIST=$TORCH_CUDA_ARCH_LIST"

        rm -rf "$BUILD_DIR"
        if ! git clone --depth 1 "$repo_url" "$BUILD_DIR" 2>&1; then
            echo "WARNING: Clone failed, trying next repo..."
            continue
        fi

        cd "$BUILD_DIR"

        if pip install . --no-build-isolation 2>&1; then
            echo "Build succeeded, caching wheel..."

            # Cache the wheel for future restarts
            pip wheel . --no-build-isolation --no-deps -w /tmp/sa_wheel/ 2>&1 || true
            local BUILT_WHEEL
            BUILT_WHEEL=$(ls /tmp/sa_wheel/sageattention-*.whl 2>/dev/null | head -1)
            if [ -n "$BUILT_WHEEL" ]; then
                local BASE_NAME
                BASE_NAME=$(basename "$BUILT_WHEEL")
                cp "$BUILT_WHEEL" "$WHEEL_DIR/${BASE_NAME%.whl}-${SM_TAG}.whl"
                echo "Cached: $WHEEL_DIR/${BASE_NAME%.whl}-${SM_TAG}.whl"
            fi
            rm -rf /tmp/sa_wheel/

            BUILD_SUCCESS=true
            break
        else
            echo "WARNING: Build failed, trying next repo..."
        fi

        cd "$WORKSPACE/ComfyUI"
    done

    # --- Cleanup ---
    rm -rf "$BUILD_DIR"
    cd "$WORKSPACE/ComfyUI"

    if [ "$BUILD_SUCCESS" = true ]; then
        python -c "from sageattention import sageattn; print('SageAttention V2 installed successfully')" 2>&1 || true
        local SA_ELAPSED=$((SECONDS - SA_START))
        echo "=== SageAttention V2 build done in ${SA_ELAPSED}s ==="
    else
        echo ""
        echo "WARNING: SageAttention V2 installation failed."
        echo "ComfyUI will still work — just without SageAttention acceleration."
        echo "Manual rebuild:"
        echo "  export CUDA_HOME=/usr/local/cuda TORCH_CUDA_ARCH_LIST=\"${GPU_CC}+PTX\""
        echo "  pip install triton"
        echo "  git clone https://github.com/thu-ml/SageAttention.git /tmp/sa"
        echo "  cd /tmp/sa && MAX_JOBS=\$(nproc) pip install . --no-build-isolation"
    fi
}

# Run in subshell so build failures don't abort the startup script (set -e is active)
(
    set +e
    install_sageattention
) 2>&1
echo ""

# ============================================
# Rclone tuning — optimized for large model files over fast datacenter links
# ============================================
RCLONE_FLAGS=(
    --transfers 16              # concurrent file transfers (default: 4)
    --checkers 16               # concurrent file checks (default: 8)
    --multi-thread-streams 8    # streams per large file (default: 4)
    --multi-thread-cutoff 50M   # use multi-thread for files >50MB
    --buffer-size 64M           # read-ahead buffer (default: 16M)
    --fast-list                 # batch directory listings (fewer API calls)
    --ignore-existing           # skip files already present (saves time on restarts)
)

# ============================================
# Sync Models from B2 (parallel)
# ============================================
if [ -n "$B2_BUCKET" ]; then
    echo "=== Syncing Models from B2 (parallel) ==="
    SYNC_START=$SECONDS

    MODEL_TYPES=(diffusion_models controlnet clip clip_vision loras text_encoders vae upscale_models)
    SYNC_PIDS=()

    for model_type in "${MODEL_TYPES[@]}"; do
        mkdir -p "$WORKSPACE/ComfyUI/models/$model_type"

        # Each model type syncs in its own background process
        (
            echo "[sync:$model_type] Starting..."
            rclone copy "b2:$B2_BUCKET/$B2_MODELS_PATH/$model_type" \
                "$WORKSPACE/ComfyUI/models/$model_type" \
                --exclude "archive/**" \
                "${RCLONE_FLAGS[@]}" 2>&1 || true
            echo "[sync:$model_type] Done."
        ) &
        SYNC_PIDS+=($!)
    done

    # Also sync workflows in parallel with models
    WORKFLOWS_DIR="$WORKSPACE/ComfyUI/user/default/workflows"
    mkdir -p "$WORKFLOWS_DIR"
    (
        echo "[sync:workflows] Starting..."
        rclone copy "b2:$B2_BUCKET/$B2_WORKFLOWS_PATH" "$WORKFLOWS_DIR" \
            --exclude "archive/**" \
            "${RCLONE_FLAGS[@]}" 2>&1 || true
        echo "[sync:workflows] Done."
    ) &
    SYNC_PIDS+=($!)

    echo "Waiting for ${#SYNC_PIDS[@]} parallel syncs to finish..."
    SYNC_FAILED=0
    for pid in "${SYNC_PIDS[@]}"; do
        wait "$pid" || ((SYNC_FAILED++))
    done

    SYNC_ELAPSED=$((SECONDS - SYNC_START))
    SYNC_MIN=$((SYNC_ELAPSED / 60))
    SYNC_SEC=$((SYNC_ELAPSED % 60))
    echo "=== All syncs finished in ${SYNC_MIN}m ${SYNC_SEC}s (${SYNC_FAILED} failures) ==="

    # Summary of what's on disk
    echo ""
    echo "--- Local model summary ---"
    for model_type in "${MODEL_TYPES[@]}"; do
        COUNT=$(ls -1 "$WORKSPACE/ComfyUI/models/$model_type" 2>/dev/null | wc -l)
        echo "  $model_type: $COUNT files"
    done
    WCOUNT=$(ls -1 "$WORKFLOWS_DIR" 2>/dev/null | wc -l)
    echo "  workflows: $WCOUNT files"
else
    echo "Skipping B2 sync (B2_BUCKET not configured)"
fi

ELAPSED=$((SECONDS - START_TIME))
MINUTES=$((ELAPSED / 60))
SECS=$((ELAPSED % 60))

echo ""
echo "============================================"
echo "Setup complete! (took ${MINUTES}m ${SECS}s)"
echo "============================================"

# Create helper script for restarting ComfyUI
cat > "$WORKSPACE/ComfyUI/start_comfy.sh" << 'SCRIPT'
#!/bin/bash
cd /workspace/ComfyUI
if pgrep -f "python main.py" > /dev/null; then
    echo "ComfyUI already running (PID: $(pgrep -f 'python main.py'))"
    echo "Stop it first: pkill -f 'python main.py'"
    exit 1
fi
source /opt/miniforge3/etc/profile.d/conda.sh
conda activate main
nohup python main.py --listen 127.0.0.1 --port 8188 --max-upload-size 999999999 > /workspace/comfyui.log 2>&1 &
echo "ComfyUI started (PID: $!)"
echo "Logs: tail -f /workspace/comfyui.log"
echo "Access via SSH tunnel: ssh -p <PORT> root@<IP> -L 8189:localhost:8188"
SCRIPT
chmod +x "$WORKSPACE/ComfyUI/start_comfy.sh"

# Start ComfyUI in background (localhost only - requires SSH tunnel)
cd "$WORKSPACE/ComfyUI"
nohup python main.py --listen 127.0.0.1 --port 8188 --max-upload-size 999999999 > /workspace/comfyui.log 2>&1 &
COMFY_PID=$!
echo "ComfyUI started in background (PID: $COMFY_PID)"
echo ""
echo "============================================"
echo "SECURE ACCESS - SSH Tunnel Required"
echo "============================================"
echo "ComfyUI is bound to localhost only (not publicly exposed)"
echo ""
echo "To access, create SSH tunnel from your local machine:"
echo "  ssh -p <SSH_PORT> root@<PUBLIC_IP> -L 8189:localhost:8188"
echo ""
echo "Then open: http://localhost:8189"
echo ""
echo "Note: Use port 8189+ to avoid conflicts with local ComfyUI on 8188"
echo ""
echo "Useful commands:"
echo "  View logs:      tail -f /workspace/comfyui.log"
echo "  Restart:        ./start_comfy.sh"
echo "  Stop:           pkill -f 'python main.py'"
echo "  Sync outputs:   rclone copy /workspace/ComfyUI/output b2:\$B2_BUCKET/comfy_outputs/\$(hostname) --progress"
echo ""
echo "Optional env vars for Slack notifications:"
echo "  SLACK_BOT_TOKEN     - Bot token (xoxb-...)"
echo "  SLACK_ERROR_CHANNEL - Channel name, ID, or user ID for DMs"