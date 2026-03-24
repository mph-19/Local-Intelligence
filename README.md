# Local Intelligence

A personal cloud: a self-hosted knowledge system and AI assistant that runs
across one or more machines on your network. Combines offline knowledge bases
(Kiwix), retrieval-augmented generation (Qdrant + nomic embeddings), and local
LLM inference — fronted by a reverse proxy and exposed through Open WebUI.

## Quick Start

```bash
git clone https://github.com/YOUR_USER/local-intelligence.git
cd local-intelligence
make setup          # detects your hardware, picks the right profile
make build          # builds Docker images (15-30 min first time)
make up             # starts all services
```

Open http://localhost:3000 — first login creates an admin account.

New to Docker? See **[docs/DOCKER_BEGINNER.md](docs/DOCKER_BEGINNER.md)**.

## Choose Your Profile

A setup wizard (`make setup`) detects your hardware and recommends a profile.
Pick the one that matches your machine:

| Profile | What runs | You need | Guide |
|---|---|---|---|
| **cpu** | Falcon3 10B on CPU | 12+ GB RAM | [PROFILE_CPU.md](docs/PROFILE_CPU.md) |
| **gpu** | Qwen 3.5 9B on GPU | NVIDIA 8+ GB VRAM | [PROFILE_GPU.md](docs/PROFILE_GPU.md) |
| **dual** | Falcon3 (CPU) + Qwen (GPU) | Both of the above | [PROFILE_DUAL.md](docs/PROFILE_DUAL.md) |
| **minimal** | Falcon3 3B on CPU | 4+ GB RAM | [PROFILE_CPU.md](docs/PROFILE_CPU.md#requirements) |

Each profile guide covers: what services start, architecture, hardware budget,
configuration, performance, and setup steps specific to that profile.

To switch profiles at any time:
```bash
make setup                  # re-run the wizard
make down && make up        # restart with new profile
```

## How It Works

```
You ask a question
        │
        ▼
┌─ Orchestrator (:8081) ────────────────────────────┐
│                                                    │
│  1. Classify the query (code? factual? general?)   │
│  2. Retrieve relevant chunks from Qdrant           │
│  3. Fall back to Kiwix fulltext if needed          │
│  4. [dual only] Falcon3 triages the chunks (CPU)   │
│  5. LLM generates an answer from the context       │
│  6. Attach source citations                        │
│                                                    │
└────────────────────────────────────────────────────┘
        │
        ▼
Answer with sources, displayed in Open WebUI
```

## Components

| Component | What it does | Docs |
|---|---|---|
| **Falcon3 10B** | CPU inference via bitnet.cpp (1.58-bit, 32K context) | [BITNET_SERVER.md](docs/BITNET_SERVER.md) |
| **Qwen 3.5 9B** | GPU inference via llama.cpp + CUDA (Q4_K_M) | [PROFILE_GPU.md](docs/PROFILE_GPU.md) |
| **Orchestrator** | RAG proxy, query routing, dual-model pipeline | [ORCHESTRATOR.md](docs/ORCHESTRATOR.md) |
| **RAG pipeline** | Nomic embeddings + Qdrant vector search | [RAG_PIPELINE.md](docs/RAG_PIPELINE.md) |
| **Kiwix** | Offline Wikipedia, Stack Overflow, Stack Exchange | [KIWIX_SETUP.md](docs/KIWIX_SETUP.md) |
| **Open WebUI** | ChatGPT-like web interface | [WEB_ACCESS.md](docs/WEB_ACCESS.md) |
| **Caddy** | Reverse proxy with auto-TLS | [MULTI_HOST.md](docs/MULTI_HOST.md) |

## Common Commands

```bash
make setup          # configure hardware profile
make build          # build/rebuild Docker images
make up             # start all services
make down           # stop all services
make health         # check service status
make logs           # stream live logs (Ctrl+C to stop)
make chat Q="..."   # quick test from the command line
make ingest-docs    # index your documents into Qdrant
make status         # show running containers and active profile
```

## All Guides

| Guide | What it covers |
|---|---|
| [DOCKER_BEGINNER.md](docs/DOCKER_BEGINNER.md) | Docker concepts, setup, commands, troubleshooting |
| [PROFILE_CPU.md](docs/PROFILE_CPU.md) | CPU profile: Falcon3 10B / 3B, no GPU needed |
| [PROFILE_GPU.md](docs/PROFILE_GPU.md) | GPU profile: Qwen 3.5 9B, NVIDIA CUDA |
| [PROFILE_DUAL.md](docs/PROFILE_DUAL.md) | Dual profile: Falcon3 triage + Qwen synthesis |
| [BITNET_SERVER.md](docs/BITNET_SERVER.md) | Falcon3 server setup, performance, systemd |
| [KIWIX_SETUP.md](docs/KIWIX_SETUP.md) | Kiwix installation, ZIM downloads |
| [RAG_PIPELINE.md](docs/RAG_PIPELINE.md) | Embedding model, Qdrant, ingestion |
| [ORCHESTRATOR.md](docs/ORCHESTRATOR.md) | Query routing, pipeline modes, env vars |
| [WEB_ACCESS.md](docs/WEB_ACCESS.md) | Open WebUI, Tailscale remote access |
| [MULTI_HOST.md](docs/MULTI_HOST.md) | Reverse proxy, multi-machine deployment |
| [LORA_FINETUNE.md](docs/LORA_FINETUNE.md) | LoRA fine-tuning (optional, needs GPU) |
| [config/drive_layout.md](config/drive_layout.md) | 1TB drive partitioning plan |

## Bare Metal Install

If you prefer running without Docker:

```bash
bash scripts/install.sh
```

Handles system deps, Python venv, bitnet.cpp build, model download, directory
structure, and systemd services. Works on Linux (x86_64, ARM64) and macOS
(Intel, Apple Silicon). See `--help` for options.

## Status

- [ ] 1TB drive partitioned and mounted at `/knowledge`
- [ ] Dependencies installed
- [ ] Kiwix serving with ZIM files
- [ ] LLM(s) serving and healthy
- [ ] RAG pipeline: documents indexed
- [ ] Orchestrator wiring all components
- [ ] Open WebUI accessible
- [ ] Caddy reverse proxy configured
- [ ] Tailscale remote access
- [ ] Kiwix content selectively indexed into Qdrant
