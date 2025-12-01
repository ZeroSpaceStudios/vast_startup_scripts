#!/bin/bash
set -e


# Create workspace if it doesn't exist
mkdir -p /workspace
cd /workspace

# Install B2 CLI
echo "Installing B2 CLI..."
wget -q https://github.com/Backblaze/B2_Command_Line_Tool/releases/latest/download/b2-linux
chmod +x b2-linux
mv b2-linux /usr/local/bin/b2
echo "B2 CLI installed: $(b2 version)"

# Set B2 credentials
export B2_APPLICATION_KEY_ID="$B2_APP_KEY_ID"
export B2_APPLICATION_KEY="$B2_APP_KEY"

# Clone ComfyUI
echo "Setting up ComfyUI..."
if [ ! -d "/workspace/ComfyUI" ]; then
    git clone https://github.com/comfyanonymous/ComfyUI.git
fi

cd /workspace/ComfyUI

# Install ComfyUI requirements
echo "Installing ComfyUI dependencies..."
pip install -r requirements.txt --no-cache-dir

# Install SageAttention
echo "Installing SageAttention..."
pip install sageattention --no-cache-dir

# Create model directories
mkdir -p models/checkpoints models/loras models/vae

# Sync from B2 if configured
if [ ! -z "$B2_BUCKET_NAME" ]; then
    echo "[5/5] Syncing models from B2..."
    
    # Test B2 connection
    b2 bucket list || {
        echo "ERROR: B2 connection failed!"
        echo "Check your credentials"
    }
    
    # Sync models
    echo "  Syncing checkpoints..."
    b2 file sync --threads 8 b2://$B2_BUCKET_NAME/checkpoints models/checkpoints || echo "  Checkpoint sync skipped"
    
    echo "  Syncing LoRAs..."
    b2 file sync --threads 8 b2://$B2_BUCKET_NAME/loras models/loras || echo "  LoRA sync skipped"
    
    echo "Models synced!"
else
    echo "B2 not configured, skipping model sync"
fi