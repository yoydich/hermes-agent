#!/bin/bash
set -e

# Mirror dashboard-ref-only's startup: create every directory hermes expects
# and seed a default config.yaml if the volume is empty. Without these,
# `hermes dashboard` endpoints that hit logs/, sessions/, cron/, etc. can fail
# with opaque errors even though no auth is actually involved.
mkdir -p /data/.hermes/cron /data/.hermes/sessions /data/.hermes/logs \
         /data/.hermes/memories /data/.hermes/skills /data/.hermes/pairing \
         /data/.hermes/hooks /data/.hermes/image_cache /data/.hermes/audio_cache \
         /data/.hermes/workspace

if [ ! -f /data/.hermes/config.yaml ] && [ -f /opt/hermes-agent/cli-config.yaml.example ]; then
  cp /opt/hermes-agent/cli-config.yaml.example /data/.hermes/config.yaml
fi

[ ! -f /data/.hermes/.env ] && touch /data/.hermes/.env

# ── Sync secrets from Railway env vars ────────────────────────────────────────
# Railway injects environment variables directly into the container.  We write
# them into /data/.hermes/.env so that hermes's credential pool picks them up
# via the normal read_env() path.  This is the single source of truth — edit
# secrets in the Railway dashboard, NOT in the .env file on disk.
#
# Every variable listed here is written ONLY if it is set in the environment
# AND the current .env file does NOT already contain a non-empty value for it.
# This means: once a secret is set in .env (e.g. from a previous run), it
# won't be overwritten by an empty Railway var on a redeploy that omits it.
#
# To force a refresh: unset the variable in Railway (or set it to empty),
# redeploy, then set it again and redeploy once more.

_RAILWAY_ENV_VARS=(
  # LLM providers
  OPENROUTER_API_KEY
  DEEPSEEK_API_KEY
  DASHSCOPE_API_KEY
  GLM_API_KEY
  KIMI_API_KEY
  MINIMAX_API_KEY
  HF_TOKEN
  NVIDIA_API_KEY
  ARCEE_API_KEY
  STEPFUN_API_KEY
  AI_GATEWAY_API_KEY
  GEMINI_API_KEY
  GROQ_API_KEY
  GOOGLE_API_KEY
  KIMI_CN_API_KEY
  # Tools
  FAL_KEY
  GITHUB_TOKEN
  GH_TOKEN
  RAILWAY_TOKEN
  TELEGRAM_BOT_TOKEN
  TELEGRAM_ALLOWED_USERS
  TELEGRAM_HOME_CHANNEL
  EMAIL_ADDRESS
  EMAIL_PASSWORD
  # Gateway
  GATEWAY_ALLOW_ALL_USERS
  HERMES_DASHBOARD_PORT
  API_SERVER_PORT
  BASH_ENV
)

# Read current .env into a temp file, merge Railway vars, write back.
python3 - <<'PYEOF'
import os
from pathlib import Path

env_file = Path("/data/.hermes/.env")
railway_vars = [
    "OPENROUTER_API_KEY", "DEEPSEEK_API_KEY", "DASHSCOPE_API_KEY",
    "GLM_API_KEY", "KIMI_API_KEY", "MINIMAX_API_KEY", "HF_TOKEN",
    "NVIDIA_API_KEY", "ARCEE_API_KEY", "STEPFUN_API_KEY",
    "AI_GATEWAY_API_KEY", "GEMINI_API_KEY", "GROQ_API_KEY",
    "GOOGLE_API_KEY", "KIMI_CN_API_KEY",
    "FAL_KEY", "GITHUB_TOKEN", "GH_TOKEN", "RAILWAY_TOKEN",
    "TELEGRAM_BOT_TOKEN", "TELEGRAM_ALLOWED_USERS", "TELEGRAM_HOME_CHANNEL",
    "EMAIL_ADDRESS", "EMAIL_PASSWORD",
    "GATEWAY_ALLOW_ALL_USERS", "HERMES_DASHBOARD_PORT", "API_SERVER_PORT",
    "BASH_ENV",
]

# Read existing .env
existing = {}
if env_file.exists():
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        v = v.strip().strip('"').strip("'")
        existing[k.strip()] = v

# Merge: Railway env var wins if non-empty AND existing is empty/missing
changed = False
for var in railway_vars:
    railway_val = os.environ.get(var, "").strip()
    if not railway_val:
        continue  # Railway doesn't have it — skip
    current = existing.get(var, "")
    if current:
        # Already set in .env — don't overwrite (user may have edited manually)
        continue
    existing[var] = railway_val
    changed = True
    print(f"[env-sync] {var} written from Railway")

# Write back
lines = []
for k, v in existing.items():
    # Quote values that contain spaces or special chars
    if " " in v or any(c in v for c in "'\"#$"):
        v = f'"{v}"'
    lines.append(f"{k}={v}")
env_file.write_text("\n".join(lines) + "\n")
if changed:
    print(f"[env-sync] {env_file} updated with Railway secrets")
else:
    print(f"[env-sync] {env_file} already in sync")
PYEOF

# SOUL.md and AGENTS.md are ALWAYS overwritten on container start from the
# repo (docker/SOUL.md, AGENTS.md). The volume is persistent across
# redeploys, so a stale copy from an older deployment would otherwise stick
# forever — overwriting on every boot guarantees the version committed to
# the fork (yoydich/hermes-agent) wins. To customize, edit the file in the
# repo and push; the next Railway build will pick it up.
HERMES_SRC=/opt/hermes-agent

if [ -f "$HERMES_SRC/docker/SOUL.md" ]; then
    cp "$HERMES_SRC/docker/SOUL.md" /data/.hermes/SOUL.md
    echo "[seed] SOUL.md synced from repo (docker/SOUL.md)"
else
    echo "[seed] WARN: $HERMES_SRC/docker/SOUL.md missing — SOUL.md left as-is"
fi

# AGENTS.md → /data/.hermes/AGENTS.md (visible in dashboard Files tab) AND
# /tmp/AGENTS.md (the terminal CWD where the agent process looks for it
# via context-file resolution). Copying to both keeps the dashboard and
# the runtime agent in sync.
if [ -f "$HERMES_SRC/AGENTS.md" ]; then
    cp "$HERMES_SRC/AGENTS.md" /data/.hermes/AGENTS.md
    mkdir -p /tmp && cp "$HERMES_SRC/AGENTS.md" /tmp/AGENTS.md
    echo "[seed] AGENTS.md synced from repo to /data/.hermes/ and /tmp/"
else
    echo "[seed] WARN: $HERMES_SRC/AGENTS.md missing — AGENTS.md left as-is"
fi

# ── First-run seeding ────────────────────────────────────────────────────────
# These files seed personal context, durable memory, and starter skills on
# the first container boot.  Each is created ONLY if it doesn't already
# exist — that way the user's own edits (via the dashboard or shell) are
# never clobbered by later redeploys.  To force a refresh, delete the file
# from the volume and let the next start re-seed it.

if [ ! -f /data/.hermes/USER.md ]; then
  cat > /data/.hermes/USER.md <<'EOF'
# About the Operator

## Identity
- Name: Dmitry (yoydich on GitHub)
- Primary languages: Russian (default), Ukrainian (sometimes)
- Code/commits/config: English

## Active projects
- **hermes-agent** (this deployment) — personal AI assistant on Railway, this repo: github.com/yoydich/hermes-agent
- **pengu-lite-v2.2** — separate Railway service

## Tech stack & preferences
- Cloud: Railway-first (Docker, GitHub auto-deploy, persistent Volumes)
- Local OS: Windows; primary working dir for hermes repo: `D:\Claude Code\hermes-agent`
- Tooling: Claude Code, GitHub, Railway GraphQL API
- Models: experimenting across DeepSeek / Gemini / OpenRouter; image gen via FAL.ai

## Working style (the operator prefers)
- Direct answers with ready-to-run commands; minimal theory
- No disclaimers, no "as an AI…", no apologies for limitations
- For multi-step tasks: numbered plan first, then execute and report progress
- For risky ops (deploy, delete, money, prod data): one-line impact summary, then confirm
- When uncertain: ask 1–2 specific clarifying questions instead of assuming

## Communication channels
- Telegram (primary chat interface)
- Railway admin dashboard (config, logs, model switching)
- This file lives at /data/.hermes/USER.md — edit it via the dashboard's
  Files tab any time. Reseeding only happens if you delete it.
EOF
  echo "[seed] USER.md created"
fi

if [ ! -f /data/.hermes/MEMORY.md ]; then
  cat > /data/.hermes/MEMORY.md <<'EOF'
# Durable Memory

This file is the agent's persistent notebook across sessions.  Append
new durable facts here when you learn them — project decisions, recurring
issues, configurations that worked, links worth keeping.

Format: one fact per bullet, dated when context matters.

## Facts
- (none yet)

## Decisions
- (none yet)

## Useful links
- Hermes docs: https://hermes-agent.nousresearch.com/docs
- This repo: https://github.com/yoydich/hermes-agent
EOF
  echo "[seed] MEMORY.md created"
fi

# ── Starter skills ───────────────────────────────────────────────────────────
# Skills are markdown files with YAML frontmatter that the agent loads
# on demand (skill_view tool).  These two cover the user's stated focus
# areas: web research and Railway operations.

if [ ! -f /data/.hermes/skills/web-research.md ]; then
  cat > /data/.hermes/skills/web-research.md <<'EOF'
---
name: web-research
description: Research a topic using Exa search + Firecrawl/web_extract for full content, then summarize with sources
required_environment_variables: [EXA_API_KEY]
---

# Web research workflow

When the user asks to research a topic, follow this pattern:

1. **Search** — use `web_search` (Exa-powered) with 5–10 results.
   Prefer recent content; pass `recency` if the topic is time-sensitive.

2. **Triage** — pick the 3–5 most authoritative / on-topic results.
   Skip low-quality SEO pages, stale forum threads, paywalled stubs.

3. **Extract full content** — for each chosen result, use `web_extract`
   (Firecrawl when FIRECRAWL_API_KEY is set, otherwise the built-in
   fetcher).  Don't rely on search snippets — they're often misleading.

4. **Synthesize** — write a structured summary:
   - **TL;DR** (2–3 lines)
   - **Key findings** (bulleted, each with [source N] reference)
   - **Disagreements / open questions**
   - **Sources** (numbered list with title + URL)

5. **Persist** (when the user asks, or topic is significant):
   write the summary to `memories/research-<slug>.md` so it survives
   the session and can be cited later.

Quality bar: every claim should be traceable to a source.  If sources
disagree, say so explicitly — don't average them.
EOF
  echo "[seed] skills/web-research.md created"
fi

# Keep this skill synchronized with the deployment because it contains
# project IDs and token-scope guidance the agent needs for Railway ops.
cat > /data/.hermes/skills/railway-ops.md <<'EOF'
---
name: railway-ops
description: Operate on Railway projects via Railway CLI or GraphQL API; distinguish project IDs from access tokens
required_environment_variables: [RAILWAY_TOKEN]
---

# Railway operations

## Credentials and project scope

`RAILWAY_TOKEN` is an access token, not a project id. A Railway project URL such
as `https://railway.com/project/<project_id>` only identifies the target
project; it does not grant access.

Before operating on a project, verify the token can see it:

```bash
RAILWAY_TOKEN="$RAILWAY_TOKEN" railway link --project <project_id> --environment production --service <service_name>
```

If this returns `Unauthorized`, do not keep retrying. The token is valid for
some Railway account/project, but it does not have access to that project. Ask
the operator for a token from the Railway account/team that owns `<project_id>`.

Current known access:
- Token currently configured in this deployment can operate the Hermes project
  `38d7b20d-c9a4-4d1b-8c25-179c7b65d94f` (`hermes-agent`).
- A previous check against project `2e55b27a-b1d6-4f53-a31f-50a1a7cdc478`
  returned `Unauthorized`; treat it as a different/inaccessible project until
  a fresh token is provided.

Endpoint: `https://backboard.railway.com/graphql/v2`
Auth: `Authorization: Bearer $RAILWAY_TOKEN`

## Known projects
- `hermes-agent` - this deployment. Project id:
  `38d7b20d-c9a4-4d1b-8c25-179c7b65d94f`
  - service `hermes-agent`: `e44f8be5-4379-4a69-9873-66ecd311032f`
  - environment `production`: `4f7c4722-a82e-44ca-b461-14dd09bc46ce`
- `confident-creativity` - Hermes Workspace service in the Hermes project.
  - service id: `18dd544e-a2ea-479f-94bd-4769bdf3cdb8`
  - public URL: `https://confident-creativity-production-8b68.up.railway.app`
- `pengu-lite-v2.2` - separate service/project. Verify access before touching.

## Common ops

### Get project + service IDs
```graphql
query { me { projects { edges { node { id name services { edges { node { id name } } } } } } } }
```

### Get latest deployment status
```graphql
query($serviceId: String!) {
  deployments(input: {serviceId: $serviceId}, first: 5) {
    edges { node { id status createdAt url } }
  }
}
```

### Read service logs
```graphql
query($deploymentId: String!) {
  deploymentLogs(deploymentId: $deploymentId, limit: 200) {
    timestamp message severity
  }
}
```

### Set / update an env variable
```graphql
mutation($input: VariableUpsertInput!) { variableUpsert(input: $input) }
# input: { projectId, environmentId, serviceId, name, value }
```

### Trigger redeploy
```graphql
mutation($serviceId: String!, $environmentId: String!) {
  serviceInstanceRedeploy(serviceId: $serviceId, environmentId: $environmentId)
}
```

## Safety rules
- Confirm before: variable deletes, service deletes, prod redeploys during busy hours, and anything touching `pengu-lite-v2.2`.
- Mask secret values in logs / replies (show first 4 chars + ***).
- After any write op, fetch current state and confirm the change took effect.

## Failure modes
- `Unauthorized` when linking/querying a specific project means the token lacks access to that project, or expired. Report the exact project id and ask for a token with access to it.
- `Forbidden` means the token is recognized but lacks scope for the operation.
- 5xx means Railway flake; retry once with backoff before reporting.
EOF
echo "[seed] skills/railway-ops.md synced"
# Migrate existing .env + config.yaml so the bbb9a8c provider fix takes
# effect on volumes that pre-date it. Without this, an old volume keeps
# `provider: "auto"` in config.yaml AND lacks `LLM_PROVIDER` in .env, so
# hermes's auto-detect picks whichever API key is present (often Gemini)
# and routes a non-Gemini model name (e.g. models/deepseek-v4-flash) to
# the Gemini API → HTTP 404 NOT_FOUND.
#
# What this does on every container start:
#   1. Read /data/.hermes/.env
#   2. If LLM_PROVIDER is missing, infer it from whichever provider API
#      key is set (DEEPSEEK_API_KEY → "deepseek", etc.)
#   3. Normalize LLM_MODEL for direct providers (strip "models/" and
#      "<provider>/" prefixes that the old UI used to suggest).
#   4. Patch config.yaml only when migration changed values or the file is
#      missing. Do not regenerate it on every boot: dashboard users edit this
#      file directly, and unconditional rewrites truncate their settings.
python3 - <<'PYEOF'
import sys
sys.path.insert(0, "/app")
from pathlib import Path
import yaml
from server import (
    read_env, write_env, write_config_yaml,
    ENV_FILE, PROVIDER_KEYS, PROVIDER_KEY_TO_ID,
)

data = read_env(ENV_FILE)
changed = False

# 1. Infer LLM_PROVIDER from which provider API key is set.
if not data.get("LLM_PROVIDER"):
    for key in PROVIDER_KEYS:
        if data.get(key):
            data["LLM_PROVIDER"] = PROVIDER_KEY_TO_ID.get(key, "auto")
            changed = True
            print(f"[migrate] LLM_PROVIDER not set — inferred '{data['LLM_PROVIDER']}' from {key}")
            break

# 2. Normalize LLM_MODEL for direct providers (Gemini, DeepSeek, etc.).
provider = (data.get("LLM_PROVIDER") or "").strip()
model = (data.get("LLM_MODEL") or "").strip()
DIRECT_PROVIDERS = {"deepseek", "gemini", "zai", "dashscope", "minimax",
                    "nvidia", "arcee", "stepfun", "kimi-coding"}
if provider in DIRECT_PROVIDERS and model:
    original = model
    if model.startswith("models/"):
        model = model.split("/", 1)[1]
    if model.startswith(provider + "/"):
        model = model[len(provider) + 1:]
    if provider == "deepseek" and model.startswith("deepseek/"):
        model = model.split("/", 1)[1]
    if model != original:
        data["LLM_MODEL"] = model
        changed = True
        print(f"[migrate] LLM_MODEL normalized: {original!r} → {model!r}")

# 3. Persist .env if needed. Patch config.yaml only when we performed a
#    migration or the file is missing/invalid, so dashboard edits persist.
if changed:
    write_env(ENV_FILE, data)
    print("[migrate] .env updated")

config_path = Path("/data/.hermes/config.yaml")
needs_config_patch = changed or not config_path.exists()
if config_path.exists() and not needs_config_patch:
    try:
        cfg = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
        if not isinstance(cfg, dict):
            needs_config_patch = True
        else:
            model_cfg = cfg.get("model")
            if not model_cfg:
                needs_config_patch = True
    except Exception:
        needs_config_patch = True

if needs_config_patch:
    write_config_yaml(data)
    print(f"[migrate] config.yaml patched — provider={provider or 'auto'}, model={data.get('LLM_MODEL', '')!r}")
else:
    print("[migrate] config.yaml left unchanged")
PYEOF

# ── Volume cleanup ────────────────────────────────────────────────────────────
# image_cache and audio_cache grow unbounded — delete files older than 30 days.
find /data/.hermes/image_cache -type f -mtime +30 -delete 2>/dev/null || true
find /data/.hermes/audio_cache -type f -mtime +30 -delete 2>/dev/null || true

# Curator writes one run.json per cycle; keep only the 20 most recent to cap growth.
curator_reports=(/data/.hermes/logs/curator/run_*.json)
if [ ${#curator_reports[@]} -gt 20 ]; then
  ls -t /data/.hermes/logs/curator/run_*.json 2>/dev/null | tail -n +21 | xargs rm -f
fi

# Checkpoint the SQLite WAL so reclaimed session space is released back to the OS.
python3 - <<'PYEOF'
import sqlite3, pathlib
db = pathlib.Path("/data/.hermes/state.db")
if db.exists():
    try:
        conn = sqlite3.connect(str(db), timeout=10)
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        conn.close()
        print("[cleanup] state.db WAL checkpoint done")
    except Exception as e:
        print(f"[cleanup] WAL checkpoint skipped: {e}")
PYEOF

echo "[cleanup] volume pruned: image_cache/audio_cache (>30d), curator logs (>20), WAL checkpoint"

# Clear any stale gateway PID file left over from the previous container.
# `hermes gateway` writes /data/.hermes/gateway.pid on start but does not
# remove it on SIGTERM. Since /data is a persistent volume, the file
# survives container restarts and causes every subsequent boot to exit with
# "ERROR gateway.run: PID file race lost to another gateway instance".
# No hermes process can be running at this point (we're pre-exec in a fresh
# container), so removing the file unconditionally is safe.
rm -f /data/.hermes/gateway.pid

# ── Grid Bot auto-start ───────────────────────────────────────────────────────
# Call the persistent startup script (lives on /data volume, survives deploys).
if [ -f /data/start_grid_bot.sh ]; then
  bash /data/start_grid_bot.sh
fi


exec python /app/server.py
