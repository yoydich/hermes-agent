FROM ghcr.io/outsourc-e/hermes-workspace:latest

USER root

RUN cat > /usr/local/bin/hermes-memory-sync.mjs <<'EOF'
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const root = path.resolve(process.env.HERMES_HOME || process.env.CLAUDE_HOME || path.join(os.homedir(), '.hermes'));
const baseUrl = (process.env.HERMES_DASHBOARD_URL || process.env.HERMES_API_URL || '').replace(/\/+$/, '');
const token = process.env.HERMES_API_TOKEN || process.env.CLAUDE_DASHBOARD_TOKEN || process.env.CLAUDE_API_TOKEN || '';
const statePath = path.join(root, '.workspace-memory-sync.json');

function allowed(rel) {
  return rel === 'MEMORY.md'
    || rel === 'USER.md'
    || rel.startsWith('memory/')
    || rel.startsWith('memories/');
}

function safePath(rel) {
  const normalized = String(rel || '').replace(/\\/g, '/').trim();
  if (!normalized || normalized.startsWith('/') || normalized.includes('..') || !normalized.endsWith('.md') || !allowed(normalized)) {
    return null;
  }
  const full = path.resolve(root, normalized);
  return full.startsWith(root) ? full : null;
}

async function remoteJson(endpoint, options = {}) {
  if (!baseUrl || !token) throw new Error('memory sync missing HERMES_DASHBOARD_URL/HERMES_API_TOKEN');
  const response = await fetch(`${baseUrl}${endpoint}`, {
    ...options,
    headers: {
      authorization: `Bearer ${token}`,
      ...(options.headers || {}),
    },
  });
  if (!response.ok) throw new Error(`${endpoint} -> HTTP ${response.status}`);
  return response.json();
}

function loadState() {
  try {
    return JSON.parse(fs.readFileSync(statePath, 'utf8'));
  } catch {
    return {};
  }
}

function saveState(state) {
  fs.mkdirSync(root, { recursive: true });
  fs.writeFileSync(statePath, JSON.stringify(state, null, 2));
}

function readLocal(rel) {
  const full = safePath(rel);
  if (!full || !fs.existsSync(full)) return null;
  return fs.readFileSync(full, 'utf8');
}

function writeLocal(rel, content) {
  const full = safePath(rel);
  if (!full) return;
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, content, 'utf8');
}

async function syncOnce() {
  const state = loadState();
  const listing = await remoteJson('/api/memory/list');
  const files = Array.isArray(listing.files) ? listing.files : [];

  for (const file of files) {
    const rel = String(file?.path || '');
    if (!safePath(rel)) continue;

    const remote = await remoteJson(`/api/memory/read?path=${encodeURIComponent(rel)}`);
    const remoteContent = typeof remote.content === 'string' ? remote.content : '';
    const localContent = readLocal(rel);
    const lastRemote = state[rel];

    if (localContent !== null && lastRemote !== undefined && localContent !== lastRemote) {
      await remoteJson('/api/memory/write', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ path: rel, content: localContent }),
      });
      state[rel] = localContent;
      continue;
    }

    if (localContent !== remoteContent) {
      writeLocal(rel, remoteContent);
    }
    state[rel] = remoteContent;
  }

  saveState(state);
}

while (true) {
  try {
    await syncOnce();
  } catch (error) {
    console.error(`[memory-sync] ${error instanceof Error ? error.message : String(error)}`);
  }
  await sleep(Number(process.env.MEMORY_SYNC_INTERVAL_MS || 10000));
}
EOF

RUN cat > /usr/local/bin/hermes-workspace-entrypoint.sh <<'EOF'
#!/usr/bin/env sh
set -eu
export HERMES_HOME="${HERMES_HOME:-/tmp/.hermes}"
mkdir -p "$HERMES_HOME/memory" "$HERMES_HOME/memories"
node /usr/local/bin/hermes-memory-sync.mjs &
exec /usr/bin/tini -- "$@"
EOF

RUN chmod +x /usr/local/bin/hermes-workspace-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/hermes-workspace-entrypoint.sh"]
CMD ["node", "--max-old-space-size=2048", "server-entry.js"]
