#!/bin/bash
# =============================================================================
# VAST.AI SERVERLESS - ComfyUI Provisioning Script
# =============================================================================
# This script runs during worker initialization to set up custom nodes and
# sync models from B2. Unlike the regular vast_v1.sh, this does NOT:
#   - Install ComfyUI (pre-installed in vastai/comfy base image)
#   - Start ComfyUI (pyworker handles this)
#   - Set up conda (base image has Python ready)
#
# Usage: Set PROVISIONING_SCRIPT env var to the raw URL of this script
# =============================================================================

set -e

echo "=== Serverless ComfyUI Provisioning ==="
START_TIME=$SECONDS

# Logging setup (serverless standard)
MODEL_LOG=${MODEL_LOG:-/var/log/portal/comfyui.log}
mkdir -p "$(dirname "$MODEL_LOG")"
exec > >(tee -a "$MODEL_LOG") 2>&1

# Workspace paths (serverless standard)
WORKSPACE_DIR=${WORKSPACE:-/workspace}
COMFYUI_DIR="$WORKSPACE_DIR/ComfyUI"
MODELS_DIR="$COMFYUI_DIR/models"
CUSTOM_NODES_DIR="$COMFYUI_DIR/custom_nodes"

echo "Workspace: $WORKSPACE_DIR"
echo "ComfyUI:   $COMFYUI_DIR"
echo "Models:    $MODELS_DIR"

# Verify ComfyUI exists (should be pre-installed in base image)
if [ ! -d "$COMFYUI_DIR" ]; then
    echo "ERROR: ComfyUI not found at $COMFYUI_DIR"
    echo "This script expects the vastai/comfy base image"
    exit 1
fi

# ============================================
# CUSTOM NODES - Add your GitHub URLs here
# ============================================
CUSTOM_NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
    "https://github.com/rgthree/rgthree-comfy.git"
    "https://github.com/kijai/ComfyUI-KJNodes.git"
    "https://github.com/WASasquatch/was-node-suite-comfyui.git"
    #"https://github.com/ShmuelRonen/ComfyUI-VideoUpscale_WithModel.git"
    #"https://github.com/neonvoid/ComfyUI-GIMM-VFI_nvFork.git"
    #"https://github.com/neonvoid/ComfyUI-SAM3_nvFork.git"
    "https://github.com/chflame163/ComfyUI_LayerStyle.git"
    "https://github.com/neonvoid/comfy-inpaint-crop-fork.git"
    "https://github.com/kijai/ComfyUI-WanVideoWrapper.git"
    "https://github.com/neonvoid/NV_Comfy_Utils.git"
    "https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git"
    "https://github.com/yolain/ComfyUI-Easy-Use.git"
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
    "https://github.com/BadCafeCode/masquerade-nodes-comfyui.git"
    "https://github.com/evanspearman/ComfyMath.git"
    "https://github.com/munkyfoot/ComfyUI-TextOverlay.git"
)

# ============================================
# B2 MODEL SYNC CONFIGURATION
# ============================================
B2_MODELS_PATH="comfy_models"
B2_WORKFLOWS_PATH="comfy_workflows"

# ============================================
# Install rclone for B2 sync
# ============================================
echo ""
echo "=== Installing rclone ==="
if ! command -v rclone &> /dev/null; then
    curl -s https://rclone.org/install.sh | bash
    echo "rclone installed: $(rclone version | head -1)"
else
    echo "rclone already installed: $(rclone version | head -1)"
fi

# Configure rclone for B2 (if credentials provided)
if [ -n "$B2_APP_KEY" ]; then
    echo "Configuring rclone for B2..."
    mkdir -p ~/.config/rclone
    cat > ~/.config/rclone/rclone.conf << EOF
[b2]
type = b2
account = ${B2_APP_KEY_ID:-$B2_KEY_ID}
key = $B2_APP_KEY
hard_delete = true
EOF
    echo "rclone B2 configured"
else
    echo "Skipping rclone config (B2_APP_KEY not set)"
fi

# ============================================
# Install System Dependencies
# ============================================
echo ""
echo "=== Installing System Dependencies ==="
apt-get update && apt-get install -y ffmpeg libgl1-mesa-glx libglib2.0-0 || true

# ============================================
# Activate Virtual Environment
# ============================================
# The vastai/comfy base image uses a venv at /venv/main
VENV_PATH="/venv/main"
if [ -d "$VENV_PATH" ]; then
    echo "Activating venv at $VENV_PATH"
    source "$VENV_PATH/bin/activate"
    PIP_CMD="$VENV_PATH/bin/pip"
    PYTHON_CMD="$VENV_PATH/bin/python"
else
    echo "No venv found, using system pip/python"
    PIP_CMD="pip"
    PYTHON_CMD="python"
fi

# Install common dependencies that many nodes need
echo ""
echo "=== Installing Common Python Dependencies ==="
$PIP_CMD install opencv-python-headless accelerate omegaconf imageio-ffmpeg --no-cache-dir || true

# ============================================
# Install Custom Nodes
# ============================================
echo ""
echo "=== Installing Custom Nodes ==="
mkdir -p "$CUSTOM_NODES_DIR"
cd "$CUSTOM_NODES_DIR"

for repo_url in "${CUSTOM_NODES[@]}"; do
    # Skip empty lines and comments
    [[ -z "$repo_url" || "$repo_url" =~ ^# ]] && continue

    # Extract repo name from URL
    repo_name=$(basename "$repo_url" .git)

    # Skip if already installed
    if [ -d "$repo_name" ]; then
        echo "--- $repo_name already exists, updating ---"
        cd "$repo_name"
        git pull --ff-only || true
        cd ..
    else
        echo "--- Cloning $repo_name ---"
        git clone "$repo_url" || { echo "Failed to clone $repo_name"; continue; }
    fi

    # Install requirements if they exist
    if [ -f "$repo_name/requirements.txt" ]; then
        echo "Installing dependencies for $repo_name..."
        $PIP_CMD install -r "$repo_name/requirements.txt" --no-cache-dir || true
    fi

    # Run install.py if it exists
    if [ -f "$repo_name/install.py" ]; then
        echo "Running install.py for $repo_name..."
        cd "$repo_name"
        $PYTHON_CMD install.py || true
        cd ..
    fi
done

echo "=== Custom Nodes Installation Complete ==="

# ============================================
# Sync Models from B2
# ============================================
if [ -n "$B2_BUCKET" ] && [ -n "$B2_APP_KEY" ]; then
    echo ""
    echo "=== Syncing Models from B2 ==="

    for model_type in diffusion_models controlnet clip clip_vision loras text_encoders vae upscale_models; do
        echo ""
        echo "--- Syncing $model_type ---"
        mkdir -p "$MODELS_DIR/$model_type"

        echo "Source: b2:$B2_BUCKET/$B2_MODELS_PATH/$model_type"
        echo "Dest:   $MODELS_DIR/$model_type"

        rclone copy "b2:$B2_BUCKET/$B2_MODELS_PATH/$model_type" \
            "$MODELS_DIR/$model_type" \
            --exclude "archive/**" \
            --progress || true

        echo "Downloaded:"
        ls -lh "$MODELS_DIR/$model_type" 2>/dev/null | head -10 || echo "  (empty)"
    done

    echo ""
    echo "=== Model Sync Complete ==="


    # ============================================
    # Sync Input Videos from B2
    # ============================================
    echo ""
    echo "=== Syncing Input Videos from B2 ==="
    INPUTS_DIR="/workspace/comfy_inputs"
    mkdir -p "$INPUTS_DIR"

    rclone copy "b2:$B2_BUCKET/comfy_inputs" \
        "$INPUTS_DIR" \
        --exclude "archive/**" \
        --progress || true

    echo "Input videos synced:"
    ls -lh "$INPUTS_DIR" 2>/dev/null | head -10 || echo "  (empty)"
    echo "=== Input Sync Complete ==="
else
    echo ""
    echo "Skipping B2 sync (B2_BUCKET or B2_APP_KEY not configured)"
fi

# ============================================
# Disk Cleanup Cron Job (Serverless Standard)
# ============================================
# Removes output files older than 24 hours when disk space < 512MB
echo ""
echo "=== Setting up disk cleanup cron ==="

CLEANUP_SCRIPT="/usr/local/bin/cleanup_outputs.sh"
cat > "$CLEANUP_SCRIPT" << 'CLEANUP'
#!/bin/bash
AVAILABLE_MB=$(df /workspace | awk 'NR==2 {print int($4/1024)}')
if [ "$AVAILABLE_MB" -lt 512 ]; then
    echo "$(date): Low disk space (${AVAILABLE_MB}MB), cleaning old outputs..."
    find /workspace/ComfyUI/output -type f -mtime +1 -delete 2>/dev/null
    find /workspace/ComfyUI/output -type d -empty -delete 2>/dev/null
    find /workspace/ComfyUI/temp -type f -mtime +1 -delete 2>/dev/null
fi
CLEANUP
chmod +x "$CLEANUP_SCRIPT"

# Add cron job (every 10 minutes)
(crontab -l 2>/dev/null | grep -v cleanup_outputs; echo "*/10 * * * * $CLEANUP_SCRIPT") | crontab -
echo "Disk cleanup cron installed"

# ============================================
# Provisioning Complete
# ============================================
ELAPSED=$((SECONDS - START_TIME))
MINUTES=$((ELAPSED / 60))
SECS=$((ELAPSED % 60))

echo ""
echo "============================================"
echo "Serverless Provisioning Complete!"
echo "Time: ${MINUTES}m ${SECS}s"
echo "============================================"
echo ""
echo "Environment:"
echo "  COMFYUI_DIR:  $COMFYUI_DIR"
echo "  MODELS_DIR:   $MODELS_DIR"
echo "  Custom Nodes: $(ls -1 "$CUSTOM_NODES_DIR" | wc -l) installed"
echo ""
echo "The pyworker will now start ComfyUI and begin accepting requests."
echo "Submit workflows via the /generate/sync endpoint."
echo ""
