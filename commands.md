# Useful Commands for Vast.ai ComfyUI Instance

## SSH Tunnel Access (Required)

ComfyUI is bound to localhost only for security. You must use SSH tunnel to access it.

### From Windows/Mac/Linux:
```bash
ssh -p <SSH_PORT> root@<IP_ADDRESS> -L 8189:localhost:8188
```

Then open in browser: `http://localhost:8189`

### Multiple Instances
```bash
# Instance 1 → localhost:8189
ssh -p <SSH_PORT_1> root@<IP_ADDRESS_1> -L 8189:localhost:8188

# Instance 2 → localhost:8190
ssh -p <SSH_PORT_2> root@<IP_ADDRESS_2> -L 8190:localhost:8188

# Instance 3 → localhost:8191
ssh -p <SSH_PORT_3> root@<IP_ADDRESS_3> -L 8191:localhost:8188
```

### Port Conflict Note
If you have local ComfyUI running on port 8188, use different local ports (8189, 8190, etc.) for your tunnels.

---

## Quick Start (On Instance)

```bash
# Use the helper script to restart ComfyUI
./start_comfy.sh

# Or manually:
source /opt/miniforge3/etc/profile.d/conda.sh
conda activate main
cd /workspace/ComfyUI
nohup python main.py --listen 127.0.0.1 --port 8188 > /workspace/comfyui.log 2>&1 &
```

## ComfyUI

```bash
# View ComfyUI logs (live)
tail -f /workspace/comfyui.log

# View last 100 lines of logs
tail -n 100 /workspace/comfyui.log

# Check if ComfyUI is running
pgrep -f "python main.py" && echo "Running" || echo "Not running"

# Kill ComfyUI
pkill -f "python main.py"

# Restart using helper script
./start_comfy.sh
```

## B2 Cloud Storage - Setup

```bash
# Check available B2 environment variables
env | grep -i b2

# Set up B2 credentials for current session
export B2_APPLICATION_KEY_ID=$B2_KEY_ID
export B2_APPLICATION_KEY=$B2_APP_KEY

# Or authorize manually (KEY_ID first, then KEY)
b2 account authorize $B2_KEY_ID $B2_APP_KEY
```

## B2 Cloud Storage - Sync Operations

```bash
# Sync outputs to B2 (with instance ID for multi-instance support)
b2 sync /workspace/ComfyUI/output b2://$B2_BUCKET/comfy_outputs/$(hostname)/

# Sync outputs from current directory
cd /workspace/ComfyUI/output
b2 sync ./ b2://$B2_BUCKET/comfy_outputs/$(hostname)/

# Sync models FROM B2 to local
b2 sync b2://$B2_BUCKET/comfy_models/loras /workspace/ComfyUI/models/loras
b2 sync b2://$B2_BUCKET/comfy_models/diffusion_models /workspace/ComfyUI/models/diffusion_models

# Sync workflows FROM B2 to local
b2 sync b2://$B2_BUCKET/comfy_workflows /workspace/ComfyUI/user/default/workflows

# Sync all model types
for model_type in diffusion_models controlnet clip clip_vision loras text_encoders vae upscale_models; do
    b2 sync b2://$B2_BUCKET/comfy_models/$model_type /workspace/ComfyUI/models/$model_type
done
```

## B2 Cloud Storage - File Operations

```bash
# List files in B2 bucket
b2 ls b2://$B2_BUCKET/comfy_models/
b2 ls b2://$B2_BUCKET/comfy_models/loras/
b2 ls b2://$B2_BUCKET/comfy_workflows/

# Upload a single file
b2 file upload $B2_BUCKET /workspace/ComfyUI/output/image.png comfy_outputs/$(hostname)/image.png

# Download a single file
b2 file download b2://$B2_BUCKET/comfy_models/loras/my_lora.safetensors /workspace/ComfyUI/models/loras/my_lora.safetensors
```

## Custom Nodes

```bash
# Navigate to custom nodes folder
cd /workspace/ComfyUI/custom_nodes

# Clone a new node
git clone https://github.com/user/ComfyUI-NodeName

# Install node dependencies (activate conda first!)
source /opt/miniforge3/etc/profile.d/conda.sh
conda activate main
pip install -r ComfyUI-NodeName/requirements.txt

# Update all custom nodes
cd /workspace/ComfyUI/custom_nodes
for d in */; do (cd "$d" && git pull); done

# Update a specific node
cd /workspace/ComfyUI/custom_nodes/ComfyUI-Manager && git pull
```

## Conda Environment

```bash
# Activate conda (REQUIRED before pip/python commands)
source /opt/miniforge3/etc/profile.d/conda.sh
conda activate main

# Check current environment
echo $CONDA_DEFAULT_ENV

# Check python/pip paths (should show /venv/main/bin/)
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

# Check all B2 environment variables
env | grep -i b2

# Check instance hostname (useful for multi-instance)
hostname

# View provisioning log
cat /var/log/portal/provisioning.log
```

## File Operations

```bash
# List models with sizes
ls -lh /workspace/ComfyUI/models/loras/
ls -lh /workspace/ComfyUI/models/diffusion_models/

# List workflows
ls -lh /workspace/ComfyUI/user/default/workflows/

# Count files in a folder
ls -1 /workspace/ComfyUI/models/loras/ | wc -l

# Find a model by name
find /workspace/ComfyUI/models -name "*flux*"

# Delete a file
rm /workspace/ComfyUI/models/loras/unwanted.safetensors
```

## Download Files to Local Machine

```bash
# From your LOCAL machine (not SSH), use scp:
# scp -P <SSH_PORT> root@<PUBLIC_IP>:/remote/path /local/path

# Example: Download provisioning log
scp -P <SSH_PORT> root@<IP_ADDRESS>:/var/log/portal/provisioning.log ./provisioning.log

# Example: Download an output image
scp -P <SSH_PORT> root@<IP_ADDRESS>:/workspace/ComfyUI/output/image.png ./image.png
```

## B2 Bucket Structure Reference

```
<BUCKET_NAME>/
├── comfy_models/
│   ├── diffusion_models/
│   ├── controlnet/
│   ├── clip/
│   ├── clip_vision/
│   ├── loras/
│   ├── text_encoders/
│   ├── vae/
│   └── upscale_models/
├── comfy_workflows/
│   ├── workflow1.json
│   └── workflow2.json
└── comfy_outputs/
    ├── C.28469202/        # instance 1 outputs
    └── C.28469999/        # instance 2 outputs
```

---

## Bash Command Reference

### File & Directory Commands

| Command | Description |
|---------|-------------|
| `ls` | List files in current directory |
| `ls -l` | List with details (permissions, size, date) |
| `ls -la` | List all files including hidden (start with `.`) |
| `ls -lh` | List with human-readable sizes (KB, MB, GB) |
| `cd /path` | Change directory to `/path` |
| `cd ..` | Go up one directory |
| `cd` | Go to home directory |
| `pwd` | Print working directory (show current path) |
| `mkdir folder` | Create a directory |
| `mkdir -p a/b/c` | Create nested directories |
| `rm file` | Delete a file |
| `rm -r folder` | Delete a folder and contents |
| `rm -rf folder` | Force delete without prompts (careful!) |
| `cp src dest` | Copy file |
| `cp -r src dest` | Copy directory recursively |
| `mv src dest` | Move or rename file/folder |
| `cat file` | Display entire file contents |
| `head -n 20 file` | Show first 20 lines |
| `tail -n 20 file` | Show last 20 lines |
| `tail -f file` | Follow file in real-time (for logs) |

### Search & Find

| Command | Description |
|---------|-------------|
| `find /path -name "*.txt"` | Find files by name pattern |
| `find /path -size +1G` | Find files larger than 1GB |
| `find /path -mmin -60` | Find files modified in last 60 minutes |
| `grep "text" file` | Search for text in file |
| `grep -r "text" /path` | Search recursively in directory |
| `grep -i "text" file` | Case-insensitive search |
| `which python` | Show full path of a command |

### Process Management

| Command | Description |
|---------|-------------|
| `ps aux` | List all running processes |
| `ps aux \| grep python` | Find python processes |
| `pgrep -f "pattern"` | Get PID of process matching pattern |
| `kill PID` | Terminate process by PID |
| `pkill -f "pattern"` | Kill processes matching pattern |
| `nohup cmd &` | Run command in background, survives logout |
| `jobs` | List background jobs |
| `fg` | Bring background job to foreground |
| `Ctrl+C` | Interrupt/stop current process |
| `Ctrl+Z` | Suspend current process |

### Environment & Variables

| Command | Description |
|---------|-------------|
| `env` | Show all environment variables |
| `env \| grep B2` | Filter env vars containing "B2" |
| `echo $VAR` | Print value of variable |
| `export VAR=value` | Set environment variable |
| `source file` | Execute commands from file in current shell |
| `$()` | Command substitution: `echo $(hostname)` |
| `$VAR` | Variable expansion |
| `${VAR:-default}` | Use default if VAR is empty |

### Disk & System

| Command | Description |
|---------|-------------|
| `df -h` | Show disk space usage |
| `du -sh /path` | Show size of directory |
| `du -sh *` | Show size of each item in current dir |
| `free -h` | Show memory usage |
| `hostname` | Show machine hostname |
| `nvidia-smi` | Show GPU status and usage |
| `watch -n 1 cmd` | Run command every 1 second |

### Pipes & Redirection

| Symbol | Description |
|--------|-------------|
| `\|` | Pipe output to another command: `cat file \| grep text` |
| `>` | Redirect output to file (overwrite) |
| `>>` | Redirect output to file (append) |
| `2>&1` | Redirect stderr to stdout |
| `> /dev/null` | Discard output |
| `2>/dev/null` | Discard error messages |
| `cmd > file 2>&1` | Save both output and errors to file |

### Conditionals & Logic

| Symbol | Description |
|--------|-------------|
| `&&` | Run next command only if previous succeeded |
| `\|\|` | Run next command only if previous failed |
| `;` | Run next command regardless of previous result |
| `cmd && echo "ok" \|\| echo "fail"` | Success/failure messages |

### Loops

```bash
# For loop over items
for item in a b c; do
    echo $item
done

# For loop over files
for file in *.txt; do
    echo $file
done

# For loop over command output
for dir in */; do
    (cd "$dir" && git pull)
done
```

### Useful Shortcuts

| Shortcut | Description |
|----------|-------------|
| `Tab` | Auto-complete file/command names |
| `↑` / `↓` | Navigate command history |
| `Ctrl+R` | Search command history |
| `Ctrl+L` | Clear screen |
| `Ctrl+A` | Move cursor to start of line |
| `Ctrl+E` | Move cursor to end of line |
| `!!` | Repeat last command |
| `!$` | Last argument of previous command |

### Special Characters

| Character | Description |
|-----------|-------------|
| `~` | Home directory |
| `.` | Current directory |
| `..` | Parent directory |
| `*` | Wildcard: matches any characters |
| `?` | Wildcard: matches single character |
| `\` | Escape special characters |
| `'text'` | Literal string (no variable expansion) |
| `"text"` | String with variable expansion |
