#!/bin/bash
set -e

echo "=== Custom ComfyUI Setup ==="

WORKSPACE="/workspace"
COMFYUI_DIR="$WORKSPACE/ComfyUI"

# Install B2 CLI
echo "Installing B2 CLI..."
wget -q https://github.com/Backblaze/B2_Command_Line_Tool/releases/latest/download/b2-linux
chmod +x b2-linux
mv b2-linux /usr/local/bin/b2

echo "B2 CLI installed: $(b2 version)"

# Set B2 environment variables
export B2_APPLICATION_KEY_ID="$B2_APP_KEY_ID"
export B2_APPLICATION_KEY="$B2_APP_KEY"

# Clone ComfyUI
echo "Cloning ComfyUI..."
if [ ! -d "$COMFYUI_DIR" ]; then
    cd "$WORKSPACE"
    git clone https://github.com/comfyanonymous/ComfyUI.git
fi

cd "$COMFYUI_DIR"

# Install dependencies
echo "Installing Python packages..."
pip install -r requirements.txt
pip install sageattention


# Sync from B2 (if credentials are set)
if [ ! -z "$B2_BUCKET_NAME" ]; then
    echo "Syncing models from B2..."
    b2 file sync --threads 8 b2://$B2_BUCKET_NAME/checkpoints models/checkpoints || echo "Checkpoint sync skipped"
    b2 file sync --threads 8 b2://$B2_BUCKET_NAME/loras models/loras || echo "LoRA sync skipped"
fi

# Start ComfyUI
echo "Starting ComfyUI on port 8188..."
cd /workspace/ComfyUI
python main.py --listen 0.0.0.0 --port 8188
