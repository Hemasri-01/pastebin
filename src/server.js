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
