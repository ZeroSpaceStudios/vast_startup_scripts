# Vast.ai Troubleshooting & Recovery Cheatsheet

Quick fixes for when things go wrong on a running instance.

---

## Model Sync Failed on Startup

**Symptom**: Startup log shows rclone errors (e.g. `unknown flag`, sync failures), models directory is empty or missing files.

**Fix** — re-run the sync manually without problematic flags:
```bash
# Sync all models
rclone copy b2:$B2_BUCKET/comfy_models /workspace/ComfyUI/models \
  --transfers 16 --checkers 16 --multi-thread-streams 8 \
  --multi-thread-cutoff 50M --buffer-size 64M --fast-list \
  --ignore-existing --progress

# Sync workflows
rclone copy b2:$B2_BUCKET/comfy_workflows /workspace/ComfyUI/user/default/workflows \
  --transfers 16 --fast-list --ignore-existing --progress
```

**Sync a single model type** (e.g. just loras):
```bash
rclone copy b2:$B2_BUCKET/comfy_models/loras /workspace/ComfyUI/models/loras \
  --transfers 16 --fast-list --ignore-existing --progress
```

---

## New LoRA / Model Uploaded to B2 After Instance Started

**Symptom**: You uploaded a new model to B2 from your local machine, but the running vast instance doesn't have it.

**Fix** — pull just that path from B2:
```bash
# Pull new loras
rclone copy b2:$B2_BUCKET/comfy_models/loras /workspace/ComfyUI/models/loras \
  --ignore-existing --progress

# Pull new diffusion models
rclone copy b2:$B2_BUCKET/comfy_models/diffusion_models /workspace/ComfyUI/models/diffusion_models \
  --ignore-existing --progress
```

Then refresh the ComfyUI browser tab — new models appear in dropdowns without restarting.

---

## ComfyUI Crashed / Not Responding

**Symptom**: Browser says connection refused, or UI is frozen.

```bash
# Check if it's running
pgrep -f "python main.py"

# Check what happened
tail -50 /workspace/comfyui.log

# Restart
pkill -f "python main.py"
./start_comfy.sh

# Verify it's back
tail -f /workspace/comfyui.log
```

---

## SSH Tunnel Disconnected

**Symptom**: Browser shows connection refused on localhost:8189. ComfyUI is still running on the instance, you just lost the tunnel. Vast auto-tmux keeps processes alive even when SSH drops.

**Fix** — reconnect from your local machine:
```bash
ssh -p <SSH_PORT> root@<IP> -L 8189:localhost:8188
```

**Verify ComfyUI is still running** (on the instance after reconnecting):
```bash
# Quick check — prints PID if running, "Not running" if dead
pgrep -f "python main.py" && echo "Running" || echo "Not running"

# Check recent logs to confirm it's healthy (not stuck/errored)
tail -20 /workspace/comfyui.log
```

If it's running, just reopen `http://localhost:8189`. Any running workflow continues — you just lost the live view temporarily.

If it's not running, restart it:
```bash
./start_comfy.sh
```

---

## Out of Disk Space

**Symptom**: ComfyUI errors about writing files, or rclone sync fails.

```bash
# Check disk usage
df -h

# Find what's eating space
du -sh /workspace/ComfyUI/output/*
du -sh /workspace/ComfyUI/models/*

# Sync outputs to B2 then delete local copies
rclone copy /workspace/ComfyUI/output b2:$B2_BUCKET/comfy_outputs/$(hostname) --progress
rm -rf /workspace/ComfyUI/output/*

# Clear pip cache
pip cache purge
```

---

## Out of VRAM (OOM)

**Symptom**: ComfyUI log shows CUDA OOM error, workflow fails mid-generation.

```bash
# Check current GPU memory usage
nvidia-smi

# Kill ComfyUI to free VRAM completely
pkill -f "python main.py"

# Restart fresh
./start_comfy.sh
```

**Prevention**: Use `NV_WorkflowFeasibilityChecker` node before running to estimate VRAM requirements. Use `NV_StreamingVAEEncode` for video workflows to free GPU before the main model loads.

---

## Conda / Python Not Found

**Symptom**: `pip: command not found` or `python: command not found` after SSH-ing in.

```bash
source /opt/miniforge3/etc/profile.d/conda.sh
conda activate main
```

This is needed every new shell session. The startup script does it automatically, but manual SSH sessions don't.

---

## Rclone Not Configured / B2 Auth Failed

**Symptom**: `rclone: command not found` or B2 auth errors when syncing manually.

```bash
# Check if rclone is installed
which rclone

# If not installed
curl -s https://rclone.org/install.sh | bash

# Check if B2 env vars are set
echo $B2_APP_KEY_ID
echo $B2_APP_KEY
echo $B2_BUCKET

# Check rclone config exists
cat ~/.config/rclone/rclone.conf

# If config is missing, recreate it
mkdir -p ~/.config/rclone
cat > ~/.config/rclone/rclone.conf << EOF
[b2]
type = b2
account = ${B2_APP_KEY_ID:-$B2_KEY_ID}
key = $B2_APP_KEY
hard_delete = true
EOF

# Test it
rclone lsd b2:$B2_BUCKET
```

---

## Custom Node Missing / Import Error

**Symptom**: ComfyUI log shows `ImportError` or `No module named ...` for a custom node.

```bash
# Activate conda first
source /opt/miniforge3/etc/profile.d/conda.sh
conda activate main

# Reinstall that node's requirements
cd /workspace/ComfyUI/custom_nodes/<node_name>
pip install -r requirements.txt --no-cache-dir

# Restart ComfyUI
pkill -f "python main.py"
cd /workspace/ComfyUI
./start_comfy.sh
```

---

## Workflow File Not Showing in ComfyUI

**Symptom**: Uploaded or synced workflow doesn't appear in the ComfyUI workflow browser.

Workflows need to be in the right directory:
```bash
# Check where they are
ls /workspace/ComfyUI/user/default/workflows/

# If you put them in the wrong place, move them
mv /workspace/ComfyUI/*.json /workspace/ComfyUI/user/default/workflows/
```

Refresh the browser — they should appear under the workflow list.

---

## File Transfers (scp)

Transfer files between your local Windows machine and the vast instance.

**Syntax:**
```
scp -P <PORT> <source> <destination>
│    │  │       │        │
│    │  │       │        └─ where to put it
│    │  │       └─ what to send
│    │  └─ SSH port (from vast.ai dashboard)
│    └─ uppercase P = port (lowercase -p means something else!)
└─ secure copy command
```

**Download outputs from instance to local:**
```bash
# Download all files from ComfyUI output
scp -P <PORT> root@<IP>:/workspace/ComfyUI/output/* .

# Download a specific file
scp -P <PORT> root@<IP>:/workspace/ComfyUI/output/myfile.mp4 .
```

**Upload local files to instance:**
```bash
# Upload to ComfyUI input directory (for use in workflows)
scp -P <PORT> "Z:\path\to\file.json" root@<IP>:/workspace/ComfyUI/input/

# Upload to any path on the instance
scp -P <PORT> "Z:\path\to\file.safetensors" root@<IP>:/workspace/ComfyUI/models/loras/
```

**Notes:**
- Run these from a local PowerShell/Terminal window, NOT from inside the SSH session
- Quote Windows paths with spaces or special characters
- `scp` doesn't skip existing files — it always overwrites. Use `rsync` if you want skip-existing behavior:
  ```bash
  rsync -avz --progress -e "ssh -p <PORT>" root@<IP>:/workspace/ComfyUI/output/ .
  ```

---

## tmux Basics

When using tmux for long-running tasks (training, large syncs):

```bash
# Start a named session
tmux new -s work

# Detach (keeps running): Ctrl+b then d

# Reattach
tmux a -t work

# Enable mouse scrolling
tmux set -g mouse on

# Scroll mode (without mouse): Ctrl+b then [
#   Arrow keys or Page Up/Down to scroll
#   q to exit scroll mode

# List sessions
tmux ls

# Kill a session
tmux kill-session -t work
```

---

## AI-Toolkit Specific

### Sync New Models to Training Instance
```bash
rclone copy b2:$B2_MODELS_BUCKET/models /app/ai-toolkit/models \
  --ignore-existing --progress
```

### Sync New Datasets / Configs
```bash
rclone copy b2:$B2_DATA_BUCKET/aitoolkit_datasets /app/ai-toolkit/datasets --progress
rclone copy b2:$B2_DATA_BUCKET/aitoolkit_configs /app/ai-toolkit/config --progress
```

### Push Finished LoRA to ComfyUI Bucket
```bash
./sync_lora_to_comfy.sh output/my_lora/my_lora.safetensors
```

### Training Crashed / Disconnected
```bash
# Reattach to tmux session
tmux a -t train

# If session is gone, check if training is still running
pgrep -f "python run.py"

# Restart training
tmux new -s train
cd /app/ai-toolkit && python run.py config/my_lora.yaml
```
