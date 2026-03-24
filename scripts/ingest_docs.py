#!/usr/bin/env python3
"""Index a directory of text/Markdown files into Qdrant."""

import sys, os
from pathlib import Path

# Add services dir to path so we can import rag module
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "services"))
from rag import (
    client, ensure_collection, chunk_text,
    embed_documents_batch, deterministic_id, PointStruct,
)

def ingest_directory(directory: str, collection: str):
    ensure_collection(collection)
    all_points = []

    paths = sorted(
        list(Path(directory).glob("**/*.md")) +
        list(Path(directory).glob("**/*.txt"))
    )
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
