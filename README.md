# Pastebin-Lite

A small Pastebin-like application (Node.js + Express + SQLite).

Features:
- Create a paste (content required). Optional TTL (seconds) and max_views (integer >= 1).
- API: GET /api/healthz, POST /api/pastes, GET /api/pastes/:id
- HTML view: GET /p/:id
- Deterministic time support for tests: set `TEST_MODE=1` and send header `x-test-now-ms: <milliseconds since epoch>` — the header will be treated as "now" for expiry logic.
- Persistence: SQLite database file `data/pastes.db` (survives server restarts).

Requirements
- Node.js 16+ recommended
- npm

Install & run
1. Install dependencies:
   npm install

2. Start:
   npm start

By default:
- PORT=3000
- BASE_URL=http://localhost:3000 (used in returned `url` from create)

Environment variables
- PORT — server port
- BASE_URL — base public URL used in returned `url` (default http://localhost:3000)
- TEST_MODE — if `1`, tests can set `x-test-now-ms` header to control time logic

API
- GET /api/healthz
  - 200, JSON: { "ok": true }

- POST /api/pastes
  - JSON body:
    {
      "content": "string",           // REQUIRED non-empty
      "ttl_seconds": 60,             // OPTIONAL integer >=1
      "max_views": 5                 // OPTIONAL integer >=1
    }
  - Success (2xx): { "id": "<id>", "url": "<BASE_URL>/p/<id>" }
  - Invalid input: 4xx with JSON error

- GET /api/pastes/:id
  - Successful response (200 JSON):
    {
      "content": "string",
      "remaining_views": 4 | null,
      "expires_at": "2026-01-01T00:00:00.000Z" | null
    }
  - Each successful API fetch counts as a view (atomic decrement).
  - Unavailable cases (missing, expired, views exhausted) -> 404 JSON

- GET /p/:id
  - Returns HTML (200) that safely renders the paste content (escaped).
  - If paste is unavailable, returns 404 (HTML or JSON depending on request).

Notes about deterministic testing
- If `TEST_MODE=1` and a request includes header `x-test-now-ms` then that value (milliseconds since epoch) will be treated as the "current time" for expiry checks and for computing `expires_at` when creating a paste. This allows deterministic expiry tests.

Persistence
- SQLite database file `data/pastes.db` (created automatically). Uses `better-sqlite3` for safe atomic updates.

License
- MIT