#!/usr/bin/env python3
"""
Query orchestrator: RAG-augmented proxy in front of one or two LLMs.
Exposes OpenAI-compatible /v1/chat/completions for Open WebUI.

Pipeline modes:
  single — one LLM handles retrieval-augmented generation (cpu/gpu/minimal)
  dual   — Falcon3 triages retrieved chunks, Qwen synthesizes the answer
"""

import json, sys, time, uuid, os
from concurrent.futures import ThreadPoolExecutor
import requests
from bs4 import BeautifulSoup
from fastapi import FastAPI
from pydantic import BaseModel

# Import shared RAG module
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rag import embed_query, embed_documents_batch, chunk_text, client as qdrant

# --- Config (override via environment) ---
PIPELINE_MODE = os.environ.get("PIPELINE_MODE", "single")  # "single" or "dual"
LLM_URL = os.environ.get("LLM_URL", "http://localhost:8080/v1/chat/completions")
TRIAGE_LLM_URL = os.environ.get("TRIAGE_LLM_URL", "")
SYNTH_LLM_URL = os.environ.get("SYNTH_LLM_URL", "")
KIWIX_URL = os.environ.get("KIWIX_URL", "http://localhost:8888")
RAG_TOP_K = int(os.environ.get("RAG_TOP_K", "5"))
KIWIX_FALLBACK_THRESHOLD = float(os.environ.get("KIWIX_FALLBACK_THRESHOLD", "0.4"))

# Resolve URLs: in single mode, everything goes through LLM_URL.
# In dual mode, TRIAGE and SYNTH must be set; fall back to LLM_URL if missing.
if PIPELINE_MODE != "dual" or not SYNTH_LLM_URL:
    TRIAGE_LLM_URL = LLM_URL
    SYNTH_LLM_URL = LLM_URL
elif not TRIAGE_LLM_URL:
    TRIAGE_LLM_URL = LLM_URL

# --- Init ---
app = FastAPI(title="Local Intelligence Orchestrator")

print(f"[orchestrator] pipeline={PIPELINE_MODE}")
if PIPELINE_MODE == "dual":
    print(f"[orchestrator] triage → {TRIAGE_LLM_URL}")
    print(f"[orchestrator] synth  → {SYNTH_LLM_URL}")
else:
    print(f"[orchestrator] llm    → {LLM_URL}")

# Cache available collections at startup (refreshed on miss)
_available_collections: set[str] | None = None

def get_available_collections(force_refresh: bool = False) -> set[str]:
    global _available_collections
    if _available_collections is None or force_refresh:
        _available_collections = {
            c.name for c in qdrant.get_collections().collections
        }
    return _available_collections

# --- Models ---
class Message(BaseModel):
    role: str
    content: str

class ChatRequest(BaseModel):
    model: str = "local-intelligence"
    messages: list[Message]
    max_tokens: int = 512
    temperature: float = 0.7

# --- Classification ---
COLLECTION_ROUTES = {
    "code":     ["stackoverflow", "unix_se"],
    "factual":  ["wikipedia"],
    "general":  ["custom_docs", "unix_se", "stackoverflow"],
}

CODE_KEYWORDS = [
    "python", "javascript", "typescript", "code", "function", "error",
    "bash", "c#", "sql", "api", "debug", "exception", "linux",
    "command", "script", "git", "docker", "rust", "go ", "golang",
]
FACTUAL_KEYWORDS = [
    "what is", "who is", "who was", "history of", "define",
    "explain", "when did", "where is",
]

def classify_query(query: str) -> str:
    q = query.lower()
    if any(kw in q for kw in CODE_KEYWORDS):
        return "code"
    if any(kw in q for kw in FACTUAL_KEYWORDS):
        return "factual"
    return "general"

# --- RAG ---
def retrieve(query: str, collections: list[str], top_k: int = RAG_TOP_K) -> list[dict]:
    """Search multiple collections, return top-K results overall."""
    available = get_available_collections()
    query_vec = embed_query(query)  # embed once, reuse across collections

    # If none of the requested collections exist, refresh the cache once
    if not any(c in available for c in collections):
        available = get_available_collections(force_refresh=True)

    def search_collection(collection: str) -> list[dict]:
        try:
            results = qdrant.search(
                collection_name=collection,
                query_vector=query_vec,
                limit=top_k,
            )
            return [{
                "text": r.payload["text"],
                "source": r.payload.get("title", r.payload.get("file", "unknown")),
                "url": r.payload.get("url", ""),
                "score": r.score,
                "collection": collection,
            } for r in results]
        except Exception as e:
            print(f"RAG error ({collection}): {e}")
            return []

    targets = [c for c in collections if c in available]
    all_results = []
    with ThreadPoolExecutor(max_workers=len(targets) or 1) as pool:
        for hits in pool.map(search_collection, targets):
            all_results.extend(hits)

    all_results.sort(key=lambda x: x["score"], reverse=True)
    return all_results[:top_k]

def kiwix_fallback(query: str, top_k: int = 3) -> list[dict]:
    """Tier 2: Search Kiwix fulltext, fetch top articles, chunk on-the-fly."""
    try:
        resp = requests.get(f"{KIWIX_URL}/search", params={
            "pattern": query, "pageLength": top_k,
        }, timeout=10)
        if resp.status_code != 200:
            return []
    except Exception:
        return []

    soup = BeautifulSoup(resp.text, "html.parser")
    links = soup.select("article a[href]")

    def fetch_article(link) -> dict | None:
        href = link.get("href", "").lstrip("/")
        title = link.get_text(strip=True)
        try:
            article = requests.get(f"{KIWIX_URL}/{href}", timeout=15)
            if article.status_code != 200:
                return None
            text = BeautifulSoup(article.text, "html.parser").get_text(" ", strip=True)
            words = text.split()[:2000]
            return {
                "text": " ".join(words),
                "source": title,
                "url": f"{KIWIX_URL}/{href}",
                "score": 0.0,
                "collection": "kiwix_fallback",
            }
        except Exception:
            return None

    with ThreadPoolExecutor(max_workers=top_k) as pool:
        results = [r for r in pool.map(fetch_article, links[:top_k]) if r]

    return results

def build_augmented_prompt(query: str, contexts: list[dict]) -> str:
    if not contexts:
        return query

    context_block = "\n\n---\n\n".join(
        f"[{c['source']}] (relevance: {c['score']:.2f})\n{c['text']}"
        for c in contexts
    )
    return f"""Use the following retrieved context to answer the user's question.
Cite sources when possible. If the context doesn't contain the answer, say so
and answer from your own knowledge.

CONTEXT:
{context_block}

QUESTION: {query}"""

# --- Dual-model triage ---

TRIAGE_PROMPT_TEMPLATE = """You are a relevance filter. Given a user question and retrieved text chunks,
score each chunk's relevance to the question. Return ONLY valid JSON — no other text.

Format: {{"keep": [list of chunk numbers to keep, 0-indexed], "confidence": 0.0-1.0}}

- "keep" should list chunks that contain information useful for answering the question.
- "confidence" is how confident you are that the kept chunks can answer the question.
- If no chunks are relevant, return {{"keep": [], "confidence": 0.0}}

QUESTION: {question}

CHUNKS:
{chunks}

JSON:"""


def build_triage_prompt(query: str, contexts: list[dict]) -> str:
    """Build a prompt for Falcon3 to score/filter retrieved chunks."""
    chunks_text = "\n\n".join(
        f"[{i}] ({c['source']}, score={c['score']:.2f}):\n{c['text'][:500]}"
        for i, c in enumerate(contexts)
    )
    return TRIAGE_PROMPT_TEMPLATE.format(question=query, chunks=chunks_text)


def parse_triage_response(llm_json: dict, contexts: list[dict]) -> tuple[list[dict], float]:
    """Parse triage LLM response, return (filtered_contexts, confidence).

    Gracefully falls back to returning all contexts if parsing fails.
    """
    try:
        content = llm_json["choices"][0]["message"]["content"].strip()
        # Extract JSON from the response (handle markdown code fences)
        if content.startswith("```"):
            content = content.split("```")[1]
            if content.startswith("json"):
                content = content[4:]
        triage = json.loads(content)
        keep_indices = triage.get("keep", [])
        confidence = float(triage.get("confidence", 0.5))
        filtered = [contexts[i] for i in keep_indices if 0 <= i < len(contexts)]
        return (filtered if filtered else contexts, confidence)
    except (json.JSONDecodeError, KeyError, IndexError, TypeError) as e:
        print(f"[triage] parse error, keeping all chunks: {e}")
        return (contexts, 0.5)


def call_llm(url: str, messages: list[dict], max_tokens: int = 512,
             temperature: float = 0.7, timeout: int = 120) -> dict:
    """Send a chat completion request to an LLM endpoint."""
    resp = requests.post(url, json={
        "model": "local-intelligence",
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
    }, timeout=timeout)
    resp.raise_for_status()
    return resp.json()


# --- API ---
@app.get("/v1/models")
async def list_models():
    return {
        "object": "list",
        "data": [{
            "id": "local-intelligence",
            "object": "model",
            "owned_by": "local",
        }]
    }

@app.post("/v1/chat/completions")
async def chat(req: ChatRequest):
    # Extract the latest user message for RAG
    user_messages = [m for m in req.messages if m.role == "user"]
    query_text = user_messages[-1].content.strip() if user_messages else ""

    # Skip RAG for empty queries
    if not query_text:
        return _chat_response(req.model, "Please provide a question or message.")

    # Classify and retrieve (Tier 1: Qdrant vectors)
    intent = classify_query(query_text)
    collections = COLLECTION_ROUTES.get(intent, COLLECTION_ROUTES["general"])
    contexts = retrieve(query_text, collections)

    # Tier 2: Kiwix fulltext fallback if vector results are weak
    best_score = max((c["score"] for c in contexts), default=0.0)
    if best_score < KIWIX_FALLBACK_THRESHOLD:
        kiwix_results = kiwix_fallback(query_text)
        contexts = kiwix_results + contexts

    # ── Dual pipeline: Falcon3 triage → Qwen synthesis ──────────
    if PIPELINE_MODE == "dual" and contexts:
        try:
            # Stage 1: Falcon3 scores and filters chunks (fast, low temp)
            triage_prompt = build_triage_prompt(query_text, contexts)
            triage_response = call_llm(
                TRIAGE_LLM_URL,
                messages=[{"role": "user", "content": triage_prompt}],
                max_tokens=200,
                temperature=0.1,
                timeout=30,
            )
            contexts, confidence = parse_triage_response(triage_response, contexts)

            # Early exit if triage says nothing is relevant
            if confidence < 0.1 and not contexts:
                return _chat_response(
                    req.model,
                    "I don't have enough information in my knowledge base to "
                    "answer that question. Try rephrasing or asking something else."
                )
        except Exception as e:
            # Triage failed — fall through to synthesis with unfiltered chunks
            print(f"[triage] error, skipping triage: {e}")

        # Stage 2: Qwen synthesizes from filtered chunks
        augmented = build_augmented_prompt(query_text, contexts)
        messages_for_llm = [
            {"role": m.role, "content": m.content} for m in req.messages[:-1]
        ]
        messages_for_llm.append({"role": "user", "content": augmented})

        try:
            llm_response = call_llm(
                SYNTH_LLM_URL,
                messages=messages_for_llm,
                max_tokens=req.max_tokens,
                temperature=req.temperature,
            )
        except Exception as e:
            return _error_response(req.model, f"Error contacting synthesis LLM: {e}")

    # ── Single pipeline: one LLM does everything ────────────────
    else:
        augmented = build_augmented_prompt(query_text, contexts)
        messages_for_llm = [
            {"role": m.role, "content": m.content} for m in req.messages[:-1]
        ]
        messages_for_llm.append({"role": "user", "content": augmented})

        try:
            llm_response = call_llm(
                LLM_URL,
                messages=messages_for_llm,
                max_tokens=req.max_tokens,
                temperature=req.temperature,
            )
        except Exception as e:
            return _error_response(req.model, f"Error contacting LLM: {e}")

    # Add source attribution
    answer = llm_response["choices"][0]["message"]["content"]
    if contexts:
        sources = list(dict.fromkeys(c["source"] for c in contexts))
        answer += "\n\n---\nSources: " + ", ".join(sources)

    return _chat_response(req.model, answer)


def _chat_response(model: str, content: str) -> dict:
    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": content},
            "finish_reason": "stop",
        }],
    }

def _error_response(model: str, message: str) -> dict:
    return _chat_response(model, message)


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("ORCHESTRATOR_PORT", "8081"))
    uvicorn.run(app, host="0.0.0.0", port=port)
