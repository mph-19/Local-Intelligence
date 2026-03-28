#!/usr/bin/env python3
"""Shared RAG utilities: embedding, Qdrant client, chunking, retrieval."""

import uuid, os
from qdrant_client.models import Distance, VectorParams, PointStruct

# --- Config ---
QDRANT_PATH = os.environ.get("QDRANT_PATH", "/knowledge/vectors/qdrant")
EMBED_MODEL = "nomic-ai/nomic-embed-text-v1.5"
EMBED_REVISION = "e5cf08aadaa33385f5990def41f7a23405aec398"  # pin to audited commit
CHUNK_SIZE = 400       # words
CHUNK_OVERLAP = 50     # words

# --- Lazy-loaded singletons ---
# Initialized on first use so that:
#   1. Importing rag.py for chunk_text()/deterministic_id() is free
#   2. SentenceTransformer (~270 MB) only loads when embedding is needed
#   3. QdrantClient only locks the database when vector ops start
#   4. Transient HuggingFace outages don't crash the import

_embedder = None
_client = None

def get_embedder():
    """Return the SentenceTransformer, loading it on first call."""
    global _embedder
    if _embedder is None:
        from sentence_transformers import SentenceTransformer
        _embedder = SentenceTransformer(
            EMBED_MODEL,
            trust_remote_code=True,
            revision=EMBED_REVISION,
        )
        print("[rag] Embedding model loaded")
    return _embedder

def get_qdrant():
    """Return the QdrantClient, creating it on first call."""
    global _client
    if _client is None:
        from qdrant_client import QdrantClient
        _client = QdrantClient(path=QDRANT_PATH)
        print(f"[rag] Qdrant client initialized at {QDRANT_PATH}")
    return _client

# Backwards-compatible aliases for existing callers
# (property-like access without changing every call site)
class _LazyProxy:
    """Transparent proxy that defers initialization to a factory function."""
    def __init__(self, factory):
        object.__setattr__(self, '_factory', factory)
        object.__setattr__(self, '_obj', None)
    def _get(self):
        obj = object.__getattribute__(self, '_obj')
        if obj is None:
            obj = object.__getattribute__(self, '_factory')()
            object.__setattr__(self, '_obj', obj)
        return obj
    def __getattr__(self, name):
        return getattr(self._get(), name)
    def __call__(self, *args, **kwargs):
        return self._get()(*args, **kwargs)

embedder = _LazyProxy(get_embedder)
client = _LazyProxy(get_qdrant)

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
    """Split text into overlapping chunks, preferring sentence boundaries.

    Targets CHUNK_SIZE words per chunk.  When a split would fall mid-sentence,
    scans backward (up to half the chunk) for sentence-ending punctuation and
    snaps the boundary there.  Falls back to word-count boundary in text
    without sentence structure (e.g. code blocks, lists).
    """
    words = text.split()
    if not words:
        return []

    chunks = []
    start = 0

    while start < len(words):
        end = min(start + CHUNK_SIZE, len(words))

        # If not at the end of text, try to snap to a sentence boundary
        if end < len(words):
            search_floor = max(start + CHUNK_SIZE // 2, start + 20)
            for i in range(end - 1, search_floor - 1, -1):
                w = words[i]
                # Sentence-ending: word ends with . ! ? or ." ?" !"
                if w[-1] in '.!?' or (len(w) >= 2 and w[-1] == '"' and w[-2] in '.!?'):
                    end = i + 1
                    break

        chunk = " ".join(words[start:end])
        if len(chunk.split()) > 20:
            chunks.append(chunk)

        # Done once we've reached the end of text
        if end >= len(words):
            break
        # Next chunk starts CHUNK_OVERLAP words before where this one ended
        start = end - CHUNK_OVERLAP

    return chunks

# Namespace UUID for deterministic chunk IDs (uuid5)
_CHUNK_NS = uuid.UUID("c4a1e2b0-7d3f-4e5a-9b1c-2d8f6a0e3c7b")

def deterministic_id(source: str, chunk_index: int) -> str:
    """Stable UUID5 from source + index so re-indexing overwrites, not duplicates."""
    return str(uuid.uuid5(_CHUNK_NS, f"{source}:{chunk_index}"))

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
