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
