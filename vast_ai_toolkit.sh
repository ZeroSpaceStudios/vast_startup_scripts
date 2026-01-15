#!/bin/bash
set -e

echo "=== AI-Toolkit Setup ==="
START_TIME=$SECONDS

# ============================================
# 1. Initialize Conda Environment
# ============================================
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
# B2 SYNC PATHS - Configurable via env vars
# ============================================
B2_MODELS_PATH=${B2_MODELS_PATH:-aitoolkit_models}
B2_DATASETS_PATH=${B2_DATASETS_PATH:-aitoolkit_datasets}

# ============================================
# 2. Install System Dependencies
# ============================================
echo "Installing system dependencies..."

# Install rclone
echo "Installing rclone..."
curl -s https://rclone.org/install.sh | bash

# Install Node.js 18 (NodeSource)
echo "Installing Node.js 18..."
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt-get install -y nodejs
echo "Node.js version: $(node --version)"
echo "npm version: $(npm --version)"

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

# ============================================
# 3. Clone & Install AI-Toolkit
# ============================================
echo "=== Setting up AI-Toolkit ==="

if [ ! -d "$WORKSPACE/ai-toolkit" ]; then
    echo "Cloning AI-Toolkit..."
    git clone https://github.com/ostris/ai-toolkit.git
else
    echo "AI-Toolkit already exists, pulling latest..."
    cd "$WORKSPACE/ai-toolkit" && git pull || true
fi

cd "$WORKSPACE/ai-toolkit"

# Install PyTorch with CUDA 12.6 (matches vast.ai environment)
echo "Installing PyTorch 2.7.0 with CUDA 12.6..."
pip install --no-cache-dir torch==2.7.0 torchvision==0.22.0 torchaudio==2.7.0 \
    --index-url https://download.pytorch.org/whl/cu126

# Install all Python dependencies
echo "Installing Python dependencies from requirements.txt..."
pip install -r requirements.txt --no-cache-dir

# Install Node.js dependencies for web UI
echo "Installing Node.js dependencies..."
npm install

echo "=== AI-Toolkit Installation Complete ==="

# ============================================
# 4. Create .env Configuration
# ============================================
if [ -n "$HF_TOKEN" ]; then
    echo "Creating .env file with HF_TOKEN..."
    cat > "$WORKSPACE/ai-toolkit/.env" << EOF
HF_TOKEN=$HF_TOKEN
EOF
    echo "HF_TOKEN configured in .env"
else
    echo "Skipping .env creation (HF_TOKEN not configured)"
fi

# ============================================
# 5. Sync Models from B2
# ============================================
if [ -n "$B2_BUCKET" ]; then
    echo ""
    echo "=== Syncing Models from B2 ==="
    mkdir -p "$WORKSPACE/ai-toolkit/models"

    echo "Source: b2:$B2_BUCKET/$B2_MODELS_PATH"
    echo "Dest:   $WORKSPACE/ai-toolkit/models"

    # List files in bucket before sync
    echo "Files in bucket:"
    rclone ls "b2:$B2_BUCKET/$B2_MODELS_PATH" 2>/dev/null || echo "  (empty or not found)"

    # Run sync with progress
    echo "Downloading..."
    rclone copy "b2:$B2_BUCKET/$B2_MODELS_PATH" "$WORKSPACE/ai-toolkit/models" --progress || true

    # Show what was downloaded
    echo "Local models after sync:"
    ls -lh "$WORKSPACE/ai-toolkit/models" 2>/dev/null || echo "  (empty)"

    echo "=== Model Sync Complete ==="
else
    echo "Skipping model sync (B2_BUCKET not configured)"
fi

# ============================================
# 6. Sync Datasets from B2
# ============================================
if [ -n "$B2_BUCKET" ]; then
    echo ""
    echo "=== Syncing Datasets from B2 ==="
    mkdir -p "$WORKSPACE/ai-toolkit/datasets"

    echo "Source: b2:$B2_BUCKET/$B2_DATASETS_PATH"
    echo "Dest:   $WORKSPACE/ai-toolkit/datasets"

    # List files in bucket before sync
    echo "Files in bucket:"
    rclone ls "b2:$B2_BUCKET/$B2_DATASETS_PATH" 2>/dev/null || echo "  (empty or not found)"

    # Run sync with progress
    echo "Downloading..."
    rclone copy "b2:$B2_BUCKET/$B2_DATASETS_PATH" "$WORKSPACE/ai-toolkit/datasets" --progress || true

    # Show what was downloaded
    echo "Local datasets after sync:"
    ls -lh "$WORKSPACE/ai-toolkit/datasets" 2>/dev/null || echo "  (empty)"

    echo "=== Dataset Sync Complete ==="
else
    echo "Skipping dataset sync (B2_BUCKET not configured)"
fi

# ============================================
# 7. Generate Helper Scripts
# ============================================
echo "Creating helper scripts..."

# start_ui.sh - Launch Node.js web UI
cat > "$WORKSPACE/ai-toolkit/start_ui.sh" << 'SCRIPT'
#!/bin/bash
cd /workspace/ai-toolkit
source /opt/miniforge3/etc/profile.d/conda.sh
conda activate main
if pgrep -f "node.*server" > /dev/null; then
    echo "UI already running (PID: $(pgrep -f 'node.*server'))"
    echo "Stop it first: pkill -f 'node.*server'"
    exit 1
fi
nohup npm run server > /workspace/aitoolkit_ui.log 2>&1 &
echo "AI-Toolkit UI started (PID: $!)"
echo "Logs: tail -f /workspace/aitoolkit_ui.log"
echo ""
echo "Access via SSH tunnel from your LOCAL machine:"
echo "  ssh -p <SSH_PORT> root@<PUBLIC_IP> -L 8675:localhost:8675"
echo "Then open: http://localhost:8675"
SCRIPT
chmod +x "$WORKSPACE/ai-toolkit/start_ui.sh"

# train.sh - Run CLI training
cat > "$WORKSPACE/ai-toolkit/train.sh" << 'SCRIPT'
#!/bin/bash
cd /workspace/ai-toolkit
source /opt/miniforge3/etc/profile.d/conda.sh
conda activate main
if [ -z "$1" ]; then
    echo "Usage: ./train.sh config/your_config.yml"
    echo ""
    echo "Example configs in: /workspace/ai-toolkit/config/"
    ls -la /workspace/ai-toolkit/config/ 2>/dev/null || echo "  (no configs found)"
    exit 1
fi
python run.py "$1"
SCRIPT
chmod +x "$WORKSPACE/ai-toolkit/train.sh"

# sync_outputs.sh - Push training outputs to B2 (hostname-separated)
cat > "$WORKSPACE/ai-toolkit/sync_outputs.sh" << 'SCRIPT'
#!/bin/bash
cd /workspace/ai-toolkit
HOSTNAME=$(hostname)
if [ -z "$B2_BUCKET" ]; then
    echo "Error: B2_BUCKET not set"
    exit 1
fi
echo "Syncing outputs to b2:$B2_BUCKET/aitoolkit_outputs/$HOSTNAME"
rclone copy output "b2:$B2_BUCKET/aitoolkit_outputs/$HOSTNAME" --progress
echo ""
echo "Done! Files uploaded to: b2:$B2_BUCKET/aitoolkit_outputs/$HOSTNAME"
echo ""
echo "To download from another machine:"
echo "  rclone copy b2:$B2_BUCKET/aitoolkit_outputs/$HOSTNAME ./downloaded_outputs --progress"
SCRIPT
chmod +x "$WORKSPACE/ai-toolkit/sync_outputs.sh"

echo "Helper scripts created: start_ui.sh, train.sh, sync_outputs.sh"

# ============================================
# 8. Calculate Setup Time
# ============================================
ELAPSED=$((SECONDS - START_TIME))
MINUTES=$((ELAPSED / 60))
SECS=$((ELAPSED % 60))

echo ""
echo "============================================"
echo "Setup complete! (took ${MINUTES}m ${SECS}s)"
echo "============================================"

# ============================================
# 9. Start UI & Print Instructions
# ============================================
cd "$WORKSPACE/ai-toolkit"
nohup npm run server > /workspace/aitoolkit_ui.log 2>&1 &
UI_PID=$!

echo ""
echo "AI-Toolkit UI started (PID: $UI_PID)"
echo "Instance hostname: $(hostname)"
echo ""
echo "============================================"
echo "SECURE ACCESS - SSH Tunnel Required"
echo "============================================"
echo "The UI is bound to localhost only (not publicly exposed)"
echo ""
echo "From your LOCAL machine, run:"
echo "  ssh -p <SSH_PORT> root@<PUBLIC_IP> -L 8675:localhost:8675"
echo ""
echo "Then open in browser: http://localhost:8675"
echo ""
echo "============================================"
echo "Useful Commands"
echo "============================================"
echo "  View logs:      tail -f /workspace/aitoolkit_ui.log"
echo "  Restart UI:     ./start_ui.sh"
echo "  Stop UI:        pkill -f 'node.*server'"
echo "  Run training:   ./train.sh config/your_config.yml"
echo ""
echo "============================================"
echo "Multi-Instance Output Sync"
echo "============================================"
echo "  Sync outputs:   ./sync_outputs.sh"
echo "  Uploads to:     b2:\$B2_BUCKET/aitoolkit_outputs/$(hostname)/"
echo ""
echo "============================================"
echo "Manual Sync Commands"
echo "============================================"
echo "  Re-sync models:   rclone copy b2:\$B2_BUCKET/$B2_MODELS_PATH \$WORKSPACE/ai-toolkit/models --progress"
echo "  Re-sync datasets: rclone copy b2:\$B2_BUCKET/$B2_DATASETS_PATH \$WORKSPACE/ai-toolkit/datasets --progress"
echo ""
echo "============================================"
echo "Environment Variables (set in vast.ai)"
echo "============================================"
echo "  B2_BUCKET           - B2 bucket name (required for sync)"
echo "  B2_APP_KEY_ID       - B2 account ID"
echo "  B2_APP_KEY          - B2 application key"
echo "  B2_MODELS_PATH      - Models path in bucket (default: aitoolkit_models)"
echo "  B2_DATASETS_PATH    - Datasets path in bucket (default: aitoolkit_datasets)"
echo "  HF_TOKEN            - HuggingFace token (optional, for gated models)"
