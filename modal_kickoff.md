# Modal.com Kickoff Guide

Step-by-step guide for deploying ComfyUI inference and LoRA training on Modal's serverless GPU platform.

**When to use Modal vs Vast.ai:**
- **Modal** — API-served inference, burst/batch processing, scale-to-zero workloads
- **Vast.ai** — Interactive dev, long training runs, cheapest GPU-hours

---

## Table of Contents

1. [Account & CLI Setup](#1-account--cli-setup)
2. [Core Concepts](#2-core-concepts)
3. [Secrets & B2 Credentials](#3-secrets--b2-credentials)
4. [Model Storage with Volumes](#4-model-storage-with-volumes)
5. [ComfyUI Inference Deployment](#5-comfyui-inference-deployment)
6. [LoRA Training](#6-lora-training)
7. [B2 Integration & Hybrid Architecture](#7-b2-integration--hybrid-architecture)
8. [Scaling & Cold Start Optimization](#8-scaling--cold-start-optimization)
9. [Monitoring & Debugging](#9-monitoring--debugging)
10. [Cost Optimization](#10-cost-optimization)
11. [Common Commands](#11-common-commands)
12. [Plan Limits](#12-plan-limits)

---

## 1. Account & CLI Setup

### Create Account
1. Go to [modal.com](https://modal.com) and sign up
2. Free tier includes **$30/month** in compute credits

### Install CLI & SDK
```bash
# Install Modal SDK (requires Python 3.9+)
pip install modal

# Authenticate (opens browser)
modal setup

# Verify installation
modal --version
```

### Project Structure
```
modal_comfy/
├── comfy_inference.py      # ComfyUI API serving
├── comfy_ui.py             # ComfyUI interactive web UI
├── lora_training.py        # LoRA fine-tuning
├── setup_volumes.py        # One-time model download
├── sync_b2.py              # B2 ↔ Volume sync utilities
└── workflows/
    └── workflow_api.json   # Exported ComfyUI API workflows
```

### Three Run Modes

| Command | Purpose | When to Use |
|---------|---------|-------------|
| `modal run app.py` | Ephemeral test run | Dev/testing — runs and exits |
| `modal serve app.py` | Dev server with live reload | Iterating on code — auto-reloads on save |
| `modal deploy app.py` | Production deployment | Stable deployment — survives laptop close |

---

## 2. Core Concepts

### Everything is Python (no YAML, no Docker)

```python
import modal

app = modal.App("my-comfy-app")

# Define container image in code
image = (
    modal.Image.debian_slim(python_version="3.11")
    .apt_install(["git", "ffmpeg"])
    .uv_pip_install(["torch==2.8.0", "comfy-cli==1.5.3"])
    .run_commands("comfy --skip-prompt install --fast-deps --nvidia")
)

# Attach GPU, mount storage, inject secrets — all via decorators
@app.function(gpu="A100-80GB", image=image, volumes={"/models": my_vol})
def generate(prompt: str):
    return run_workflow(prompt)
```

### Key Building Blocks

| Concept | What It Does |
|---------|-------------|
| **App** | Container for your functions. One app = one deployment. |
| **Image** | Container image defined via Python method chaining. Cached per-layer. |
| **Function** | A Python function that runs in the cloud with GPU attached. |
| **Cls** | Class-based function with lifecycle hooks (`@modal.enter` for model loading). |
| **Volume** | Persistent distributed filesystem for models/data (up to 2.5 GB/s). |
| **Secret** | Encrypted env vars (B2 keys, Slack tokens, HF tokens). |
| **CloudBucketMount** | Mount S3-compatible buckets (including B2) directly as a filesystem. |
| **Web Endpoint** | Expose a function as an HTTPS API. |

### Container Lifecycle

```python
@app.cls(gpu="L40S", image=image)
class ComfyInference:
    @modal.enter()           # Runs ONCE when container starts → load models here
    def startup(self):
        self.model = load_model("/models/flux.safetensors")

    @modal.method()          # Called per-request
    def generate(self, prompt):
        return self.model(prompt)

    @modal.exit()            # Runs on shutdown (30s grace period)
    def cleanup(self):
        sync_outputs()
```

---

## 3. Secrets & B2 Credentials

### Create Secrets via CLI
```bash
# B2 credentials (S3-compatible format for CloudBucketMount)
modal secret create b2-credentials \
  AWS_ACCESS_KEY_ID=<your_B2_APP_KEY_ID> \
  AWS_SECRET_ACCESS_KEY=<your_B2_APP_KEY>

# Slack integration (optional)
modal secret create slack-credentials \
  SLACK_BOT_TOKEN=xoxb-... \
  SLACK_ERROR_CHANNEL=C0123456789

# HuggingFace token (optional)
modal secret create hf-credentials \
  HF_TOKEN=hf_...
```

### Create Secrets via Dashboard
Go to [modal.com/secrets](https://modal.com/secrets) — templates available for common services.

### Use Secrets in Functions
```python
@app.function(secrets=[
    modal.Secret.from_name("b2-credentials"),
    modal.Secret.from_name("slack-credentials"),
])
def my_func():
    import os
    b2_key = os.environ["AWS_ACCESS_KEY_ID"]
    slack_token = os.environ["SLACK_BOT_TOKEN"]
```

---

## 4. Model Storage with Volumes

### Create a Volume
```bash
modal volume create comfy-models
modal volume create comfy-models --version=2    # v2 for unlimited files
```

### Download Models into a Volume

```python
# setup_volumes.py
import modal
import subprocess

app = modal.App("setup-volumes")

vol = modal.Volume.from_name("comfy-models", create_if_missing=True)

image = (
    modal.Image.debian_slim(python_version="3.11")
    .apt_install(["curl", "unzip"])
    .run_commands("curl -s https://rclone.org/install.sh | bash")
)

@app.function(
    image=image,
    volumes={"/models": vol},
    secrets=[modal.Secret.from_name("b2-credentials")],
    timeout=3600,  # 1 hour for large models
)
def sync_models_from_b2():
    """One-time: pull models from B2 into Modal Volume."""
    import os

    # Configure rclone for B2
    os.makedirs("/root/.config/rclone", exist_ok=True)
    with open("/root/.config/rclone/rclone.conf", "w") as f:
        f.write(f"""[b2]
type = b2
account = {os.environ['AWS_ACCESS_KEY_ID']}
key = {os.environ['AWS_SECRET_ACCESS_KEY']}
hard_delete = true
""")

    # Sync your existing B2 model structure
    # Adjust bucket name and path to match your B2_BUCKET/comfy_models layout
    model_types = [
        "diffusion_models", "controlnet", "clip", "clip_vision",
        "loras", "text_encoders", "vae", "upscale_models"
    ]

    for model_type in model_types:
        print(f"[sync:{model_type}] Starting...")
        subprocess.run([
            "rclone", "copy",
            f"b2:YOUR_B2_BUCKET/comfy_models/{model_type}",
            f"/models/{model_type}",
            "--transfers", "16",
            "--fast-list",
            "--progress",
        ], check=False)
        print(f"[sync:{model_type}] Done.")

    vol.commit()  # CRITICAL: persist to Volume
    print("All models synced to Volume.")

@app.local_entrypoint()
def main():
    sync_models_from_b2.remote()
```

Run once:
```bash
modal run setup_volumes.py
```

### Volume CLI Commands
```bash
modal volume list                       # List all volumes
modal volume ls comfy-models            # List contents
modal volume ls comfy-models /loras     # List subdirectory
modal volume put comfy-models ./local_model.safetensors /loras/  # Upload file
modal volume get comfy-models /loras/my_lora.safetensors ./      # Download file
```

### Volume Performance

| Feature | v1 | v2 (beta) |
|---------|-----|-----------|
| Max files | 500K (recommend <50K) | Unlimited |
| Concurrent writers | ~5 | Hundreds |
| Max file size | — | 1 TiB |
| Bandwidth | Up to 2.5 GB/s | Up to 2.5 GB/s |

---

## 5. ComfyUI Inference Deployment

### Option A: Interactive Web UI (for development)

```python
# comfy_ui.py
import modal
import subprocess

app = modal.App("comfy-ui")

vol = modal.Volume.from_name("comfy-models")

# Build the ComfyUI container image
image = (
    modal.Image.debian_slim(python_version="3.11")
    .apt_install(["git", "ffmpeg", "libgl1"])
    .uv_pip_install(["comfy-cli==1.5.3"])
    .run_commands(
        "comfy --skip-prompt install --fast-deps --nvidia --version 0.3.71"
    )
    # Install custom nodes (from ComfyUI registry)
    .run_commands(
        "comfy node install --fast-deps was-ns",
        "comfy node install --fast-deps comfyui-kjnodes",
        "comfy node install --fast-deps rgthree-comfy",
        "comfy node install --fast-deps ComfyUI-VideoHelperSuite",
    )
    # Install NV_Comfy_Utils (not on registry — clone from GitHub)
    .run_commands(
        "cd /root/comfy/ComfyUI/custom_nodes && "
        "git clone https://github.com/neonvoid/NV_Comfy_Utils.git && "
        "pip install -r NV_Comfy_Utils/requirements.txt"
    )
)

@app.function(
    image=image,
    gpu="L40S",                          # 48GB VRAM — good for most workflows
    volumes={"/models": vol},
    secrets=[modal.Secret.from_name("slack-credentials")],
    max_containers=1,
    scaledown_window=600,                # Keep alive 10 min after last request
    timeout=3600,
)
@modal.concurrent(max_inputs=10)
@modal.web_server(8000, startup_timeout=120)
def ui():
    import os

    # Symlink Volume models into ComfyUI's expected paths
    model_types = [
        "diffusion_models", "controlnet", "clip", "clip_vision",
        "loras", "text_encoders", "vae", "upscale_models"
    ]
    for mt in model_types:
        src = f"/models/{mt}"
        dst = f"/root/comfy/ComfyUI/models/{mt}"
        if os.path.exists(src):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if not os.path.exists(dst):
                os.symlink(src, dst)

    # Configure Slack .env for NV_Comfy_Utils
    nv_dir = "/root/comfy/ComfyUI/custom_nodes/NV_Comfy_Utils"
    if os.path.isdir(nv_dir):
        with open(f"{nv_dir}/.env", "w") as f:
            f.write(f"SLACK_BOT_TOKEN={os.environ.get('SLACK_BOT_TOKEN', '')}\n")
            f.write(f"SLACK_ERROR_CHANNEL={os.environ.get('SLACK_ERROR_CHANNEL', '')}\n")

    # Launch ComfyUI — must bind 0.0.0.0 for Modal's reverse proxy
    subprocess.Popen(
        "comfy launch -- --listen 0.0.0.0 --port 8000",
        shell=True
    )
```

Deploy and access:
```bash
# Dev mode (live reload, temporary URL)
modal serve comfy_ui.py

# Production (stable URL)
modal deploy comfy_ui.py
```

Modal gives you an HTTPS URL like:
`https://your-workspace--comfy-ui-ui.modal.run`

No SSH tunnel needed.

### Option B: Headless API (for production serving)

```python
# comfy_inference.py
import modal
import json
import uuid
import subprocess
import urllib.request
import socket
from pathlib import Path

app = modal.App("comfy-inference")

vol = modal.Volume.from_name("comfy-models")

image = (
    modal.Image.debian_slim(python_version="3.11")
    .apt_install(["git", "ffmpeg", "libgl1"])
    .uv_pip_install(["comfy-cli==1.5.3", "fastapi[standard]"])
    .run_commands(
        "comfy --skip-prompt install --fast-deps --nvidia --version 0.3.71"
    )
    .run_commands(
        "cd /root/comfy/ComfyUI/custom_nodes && "
        "git clone https://github.com/neonvoid/NV_Comfy_Utils.git && "
        "pip install -r NV_Comfy_Utils/requirements.txt"
    )
    # Bundle your workflow JSON into the image
    # Export from ComfyUI via menu → "Export (API)"
    .add_local_file("workflows/workflow_api.json", "/root/workflow_api.json")
)

@app.cls(
    image=image,
    gpu="L40S",
    volumes={"/models": vol},
    scaledown_window=300,       # Keep warm 5 min between requests
    min_containers=0,           # Scale to zero when idle (set 1+ to stay warm)
    max_containers=10,          # Burst up to 10 GPUs
)
@modal.concurrent(max_inputs=1) # 1 per container — ComfyUI is single-threaded
class ComfyAPI:
    port: int = 8000

    @modal.enter()
    def launch_comfy(self):
        """Start ComfyUI server once per container."""
        import os

        # Symlink models from Volume
        model_types = [
            "diffusion_models", "controlnet", "clip", "clip_vision",
            "loras", "text_encoders", "vae", "upscale_models"
        ]
        for mt in model_types:
            src = f"/models/{mt}"
            dst = f"/root/comfy/ComfyUI/models/{mt}"
            if os.path.exists(src) and not os.path.exists(dst):
                os.symlink(src, dst)

        # Start ComfyUI in background
        subprocess.run(
            f"comfy launch --background -- --port {self.port}",
            shell=True, check=True
        )

        # Wait for server to be ready
        self._wait_for_server()

    def _wait_for_server(self, timeout=120):
        """Poll until ComfyUI is responding."""
        import time
        start = time.time()
        while time.time() - start < timeout:
            try:
                req = urllib.request.Request(f"http://127.0.0.1:{self.port}/system_stats")
                urllib.request.urlopen(req, timeout=5)
                print("ComfyUI server is ready.")
                return
            except (socket.timeout, urllib.error.URLError, ConnectionRefusedError):
                time.sleep(2)
        raise RuntimeError("ComfyUI failed to start within timeout")

    @modal.method()
    def run_workflow(self, workflow_json: str, overrides: dict = None):
        """Run a ComfyUI workflow and return output file bytes."""
        workflow = json.loads(workflow_json)

        # Apply any prompt/parameter overrides
        if overrides:
            for node_id, inputs in overrides.items():
                if node_id in workflow:
                    workflow[node_id]["inputs"].update(inputs)

        # Set unique filename prefix for this run
        client_id = uuid.uuid4().hex[:12]
        for node_id, node in workflow.items():
            if node.get("class_type") == "SaveImage":
                node["inputs"]["filename_prefix"] = client_id

        # Write temp workflow and run
        tmp_path = f"/tmp/{client_id}.json"
        with open(tmp_path, "w") as f:
            json.dump(workflow, f)

        result = subprocess.run(
            f"comfy run --workflow {tmp_path} --wait --timeout 1200 --verbose",
            shell=True, capture_output=True, text=True
        )

        if result.returncode != 0:
            return {"error": result.stderr}

        # Collect outputs
        output_dir = Path("/root/comfy/ComfyUI/output")
        outputs = []
        for f in output_dir.iterdir():
            if f.name.startswith(client_id):
                outputs.append({"filename": f.name, "bytes": f.read_bytes()})

        return outputs

    @modal.fastapi_endpoint(method="POST")
    def api(self, request: dict):
        """HTTP POST endpoint for external callers."""
        from fastapi import Response

        workflow_json = json.dumps(request.get("workflow", {}))
        overrides = request.get("overrides", {})

        results = self.run_workflow.local(workflow_json, overrides)

        if isinstance(results, dict) and "error" in results:
            return Response(content=results["error"], status_code=500)

        if results:
            return Response(content=results[0]["bytes"], media_type="image/png")
        return Response(content="No output generated", status_code=500)
```

Deploy:
```bash
modal deploy comfy_inference.py
```

Call the API:
```python
import requests, json

url = "https://your-workspace--comfy-inference-comfyapi-api.modal.run"

# Load your exported workflow JSON
with open("workflow_api.json") as f:
    workflow = json.load(f)

response = requests.post(url, json={
    "workflow": workflow,
    "overrides": {
        "6": {"inputs": {"text": "a cat astronaut, photorealistic"}}
    }
})

with open("output.png", "wb") as f:
    f.write(response.content)
```

---

## 6. LoRA Training

### Training on Modal (short runs, < 2 hours)

```python
# lora_training.py
import modal
import subprocess

app = modal.App("lora-training")

models_vol = modal.Volume.from_name("comfy-models", create_if_missing=True)
training_vol = modal.Volume.from_name("training-data", create_if_missing=True)

image = (
    modal.Image.debian_slim(python_version="3.11")
    .apt_install(["git", "curl"])
    .run_commands("curl -s https://rclone.org/install.sh | bash")
    .uv_pip_install([
        "torch==2.8.0",
        "accelerate",
        "peft",
        "transformers",
        "datasets",
        "huggingface_hub",
    ])
    # Clone AI-Toolkit
    .run_commands(
        "cd /app && git clone https://github.com/ostris/ai-toolkit.git && "
        "cd ai-toolkit && pip install -e . --no-cache-dir"
    )
)

@app.function(
    image=image,
    gpu="A100-80GB",           # LoRA training needs VRAM
    volumes={
        "/app/ai-toolkit/models": models_vol,
        "/app/ai-toolkit/datasets": training_vol,
    },
    secrets=[modal.Secret.from_name("b2-credentials")],
    timeout=7200,              # 2 hour max
)
def train_lora(config_yaml: str):
    """Run LoRA training with a YAML config string."""
    import os

    # Write config to file
    config_path = "/app/ai-toolkit/config/modal_train.yaml"
    os.makedirs(os.path.dirname(config_path), exist_ok=True)
    with open(config_path, "w") as f:
        f.write(config_yaml)

    # Run training
    result = subprocess.run(
        ["python", "run.py", config_path],
        cwd="/app/ai-toolkit",
        capture_output=True, text=True
    )

    print(result.stdout)
    if result.returncode != 0:
        print(f"STDERR: {result.stderr}")

    # Commit outputs to volume
    models_vol.commit()

    return {
        "returncode": result.returncode,
        "stdout": result.stdout[-2000:],  # Last 2000 chars
        "stderr": result.stderr[-2000:],
    }

@app.function(
    image=image,
    volumes={"/data": training_vol},
    secrets=[modal.Secret.from_name("b2-credentials")],
    timeout=1800,
)
def sync_training_data():
    """Pull datasets and configs from B2 into training Volume."""
    import os

    os.makedirs("/root/.config/rclone", exist_ok=True)
    with open("/root/.config/rclone/rclone.conf", "w") as f:
        f.write(f"""[b2]
type = b2
account = {os.environ['AWS_ACCESS_KEY_ID']}
key = {os.environ['AWS_SECRET_ACCESS_KEY']}
hard_delete = true
""")

    # Sync datasets from B2
    subprocess.run([
        "rclone", "copy",
        "b2:YOUR_B2_DATA_BUCKET/aitoolkit_datasets",
        "/data",
        "--transfers", "16", "--fast-list", "--progress"
    ], check=False)

    training_vol.commit()

@app.local_entrypoint()
def main():
    # Step 1: Sync training data
    sync_training_data.remote()

    # Step 2: Run training with your config
    config = """
config:
  name: my_lora_v1
  process:
    - type: sd_trainer
      training_folder: output/my_lora_v1
      model:
        name_or_path: "models/FLUX.1-dev"
      train:
        steps: 2000
        lr: 1e-4
      datasets:
        - folder_path: "datasets/my_character"
      save:
        save_every: 500
"""
    result = train_lora.remote(config)
    print(f"Training finished with code: {result['returncode']}")
```

### Training Recommendation

For **long training runs (2+ hours)**, stick with Vast.ai:
- Persistent SSH sessions with tmux
- No timeout limits
- Cheaper per GPU-hour
- Your existing `vast_ai_toolkit.sh` workflow works great

For **quick experiments (< 2 hours)** or **batch training sweeps**, Modal works well:
- Spin up, train, shut down automatically
- No idle costs
- Can run multiple configs in parallel

---

## 7. B2 Integration & Hybrid Architecture

### Direct B2 Bucket Mount (S3-compatible)

```python
# B2 is S3-compatible — use CloudBucketMount with endpoint URL
b2_models_mount = modal.CloudBucketMount(
    bucket_name="your-b2-models-bucket",
    bucket_endpoint_url="https://s3.us-west-004.backblazeb2.com",  # Your B2 region
    secret=modal.Secret.from_name("b2-credentials"),
    read_only=True,   # Read-only for serving
)

b2_data_mount = modal.CloudBucketMount(
    bucket_name="your-b2-data-bucket",
    bucket_endpoint_url="https://s3.us-west-004.backblazeb2.com",
    secret=modal.Secret.from_name("b2-credentials"),
    read_only=False,  # Read-write for outputs
)

@app.function(volumes={
    "/b2_models": b2_models_mount,
    "/b2_data": b2_data_mount,
})
def access_b2():
    import os
    # /b2_models/comfy_models/loras/ etc. available as local filesystem
    print(os.listdir("/b2_models/comfy_models/loras"))
```

**B2 mount caveats:**
- Slower than Modal Volumes (public internet, not Modal's internal network)
- No random-write or append — write-once only
- Best for syncing, not hot model serving
- Find your B2 S3 endpoint at: Backblaze dashboard → Buckets → Endpoint

### Recommended Hybrid Architecture

```
  ┌──────────────────────────────────────────────────┐
  │                    B2 Storage                      │
  │  (source of truth for models, datasets, outputs)   │
  │                                                    │
  │  models-bucket/comfy_models/    ← shared models    │
  │  models-bucket/models/          ← diffusers format │
  │  data-bucket/aitoolkit_*/       ← training data    │
  │  comfy-bucket/comfy_workflows/  ← workflows        │
  │  comfy-bucket/comfy_outputs/    ← outputs          │
  └──────────┬──────────────────────────┬──────────────┘
             │                          │
     ┌───────┴────────┐       ┌────────┴───────┐
     │  Modal Volume   │       │    Vast.ai     │
     │  (hot cache)    │       │   (rclone)     │
     │                 │       │                │
     │ comfy-models/   │       │ /workspace/    │
     │ └─ loras/       │       │  ComfyUI/      │
     │ └─ diffusion_*/ │       │  models/       │
     │ └─ vae/         │       │                │
     └───────┬─────────┘       └────────┬───────┘
             │                          │
     ┌───────┴─────────┐       ┌───────┴────────┐
     │  Modal Functions │       │  SSH Sessions  │
     │  (serverless)    │       │  (persistent)  │
     │                  │       │                │
     │ - API inference  │       │ - Interactive  │
     │ - Batch process  │       │ - Long training│
     │ - Scale 0→N     │       │ - Dev/debug    │
     └──────────────────┘       └────────────────┘
```

### Sync Utility: B2 → Modal Volume

```python
# sync_b2.py
import modal
import subprocess
import os

app = modal.App("b2-sync")

vol = modal.Volume.from_name("comfy-models", create_if_missing=True)

image = (
    modal.Image.debian_slim()
    .run_commands("curl -s https://rclone.org/install.sh | bash")
)

@app.function(
    image=image,
    volumes={"/vol": vol},
    secrets=[modal.Secret.from_name("b2-credentials")],
    timeout=3600,
)
def sync_from_b2(b2_bucket: str, b2_path: str, vol_path: str):
    """Pull files from B2 into Modal Volume."""
    os.makedirs("/root/.config/rclone", exist_ok=True)
    with open("/root/.config/rclone/rclone.conf", "w") as f:
        f.write(f"""[b2]
type = b2
account = {os.environ['AWS_ACCESS_KEY_ID']}
key = {os.environ['AWS_SECRET_ACCESS_KEY']}
hard_delete = true
""")

    dest = f"/vol/{vol_path}"
    os.makedirs(dest, exist_ok=True)

    subprocess.run([
        "rclone", "copy",
        f"b2:{b2_bucket}/{b2_path}", dest,
        "--transfers", "16", "--fast-list", "--ignore-existing", "--progress"
    ], check=True)

    vol.commit()
    print(f"Synced b2:{b2_bucket}/{b2_path} → Volume:/{vol_path}")

@app.function(
    image=image,
    volumes={"/vol": vol},
    secrets=[modal.Secret.from_name("b2-credentials")],
    timeout=3600,
)
def push_to_b2(vol_path: str, b2_bucket: str, b2_path: str):
    """Push files from Modal Volume to B2 (e.g., trained LoRAs)."""
    os.makedirs("/root/.config/rclone", exist_ok=True)
    with open("/root/.config/rclone/rclone.conf", "w") as f:
        f.write(f"""[b2]
type = b2
account = {os.environ['AWS_ACCESS_KEY_ID']}
key = {os.environ['AWS_SECRET_ACCESS_KEY']}
hard_delete = true
""")

    vol.reload()  # Get latest Volume state

    subprocess.run([
        "rclone", "copy",
        f"/vol/{vol_path}", f"b2:{b2_bucket}/{b2_path}",
        "--transfers", "16", "--progress"
    ], check=True)

    print(f"Pushed Volume:/{vol_path} → b2:{b2_bucket}/{b2_path}")

@app.local_entrypoint()
def main():
    # Example: sync all models from B2
    sync_from_b2.remote("your-models-bucket", "comfy_models", "")

    # Example: push a trained LoRA back to B2
    # push_to_b2.remote("loras/my_lora.safetensors", "your-models-bucket", "comfy_models/loras")
```

```bash
# Sync models from B2 to Volume
modal run sync_b2.py

# Or call specific functions
modal run sync_b2.py::app.sync_from_b2 --b2-bucket "my-bucket" --b2-path "comfy_models/loras" --vol-path "loras"
```

---

## 8. Scaling & Cold Start Optimization

### Scaling Parameters

```python
@app.cls(
    gpu="L40S",
    min_containers=0,         # 0 = scale to zero (cheapest)
    max_containers=10,        # Burst up to 10 GPUs
    buffer_containers=2,      # Keep 2 extra warm during active periods
    scaledown_window=300,     # Wait 5 min before scaling down idle container
)
class MyService:
    ...
```

| Parameter | What It Does | Cost Impact |
|-----------|-------------|-------------|
| `min_containers=0` | Scale to zero when idle | Cheapest — pay nothing when idle |
| `min_containers=1` | Always keep 1 warm | ~$1.95/hr (L40S) or $47/day — no cold starts |
| `buffer_containers=2` | Pre-warm 2 extras during active periods | Only costs during active use |
| `scaledown_window=300` | Keep container alive 5 min after last request | Small cost buffer to avoid cold starts |
| `max_containers=10` | Cap at 10 simultaneous GPUs | Safety valve on costs |

### Cold Start Reduction

**Baseline cold start**: ~10-20s for ComfyUI (container boot + model loading)

**Strategy 1: Keep warm**
```python
min_containers=1  # Eliminates cold start entirely (~$47/day for L40S)
```

**Strategy 2: Extend scaledown window**
```python
scaledown_window=600  # 10 minutes — containers live longer between requests
```

**Strategy 3: Memory snapshots (advanced)**
```python
@app.cls(
    gpu="L40S",
    enable_memory_snapshot=True,
)
class FastInference:
    @modal.enter(snap=True)      # Runs once, captured in snapshot
    def load_to_cpu(self):
        self.model = load_model("/models/flux.safetensors")  # CPU only

    @modal.enter(snap=False)     # Runs after snapshot restore
    def move_to_gpu(self):
        self.model = self.model.to("cuda")  # Fast GPU transfer

    @modal.method()
    def generate(self, prompt):
        return self.model(prompt)
```

Memory snapshots capture the container state after model loading. On subsequent cold starts, the snapshot is restored instead of re-running the load. Brings cold start from ~20s down to ~3s.

**Important:** Snapshots only work with `modal deploy` (not `modal run` or `modal serve`).

### Concurrency

```python
# ComfyUI is single-threaded — use 1 input per container for best latency
@modal.concurrent(max_inputs=1)

# For lightweight pre/post processing, allow more
@modal.concurrent(max_inputs=10)
```

| Setup | Median Latency | Cost | Best For |
|-------|---------------|------|----------|
| 1 container per input | ~4.4s | Higher (more containers) | Production API |
| Concurrent on 1 container | ~32s | Lower (fewer containers) | Dev/testing |
| Warm pool + 1:1 | ~4.4s | Highest | Low-latency production |

---

## 9. Monitoring & Debugging

### Dashboard
- **modal.com** → Apps → select your app → view logs, containers, metrics

### CLI
```bash
modal app list                    # List deployed apps
modal app logs my-app             # Stream logs
modal app stop my-app             # Stop deployment (must redeploy after)
modal volume ls comfy-models      # Check Volume contents
```

### Health Check Pattern (in code)
```python
def check_comfy_health(self):
    """Stop accepting inputs if ComfyUI server dies."""
    try:
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/system_stats")
        urllib.request.urlopen(req, timeout=5)
    except (socket.timeout, urllib.error.URLError):
        modal.experimental.stop_fetching_inputs()
        raise RuntimeError("ComfyUI server unhealthy — draining container")
```

### Dev Workflow
```bash
# 1. Iterate with live reload
modal serve comfy_ui.py
# → gives you a temp URL, reloads on file save

# 2. Test a one-off function
modal run setup_volumes.py

# 3. Deploy to production
modal deploy comfy_inference.py
# → gives you a stable URL
```

---

## 10. Cost Optimization

### GPU Selection Guide

| Workload | Recommended GPU | $/hr | Why |
|----------|----------------|------|-----|
| Image generation (Flux/SD) | L40S | $1.95 | 48GB VRAM, best cost/perf ratio |
| Video generation (WAN 14B) | A100-80GB | $2.50 | Needs 80GB VRAM |
| LoRA training (Flux) | A100-80GB | $2.50 | Training needs VRAM headroom |
| LoRA training (large models) | H100 | $3.95 | Faster training, 80GB HBM3 |
| Light inference | A10 | $1.10 | 24GB, budget option |

### Cost Comparison: Modal vs Vast.ai

| Scenario | Modal | Vast.ai |
|----------|-------|---------|
| A100-80GB for 1 hour continuous | ~$2.50 | ~$0.50-1.00 |
| A100-80GB for 5 min of a 1-hour session | ~$0.21 | ~$0.50-1.00 |
| Idle GPU for 8 hours overnight | $0 (scale to zero) | ~$4-8 |
| Burst: 10 GPUs for 10 minutes | ~$4.17 | Hard to get 10 GPUs fast |

**Rule of thumb:** Modal is cheaper when GPU utilization is < 30% of the time. Vast.ai is cheaper for sustained workloads.

### Cost-Saving Patterns

1. **Scale to zero** (`min_containers=0`) — pay nothing when idle
2. **Use L40S over A100** when 48GB is enough — saves 22%
3. **Batch requests** — keep containers busy, don't pay for idle warm time
4. **Short `scaledown_window`** for batch jobs — containers die faster when done
5. **Long `scaledown_window`** for API traffic — avoid repeated cold starts

---

## 11. Common Commands

### Setup & Deploy
```bash
pip install modal                          # Install SDK
modal setup                                # Authenticate
modal run app.py                           # Test run (ephemeral)
modal serve app.py                         # Dev server (live reload)
modal deploy app.py                        # Production deploy
```

### Management
```bash
modal app list                             # List deployments
modal app stop <app-name>                  # Stop deployment
modal app logs <app-name>                  # Stream logs
```

### Volumes
```bash
modal volume create my-vol                 # Create volume
modal volume create my-vol --version=2     # Create v2 volume
modal volume list                          # List volumes
modal volume ls my-vol                     # List contents
modal volume ls my-vol /path               # List subdirectory
modal volume put my-vol ./file /remote/    # Upload file
modal volume get my-vol /remote/file ./    # Download file
modal volume rm my-vol                     # Delete volume
```

### Secrets
```bash
modal secret create my-secret K1=V1 K2=V2 # Create secret
modal secret list                          # List secrets
modal secret delete my-secret              # Delete secret
```

### Debugging
```bash
modal run app.py --detach                  # Run without blocking terminal
modal container list                       # List running containers
modal container exec <id> bash             # Shell into running container
```

---

## 12. Plan Limits

### Starter (Free) — $30/month Credits

| Resource | Limit |
|----------|-------|
| Containers | 100 |
| GPU concurrency | 10 |
| Deployed apps | 200 |
| Web endpoints | 8 |
| Crons | 5 |
| Log retention | 1 day |
| Seats | 3 |

### Team — $250/month + $100 Credits

| Resource | Limit |
|----------|-------|
| Containers | 1,000 |
| GPU concurrency | 50 |
| Deployed apps | 1,000 |
| Web endpoints | Unlimited |
| Crons | Unlimited |
| Log retention | 30 days |
| Seats | Unlimited |

### GPU Availability

| GPU | VRAM | $/hr | Max per Container |
|-----|------|------|-------------------|
| T4 | 16 GB | $0.59 | 8 |
| L4 | 24 GB | $0.80 | 8 |
| A10 | 24 GB | $1.10 | 4 |
| L40S | 48 GB | $1.95 | 8 |
| A100-40GB | 40 GB | $2.10 | 8 |
| A100-80GB | 80 GB | $2.50 | 8 |
| H100 | 80 GB | $3.95 | 8 |
| H200 | 141 GB | $4.54 | 8 |
| B200 | — | $6.25 | 8 |

Multi-GPU: up to 8 GPUs per container (e.g., `gpu="H100:8"`)

---

## Quick Start Checklist

1. [ ] Create Modal account at [modal.com](https://modal.com)
2. [ ] `pip install modal && modal setup`
3. [ ] Create secrets: `modal secret create b2-credentials AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...`
4. [ ] Create volume: `modal volume create comfy-models`
5. [ ] Sync models from B2: `modal run setup_volumes.py`
6. [ ] Test ComfyUI UI: `modal serve comfy_ui.py`
7. [ ] Deploy inference API: `modal deploy comfy_inference.py`
8. [ ] Call API from your app or test with curl
