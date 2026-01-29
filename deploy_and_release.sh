#!/usr/bin/env bash
# deploy_and_release.sh
# Usage:
#   ./deploy_and_release.sh [--https]
# If --https is given the script will use https clone URL; otherwise SSH is used.
set -euo pipefail

# Config
OWNER="Hemasri-01"
REPO="Pastebin-lite"
SSH_URL="git@github.com:${OWNER}/${REPO}.git"
HTTPS_URL="https://github.com/${OWNER}/${REPO}.git"
USE_HTTPS=false
if [ "${1:-}" = "--https" ]; then
  USE_HTTPS=true
fi

CLONE_DIR="${REPO}"
ZIP_NAME="pastebin-lite.zip"
GH_EXISTS=false
if command -v gh >/dev/null 2>&1; then
  GH_EXISTS=true
fi

# Clone repo if absent
if [ ! -d "${CLONE_DIR}" ]; then
  if [ "${USE_HTTPS}" = true ]; then
    git clone "${HTTPS_URL}" "${CLONE_DIR}"
  else
    git clone "${SSH_URL}" "${CLONE_DIR}"
  fi
fi

cd "${CLONE_DIR}"

# Ensure main branch exists and is checked out
git fetch origin >/dev/null 2>&1 || true
if git show-ref --verify --quiet refs/heads/main; then
  git checkout main
else
  git checkout -b main
fi

# Create directories
mkdir -p src .github/workflows

# Write files (idempotent - overwrite)
cat > .gitignore <<'EOF'
node_modules/
data/
npm-debug.log
EOF

cat > src/db.js <<'EOF'
// Simple SQLite initialization and helper functions using better-sqlite3
const fs = require('fs');
const path = require('path');
const Database = require('better-sqlite3');

const dataDir = path.join(__dirname, '..', 'data');
if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir);

const dbFile = path.join(dataDir, 'pastes.db');
const db = new Database(dbFile);

// Initialize table
db.exec(`
CREATE TABLE IF NOT EXISTS pastes (
  id TEXT PRIMARY KEY,
  content TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL,
  expires_at_ms INTEGER,
  remaining_views INTEGER
);

CREATE INDEX IF NOT EXISTS idx_expires_at ON pastes (expires_at_ms);
`);

module.exports = {
  db
};
EOF

cat > src/server.js <<'EOF'
const express = require('express');
const bodyParser = require('body-parser');
const helmet = require('helmet');
const crypto = require('crypto');
const { db } = require('./db');

const app = express();
app.use(helmet());
app.use(bodyParser.json());

// Config
const PORT = process.env.PORT || 3000;
const BASE_URL = process.env.BASE_URL || `http://localhost:${PORT}`;
const TEST_MODE = process.env.TEST_MODE === '1';

// Helpers
function genId(len = 8) {
  const bytes = crypto.randomBytes(len);
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let out = '';
  for (let b of bytes) {
    out += alphabet[b % alphabet.length];
  }
  return out;
}

function parseIntStrict(v) {
  if (v === undefined || v === null) return null;
  if (Number.isInteger(v)) return v;
  const n = Number(v);
  if (!Number.isFinite(n) || !Number.isInteger(n)) return null;
  return n;
}

function nowMs(req) {
  if (TEST_MODE) {
    const header = req.headers['x-test-now-ms'];
    if (header) {
      const n = Number(header);
      if (!Number.isNaN(n)) return n;
    }
  }
  return Date.now();
}

// Escape HTML to avoid script execution
function escapeHtml(str) {
  if (!str) return '';
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// Health check
app.get('/api/healthz', (req, res) => {
  res.json({ ok: true });
});

// Create a paste
app.post('/api/pastes', (req, res) => {
  const body = req.body || {};
  const content = typeof body.content === 'string' ? body.content.trim() : '';
  if (!content) {
    return res.status(400).json({ error: 'content is required and must be a non-empty string' });
  }

  const ttlSecondsRaw = body.ttl_seconds;
  const maxViewsRaw = body.max_views;

  let ttlSeconds = null;
  let maxViews = null;

  if (ttlSecondsRaw !== undefined) {
    const parsed = parseIntStrict(ttlSecondsRaw);
    if (parsed === null || parsed < 1) {
      return res.status(400).json({ error: 'ttl_seconds must be an integer >= 1 if present' });
    }
    ttlSeconds = parsed;
  }

  if (maxViewsRaw !== undefined) {
    const parsed = parseIntStrict(maxViewsRaw);
    if (parsed === null || parsed < 1) {
      return res.status(400).json({ error: 'max_views must be an integer >= 1 if present' });
    }
    maxViews = parsed;
  }

  const reqNow = nowMs(req);
  const createdAt = Date.now();
  const expiresAt = ttlSeconds ? (reqNow + ttlSeconds * 1000) : null;

  const id = genId(10);

  const insert = db.prepare(`
    INSERT INTO pastes (id, content, created_at_ms, expires_at_ms, remaining_views)
    VALUES (@id, @content, @created_at_ms, @expires_at_ms, @remaining_views)
  `);

  insert.run({
    id,
    content,
    created_at_ms: createdAt,
    expires_at_ms: expiresAt,
    remaining_views: maxViews === null ? null : maxViews
  });

  res.status(201).json({
    id,
    url: `${BASE_URL}/p/${id}`
  });
});

// Fetch a paste (API) - this counts as a view on each successful fetch
app.get('/api/pastes/:id', (req, res) => {
  const id = req.params.id;
  const reqNow = nowMs(req);

  const get = db.prepare('SELECT id, content, expires_at_ms, remaining_views FROM pastes WHERE id = ?');
  const updateRemaining = db.prepare('UPDATE pastes SET remaining_views = @remaining_views WHERE id = @id');

  const tx = db.transaction((id) => {
    const row = get.get(id);
    if (!row) return { status: 404 };

    if (row.expires_at_ms !== null && row.expires_at_ms <= reqNow) {
      return { status: 404 };
    }

    if (row.remaining_views !== null) {
      if (row.remaining_views <= 0) return { status: 404 };
      const newRemaining = row.remaining_views - 1;
      updateRemaining.run({ remaining_views: newRemaining, id: id });
      return {
        status: 200,
        content: row.content,
        remaining_views: newRemaining,
        expires_at_ms: row.expires_at_ms
      };
    }

    return {
      status: 200,
      content: row.content,
      remaining_views: null,
      expires_at_ms: row.expires_at_ms
    };
  });

  const result = tx(id);
  if (result.status === 404) {
    return res.status(404).json({ error: 'paste not found or unavailable' });
  }

  res.json({
    content: result.content,
    remaining_views: result.remaining_views,
    expires_at: result.expires_at_ms ? new Date(result.expires_at_ms).toISOString() : null
  });
});

// View a paste (HTML) - does NOT count as a view. Returns 404 if unavailable.
app.get('/p/:id', (req, res) => {
  const id = req.params.id;
  const reqNow = nowMs(req);

  const row = db.prepare('SELECT id, content, expires_at_ms, remaining_views FROM pastes WHERE id = ?').get(id);
  if (!row) {
    res.status(404).send('<h1>404 not found</h1>');
    return;
  }

  if (row.expires_at_ms !== null && row.expires_at_ms <= reqNow) {
    res.status(404).send('<h1>404 not found</h1>');
    return;
  }

  if (row.remaining_views !== null && row.remaining_views <= 0) {
    res.status(404).send('<h1>404 not found</h1>');
    return;
  }

  const html = `
  <!doctype html>
  <html>
  <head>
    <meta charset="utf-8"/>
    <title>Paste ${escapeHtml(id)}</title>
    <meta name="viewport" content="width=device-width,initial-scale=1"/>
    <style>
      body { font-family: system-ui, sans-serif; margin: 1.5rem; }
      pre { white-space: pre-wrap; word-wrap: break-word; background: #f7f7f7; padding: 1rem; border-radius: 6px; }
    </style>
  </head>
  <body>
    <h1>Paste ${escapeHtml(id)}</h1>
    <pre>${escapeHtml(row.content)}</pre>
  </body>
  </html>
  `;
  res.set('Content-Type', 'text/html; charset=utf-8');
  res.send(html);
});

// Generic 404 for other routes
app.use((req, res) => {
  res.status(404).json({ error: 'not found' });
});

app.listen(PORT, () => {
  console.log(`Pastebin-Lite listening on ${PORT}`);
  console.log(`BASE_URL=${BASE_URL}`);
});
EOF

cat > .github/workflows/release.yml <<'EOF'
name: Build and Release
on:
  push:
    branches: [ main ]

jobs:
  build-and-release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '18'
      - name: Install dependencies
        run: npm ci
      - name: Create zip
        run: |
          zip -r pastebin-lite.zip . -x "*.git*" "node_modules/*" "data/*"
      - name: Create Release
        id: create_release
        uses: actions/create-release@v1
        with:
          tag_name: v1.0.0
          release_name: "Release v1.0.0"
          body: "Automated release containing pastebin-lite.zip"
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      - name: Upload Release Asset
        uses: actions/upload-release-asset@v1
        with:
          upload_url: ${{ steps.create_release.outputs.upload_url }}
          asset_path: ./pastebin-lite.zip
          asset_name: pastebin-lite.zip
          asset_content_type: application/zip
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
EOF

# Stage changes
git add .gitignore src/db.js src/server.js .github/workflows/release.yml || true

# Commit
if git diff --staged --quiet; then
  echo "No changes to commit."
else
  git commit -m "Add server, db, workflow, and helper script"
fi

# Push
git push origin main

# Create zip
cd ..
ZIP_ROOT_DIR="${CLONE_DIR}"
if [ -f "${ZIP_NAME}" ]; then
  rm -f "${ZIP_NAME}"
fi
cd "${ZIP_ROOT_DIR}"
zip -r "../${ZIP_NAME}" . -x ".git/*" "node_modules/*" "data/*" > /dev/null
cd ..

echo "Created ${ZIP_NAME} in $(pwd)"

# Create release with gh if available
if [ "${GH_EXISTS}" = true ]; then
  echo "gh CLI detected. Creating release v1.0.0 and uploading ${ZIP_NAME}"
  gh release create v1.0.0 "${ZIP_NAME}" --title "Release v1.0.0" --notes "Automated release containing ${ZIP_NAME}" || {
    echo "gh release failed; perhaps tag v1.0.0 already exists."
  }
else
  echo "gh CLI not found. To upload ${ZIP_NAME} as a release asset you can use the GitHub web UI or install GitHub CLI."
fi

echo "Done. Files pushed to origin/main. Release step attempted (if gh present)."
