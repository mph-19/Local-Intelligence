# Query Orchestrator

The orchestrator is a FastAPI service that sits between the chat interface
(Open WebUI) and the backend components. It classifies queries, retrieves
relevant context from Qdrant (with Kiwix fulltext fallback), assembles an
augmented prompt, and forwards it to one or two LLMs for generation.

## Why an Orchestrator?

Open WebUI connects to an OpenAI-compatible endpoint. If you point it directly
at an LLM server, you get raw model output with no retrieval. The orchestrator
adds the RAG layer transparently — Open WebUI sends a chat message, and the
orchestrator handles retrieval, triage, synthesis, and source attribution
behind the scenes.

From Open WebUI's perspective, it's just talking to an OpenAI-compatible API.

## Pipeline Modes

The orchestrator supports two pipeline modes, controlled by the `PIPELINE_MODE`
environment variable (set automatically by `make setup` based on your profile).

### Single mode (`PIPELINE_MODE=single`)

Used by the `cpu`, `gpu`, and `minimal` profiles. One LLM does everything.

```
User query
    │
    ▼
Classify intent (weighted keyword scoring)
    │
    ▼
Retrieve from Qdrant collections
    │
    ▼
Kiwix fulltext fallback (if vector scores are weak)
    │
    ▼
Build augmented prompt (query + context)
    │
    ▼
Forward to LLM (LLM_URL)
    │
    ▼
Append source citations → return response
```

### Dual mode (`PIPELINE_MODE=dual`)

Used by the `dual` profile. Falcon3 triages on CPU, Qwen synthesizes on GPU.

```
User query
    │
    ▼
Classify intent → Retrieve from Qdrant → Kiwix fallback
    │
    ▼
┌───────────────────────────────────────┐
│ Stage 1: Triage (Falcon3, CPU)        │
│                                       │
│ Score each chunk's relevance to the   │
│ question. Return JSON with indices    │
│ of chunks to keep + confidence score. │
│                                       │
│ Fast: ~1-3 seconds, low temperature   │
│ Uses: TRIAGE_LLM_URL                  │
└──────────────────┬────────────────────┘
                   │ filtered chunks
                   ▼
┌───────────────────────────────────────┐
│ Stage 2: Synthesis (Qwen 3.5, GPU)    │
│                                       │
│ Reason over filtered chunks and       │
│ generate a cited answer.              │
│                                       │
│ Quality: uses full temperature,       │
│ longer max_tokens                     │
│ Uses: SYNTH_LLM_URL                   │
└──────────────────┬────────────────────┘
                   │
                   ▼
Append source citations → return response
```

The orchestrator distinguishes between two triage outcomes:

- **Parse failure** (invalid JSON, missing fields): Falls back to sending all
  chunks to Qwen unfiltered. This is graceful degradation — the triage step
  is skipped, but synthesis still works.
- **Explicit rejection** (valid JSON with `"keep": []`, confidence < 0.1):
  The model understood the chunks and determined none are relevant. The
  orchestrator respects this and returns an "I don't have enough information"
  response instead of hallucinating from irrelevant context.

## Routing Logic

```
User query
    |
    v
Classify intent (weighted keyword scoring, three tiers)
    |
    v
Score code keywords (0.5 ambiguous, 1.0 strong, 2.0 phrases, 3.0 compounds)
Score factual keywords (same tiers)
    |
    v
Threshold: 2.0 required for confident routing
    |-- code only (≥2.0)      -> stackoverflow, unix_se collections
    |-- factual only (≥2.0)   -> wikipedia collection → Kiwix fulltext fallback
    |-- both score (ambiguous) -> merge all collections → Kiwix fallback
    |-- neither (below 2.0)   -> all collections → Kiwix fallback
    '-- chat (no keywords)    -> skip RAG, LLM direct
```

Word-boundary regex with lookaround handles special characters (`c#`, `c++`,
`.net`). Disambiguation compounds (`python code`, `java class`) add 3.0 to
prevent false positives like "Let's go fishing" triggering code routing.

## Error Handling

LLM calls use split timeouts: **5 seconds** to establish a TCP connection (fail
fast if the service is down) and **90 seconds** for the response (inference is
slow at ~8-18 tok/s on CPU). The triage stage uses a shorter 30-second read
timeout since it only generates ~200 tokens.

On connection errors or HTTP 5xx responses, the orchestrator retries once after
a 2-second backoff. If the retry also fails, an **HTTP 502** response is
returned with an OpenAI-compatible error body:

```json
{
  "error": {
    "message": "Error contacting LLM: ...",
    "type": "upstream_error",
    "code": "502"
  }
}
```

| Scenario | Behavior |
|---|---|
| LLM container is down | Fails in ~12s (5s connect + 2s backoff + 5s retry) |
| LLM returns 503 (restarting) | Retries after 2s, usually succeeds |
| LLM generating a long response | Waits up to 90s (enough for ~720 tokens at 8 tok/s) |
| Triage parse fails (bad JSON) | Falls back to unfiltered chunks, logs warning |
| Triage rejects all chunks (keep: []) | Returns "not enough information" response |
| Request exceeds size limits | Returns HTTP 422 with field-level error details |

## Input Limits

The chat endpoint enforces request size limits via Pydantic validation.
Oversized requests are rejected with HTTP 422 before any processing begins.

| Field | Limit | Rationale |
|---|---|---|
| `max_tokens` | 1–4096 | Prevents memory exhaustion (~6 pages of output) |
| `messages` | 50 max | Generous for chat, blocks context flooding |
| `content` (per message) | 32,000 chars | Aligns with model context windows |
| `temperature` | 0.0–2.0 | Standard OpenAI range |

## CORS

Cross-origin requests are restricted to allowed origins only. By default, only
Open WebUI (`http://localhost:3000`) is permitted. Add origins via the
`CORS_ORIGINS` environment variable (comma-separated) for multi-host setups.

Server-to-server calls (curl, Caddy proxy) are unaffected — CORS only gates
browser JavaScript.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `PIPELINE_MODE` | `single` | `single` or `dual` — set by profile |
| `LLM_URL` | `http://localhost:8080/v1/chat/completions` | LLM endpoint (single mode) |
| `TRIAGE_LLM_URL` | (empty) | Falcon3 endpoint (dual mode) |
| `SYNTH_LLM_URL` | (empty) | Qwen endpoint (dual mode) |
| `KIWIX_URL` | `http://localhost:8888` | Kiwix server |
| `ORCHESTRATOR_PORT` | `8081` | Port to listen on |
| `RAG_TOP_K` | `5` | Number of chunks to retrieve per query |
| `KIWIX_FALLBACK_THRESHOLD` | `0.4` | Min vector score before falling back to Kiwix |
| `CORS_ORIGINS` | `http://localhost:3000` | Comma-separated allowed origins for CORS |

In single mode, `LLM_URL` is used for everything. In dual mode, `TRIAGE_LLM_URL`
and `SYNTH_LLM_URL` must both be set. If either is missing, the orchestrator
falls back to `LLM_URL`.

## Running

### Via Docker (recommended)

The orchestrator starts automatically with `make up`. Configuration is read
from `.env`, which is generated by `make setup`.

### Standalone

```bash
# Single mode (default)
python services/orchestrator.py

# Dual mode with explicit URLs
PIPELINE_MODE=dual \
TRIAGE_LLM_URL=http://localhost:8080/v1/chat/completions \
SYNTH_LLM_URL=http://localhost:8082/v1/chat/completions \
  python services/orchestrator.py

# With auto-reload during development
cd services && uvicorn orchestrator:app --host 0.0.0.0 --port 8081 --reload
```

## systemd Service

```ini
# /etc/systemd/system/orchestrator.service
[Unit]
Description=Local Intelligence Query Orchestrator
After=falcon3-server.service kiwix-serve.service
Wants=falcon3-server.service

[Service]
ExecStart=/usr/bin/python3 /knowledge/services/orchestrator.py
WorkingDirectory=/knowledge/services
Restart=on-failure
RestartSec=5
User=matt
# Single mode (default):
Environment=LLM_URL=http://localhost:8080/v1/chat/completions
Environment=KIWIX_URL=http://localhost:8888
Environment=ORCHESTRATOR_PORT=8081
# For dual mode, add:
# Environment=PIPELINE_MODE=dual
# Environment=TRIAGE_LLM_URL=http://localhost:8080/v1/chat/completions
# Environment=SYNTH_LLM_URL=http://localhost:8082/v1/chat/completions

[Install]
WantedBy=multi-user.target
```

## Port Map

All ports bind to `127.0.0.1` by default. Set `BIND_ADDR=0.0.0.0` in `.env`
for LAN/multi-host access.

| Service | Port | Purpose |
|---|---|---|
| Falcon3 (bitnet.cpp) | 8080 | CPU LLM inference (triage in dual mode) |
| Qwen 3.5 (llama.cpp) | 8082 | GPU LLM inference (synthesis in dual mode) |
| Orchestrator | 8081 | RAG-augmented proxy (Open WebUI connects here) |
| Kiwix | 8888 | Knowledge base browsing + article API |
| Open WebUI | 3000 | Web chat interface |
| Caddy | 80/443 | Reverse proxy (see MULTI_HOST.md) |

## CLI Chat (for testing without Open WebUI)

```python
#!/usr/bin/env python3
"""Quick CLI chat against the orchestrator."""
import requests, sys

URL = "http://localhost:8081/v1/chat/completions"

def chat(message: str) -> str:
    resp = requests.post(URL, json={
        "model": "local-intelligence",
        "messages": [{"role": "user", "content": message}],
    })
    data = resp.json()
    if "error" in data:
        return f"[Error {resp.status_code}] {data['error']['message']}"
    return data["choices"][0]["message"]["content"]

if __name__ == "__main__":
    if len(sys.argv) > 1:
        print(chat(" ".join(sys.argv[1:])))
    else:
        print("Local Intelligence CLI — Ctrl+C to exit\n")
        while True:
            try:
                msg = input("You: ").strip()
                if msg:
                    print(f"\n{chat(msg)}\n")
            except (EOFError, KeyboardInterrupt):
                break
```
