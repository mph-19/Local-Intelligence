# 1TB Drive Layout Plan

## Partition Scheme

Single ext4 partition, mounted at `/knowledge`.

```
/dev/sdX1   1TB   ext4   /knowledge
```

### fstab entry
```bash
UUID=<uuid>  /knowledge  ext4  defaults,noatime  0  2
```

`noatime` avoids unnecessary write I/O on every ZIM file read. The 32GB of
system RAM means no swap partition is needed on this drive.

## Directory Structure

```
/knowledge/
├── zim/                           # Kiwix ZIM files
│   ├── wikipedia_en_all_maxi.zim      (~97 GB)
│   ├── stackoverflow.com_en_all.zim   (~55 GB)
│   ├── stackexchange_unix.zim         (~5 GB)
│   ├── stackexchange_superuser.zim    (~3 GB)
│   ├── stackexchange_serverfault.zim  (~3 GB)
│   └── stackexchange_ai.zim           (~1 GB)
│   Subtotal: ~164 GB
│
├── vectors/                       # Qdrant persistent storage
│   └── qdrant/                    # Embedded mode data dir
│   Subtotal: ~20–40 GB (see estimates below)
│
├── models/
│   └── nomic-embed-text-v1.5/    # Embedding model (~270 MB)
│   Subtotal: ~0.3 GB (Falcon3 GGUF lives inside services/bitnet-cpp/models/)
│
├── lora/                          # LoRA adapter checkpoints
│   └── checkpoints/
│   Subtotal: ~5–20 GB
│
├── docs/                          # Raw document sources for RAG
│   └── custom/                    # Your own documents
│   Subtotal: varies
│
├── services/                      # Server scripts + runtime
│   ├── orchestrator.py
│   ├── rag.py
│   └── bitnet-cpp/                # bitnet.cpp build + model
│
├── kiwix-library.xml              # Kiwix library manifest
└── logs/
```

## Vector Storage Estimates

Qdrant stores vectors + payload (the chunk text for retrieval). Per chunk:
- 768 floats x 4 bytes = **3,072 bytes** for the vector
- ~1,600 bytes average payload (chunk text + metadata)
- **~5 KB per chunk** total

| Collection | Est. Articles | Est. Chunks | Est. Storage |
|---|---|---|---|
| `custom_docs` | varies | varies | varies |
| `unix_se` | ~400K | ~2M | ~10 GB |
| `stackoverflow` | ~24M | ~100M+ | ~500 GB+ |
| `wikipedia` | ~6.8M | ~60M+ | ~300 GB+ |

**Full Wikipedia + SO vectorization would exceed the drive.** Practical strategy:
- Start with your own documents and `unix_se` (~10 GB)
- Selectively index SO tags you care about, not the full dump
- For Wikipedia, rely on Kiwix full-text search and only embed a curated subset
- Use Kiwix as the "broad search" fallback, RAG as the "precise retrieval"

## Space Budget (Realistic)

| Component | Size | Notes |
|---|---|---|
| ZIM files | ~164 GB | Initial set, expandable |
| Qdrant vectors | ~15 GB | Custom docs + unix_se + selective SO |
| Models + bitnet-cpp | ~3 GB | Falcon3 10B GGUF + nomic + bitnet.cpp build |
| LoRA adapters | ~10 GB | Multiple adapter versions |
| Documents | ~2 GB | Source corpus |
| Open WebUI + Docker | ~5 GB | Container images |
| **Used** | **~197 GB** | |
| **Free** | **~803 GB** | Room for more ZIMs, vectors, experiments |

## Setup Commands

```bash
# Identify the drive
lsblk

# Format (replace sdX with actual device — DESTRUCTIVE)
sudo mkfs.ext4 -L knowledge /dev/sdX1

# Mount
sudo mkdir -p /knowledge
sudo mount /dev/sdX1 /knowledge
sudo chown $(whoami):$(whoami) /knowledge

# Create structure
mkdir -p /knowledge/{zim,vectors/qdrant,models,lora,docs/custom,services,logs}

# Persist mount — get UUID first
blkid /dev/sdX1
# Then add to /etc/fstab:
# UUID=<uuid>  /knowledge  ext4  defaults,noatime  0  2

# Verify
df -h /knowledge
```
