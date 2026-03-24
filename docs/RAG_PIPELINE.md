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

```python
#!/usr/bin/env python3
"""Shared RAG utilities: embedding, Qdrant client, chunking, retrieval."""

import hashlib, uuid
from sentence_transformers import SentenceTransformer
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, VectorParams, PointStruct

# --- Config ---
QDRANT_PATH = "/knowledge/vectors/qdrant"
CHUNK_SIZE = 400       # words
CHUNK_OVERLAP = 50     # words

# --- Init (runs once at import time) ---
embedder = SentenceTransformer(
    "nomic-ai/nomic-embed-text-v1.5",
    trust_remote_code=True,
)
client = QdrantClient(path=QDRANT_PATH)

# --- Embedding ---
def embed_document(text: str) -> list[float]:
    """Embed a text chunk for indexing. Uses search_document: prefix."""
    return embedder.encode(
        f"search_document: {text}",
        normalize_embeddings=True,
    ).tolist()

def embed_query(text: str) -> list[float]:
    """Embed a user query for retrieval. Uses search_query: prefix."""
    return embedder.encode(
        f"search_query: {text}",
        normalize_embeddings=True,
    ).tolist()

def embed_documents_batch(texts: list[str], batch_size: int = 64) -> list:
    """Embed a batch of document chunks."""
    prefixed = [f"search_document: {t}" for t in texts]
    return embedder.encode(
        prefixed,
        normalize_embeddings=True,
        batch_size=batch_size,
        show_progress_bar=True,
    ).tolist()

# --- Qdrant ---
def ensure_collection(name: str):
    existing = [c.name for c in client.get_collections().collections]
    if name not in existing:
        client.create_collection(
            collection_name=name,
            vectors_config=VectorParams(size=768, distance=Distance.COSINE),
        )
        print(f"Created collection: {name}")

# --- Chunking ---
def chunk_text(text: str) -> list[str]:
    words = text.split()
    chunks = []
    step = CHUNK_SIZE - CHUNK_OVERLAP
    for i in range(0, len(words), step):
        chunk = " ".join(words[i:i + CHUNK_SIZE])
        if len(chunk.split()) > 20:
            chunks.append(chunk)
    return chunks

def deterministic_id(source: str, chunk_index: int) -> str:
    """Stable UUID from source + index so re-indexing overwrites, not duplicates."""
    digest = hashlib.md5(f"{source}:{chunk_index}".encode()).hexdigest()
    return str(uuid.UUID(digest))

# --- Retrieval ---
def retrieve(query: str, collection: str, top_k: int = 5) -> list[dict]:
    """Retrieve the most relevant chunks for a query."""
    vec = embed_query(query)
    results = client.search(
        collection_name=collection,
        query_vector=vec,
        limit=top_k,
    )
    return [
        {
            "text": r.payload["text"],
            "source": r.payload.get("title", r.payload.get("file", "unknown")),
            "url": r.payload.get("url", ""),
            "score": r.score,
        }
        for r in results
    ]
```

## Ingestion Scripts

### Ingest local documents

`scripts/ingest_docs.py` — indexes plain text/Markdown files from a directory.

```python
#!/usr/bin/env python3
"""Index a directory of text/Markdown files into Qdrant."""

import sys
from pathlib import Path

# Add services dir to path so we can import rag module
sys.path.insert(0, "/knowledge/services")
from rag import (
    client, ensure_collection, chunk_text,
    embed_documents_batch, deterministic_id, PointStruct,
)

def ingest_directory(directory: str, collection: str):
    ensure_collection(collection)
    all_points = []

    paths = sorted(Path(directory).glob("**/*.md"))
    if not paths:
        # Also try .txt files
        paths = sorted(Path(directory).glob("**/*.txt"))
    print(f"Found {len(paths)} files in {directory}")

    for path in paths:
        text = path.read_text(errors="replace")
        chunks = chunk_text(text)
        if not chunks:
            continue
        vectors = embed_documents_batch(chunks)

        for i, (chunk, vec) in enumerate(zip(chunks, vectors)):
            all_points.append(PointStruct(
                id=deterministic_id(str(path), i),
                vector=vec,
                payload={
                    "source": "local",
                    "file": str(path.relative_to(directory)),
                    "chunk_index": i,
                    "text": chunk,
                }
            ))

        if len(all_points) >= 500:
            client.upsert(collection_name=collection, points=all_points)
            all_points = []

    if all_points:
        client.upsert(collection_name=collection, points=all_points)

    count = client.get_collection(collection).points_count
    print(f"Collection '{collection}' now has {count} points.")


if __name__ == "__main__":
    directory = sys.argv[1] if len(sys.argv) > 1 else "/knowledge/docs/custom"
    collection = sys.argv[2] if len(sys.argv) > 2 else "custom_docs"
    print(f"Ingesting {directory} into collection '{collection}'...")
    ingest_directory(directory, collection)
```

### Ingest Kiwix articles

`scripts/ingest_kiwix.py` — fetches articles from kiwix-serve, strips HTML,
chunks, and indexes.

```python
#!/usr/bin/env python3
"""Index Kiwix articles into Qdrant via the kiwix-serve HTTP API."""

import sys, json, os
import requests
from bs4 import BeautifulSoup

sys.path.insert(0, "/knowledge/services")
from rag import (
    client, ensure_collection, chunk_text,
    embed_documents_batch, deterministic_id, PointStruct,
)

KIWIX_URL = "http://localhost:8888"
SYNC_STATE_FILE = "/knowledge/vectors/kiwix_sync.json"

def fetch_article_text(book: str, path: str) -> str:
    """Fetch an article from kiwix-serve and return plain text."""
    resp = requests.get(f"{KIWIX_URL}/{book}/{path}", timeout=30)
    if resp.status_code != 200:
        return ""
    soup = BeautifulSoup(resp.text, "html.parser")
    for tag in soup(["nav", "header", "footer", "script", "style"]):
        tag.decompose()
    return soup.get_text(separator=" ", strip=True)

def load_sync_state() -> dict:
    if os.path.exists(SYNC_STATE_FILE):
        with open(SYNC_STATE_FILE) as f:
            return json.load(f)
    return {"ingested": {}}

def save_sync_state(state: dict):
    with open(SYNC_STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)

def ingest_search_results(book: str, query: str, collection: str, max_pages: int = 100):
    """Search kiwix for articles matching a query, then ingest them."""
    ensure_collection(collection)
    state = load_sync_state()
    ingested_count = 0

    for page in range(0, max_pages):
        resp = requests.get(f"{KIWIX_URL}/search", params={
            "pattern": query,
            "books": book,
            "pageStart": page * 25,
            "pageLength": 25,
        }, timeout=30)

        soup = BeautifulSoup(resp.text, "html.parser")
        links = soup.select("article a[href]")
        if not links:
            break

        for link in links:
            href = link.get("href", "")
            article_key = f"{book}:{href}"

            if article_key in state["ingested"]:
                continue

            text = fetch_article_text(book, href.lstrip("/"))
            if len(text) < 100:
                continue

            chunks = chunk_text(text)
            if not chunks:
                continue
            vectors = embed_documents_batch(chunks)
            points = []

            for i, (chunk, vec) in enumerate(zip(chunks, vectors)):
                points.append(PointStruct(
                    id=deterministic_id(article_key, i),
                    vector=vec,
                    payload={
                        "source": "kiwix",
                        "book": book,
                        "title": link.get_text(strip=True),
                        "path": href,
                        "chunk_index": i,
                        "text": chunk,
                        "url": f"{KIWIX_URL}/{book}/{href.lstrip('/')}"
                    }
                ))

            if points:
                client.upsert(collection_name=collection, points=points)
                state["ingested"][article_key] = len(points)
                ingested_count += 1

        save_sync_state(state)

    print(f"Ingested {ingested_count} new articles into '{collection}'.")


if __name__ == "__main__":
    book = sys.argv[1] if len(sys.argv) > 1 else "wikipedia"
    query = sys.argv[2] if len(sys.argv) > 2 else "python programming"
    collection = sys.argv[3] if len(sys.argv) > 3 else "wikipedia"
    print(f"Ingesting from {book}, query='{query}', collection='{collection}'...")
    ingest_search_results(book, query, collection)
```

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
