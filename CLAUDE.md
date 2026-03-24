# Local Intelligence — CLAUDE.md

## Project Purpose

A personal cloud knowledge system running across one or more machines on the
local network. Combines Kiwix offline knowledge bases, a RAG pipeline, and
local LLM inference, fronted by a reverse proxy and exposed via Open WebUI.

Supports multiple hardware profiles: CPU-only (Falcon3 10B), GPU (Qwen 3.5 9B),
dual-model pipeline (Falcon3 triage + Qwen synthesis), or minimal (Falcon3 3B).

## Hardware

Designed to run on **CPU only** in its default profile — no GPU required.
Portable to any machine with AVX2 (x86) or NEON (ARM) and 8+ GB RAM. GPU
profiles require an NVIDIA card with 8+ GB VRAM. Originally developed on:

| Component | Spec |
|---|---|
| CPU | Intel i9-10900K (10c/20t, AVX2) |
| RAM | 32GB DDR4 |
| GPU | NVIDIA RTX 3080 10GB (used by gpu/dual profiles) |
| Storage | 1TB dedicated drive mounted at `/knowledge` |
| OS | Distro-agnostic (pacman, apt, dnf all supported) |

## Hardware Profiles

Set via `make setup` (interactive wizard) or manually in `.env`.

| Profile | LLM(s) | Pipeline mode | Requirements |
|---|---|---|---|
| `cpu` | Falcon3 10B (bitnet.cpp, CPU) | single | 12+ GB RAM, AVX2 |
| `gpu` | Qwen 3.5 9B (llama.cpp, CUDA) | single | NVIDIA 8+ GB VRAM |
| `dual` | Falcon3 (CPU) + Qwen 3.5 (GPU) | dual | 16+ GB RAM + NVIDIA 8+ GB VRAM |
| `minimal` | Falcon3 3B (bitnet.cpp, CPU) | single | 4+ GB RAM |

In **dual** mode, the orchestrator runs a two-stage pipeline:
1. **Triage** (Falcon3, CPU): Scores and filters retrieved chunks — fast, low temp
2. **Synthesis** (Qwen 3.5, GPU): Reasons over filtered chunks — high quality

## Directory Structure

```
local-intelligence/
├── CLAUDE.md              ← you are here
├── README.md              ← project overview + architecture
├── docker-compose.yml     ← Docker deployment (profile-based, all services)
├── .env.example           ← configurable env vars (profiles, ports, models)
├── config/
│   └── drive_layout.md    ← 1TB drive partitioning and directory plan
├── Makefile               ← common operations (make up, make setup, make health)
├── docker/
│   ├── Dockerfile.falcon3       ← multi-stage build for CPU LLM (bitnet.cpp)
│   ├── Dockerfile.qwen          ← multi-stage build for GPU LLM (llama.cpp + CUDA)
│   ├── Dockerfile.orchestrator  ← orchestrator + ingest (multi-target)
│   └── requirements.orchestrator.txt
├── docs/
│   ├── DOCKER_BEGINNER.md ← Docker guide for beginners
│   ├── PROFILE_CPU.md     ← CPU profile: Falcon3 10B/3B, no GPU
│   ├── PROFILE_GPU.md     ← GPU profile: Qwen 3.5 9B, NVIDIA CUDA
│   ├── PROFILE_DUAL.md    ← Dual profile: Falcon3 triage + Qwen synthesis
│   ├── KIWIX_SETUP.md     ← Kiwix installation + ZIM management
│   ├── BITNET_SERVER.md   ← Falcon3 10B API server (OpenAI-compatible)
│   ├── RAG_PIPELINE.md    ← Embedding, vector store, ingestion
│   ├── ORCHESTRATOR.md    ← Query routing logic + dual-model pipeline
│   ├── LORA_FINETUNE.md   ← LoRA fine-tuning (optional, requires GPU)
│   ├── WEB_ACCESS.md      ← Open WebUI + remote access
│   └── MULTI_HOST.md      ← Running services across multiple machines
├── services/
│   ├── rag.py             ← shared RAG module (embedding, Qdrant, chunking)
│   └── orchestrator.py    ← query routing + RAG proxy + dual-model pipeline
├── scripts/
│   ├── install.sh         ← one-command bare metal installer
│   ├── setup.sh           ← lighter dependency-only installer
│   ├── configure.sh       ← hardware detection + profile wizard (make setup)
│   ├── ingest_docs.py     ← index local documents into Qdrant
│   └── ingest_kiwix.py    ← index Kiwix articles into Qdrant
└── data/                   ← local working data (Docker default KNOWLEDGE_DIR)
```

## Related Work

- `~/ai-s/AIplayground/BitNet/` — BitNet build on Surface Pro (CPU-only)
- `~/ai-s/AIplayground/RAG_SETUP.md` — RAG pipeline guide (Surface-targeted)

## Key Decisions

- **Profile-based deployment**: `cpu`, `gpu`, `dual`, `minimal` profiles control
  which LLM services start. Set via `COMPOSE_PROFILES` in `.env`.
- **Falcon3 10B** (1.58-bit quantized, ~2 GB RAM) for CPU inference via bitnet.cpp
- **Qwen 3.5 9B** (Q4_K_M GGUF, ~5.5 GB VRAM) for GPU inference via llama.cpp
- **Dual-model pipeline**: Falcon3 triages (fast, CPU), Qwen synthesizes (quality, GPU)
  — controlled by `PIPELINE_MODE=dual` in `.env`
- **32K context window** on Falcon3 with automatic context shifting
- **8K context window** on Qwen (configurable, limited by 10 GB VRAM)
- Designed for portability — runs on any machine with AVX2/NEON and 4+ GB RAM
- **Tiered retrieval**: Qdrant vectors for curated content, Kiwix fulltext fallback
- **Model served via persistent process**, not subprocess-per-request
- **Nomic embeddings require prefixes**: `search_document:` for indexing,
  `search_query:` for queries — omitting these degrades retrieval quality
- **Qdrant embedded mode** (in-process) to avoid a separate server
- **Open WebUI** is the primary interface, connecting over OpenAI-compatible API
- **Caddy** as the reverse proxy, fronting all services under one hostname
- **Tailscale** for secure remote access without port forwarding
- **Services are host-agnostic** — each component addresses others by
  configurable URL, so they can run on the same machine or across the network

## Port Map

| Service | Port | Active in profiles |
|---|---|---|
| Falcon3 (bitnet.cpp) | 8080 | cpu, dual, minimal |
| Qwen 3.5 (llama.cpp) | 8082 | gpu, dual |
| Orchestrator | 8081 | all |
| Kiwix | 8888 | all |
| Open WebUI | 3000 | all |
| Caddy | 80/443 | all (if configured) |

## Deployment Options

1. **Docker** (recommended): `make setup && make build && make up` — detects
   hardware, picks profile, builds images, starts everything. Works on any OS
   with Docker. GPU profiles require nvidia-container-toolkit.
2. **Bare metal**: `bash scripts/install.sh` — supports Linux (x86_64, ARM64) and
   macOS (Intel, Apple Silicon). Creates a Python venv, builds bitnet.cpp, installs
   systemd services.

## Known Limitations

- **Qdrant embedded mode file locking**: The orchestrator and ingest containers
  cannot write to the same Qdrant path simultaneously. Run ingestion while the
  orchestrator is stopped, or accept read-only access during ingestion.
- **Blocking HTTP in async handler**: `orchestrator.py` uses synchronous `requests`
  inside async FastAPI handlers. Works fine for single-user, but would need
  `httpx.AsyncClient` for concurrent users.
- **Clang 18+ build requirement**: bitnet.cpp requires clang 18+, which isn't in
  default repos on Ubuntu < 24.04 or Debian stable. The installer handles this
  via the LLVM APT repository.
- **Triage parsing**: The dual-model triage step asks Falcon3 to return JSON.
  If the model produces invalid JSON, the orchestrator falls back to sending
  all chunks to Qwen unfiltered. This is a graceful degradation, not a failure.
- **CUDA architecture pinned to sm_86**: The Qwen Dockerfile targets Ampere GPUs
  (RTX 3000 series). Other generations need `CMAKE_CUDA_ARCHITECTURES` adjusted
  in `docker/Dockerfile.qwen`.
