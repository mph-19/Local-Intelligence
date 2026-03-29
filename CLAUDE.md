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
- **Pre-built GGUF download**: The Falcon3 Dockerfile downloads a pre-converted
  GGUF from `tiiuae/Falcon3-10B-Instruct-1.58bit-GGUF` instead of running the
  slow `prepare_model()` conversion (~30+ min). `setup_env.py` is patched to
  skip `prepare_model()` while preserving kernel codegen and compilation.
- **Qwen 3.5 9B** (Q4_K_M GGUF, ~5.5 GB VRAM) for GPU inference via llama.cpp
- **Dual-model pipeline**: Falcon3 triages (fast, CPU), Qwen synthesizes (quality, GPU)
  — controlled by `PIPELINE_MODE=dual` in `.env`
- **32K context window** on Falcon3 with automatic context shifting
- **8K context window** on Qwen (configurable, limited by 10 GB VRAM)
- Designed for portability — runs on any machine with AVX2/NEON and 4+ GB RAM
- **Weighted query classification**: `classify_query()` uses three-tier weighted
  keyword scoring (ambiguous 0.5, strong 1.0, phrases 2.0, disambiguation
  compounds 3.0) with a confidence threshold of 2.0. Returns a list of collection
  names; ambiguous queries merge collections for broad retrieval.
- **Lazy-loaded RAG module**: `rag.py` defers SentenceTransformer (~270 MB) and
  QdrantClient initialization to first use via `_LazyProxy`. Import is free;
  scripts that only need `chunk_text()` or `deterministic_id()` never load models.
- **Sentence-aware chunking**: `chunk_text()` scans backward from chunk boundaries
  for sentence-ending punctuation, snapping to sentence breaks when possible.
  Falls back to word-count splitting for code/lists. Same CHUNK_SIZE/OVERLAP.
- **UUID5 chunk IDs**: `deterministic_id()` uses `uuid.uuid5()` with a project-
  specific namespace UUID. RFC 4122-compliant, SHA-1 based. No collision risk.
- **Prompt injection defense**: Retrieved context is wrapped in `<context>` delimiter
  tags with explicit data-only instructions before and after the block.
- **Structured observability**: Every decision point in `chat()` logs with `[tag]`
  prefixes — classification scores, RAG timing, chunk scores, triage filtering,
  LLM timing, and end-to-end summary. Viewable via `docker compose logs`.
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
- **Service startup ordering**: Orchestrator uses `depends_on` with
  `required: false` on all LLM services and Kiwix. Only services active in
  the current profile are waited on; inactive services are skipped. Requires
  Docker Compose v2.20+.
- **LLM error handling**: `call_llm()` uses tuple timeouts `(connect, read)`
  to fail fast on unreachable services (5s connect) while tolerating slow
  inference (90s read). Retries once on connection errors and 5xx responses.
  Errors return HTTP 502 with an OpenAI-compatible error body.
- **Container memory limits**: Every service has a `deploy.resources.limits.memory`
  cap — falcon3 12g, falcon3-mini 4g, orchestrator 2g, open-webui 1g,
  kiwix 512m, ingest 2g. Prevents a leak from OOM-killing unrelated services.
- **Non-root containers**: All custom Dockerfiles run as non-root via
  `USER 1000`. User/group creation is conditional (`getent`/`id` checks
  before `groupadd`/`useradd`) so builds succeed even when the base image
  already has UID/GID 1000. All `chown`, `--chown`, and `USER` directives
  use numeric IDs (not names) for the same reason. Binaries and model files
  are root-owned and read-only to the runtime user. Files on bind-mounted
  volumes are owned by UID 1000 (matching the typical host user), avoiding
  permission conflicts.
- **Localhost-only port binding**: All Docker port mappings use
  `${BIND_ADDR:-127.0.0.1}` so services are only reachable from the host by
  default. Set `BIND_ADDR=0.0.0.0` in `.env` for LAN/multi-host access.
- **Embedding model revision pinning**: The nomic-embed-text-v1.5 model
  requires `trust_remote_code=True` (custom attention implementation). The
  revision is pinned to an audited commit hash in both `rag.py` and
  `Dockerfile.orchestrator` so a compromised HuggingFace repo cannot inject
  code. Update the hash deliberately after auditing new versions.
- **Streaming ingestion**: `ingest_docs.py` reads files larger than 1 MB in
  slices with word-level overlap, so arbitrarily large documents are fully
  indexed without spiking container memory.
- **Kiwix ingestion limits**: `ingest_kiwix.py` caps pagination at 500 pages
  (12,500 results) and stops after 5,000 new articles per run. Both clamped
  at the function boundary to prevent runaway requests.
- **Image digest pinning**: Pre-built Docker images (Open WebUI, Kiwix) are
  pinned with `tag@sha256:digest` for immutable builds. Tags retained for
  readability.
- **Profile-aware builds**: `make build` reads `COMPOSE_PROFILES` from `.env`
  and only builds services needed for the active profile. Saves 5-10 min and
  ~3 GB disk when GPU/minimal services aren't used.
- **Port availability checking**: `make setup` auto-detects busy ports and
  reassigns to the next free one. `make check-ports` verifies before startup.
- **Health polling**: `make wait-healthy` replaces fixed `sleep` with polling —
  succeeds immediately when all services respond, times out with per-service
  status after `WAIT_TIMEOUT` (default 120s).
- **Dynamic model paths**: `install.sh` derives all model paths from `MODEL_REPO`
  and `MODEL_QUANT` variables. The systemd unit, download instructions, and
  verification all adapt to whichever model was installed (10B, 3B, etc.).
- **Disk space pre-check**: `install.sh` verifies available space before the
  bitnet.cpp build (4 GB with model, 2 GB without `--no-model`).
- **MIG-compatible NVIDIA detection**: `configure.sh` queries GPU by index
  (`nvidia-smi -i 0`) which works in both MIG and non-MIG modes.
- **Request size limits**: `ChatRequest` uses Pydantic `Field()` constraints —
  `max_tokens` capped at 4096, `messages` limited to 50, individual message
  content limited to 32,000 characters, `temperature` bounded to 0.0–2.0.
  FastAPI returns HTTP 422 automatically for violations.
- **Safe JSON in Makefile**: `make chat` uses `jq --arg` to construct the JSON
  payload, preventing both shell injection and JSON injection from the `Q`
  variable. The payload is piped to `curl -d @-` via stdin.
- **CORS middleware**: The orchestrator restricts cross-origin requests via
  `CORSMiddleware`. Allowed origins default to `http://localhost:3000`
  (Open WebUI) and are configurable via `CORS_ORIGINS` env var for
  multi-host deployments.
- **Download-then-execute**: Install scripts (`install.sh`, `setup.sh`) download
  remote scripts to a tempfile before executing, instead of piping directly to
  shell. Prevents execution of truncated downloads on network failure.
- **Qwen model path via ENV**: The Qwen Dockerfile propagates the model filename
  from build arg to runtime via `ARG MODEL_FILE` → `ENV MODEL_PATH`, eliminating
  the `$(cat /model_path.txt)` command substitution in the ENTRYPOINT.
- **Signup disabled by default**: Open WebUI's `ENABLE_SIGNUP` defaults to `false`
  in docker-compose.yml. The first user to register becomes admin; no further
  signups are allowed unless `ENABLE_SIGNUP=true` is set in `.env`.
- **Strict shell mode**: Both `install.sh` and `setup.sh` use `set -euo pipefail`
  — exits on error, treats unset variables as errors, and catches pipe failures.
- **Security headers**: The orchestrator sets `X-Content-Type-Options: nosniff`,
  `X-Frame-Options: DENY`, `Cache-Control: no-store`, and a strict
  `Content-Security-Policy` on all responses via `SecurityHeadersMiddleware`.
- **Exact dependency pinning**: `requirements.orchestrator.txt` uses `==` pins
  (not `~=`) for all 11 dependencies. Builds are deterministic — update versions
  deliberately by editing the file and rebuilding.
- **Read-only LLM containers**: All three LLM services (falcon3, falcon3-mini,
  qwen) run with `read_only: true` and `tmpfs: /tmp`. The container filesystem
  is immutable at runtime; `/tmp` provides ephemeral scratch space in RAM only.

## Port Map

All ports bind to `127.0.0.1` (localhost) by default. Set `BIND_ADDR=0.0.0.0`
in `.env` for LAN/multi-host access.

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
   hardware, picks profile, builds images, starts everything. Requires Docker
   Compose v2.20+ (for `depends_on: required: false`). GPU profiles require
   nvidia-container-toolkit.
2. **Bare metal**: `bash scripts/install.sh` — supports Linux (x86_64, ARM64) and
   macOS (Intel, Apple Silicon). Creates a Python venv, builds bitnet.cpp, installs
   systemd services.

## Known Limitations

- **Qdrant embedded mode file locking**: The orchestrator and ingest containers
  cannot write to the same Qdrant path simultaneously. Run ingestion while the
  orchestrator is stopped, or accept read-only access during ingestion.
- **Async HTTP via httpx**: `orchestrator.py` uses `httpx.AsyncClient` for all
  LLM calls, so concurrent requests don't block the FastAPI event loop. A shared
  client instance is reused across requests for connection pooling.
- **Clang 18+ build requirement**: bitnet.cpp requires clang 18+, which isn't in
  default repos on Ubuntu < 24.04 or Debian stable. The installer handles this
  via the LLVM APT repository.
- **Triage parsing**: The dual-model triage step asks Falcon3 to return JSON.
  If the model produces invalid JSON, the orchestrator falls back to sending
  all chunks to Qwen unfiltered (graceful degradation). If the model returns
  valid JSON with `"keep": []` (explicitly rejecting all chunks), that decision
  is respected — the orchestrator returns an "I don't have enough information"
  response instead of hallucinating.
- **CUDA architecture pinned to sm_86**: The Qwen Dockerfile targets Ampere GPUs
  (RTX 3000 series). Other generations need `CMAKE_CUDA_ARCHITECTURES` adjusted
  in `docker/Dockerfile.qwen`.
- **Docker Compose v2.20+ required**: The `depends_on: required: false` syntax
  used for profile-aware service ordering requires Compose v2.20 or later.
  Check with `docker compose version`.
- **BitNet `setup_env.py` patching**: The Dockerfile and installer use `sed` to
  patch `prepare_model()` out of `setup_env.py`. If Microsoft restructures
  this function in a future commit, the patch will fail and the build will
  exit with a clear error. Fix by updating `BITNET_COMMIT` to a tested hash.
- **`jq` required for `make chat`**: The `make chat` target uses `jq` to safely
  construct JSON payloads. `jq` is pre-installed on most Linux distros and macOS
  (via Homebrew). If missing: `apt install jq` / `pacman -S jq` / `brew install jq`.
