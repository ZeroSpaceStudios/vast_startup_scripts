#!/bin/bash
set -e

echo "=== Custom ComfyUI Setup ==="

# Don't assume venv exists - check first
if [ -d "/venv/main" ]; then
    source /venv/main/bin/activate
fi

# Use WORKSPACE if set, otherwise default to /workspace
WORKSPACE=${WORKSPACE:-/workspace}
mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

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

# Install SageAttention
echo "Installing SageAttention..."
pip install sageattention --no-cache-dir

# Create model directories
mkdir -p models/checkpoints models/loras models/vae

echo "Setup complete!"

# Start ComfyUI
cd "$WORKSPACE/ComfyUI"
python main.py --listen 0.0.0.0 --port 8188