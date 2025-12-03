#!/bin/bash
set -e

echo "=== Custom ComfyUI Setup ==="

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
pip install -r requirements.txt --no-cache-dir

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
else
    echo "Skipping B2 model sync (B2_BUCKET not configured)"
fi

echo "Setup complete!"
echo "To start ComfyUI: cd /workspace/ComfyUI && python main.py --listen 0.0.0.0 --port 8188"