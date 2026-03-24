#!/usr/bin/env python3
"""Shared RAG utilities: embedding, Qdrant client, chunking, retrieval."""

import hashlib, uuid, os
from sentence_transformers import SentenceTransformer
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, VectorParams, PointStruct

# --- Config ---
QDRANT_PATH = os.environ.get("QDRANT_PATH", "/knowledge/vectors/qdrant")
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
