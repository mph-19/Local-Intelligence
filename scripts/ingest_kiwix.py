#!/usr/bin/env python3
"""Index Kiwix articles into Qdrant via the kiwix-serve HTTP API."""

import sys, json, os
import requests
from bs4 import BeautifulSoup

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "services"))
from rag import (
    client, ensure_collection, chunk_text,
    embed_documents_batch, deterministic_id, PointStruct,
)

KIWIX_URL = os.environ.get("KIWIX_URL", "http://localhost:8888")
SYNC_STATE_FILE = os.environ.get(
    "KIWIX_SYNC_STATE", "/knowledge/vectors/kiwix_sync.json"
)
MAX_PAGES = 500          # hard ceiling — 500 pages × 25 = 12,500 search results
MAX_ARTICLES = 5000      # stop after ingesting this many new articles per run

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

def ingest_search_results(book: str, query: str, collection: str,
                          max_pages: int = 100, max_articles: int = MAX_ARTICLES):
    """Search kiwix for articles matching a query, then ingest them."""
    max_pages = min(max(1, max_pages), MAX_PAGES)
    max_articles = min(max(1, max_articles), MAX_ARTICLES)

    ensure_collection(collection)
    state = load_sync_state()
    ingested_count = 0

    for page in range(0, max_pages):
        if ingested_count >= max_articles:
            print(f"Reached article limit ({max_articles}), stopping.")
            break

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
            if ingested_count >= max_articles:
                break

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
