# Useful Commands for Vast.ai ComfyUI Instance

## ComfyUI

```bash
# View ComfyUI logs (live)
tail -f /workspace/comfyui.log

# View last 100 lines of logs
tail -n 100 /workspace/comfyui.log

# Find ComfyUI process
ps aux | grep python

# Kill ComfyUI
pkill -f "python main.py"

# Restart ComfyUI manually
cd /workspace/ComfyUI
nohup python main.py --listen 0.0.0.0 --port 8188 > /workspace/comfyui.log 2>&1 &
```

## B2 Cloud Storage

```bash
# Sync outputs to B2
b2 sync /workspace/ComfyUI/output b2://$B2_BUCKET/comfy_outputs

# Sync a specific model folder from B2
b2 sync b2://$B2_BUCKET/comfy_models/loras /workspace/ComfyUI/models/loras

# List files in B2 bucket
b2 ls b2://$B2_BUCKET/comfy_models/

# Upload a single file
b2 file upload $B2_BUCKET /local/path/file.safetensors comfy_models/loras/file.safetensors

# Download a single file
b2 file download b2://$B2_BUCKET/comfy_models/loras/file.safetensors /workspace/ComfyUI/models/loras/file.safetensors
```

## Custom Nodes

```bash
# Navigate to custom nodes folder
cd /workspace/ComfyUI/custom_nodes

# Clone a new node
git clone https://github.com/user/ComfyUI-NodeName

# Install node dependencies
pip install -r ComfyUI-NodeName/requirements.txt

# Update all custom nodes
for d in */; do (cd "$d" && git pull); done

# Update a specific node
cd /workspace/ComfyUI/custom_nodes/ComfyUI-Manager && git pull
```

## Conda Environment

```bash
# Activate conda
source /opt/miniforge3/etc/profile.d/conda.sh
conda activate main

# Check current environment
echo $CONDA_DEFAULT_ENV

# Check python/pip paths
which python
which pip

# List installed packages
pip list

# Install a package
pip install package-name
```

## Disk & Storage

```bash
# Check disk usage
df -h

# Check folder sizes
du -sh /workspace/*

# Check model folder sizes
du -sh /workspace/ComfyUI/models/*

# Find large files (>1GB)
find /workspace -size +1G -type f

# Clear pip cache
pip cache purge
```

## Debugging

```bash
# Check if ComfyUI is running
pgrep -f "python main.py" && echo "Running" || echo "Not running"

# Check port 8188
netstat -tlnp | grep 8188

# Check GPU status
nvidia-smi

# Watch GPU usage (updates every 1s)
watch -n 1 nvidia-smi

# Check memory usage
free -h

# Check environment variables
env | grep B2
```

## File Operations

```bash
# List models with sizes
ls -lh /workspace/ComfyUI/models/loras/

# Count files in a folder
ls -1 /workspace/ComfyUI/models/loras/ | wc -l

# Find a model by name
find /workspace/ComfyUI/models -name "*flux*"

# Delete a file
rm /workspace/ComfyUI/models/loras/unwanted.safetensors
```
