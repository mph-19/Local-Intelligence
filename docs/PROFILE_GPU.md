# Profile: GPU

Qwen 3.5 9B running on an NVIDIA GPU via llama.cpp with CUDA. Significantly
higher quality than Falcon3 on CPU, with faster inference thanks to GPU
acceleration.

## Requirements

| Resource | Minimum |
|---|---|
| GPU | NVIDIA with 8+ GB VRAM (RTX 3060 12GB, RTX 3080 10GB, etc.) |
| RAM | 8+ GB (Qwen runs on GPU, not system RAM) |
| Storage | 15+ GB (model ~5.5 GB + CUDA image) |
| Software | Docker + [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/) |

## What Runs

```
┌──────────────────────────────────────────────────┐
│                Services started                   │
├──────────────┬───────┬───────────────────────────┤
│  Qwen 3.5 9B│ :8082 │ LLM inference (GPU/CUDA)  │
│  Orchestrator│ :8081 │ RAG proxy (single mode)   │
│  Kiwix       │ :8888 │ Offline knowledge bases   │
│  Open WebUI  │ :3000 │ Chat interface            │
└──────────────┴───────┴───────────────────────────┘
```

Falcon3 is **not started** in this profile. The GPU handles all inference.

## Architecture

```
User query
    │
    ▼
Orchestrator (:8081)
    ├── Classify intent
    ├── Retrieve from Qdrant
    ├── Kiwix fulltext fallback (if vector scores weak)
    ├── Build augmented prompt
    └── Forward to Qwen 3.5 (:8082)
            │  (GPU inference, ~60-100 tok/s)
            ▼
        Response + source citations
```

One LLM handles everything. The orchestrator runs in `single` pipeline mode,
same as the `cpu` profile — the only difference is which model it talks to.

## Setup

### Docker (recommended)

```bash
make setup              # select "gpu" when prompted (auto-detected if GPU present)
make build              # builds Qwen image (~15-30 min, downloads ~5.5 GB model)
make up                 # start all services
make health             # verify [OK] for all 4 services
```

Or force the profile:
```bash
bash scripts/configure.sh --profile gpu
```

### Prerequisites

**nvidia-container-toolkit** must be installed for Docker to access the GPU:

```bash
# Ubuntu/Debian
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Arch Linux
sudo pacman -S nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Verify it works: `docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu24.04 nvidia-smi`

## Configuration

These are the key `.env` settings for this profile (set automatically by
`make setup`):

```bash
COMPOSE_PROFILES=gpu
PIPELINE_MODE=single
LLM_URL=http://qwen:8082/v1/chat/completions
QWEN_CTX_SIZE=8192            # increase if you have more VRAM
QWEN_GPU_LAYERS=99            # offload all layers to GPU
```

### VRAM Budget

| Context size | VRAM usage (Q4_K_M) | Suitable for |
|---|---|---|
| 8192 | ~6.5 GB | 8 GB cards (RTX 3060 8GB, RTX 4060) |
| 16384 | ~8 GB | 10 GB cards (RTX 3080) |
| 32768 | ~11 GB | 12+ GB cards (RTX 3060 12GB, RTX 4070 Ti) |

Set `QWEN_CTX_SIZE` in `.env` to match your VRAM. The default (8192) is
conservative and works on any 8+ GB card.

### Alternative Quantizations

Trade quality for VRAM:

```bash
# Higher quality, more VRAM (~6.5 GB weights)
docker compose build --build-arg MODEL_FILE=Qwen3.5-9B-Q5_K_M.gguf qwen

# Lower VRAM (~3.5 GB weights), some quality loss
docker compose build --build-arg MODEL_FILE=Qwen3.5-9B-Q2_K.gguf qwen
```

## Performance

GPU inference is dramatically faster than CPU, especially for prompt ingestion
(reading retrieved context):

| | CPU (Falcon3 10B, i9-10900K) | GPU (Qwen 3.5 9B, RTX 3080) |
|---|---|---|
| Token generation | ~10-18 tok/s | ~60-100 tok/s |
| Prompt ingestion | ~50-100 tok/s | ~2000-4000 tok/s |

Prompt ingestion speed matters a lot for RAG — the model reads thousands of
tokens of retrieved context before generating. On CPU this can take 10-30
seconds; on GPU it's under a second.

## When to Use This Profile

- You have an NVIDIA GPU with 8+ GB VRAM
- You want the best single-model quality
- You don't need CPU inference (Falcon3 not running)
- You want fast inference for interactive use

## Upgrading to Dual

If you also want Falcon3 as a triage filter to improve retrieval quality:

```bash
make setup      # re-run wizard, select "dual"
make build      # builds the Falcon3 image (Qwen image is reused)
make down && make up
```

See [PROFILE_DUAL.md](PROFILE_DUAL.md) for details.
