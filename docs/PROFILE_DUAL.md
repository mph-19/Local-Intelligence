# Profile: Dual

Two models working together: Falcon3 10B on CPU for fast triage, Qwen 3.5 9B
on GPU for high-quality synthesis. This is the best configuration if you have
both CPU headroom and an NVIDIA GPU.

## Requirements

| Resource | Minimum |
|---|---|
| CPU | 4+ cores with AVX2 or NEON |
| RAM | 16+ GB (Falcon3 + Qdrant + services) |
| GPU | NVIDIA with 8+ GB VRAM |
| Storage | 20+ GB (both models + CUDA image) |
| Software | Docker + [nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/) |

## What Runs

```
┌──────────────────────────────────────────────────┐
│                Services started                   │
├──────────────┬───────┬───────────────────────────┤
│  Falcon3 10B │ :8080 │ Triage LLM (CPU)          │
│  Qwen 3.5 9B│ :8082 │ Synthesis LLM (GPU/CUDA)  │
│  Orchestrator│ :8081 │ RAG proxy (dual mode)     │
│  Kiwix       │ :8888 │ Offline knowledge bases   │
│  Open WebUI  │ :3000 │ Chat interface            │
└──────────────┴───────┴───────────────────────────┘
```

Both LLMs run simultaneously on different hardware — no resource contention.

## How the Pipeline Works

```
User query
    │
    ▼
Orchestrator (:8081)
    ├── Classify intent
    ├── Retrieve from Qdrant (returns N candidate chunks)
    ├── Kiwix fulltext fallback (if vector scores weak)
    │
    ├── STAGE 1: Triage ──────────────────────────────────
    │   │
    │   └── Send chunks + query to Falcon3 (:8080, CPU)
    │       │  "Score each chunk's relevance. Return JSON."
    │       │  Fast: ~1-3 seconds, temperature=0.1
    │       │
    │       ▼
    │       Parse JSON → keep only relevant chunks
    │       Confidence check → bail if nothing relevant
    │
    ├── STAGE 2: Synthesis ───────────────────────────────
    │   │
    │   └── Send filtered chunks + query to Qwen (:8082, GPU)
    │       │  "Reason over this context and answer the question."
    │       │  Quality: full temperature, longer generation
    │       │
    │       ▼
    │       Final answer
    │
    └── Append source citations → return response
```

### Why Two Stages?

**Filtering is easier than generation.** A weaker model can reliably say "this
chunk isn't relevant" even if it can't synthesize a good answer. By filtering
first, Qwen receives a smaller, cleaner context — which means:

- **Faster synthesis** — Qwen reads 4 curated chunks instead of 20 raw ones
- **Better answers** — less noise for the model to sort through
- **Cheaper confidence gating** — Falcon3 can flag "nothing relevant" before
  Qwen spends time generating a hallucinated answer

### Fallback Behavior

The pipeline degrades gracefully:

| Situation | What happens |
|---|---|
| Falcon3 returns invalid JSON | All chunks pass through unfiltered to Qwen |
| Falcon3 is slow or times out | Triage is skipped, all chunks go to Qwen |
| Triage confidence < 0.1 | "I don't have enough information" response |
| Qwen is unavailable | Error message returned to user |

## Architecture Diagram

```
     ┌───────────────────────────────────────────────────┐
     │                  Orchestrator :8081                │
     │                                                   │
     │   Query → Retrieve → Triage → Synthesize → Reply  │
     └──────┬──────────┬───────────┬────────────┬────────┘
            │          │           │            │
     ┌──────▼───┐ ┌────▼───┐ ┌────▼─────┐ ┌────▼──────┐
     │  Kiwix   │ │ Qdrant │ │ Falcon3  │ │ Qwen 3.5  │
     │  :8888   │ │ 768-d  │ │ 10B CPU  │ │ 9B GPU    │
     │ fallback │ │ vectors│ │ triage   │ │ synthesis │
     │          │ │        │ │ :8080    │ │ :8082     │
     └──────────┘ └────────┘ └──────────┘ └───────────┘
```

## Hardware Utilization

Both models run on separate hardware simultaneously:

```
┌──────────────────┐     ┌──────────────────┐
│      CPU          │     │      GPU          │
│                   │     │                   │
│  Falcon3 1.58-bit│     │  Qwen 3.5 Q4_K_M │
│  (~2.5 GB RAM)   │     │  (~5.5 GB VRAM)   │
│                   │     │                   │
│  Qdrant           │     │                   │
│  Kiwix            │     │                   │
│  Orchestrator     │     │                   │
│  Nomic embeddings │     │                   │
└──────────────────┘     └──────────────────┘
```

Typical memory usage on a 32 GB RAM / 10 GB VRAM system:

| Component | Where | Usage |
|---|---|---|
| Falcon3 10B (weights + KV cache) | RAM | ~5 GB |
| Qwen 3.5 9B (weights + KV cache) | VRAM | ~6.5 GB |
| Qdrant + Nomic embeddings | RAM | ~1.5 GB |
| Kiwix + OS + services | RAM | ~3 GB |
| **Total** | | **~10 GB RAM + ~6.5 GB VRAM** |

Plenty of headroom on both sides.

## Setup

### Docker

```bash
make setup              # select "dual" when prompted
make build              # builds both LLM images (~20-40 min first time)
make up                 # start all 5 services
make health             # verify [OK] for all services including both LLMs
```

Or force the profile:
```bash
bash scripts/configure.sh --profile dual
```

### Prerequisites

Same as the GPU profile — nvidia-container-toolkit must be installed.
See [PROFILE_GPU.md](PROFILE_GPU.md#prerequisites) for installation steps.

## Configuration

These are the key `.env` settings for this profile (set automatically by
`make setup`):

```bash
COMPOSE_PROFILES=dual
PIPELINE_MODE=dual
TRIAGE_LLM_URL=http://falcon3:8080/v1/chat/completions
SYNTH_LLM_URL=http://qwen:8082/v1/chat/completions
FALCON_CTX_SIZE=16384         # triage needs less context than full generation
FALCON_MEM_LIMIT=8g
QWEN_CTX_SIZE=8192
QWEN_GPU_LAYERS=99
```

Note: `FALCON_CTX_SIZE` is set to 16K (not 32K) in dual mode because the
triage prompt is much shorter than a full RAG-augmented generation prompt.
This saves ~2 GB of RAM.

## Estimated Latency

For a typical RAG query (retrieve 20 chunks, triage down to 4, synthesize):

| Stage | Time |
|---|---|
| Qdrant retrieval | ~100-200 ms |
| Falcon3 triage (score 20 chunks) | ~2-4 s |
| Qwen synthesis (~2K prompt, ~500 tok answer) | ~1-6 s |
| **Total** | **~3-10 s** |

Compare to CPU-only (single Falcon3): 20-45 seconds for the same query.

## When to Use This Profile

- You have both a capable CPU (8+ cores) and an NVIDIA GPU (8+ GB VRAM)
- You want the best answer quality
- You're willing to use more resources for better results
- Your use case involves complex queries over retrieved documents

## Downgrading

If you want to simplify or free up GPU resources:

```bash
make setup      # re-run wizard, select "cpu" or "gpu"
make down && make up
```

No rebuild needed — the existing images are reused. Only the active services
change.
