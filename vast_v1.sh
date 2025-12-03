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
    # Add more URLs below:
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

# Install B2 CLI
echo "Installing B2 CLI..."
wget -q https://github.com/Backblaze/B2_Command_Line_Tool/releases/latest/download/b2-linux
chmod +x b2-linux
mv b2-linux /usr/local/bin/b2

# Set B2 credentials (use both naming conventions)
export B2_APPLICATION_KEY_ID="${B2_APP_KEY_ID:-$B2_KEY_ID}"
export B2_APPLICATION_KEY="$B2_APP_KEY"

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

# ============================================
# Sync Models from B2
# ============================================
if [ -n "$B2_BUCKET" ]; then
    echo "=== Syncing Models from B2 ==="

    # Sync each model type folder
    for model_type in diffusion_models controlnet clip clip_vision loras text_encoders vae upscale_models; do
        echo ""
        echo "--- Syncing $model_type ---"
        echo "Source: b2://$B2_BUCKET/$B2_MODELS_PATH/$model_type"
        echo "Dest:   $WORKSPACE/ComfyUI/models/$model_type"
        mkdir -p "$WORKSPACE/ComfyUI/models/$model_type"

        # List files in bucket before sync
        echo "Files in bucket:"
        b2 ls "b2://$B2_BUCKET/$B2_MODELS_PATH/$model_type" 2>/dev/null || echo "  (empty or not found)"

        # Run sync
        echo "Syncing..."
        b2 sync "b2://$B2_BUCKET/$B2_MODELS_PATH/$model_type" "$WORKSPACE/ComfyUI/models/$model_type" || true

        # Show what was downloaded
        echo "Local files after sync:"
        ls -lh "$WORKSPACE/ComfyUI/models/$model_type" 2>/dev/null || echo "  (empty)"
    done

    echo "=== Model Sync Complete ==="

    # ============================================
    # Sync Workflows from B2
    # ============================================
    echo ""
    echo "=== Syncing Workflows from B2 ==="
    WORKFLOWS_DIR="$WORKSPACE/ComfyUI/user/default/workflows"
    mkdir -p "$WORKFLOWS_DIR"
    echo "Source: b2://$B2_BUCKET/$B2_WORKFLOWS_PATH"
    echo "Dest:   $WORKFLOWS_DIR"

    echo "Files in bucket:"
    b2 ls "b2://$B2_BUCKET/$B2_WORKFLOWS_PATH" 2>/dev/null || echo "  (empty or not found)"

    echo "Syncing..."
    b2 sync "b2://$B2_BUCKET/$B2_WORKFLOWS_PATH" "$WORKFLOWS_DIR" || true

    echo "Local workflows after sync:"
    ls -lh "$WORKFLOWS_DIR" 2>/dev/null || echo "  (empty)"
    echo "=== Workflow Sync Complete ==="
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
nohup python main.py --listen 127.0.0.1 --port 8188 > /workspace/comfyui.log 2>&1 &
echo "ComfyUI started (PID: $!)"
echo "Logs: tail -f /workspace/comfyui.log"
echo "Access via SSH tunnel: ssh -p <PORT> root@<IP> -L 8188:localhost:8188"
SCRIPT
chmod +x "$WORKSPACE/ComfyUI/start_comfy.sh"

# Start ComfyUI in background (localhost only - requires SSH tunnel)
cd "$WORKSPACE/ComfyUI"
nohup python main.py --listen 127.0.0.1 --port 8188 > /workspace/comfyui.log 2>&1 &
COMFY_PID=$!
echo "ComfyUI started in background (PID: $COMFY_PID)"
echo ""
echo "============================================"
echo "SECURE ACCESS - SSH Tunnel Required"
echo "============================================"
echo "ComfyUI is bound to localhost only (not publicly exposed)"
echo ""
echo "To access, create SSH tunnel from your local machine:"
echo "  ssh -p <SSH_PORT> root@<PUBLIC_IP> -L 8188:localhost:8188"
echo ""
echo "Then open: http://localhost:8188"
echo ""
echo "Useful commands:"
echo "  View logs:      tail -f /workspace/comfyui.log"
echo "  Restart:        ./start_comfy.sh"
echo "  Stop:           pkill -f 'python main.py'"
echo "  Sync outputs:   b2 sync /workspace/ComfyUI/output b2://\$B2_BUCKET/comfy_outputs"