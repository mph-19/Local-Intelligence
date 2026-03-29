#!/usr/bin/env python3
"""Index a directory of text/Markdown files into Qdrant."""

import sys, os, time
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, Future

# Add services dir to path so we can import rag module
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "services"))
from rag import (
    client, ensure_collection, chunk_text, CHUNK_OVERLAP,
    embed_documents_batch, deterministic_id, PointStruct,
)

EMBED_BATCH_SIZE = 256    # chunks per embedding call (cross-file)
UPSERT_BATCH_SIZE = 500   # points per Qdrant upsert
SLICE_SIZE = 1024 * 1024  # 1 MB — read large files in slices to bound memory


def read_and_chunk(paths: list[Path], directory: str) -> list[tuple[str, int, str]]:
    """Read files and chunk them. Returns list of (file_rel_path, chunk_index, chunk_text).

    Small files are read whole. Files larger than SLICE_SIZE are read in slices
    with word-level overlap to ensure chunk boundaries stay consistent.
    """
    items = []
    for path in paths:
        rel = str(path.relative_to(directory))
        size = path.stat().st_size

        if size <= SLICE_SIZE:
            # Small file — read whole (fast path, most files)
            text = path.read_text(errors="replace")
            for i, chunk in enumerate(chunk_text(text)):
                items.append((rel, i, chunk))
        else:
            # Large file — stream in slices to bound memory
            print(f"  [stream] {path.name} ({size / 1024 / 1024:.1f} MB, reading in slices)")
            chunk_idx = 0
            overlap_words: list[str] = []
            with open(path, "r", errors="replace") as f:
                while True:
                    raw = f.read(SLICE_SIZE)
                    if not raw and not overlap_words:
                        break
                    # Prepend overlap from previous slice
                    if overlap_words:
                        text = " ".join(overlap_words) + " " + raw
                    else:
                        text = raw
                    is_last = len(raw) < SLICE_SIZE
                    words = text.split()

                    if not is_last:
                        # Keep last CHUNK_OVERLAP words for next slice
                        overlap_words = words[-CHUNK_OVERLAP:]
                        words = words[:-CHUNK_OVERLAP]
                    else:
                        overlap_words = []

                    slice_text = " ".join(words)
                    for chunk in chunk_text(slice_text):
                        items.append((rel, chunk_idx, chunk))
                        chunk_idx += 1

                    if is_last:
                        break
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

    pool.shutdown(wait=True)

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
