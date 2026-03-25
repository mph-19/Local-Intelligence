#!/usr/bin/env python3
"""Index a directory of text/Markdown files into Qdrant."""

import sys, os, time
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, Future

# Add services dir to path so we can import rag module
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "services"))
from rag import (
    client, ensure_collection, chunk_text,
    embed_documents_batch, deterministic_id, PointStruct,
)

EMBED_BATCH_SIZE = 256    # chunks per embedding call (cross-file)
UPSERT_BATCH_SIZE = 500   # points per Qdrant upsert


def read_and_chunk(paths: list[Path], directory: str) -> list[tuple[str, int, str]]:
    """Read files and chunk them. Returns list of (file_rel_path, chunk_index, chunk_text)."""
    items = []
    for path in paths:
        text = path.read_text(errors="replace")
        chunks = chunk_text(text)
        rel = str(path.relative_to(directory))
        for i, chunk in enumerate(chunks):
            items.append((rel, i, chunk))
    return items


def ingest_directory(directory: str, collection: str):
    ensure_collection(collection)

    paths = sorted(
        list(Path(directory).glob("**/*.md")) +
        list(Path(directory).glob("**/*.txt"))
    )
    total_files = len(paths)
    print(f"Found {total_files} files in {directory}")
    if not paths:
        return

    t_start = time.time()
    total_chunks = 0
    total_points = 0
    upsert_buffer = []

    # Split files into groups for cross-file batching.
    # Read/chunk a group while the previous group is embedding.
    GROUP_SIZE = 50  # files per group
    groups = [paths[i:i + GROUP_SIZE] for i in range(0, len(paths), GROUP_SIZE)]

    pool = ThreadPoolExecutor(max_workers=1)
    prefetch: Future | None = None

    # Kick off reading the first group in the background
    if groups:
        prefetch = pool.submit(read_and_chunk, groups[0], directory)

    files_done = 0
    for gi, group in enumerate(groups):
        # Collect the pre-fetched read/chunk result
        items = prefetch.result()

        # Start reading the next group while we embed this one
        if gi + 1 < len(groups):
            prefetch = pool.submit(read_and_chunk, groups[gi + 1], directory)

        if not items:
            files_done += len(group)
            continue

        # Embed in cross-file batches
        all_chunks = [text for _, _, text in items]
        for batch_start in range(0, len(all_chunks), EMBED_BATCH_SIZE):
            batch_end = min(batch_start + EMBED_BATCH_SIZE, len(all_chunks))
            batch_texts = all_chunks[batch_start:batch_end]
            batch_items = items[batch_start:batch_end]

            vectors = embed_documents_batch(batch_texts)

            for (rel_path, chunk_idx, chunk), vec in zip(batch_items, vectors):
                upsert_buffer.append(PointStruct(
                    id=deterministic_id(rel_path, chunk_idx),
                    vector=vec,
                    payload={
                        "source": "local",
                        "file": rel_path,
                        "chunk_index": chunk_idx,
                        "text": chunk,
                    }
                ))

            if len(upsert_buffer) >= UPSERT_BATCH_SIZE:
                client.upsert(collection_name=collection, points=upsert_buffer)
                total_points += len(upsert_buffer)
                upsert_buffer = []

        files_done += len(group)
        total_chunks += len(items)
        elapsed = time.time() - t_start
        rate = files_done / elapsed if elapsed > 0 else 0
        remaining = (total_files - files_done) / rate if rate > 0 else 0
        print(f"  [{files_done}/{total_files}] {total_chunks} chunks | "
              f"{rate:.1f} files/s | ~{remaining:.0f}s remaining")

    pool.shutdown(wait=False)

    # Flush remaining points
    if upsert_buffer:
        client.upsert(collection_name=collection, points=upsert_buffer)
        total_points += len(upsert_buffer)

    elapsed = time.time() - t_start
    count = client.get_collection(collection).points_count
    print(f"Done: {total_files} files, {total_chunks} chunks, "
          f"{count} points in collection '{collection}' ({elapsed:.1f}s)")


if __name__ == "__main__":
    directory = sys.argv[1] if len(sys.argv) > 1 else "/knowledge/docs/custom"
    collection = sys.argv[2] if len(sys.argv) > 2 else "custom_docs"
    print(f"Ingesting {directory} into collection '{collection}'...")
    ingest_directory(directory, collection)
