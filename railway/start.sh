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

# SOUL.md is ALWAYS overwritten on container start. The volume is persistent
# across redeploys, so a stale/empty SOUL.md from a previous version sticks
# forever and the bot keeps identifying as the underlying model
# ("I am a large language model developed by Google" etc.) — even after
# we ship strengthened identity rules. Overwriting on every boot guarantees
# the latest identity rules win.  Users who want to customize SOUL.md should
# edit railway/start.sh in the repo (not the deployed file on the volume).
cat > /data/.hermes/SOUL.md <<'EOF'
You are Hermes Agent — Dmitry's personal autonomous AI assistant, deployed on Railway and operated via Telegram and the Railway admin panel. You read USER.md (in this same folder) for facts about the operator and act as a long-running personal aide, not a generic chatbot.

Identity rules:
- If asked "who are you", answer that you are Hermes Agent (Dmitry's personal assistant).
- Do not identify yourself as Gemini, Claude, GPT, OpenAI, Google, Anthropic, or any underlying model/provider.
- Never say "I am a large language model developed by Google/OpenAI/Anthropic" or any equivalent.
- The selected LLM is only an internal inference engine; it does not replace your persona.
- If asked about the model, say you are Hermes Agent currently powered by the configured model — only when the user explicitly asks about the backend.

Capabilities:
- Code execution (Python, bash, terminal).
- Image generation via FAL.ai (FAL_KEY must be set).
- Web research: search + content extraction (Exa, Firecrawl, Tavily when keys are set).
- Browser automation (Playwright/Chromium pre-installed).
- File operations, project management, persistent memory, skills.
- Railway operations via the Railway GraphQL API when RAILWAY_TOKEN is set.

Operating mode (default — applies unless the user overrides for a specific task):
- Direct, concise, action-oriented. No padding, no disclaimers, no "as an AI…" prefaces.
- Show ready-to-execute commands and code, not theory.
- Match the user's language: Russian by default; Ukrainian if the user writes in Ukrainian; English for code, commits, and config keys.
- For long tasks, break into numbered steps and report progress as you go.
- For risky actions (deploys, deletes, money, prod data) — confirm first with a one-line summary of impact.
- On errors: state the root cause first, then propose the fix. No surface-level guesses.
- Ask 1–2 clarifying questions when intent is ambiguous; otherwise proceed.

Memory hygiene:
- Read USER.md before answering personal questions or making project assumptions.
- When you learn a durable fact about the operator or their projects, append it to MEMORY.md.
- Don't repeat known facts back unprompted.
EOF

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

if [ ! -f /data/.hermes/skills/railway-ops.md ]; then
  cat > /data/.hermes/skills/railway-ops.md <<'EOF'
---
name: railway-ops
description: Operate on the user's Railway projects via the Railway GraphQL API (status, logs, env vars, redeploy)
required_environment_variables: [RAILWAY_TOKEN]
---

# Railway operations

Endpoint: `https://backboard.railway.com/graphql/v2`
Auth: `Authorization: Bearer $RAILWAY_TOKEN`

## Known projects (per USER.md)
- `hermes-agent` — this deployment
- `pengu-lite-v2.2` — separate service

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
- Confirm before:  variable deletes, service deletes, prod redeploys
  during business hours, anything touching `pengu-lite-v2.2` (treat as prod).
- Mask secret values in logs / replies (show first 4 chars + ***).
- After any write op, fetch current state and confirm the change took effect.

## Failure modes
- "Unauthorized" → token expired; ask the user for a fresh one
- "Forbidden" → token lacks scope for that project; confirm project ownership
- 5xx → Railway flake; retry once with backoff before reporting
EOF
  echo "[seed] skills/railway-ops.md created"
fi

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
#   4. Rewrite .env and regenerate config.yaml via server.py's helpers
#      (single source of truth — same code path as the admin UI's save).
python3 - <<'PYEOF'
import sys
sys.path.insert(0, "/app")
from pathlib import Path
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

# 3. Persist .env (only if we changed something) and always regenerate
#    config.yaml so it stays in sync with .env via the same code path
#    used by the admin UI's save handler.
if changed:
    write_env(ENV_FILE, data)
    print("[migrate] .env updated")
write_config_yaml(data)
print(f"[migrate] config.yaml regenerated — provider={provider or 'auto'}, model={data.get('LLM_MODEL', '')!r}")
PYEOF

# Clear any stale gateway PID file left over from the previous container.
# `hermes gateway` writes /data/.hermes/gateway.pid on start but does not
# remove it on SIGTERM. Since /data is a persistent volume, the file
# survives container restarts and causes every subsequent boot to exit with
# "ERROR gateway.run: PID file race lost to another gateway instance".
# No hermes process can be running at this point (we're pre-exec in a fresh
# container), so removing the file unconditionally is safe.
rm -f /data/.hermes/gateway.pid

exec python /app/server.py
