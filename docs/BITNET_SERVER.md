# LLM Server Setup (Falcon3 10B 1.58-bit)

Run Falcon3 10B (1.58-bit quantized) as a persistent OpenAI-compatible server
using CPU-only inference via bitnet.cpp. Any client (Open WebUI, OpenCode,
curl) can query it via standard `/v1/chat/completions` calls.

CPU-only means **no GPU required** — the system runs on any machine with a
modern x86 CPU (AVX2) or ARM CPU (NEON) and enough RAM. This makes the project
portable and easy to share.

Falcon3 is used as the **sole LLM** in the `cpu` and `minimal` profiles, or as
the **fast triage model** in the `dual` profile (where Qwen 3.5 9B handles
synthesis on GPU). See `ORCHESTRATOR.md` for details on dual-model pipeline.

## Minimum Hardware

| Resource | Minimum | Recommended | Notes |
|---|---|---|---|
| CPU | 4 cores, AVX2 or NEON | 8+ cores | More cores = faster inference |
| RAM | 8 GB | 16+ GB | Model ~2 GB + KV cache + OS |
| GPU | **None required** | — | bitnet.cpp uses optimized CPU ternary kernels |
| Storage | 10 GB (model only) | 200+ GB | Full setup with ZIMs needs more |

The 1.58-bit quantization means the entire 10B model is only ~2 GB in memory.
The KV cache for context scales at ~160 KB/token — 32K context uses ~5 GB RAM.

## Prerequisites

### 1. Clone and build bitnet.cpp with Falcon3 10B

bitnet.cpp (Microsoft's BitNet framework) officially supports Falcon3 1.58-bit
models. The `setup_env.py` script generates optimized ternary lookup-table
kernels for your CPU architecture and compiles the `llama-server` binary.

#### Docker (recommended)

The Dockerfile handles everything automatically. It patches `setup_env.py` to
skip the slow model conversion (~30+ min) and instead downloads a pre-built
GGUF from HuggingFace in a parallel build stage:

```bash
make build    # ~5-10 min (compile + parallel GGUF download)
```

#### Bare metal

```bash
cd /knowledge/services
git clone https://github.com/microsoft/BitNet.git bitnet-cpp
cd bitnet-cpp
pip install -r requirements.txt

# Option A: Full setup (builds binary + downloads & converts model, ~30+ min)
python setup_env.py --hf-repo tiiuae/Falcon3-10B-Instruct-1.58bit -q i2_s

# Option B: Build binary only, then download pre-built GGUF (faster, ~10 min)
#   Step 1: Build with kernel codegen (patch out the slow model conversion)
sed -i 's/^    prepare_model()/    pass  # skipped/' setup_env.py
python setup_env.py --hf-repo tiiuae/Falcon3-10B-Instruct-1.58bit -q i2_s
#   Step 2: Download pre-built GGUF (~2 GB)
pip install huggingface-hub
python3 -c "
from huggingface_hub import hf_hub_download
hf_hub_download(repo_id='tiiuae/Falcon3-10B-Instruct-1.58bit-GGUF',
    filename='ggml-model-i2_s.gguf',
    local_dir='models/Falcon3-10B-Instruct-1.58bit')
"
```

Both options produce the same result: a `llama-server` binary with optimized
ternary kernels matched to your CPU (AVX2, AVX-512, or ARM NEON — auto-detected)
and a GGUF model at `models/Falcon3-10B-Instruct-1.58bit/ggml-model-i2_s.gguf`.

The pre-built GGUFs are published by TII (the Falcon team) at
`tiiuae/Falcon3-{10B,3B,1B}-Instruct-1.58bit-GGUF` on HuggingFace.

### 2. Verify inference works

```bash
python run_inference.py \
  -m models/Falcon3-10B-Instruct-1.58bit/ggml-model-i2_s.gguf \
  -p "You are a helpful assistant" \
  -cnv
```

## Server: Persistent Process with llama-server

bitnet.cpp is built on llama.cpp and includes `llama-server` — an
OpenAI-compatible HTTP server. This is far better than spawning a subprocess
per request.

### Option A: llama-server directly (recommended)

```bash
/knowledge/services/bitnet-cpp/build/bin/llama-server \
  --model /knowledge/services/bitnet-cpp/models/Falcon3-10B-Instruct-1.58bit/ggml-model-i2_s.gguf \
  --host 0.0.0.0 \
  --port 8080 \
  --n-gpu-layers 0 \
  --ctx-size 32768 \
  --threads $(nproc)
```

`--n-gpu-layers 0` runs entirely on CPU using bitnet.cpp's optimized ternary
kernels. No GPU drivers or CUDA needed.

`--ctx-size 32768` takes advantage of system RAM (no VRAM constraint). At
~160 KB/token, 32K context uses ~5 GB RAM — easily within any 16+ GB machine.
When the KV cache fills, context shifting automatically evicts the oldest
tokens to keep conversation flowing indefinitely.

`--threads $(nproc)` uses all available CPU cores. On machines running other
services (Kiwix, Qdrant), reduce this — e.g., `--threads 8` on a 10-core CPU
leaves 2 cores free for other work.

This exposes:
- `GET  /v1/models` — list available models
- `POST /v1/chat/completions` — chat endpoint
- `POST /v1/completions` — raw completion endpoint

### Option B: FastAPI wrapper (if llama-server isn't available)

If your bitnet.cpp build doesn't include llama-server, wrap inference in a
persistent process:

```python
#!/usr/bin/env python3
"""Falcon3 OpenAI-compatible API server.
Loads the model once at startup, serves requests without subprocess overhead.
"""

from contextlib import asynccontextmanager
from fastapi import FastAPI
from pydantic import BaseModel
import time, uuid

# Import inference — adjust path to your build
import sys
sys.path.insert(0, "/knowledge/services/bitnet-cpp")

MODEL_PATH = "/knowledge/services/bitnet-cpp/models/Falcon3-10B-Instruct-1.58bit/ggml-model-i2_s.gguf"
model = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global model
    print(f"Loading model from {MODEL_PATH}...")
    # model = load_model(MODEL_PATH)  # replace with actual API
    print("Model loaded.")
    yield
    # Cleanup on shutdown (if needed)
    print("Shutting down.")

app = FastAPI(title="Falcon3 Local Server", lifespan=lifespan)

class Message(BaseModel):
    role: str
    content: str

class ChatRequest(BaseModel):
    model: str = "falcon3-10b-1.58bit"
    messages: list[Message]
    max_tokens: int = 512
    temperature: float = 0.7

@app.get("/v1/models")
async def list_models():
    return {
        "object": "list",
        "data": [{
            "id": "falcon3-10b-1.58bit",
            "object": "model",
            "owned_by": "local"
        }]
    }

@app.post("/v1/chat/completions")
async def chat(req: ChatRequest):
    prompt = "\n".join(
        f"{m.role}: {m.content}" for m in req.messages
    )

    # Replace with actual inference call
    # output = model.generate(prompt, max_tokens=req.max_tokens, temp=req.temperature)
    output = "[placeholder — wire up model.generate()]"

    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": req.model,
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": output},
            "finish_reason": "stop"
        }],
        "usage": {
            "prompt_tokens": len(prompt.split()),
            "completion_tokens": len(output.split()),
            "total_tokens": len(prompt.split()) + len(output.split())
        }
    }
```

Run with:
```bash
uvicorn bitnet_server:app --host 0.0.0.0 --port 8080
```

**Option A (llama-server) is strongly preferred** — it handles streaming,
token counting, and batching natively.

## systemd Service

```ini
# /etc/systemd/system/bitnet-server.service
[Unit]
Description=Falcon3 10B OpenAI-Compatible API Server
After=local-fs.target
Requires=local-fs.target

[Service]
ExecStart=/knowledge/services/bitnet-cpp/build/bin/llama-server \
  --model /knowledge/services/bitnet-cpp/models/Falcon3-10B-Instruct-1.58bit/ggml-model-i2_s.gguf \
  --host 0.0.0.0 \
  --port 8080 \
  --n-gpu-layers 0 \
  --ctx-size 32768 \
  --threads 8
Restart=on-failure
RestartSec=5
User=matt

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now bitnet-server
```

## Testing

```bash
# Health check
curl -s http://localhost:8080/v1/models | python3 -m json.tool

# Chat
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "falcon3-10b-1.58bit",
    "messages": [{"role": "user", "content": "Explain what Kiwix is in one sentence."}],
    "max_tokens": 100
  }' | python3 -m json.tool
```

## Performance (CPU-only)

Speed depends on core count and instruction set. bitnet.cpp's ternary kernels
replace float multiplication with additions, making CPU inference much faster
than standard quantized models.

| CPU | Cores/Threads | ISA | Est. tok/s |
|---|---|---|---|
| i9-10900K | 10c/20t | AVX2 | 8–18 |
| i5-1035G4 (Surface) | 4c/8t | AVX-512 | 6–14 |
| Ryzen 5600X | 6c/12t | AVX2 | 6–14 |
| Apple M2 | 8c | NEON | 12–25 |
| Any 4-core AVX2 | 4c | AVX2 | 3–8 |

| Resource | Usage (32K context) |
|---|---|
| RAM (model weights) | ~2 GB |
| RAM (KV cache, 32K) | ~5 GB |
| RAM total | ~7–8 GB |
| GPU | **None** |

8–18 tok/s is roughly 1–2 sentences per second — responsive enough for a
personal assistant. Reduce `--ctx-size` to 8192 or 16384 on machines with
less RAM.

## Context Shifting (Auto-Compacting)

llama.cpp handles context overflow automatically:

1. KV cache fills up at `--ctx-size` tokens
2. Oldest N tokens are evicted (system prompt is preserved)
3. Token positions are shifted so the model sees a contiguous sequence
4. Inference continues seamlessly — no restart needed

This means conversations can run indefinitely. RAG-injected context is always
in the most recent portion of the window, so it's never the content that gets
evicted. No custom code is needed — this is built into llama-server.
