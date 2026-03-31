# FIWARE Knowledge API — AI Agent Guide

## What This Is

A self-hosted semantic search API over multiple FIWARE GitHub repositories.
Query it to get real commit history, diffs, and deployment context to answer questions about FIWARE components accurately.

**Base URL:** `http://<your-public-ip>:5000`
**Auth:** `X-API-Key: <your_api_key>` header on all endpoints except `/health`

---

## Recommended Endpoint: `/ask`

Use `/ask` for all FIWARE questions. It returns a `context` block pre-formatted for LLM injection and a `sources` list for citations.

### Request
```
POST /ask
X-API-Key: <your_api_key>
Content-Type: application/json

{
  "question": "How do I deploy the FIWARE data space connector with Helm?",
  "n_results": 5
}
```

### Response
```json
{
  "context": "The following information was retrieved from FIWARE GitHub repositories...\n[Source 1] FIWARE/helm-charts | 2024-11-03 | ...",
  "sources": [
    {"rank": 1, "repo": "FIWARE/helm-charts", "sha": "a1b2c3d", "date": "2024-11-03", "message": "Add connector chart values"},
    {"rank": 2, "repo": "FIWARE/data-space-connector", "sha": "e4f5g6h", "date": "2024-10-28", "message": "Fix trust anchor config"}
  ],
  "total_results": 5,
  "query_time_ms": 38.4
}
```

**How to use the response:** Inject `context` directly into your system prompt before answering the user. Cite `sources` entries when referencing specific changes.

---

## Other Endpoints

### `POST /search` — Structured results with full metadata
Returns each result as a separate object with `content`, `repo`, `sha`, `author`, `date`, `message`, `relevance_rank`.
Also returns `context` (all results joined) for direct injection.

```json
{
  "question": "ODRL policy endpoint configuration",
  "n_results": 3
}
```

### `GET /health` — Public health check
Returns server status, repos monitored, and total documents indexed. No auth required.

### `GET /stats` — Database statistics (authenticated)
Returns `total_documents`, `repos_monitored`, `rate_limit_per_minute`.

---

## Python Integration Example

```python
import requests

BASE_URL = "http://<your-public-ip>:5000"
API_KEY  = "<your_api_key>"
HEADERS  = {"X-API-Key": API_KEY, "Content-Type": "application/json"}

def ask_fiware(question: str, n_results: int = 5) -> dict:
    resp = requests.post(
        f"{BASE_URL}/ask",
        headers=HEADERS,
        json={"question": question, "n_results": n_results},
        timeout=15,
    )
    resp.raise_for_status()
    return resp.json()

# Usage
result = ask_fiware("How to configure the trust anchor in data-space-connector?")

# Inject into your LLM system prompt:
system_prompt = f"""You are a FIWARE deployment expert.
Use the following retrieved knowledge to answer accurately:

{result['context']}
"""

# Cite sources:
for src in result["sources"]:
    print(f"[{src['rank']}] {src['repo']} ({src['date']}): {src['message']}")
```

---

## Configuration Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `API_KEY` | — | **Required.** Authentication key |
| `GITHUB_REPOS` | 3 default repos | Comma-separated list of `owner/repo` to sync |
| `GITHUB_TOKEN` | — | GitHub PAT — add this to avoid rate limits |
| `HOST` | `0.0.0.0` | Bind address |
| `PORT` | `5000` | Server port |
| `DB_PATH` | `./fiware_db` | ChromaDB storage path |
| `RATE_LIMIT_REQUESTS` | `60` | Requests per minute per IP |
| `MAX_DIFF_CHARS` | `5000` | Max diff characters stored per file |
| `MAX_FILES_PER_COMMIT` | `20` | Max files captured per commit |
| `LOG_LEVEL` | `INFO` | Logging verbosity |

### Adding More Repos

Edit `GITHUB_REPOS` in `.env`:
```
GITHUB_REPOS=FIWARE/data-space-connector,FIWARE/tutorials.NGSI-LD,FIWARE/helm-charts,FIWARE/orion-ld
```

---

## Architecture

```
AI Agent / External Client
        │
        │  POST /ask  (X-API-Key)
        ▼
┌──────────────────────┐
│   FastAPI Server     │  :5000
│   Rate Limiting      │
│   Auth Middleware    │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│   ChromaDB           │  ./fiware_db
│   Vector Store       │
└──────────▲───────────┘
           │
┌──────────┴───────────┐
│   Sync Worker        │  every 1h
│   (multi-repo)       │
└──────────────────────┘
           │
   FIWARE/data-space-connector
   FIWARE/tutorials.NGSI-LD
   FIWARE/helm-charts
   (+ any repos in GITHUB_REPOS)
```

---

## Troubleshooting

| Error | Fix |
|-------|-----|
| `Database not initialized` | Run `python sync.py` to populate the DB first |
| `GitHub API rate limit reached` | Add `GITHUB_TOKEN` to `.env` |
| `Missing X-API-Key header` | Include `X-API-Key: <key>` in all requests |
| `Rate limit exceeded` | Wait 60s or raise `RATE_LIMIT_REQUESTS` in `.env` |
| `Repository not found` | Check repo names in `GITHUB_REPOS` — must be `owner/repo` format |
