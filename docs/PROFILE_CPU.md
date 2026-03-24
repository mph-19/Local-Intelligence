# Profile: CPU

Falcon3 10B running entirely on CPU. No GPU required.

This is the default profile and works on any machine with a modern x86 (AVX2)
or ARM (NEON) processor and enough RAM. The `minimal` variant uses Falcon3 3B
for machines with less than 8 GB RAM.

## Requirements

| | cpu profile | minimal profile |
|---|---|---|
| CPU | 4+ cores with AVX2 or NEON | Same |
| RAM | 12+ GB | 4+ GB |
| GPU | None | None |
| Storage | 10+ GB (model + images) | 8+ GB |

## What Runs

```
┌──────────────────────────────────────────────────┐
│                Services started                   │
├──────────────┬───────┬───────────────────────────┤
│  Falcon3 10B │ :8080 │ LLM inference (CPU)       │
│  Orchestrator│ :8081 │ RAG proxy (single mode)   │
│  Kiwix       │ :8888 │ Offline knowledge bases   │
│  Open WebUI  │ :3000 │ Chat interface            │
└──────────────┴───────┴───────────────────────────┘
```

In `minimal` profile, Falcon3 3B replaces 10B with a smaller context window
(8K vs 32K) and lower memory usage (~2 GB vs ~7 GB).

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
    └── Forward to Falcon3 (:8080)
            │
            ▼
        Response + source citations
```

One LLM handles everything. The orchestrator runs in `single` pipeline mode.

## Setup

### Docker (recommended)

```bash
make setup              # select "cpu" or "minimal" when prompted
make build              # builds Falcon3 image (~15-30 min first time)
make up                 # start all services
make health             # verify [OK] for all 4 services
```

Or force the profile directly:
```bash
bash scripts/configure.sh --profile cpu
# or for low-RAM machines:
bash scripts/configure.sh --profile minimal
```

### Bare metal

```bash
bash scripts/install.sh     # builds bitnet.cpp, downloads Falcon3 10B
```

For minimal (Falcon3 3B), use the build arg or download the 3B model:
```bash
# Docker:
docker compose build --build-arg MODEL_REPO=tiiuae/Falcon3-3B-Instruct-1.58bit falcon3

# Bare metal:
cd /knowledge/services/bitnet-cpp
python setup_env.py --hf-repo tiiuae/Falcon3-3B-Instruct-1.58bit -q i2_s
```

## Configuration

These are the key `.env` settings for this profile (set automatically by
`make setup`):

```bash
COMPOSE_PROFILES=cpu          # or "minimal"
PIPELINE_MODE=single
LLM_URL=http://falcon3:8080/v1/chat/completions
FALCON_CTX_SIZE=32768         # 8192 for minimal
FALCON_MEM_LIMIT=12g          # 4g for minimal
```

## Performance

Speed depends on core count and instruction set. bitnet.cpp replaces float
multiplication with additions using ternary weights, making CPU inference
much faster than standard quantized models.

| CPU | Cores/Threads | ISA | Est. tok/s |
|---|---|---|---|
| i9-10900K | 10c/20t | AVX2 | 8-18 |
| i5-1035G4 (Surface) | 4c/8t | AVX-512 | 6-14 |
| Ryzen 5600X | 6c/12t | AVX2 | 6-14 |
| Apple M2 | 8c | NEON | 12-25 |

8-18 tok/s is roughly 1-2 sentences per second — responsive enough for a
personal assistant.

| Resource | cpu profile | minimal profile |
|---|---|---|
| RAM (model) | ~2 GB | ~0.7 GB |
| RAM (KV cache, max context) | ~5 GB (32K) | ~1.3 GB (8K) |
| RAM total | ~7-8 GB | ~2-3 GB |

## When to Use This Profile

- You don't have an NVIDIA GPU
- You want the simplest setup with the fewest dependencies
- You're running on a laptop, NUC, or ARM device
- You want to distribute the LLM to a different host than the GPU machine

## Upgrading to Dual

If you later add a GPU to your system, you can switch to the `dual` profile
to use Falcon3 as a fast triage filter alongside Qwen 3.5:

```bash
make setup      # re-run wizard, it will detect the GPU and recommend "dual"
make build      # builds the new Qwen image
make down && make up
```

See [PROFILE_DUAL.md](PROFILE_DUAL.md) for details.
