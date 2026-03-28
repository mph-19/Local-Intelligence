# RAG Pipeline Setup

Retrieval-Augmented Generation pipeline that indexes Kiwix content and custom
documents into Qdrant, then retrieves relevant context at query time to ground
LLM responses in real sources.

## Architecture

```
Indexing (offline):                    Querying (real-time):

  Kiwix HTML article                     User query
        |                                     |
        v                                     v
  Strip HTML -> plain text             Embed with prefix
        |                              "search_query: ..."
        v                                     |
  Chunk (400 words, 50 overlap)               v
        |                              Qdrant nearest-neighbor
        v                                     |
  Embed with prefix                           v
  "search_document: ..."               Top-K chunks + metadata
        |                                     |
        v                                     v
  Upsert to Qdrant                     Inject into LLM prompt
```

## Dependencies

```bash
pip install qdrant-client sentence-transformers requests beautifulsoup4 tqdm
```

## Shared Module: `services/rag.py`

All ingestion and query scripts import from this shared module. Place it at
`/knowledge/services/rag.py` so all scripts can use it.

Key design features:
- **Lazy-loaded**: Importing `rag.py` is free (~0 cost). The SentenceTransformer
  model (~270 MB) and QdrantClient are only loaded on first use via `_LazyProxy`.
  Scripts that only need `chunk_text()` or `deterministic_id()` never load models.
- **Sentence-aware chunking**: `chunk_text()` scans backward from chunk boundaries
  for sentence-ending punctuation (`.!?` and quoted variants), snapping to natural
  breaks. Falls back to word-count splitting for code/lists.
- **UUID5 chunk IDs**: `deterministic_id()` uses `uuid.uuid5()` with a project-
  specific namespace UUID for RFC 4122-compliant, collision-free IDs.
- **Nomic prefix convention**: `search_document:` for indexing, `search_query:`
  for retrieval — required by nomic-embed-text-v1.5 for optimal quality.

See `services/rag.py` for the full implementation. The module exports:

| Function | Purpose |
|---|---|
| `embed_document(text)` | Embed a single chunk for indexing |
| `embed_query(text)` | Embed a user query for retrieval |
| `embed_documents_batch(texts)` | Batch-embed chunks (50-100/sec CPU) |
| `ensure_collection(name)` | Create Qdrant collection if missing |
| `chunk_text(text)` | Sentence-aware splitting (400 words, 50 overlap) |
| `deterministic_id(source, i)` | Stable UUID5 for upsert-not-duplicate |
| `retrieve(query, collection)` | Top-K vector search with metadata |
| `embedder` | Lazy-loaded SentenceTransformer instance |
| `client` | Lazy-loaded QdrantClient instance |

## Ingestion Scripts

### Ingest local documents

`scripts/ingest_docs.py` — indexes plain text/Markdown files from a directory.

Features:
- Scans for `**/*.md` and `**/*.txt` files recursively
- Groups files into batches of 50 for cross-file embedding efficiency
- Prefetches the next group while the current one embeds
- **Streams large files** (> 1 MB) in slices with word-level overlap to avoid
  memory spikes — arbitrarily large documents are fully indexed
- Deterministic UUIDs so re-indexing overwrites, not duplicates
- Upserts in batches of 500 points to Qdrant

```bash
# Via Docker (recommended)
make ingest-docs

# Standalone
python scripts/ingest_docs.py /path/to/docs collection_name
```

See `scripts/ingest_docs.py` for the full implementation.

### Ingest Kiwix articles

`scripts/ingest_kiwix.py` — fetches articles from kiwix-serve, strips HTML,
chunks, and indexes.

Features:
- Searches Kiwix's fulltext search API, paginates through results
- Strips HTML boilerplate (nav, header, footer, script, style tags)
- Skips articles under 100 characters
- Tracks ingested articles in `/knowledge/vectors/kiwix_sync.json` — re-runs
  skip already-indexed articles
- **Safety limits**: max 500 pages (12,500 search results) and 5,000 new articles
  per run, preventing runaway requests against large ZIM files

```bash
# Via Docker (recommended)
docker compose run --rm ingest python scripts/ingest_kiwix.py wikipedia "python programming" wikipedia

# Standalone
python scripts/ingest_kiwix.py <book> <query> <collection>
```

See `scripts/ingest_kiwix.py` for the full implementation.

## Incremental Sync

The Kiwix ingestion script tracks which articles have been ingested in
`/knowledge/vectors/kiwix_sync.json`. Re-running the script skips already-
indexed articles. To force re-indexing, delete the entry from the JSON file
or delete the whole file to start fresh.

For local documents, the deterministic UUID means re-running the indexer
overwrites existing chunks with updated content rather than creating
duplicates.

## Performance on i9-10900K

| Operation | Speed | Notes |
|---|---|---|
| Embedding (CPU, batched) | ~50-100 chunks/sec | 10 cores, nomic v1.5 |
| Embedding (RTX 3080) | ~500+ chunks/sec | If GPU is free |
| Qdrant upsert | ~5,000 points/sec | Embedded mode, SSD |
| Custom docs (~1K files) | ~5 minutes total | Good first validation set |
| Unix SE (~400K articles) | ~2-4 hours | Good second test |

Start with your own documents to validate end-to-end, then expand to Kiwix.
