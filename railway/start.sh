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

# Keep dependency/download caches out of the persistent Railway volume.
# /data should hold durable Hermes state only; package caches can be rebuilt.
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/.cache}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-/tmp/.cache/pip}"
export npm_config_cache="${npm_config_cache:-/tmp/.npm}"
export npm_config_store_dir="${npm_config_store_dir:-/tmp/.local/share/pnpm/store}"
export PNPM_HOME="${PNPM_HOME:-/tmp/.local/share/pnpm}"
export PNPM_STORE_DIR="${PNPM_STORE_DIR:-/tmp/.local/share/pnpm/store}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/.cache/uv}"
export ELECTRON_CACHE="${ELECTRON_CACHE:-/tmp/.cache/electron}"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/tmp/.cache/ms-playwright}"
mkdir -p "$XDG_CACHE_HOME" "$PIP_CACHE_DIR" "$npm_config_cache" \
         "$npm_config_store_dir" "$PNPM_HOME" "$PNPM_STORE_DIR" "$UV_CACHE_DIR" \
         "$ELECTRON_CACHE" "$PLAYWRIGHT_BROWSERS_PATH"

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
  RAILWAY_API_TOKEN
  RAILWAY_PENGU_TOKEN
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
    "FAL_KEY", "GITHUB_TOKEN", "GH_TOKEN", "RAILWAY_TOKEN", "RAILWAY_API_TOKEN",
    "RAILWAY_PENGU_TOKEN",
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

if [ -z "${RAILWAY_TOKEN:-}" ] || [ -z "${RAILWAY_API_TOKEN:-}" ] || [ -z "${RAILWAY_PENGU_TOKEN:-}" ]; then
  _railway_tokens_from_env_file="$(python3 - <<'PYEOF'
from pathlib import Path
env = Path("/data/.hermes/.env")
values = {"RAILWAY_TOKEN": "", "RAILWAY_API_TOKEN": "", "RAILWAY_PENGU_TOKEN": ""}
if env.exists():
    for line in env.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, raw = line.partition("=")
        key = key.strip()
        if key in values:
            values[key] = raw.strip().strip('"').strip("'")
for key, value in values.items():
    if value:
        print(f"{key}={value}")
PYEOF
)"
  while IFS='=' read -r _railway_key _railway_value; do
    case "$_railway_key" in
      RAILWAY_TOKEN)
        if [ -z "${RAILWAY_TOKEN:-}" ] && [ -n "$_railway_value" ]; then
          export RAILWAY_TOKEN="$_railway_value"
          echo "[env-sync] RAILWAY_TOKEN exported from /data/.hermes/.env"
        fi
        ;;
      RAILWAY_API_TOKEN)
        if [ -z "${RAILWAY_API_TOKEN:-}" ] && [ -n "$_railway_value" ]; then
          export RAILWAY_API_TOKEN="$_railway_value"
          echo "[env-sync] RAILWAY_API_TOKEN exported from /data/.hermes/.env"
        fi
        ;;
      RAILWAY_PENGU_TOKEN)
        if [ -z "${RAILWAY_PENGU_TOKEN:-}" ] && [ -n "$_railway_value" ]; then
          export RAILWAY_PENGU_TOKEN="$_railway_value"
          echo "[env-sync] RAILWAY_PENGU_TOKEN exported from /data/.hermes/.env"
        fi
        ;;
    esac
  done <<EOF
$_railway_tokens_from_env_file
EOF
  unset _railway_key _railway_value _railway_tokens_from_env_file
fi

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
rm -rf /data/.hermes/skills/railway-ops.md \
       /data/.hermes/skills/railway-ops-v2.md \
       /data/.hermes/skills/railway-ops-v2 \
       /data/.hermes/skills/devops/railway-ops-v2
mkdir -p /data/.hermes/skills/devops/railway-ops/scripts
cat > /data/.hermes/skills/devops/railway-ops/SKILL.md <<'EOF'
---
name: railway-ops
description: Operate Railway projects from Hermes; use CLI only for Hermes project token and GraphQL Project-Access-Token for project-scoped tokens like hearty-truth
required_environment_variables: [RAILWAY_TOKEN, RAILWAY_PENGU_TOKEN]
---

# Railway operations

## Non-negotiable facts

- The `hearty-truth` project is project id `2e55b27a-b1d6-4f53-a31f-50a1a7cdc478`.
- Its environment id is `95f33876-ab3b-4307-a346-97ed1a50ef11`.
- Its token is available as `RAILWAY_PENGU_TOKEN`.
- Helper script for logs/deployments:
  `/data/.hermes/skills/devops/railway-ops/scripts/hearty_truth.py`
- The token was verified with Railway GraphQL:
  `query { projectToken { projectId environmentId } }`
  using header `Project-Access-Token: $RAILWAY_PENGU_TOKEN`.
- Railway CLI 4.58.0 in this container accepts the Hermes project token for
  the Hermes project, but returned `Unauthorized` for `variable list` and
  `logs` when called with `RAILWAY_PENGU_TOKEN`. For project-scoped tokens,
  prefer Railway GraphQL with `Project-Access-Token`.
- Do not conclude "Railway is unavailable" just because `railway whoami`,
  `railway link`, or `railway logs` fails with a project token. Those commands
  are not a valid universal test for project-scoped tokens.

## Credentials and project scope

`RAILWAY_TOKEN` is an access token, not a project id. A Railway project URL such
as `https://railway.com/project/<project_id>` only identifies the target
project; it does not grant access.

Railway has two token modes:
- Project token: store as `RAILWAY_TOKEN`. It is scoped to one project
  environment. Use it for project-level CLI commands (`railway variable`,
  `railway logs`, `railway up`, etc.). Do not use `railway whoami` to test it.
- Account/workspace token: store as `RAILWAY_API_TOKEN`. Use it for
  account/workspace CLI commands (`railway whoami`, `railway project list`) and
GraphQL with `Authorization: Bearer`.
- Extra project tokens can be stored under named vars. This deployment uses
  `RAILWAY_PENGU_TOKEN` for project `2e55b27a-b1d6-4f53-a31f-50a1a7cdc478`.

Before operating on the current Hermes project with `RAILWAY_TOKEN`, verify CLI
access with a project-scoped command:

```bash
command -v railway
printf '%s\n' "${RAILWAY_TOKEN:+RAILWAY_TOKEN=set}"
railway variable list --service <service_name> --environment production
```

For `hearty-truth`, verify token access through GraphQL instead:

```bash
curl -sS https://backboard.railway.com/graphql/v2 \
  -H "Content-Type: application/json" \
  -H "Project-Access-Token: $RAILWAY_PENGU_TOKEN" \
  --data '{"query":"query { projectToken { projectId environmentId } }"}'
```

Do not run `railway login` in this container.

If a project-scoped command returns `Unauthorized`, do not keep retrying. The
token is valid for some Railway account/project, but it does not have access to
that project/environment. Ask the operator for a project token created inside
that Railway project/environment.

Current known access:
- Token currently configured in this deployment can operate the Hermes project
  `38d7b20d-c9a4-4d1b-8c25-179c7b65d94f` (`hermes-agent`).
- A previous check against project `2e55b27a-b1d6-4f53-a31f-50a1a7cdc478`
  returned `Unauthorized`; treat it as a different/inaccessible project until
  a fresh token is provided.

Endpoint: `https://backboard.railway.com/graphql/v2`
Auth:
- Account/workspace/OAuth token: `Authorization: Bearer $RAILWAY_API_TOKEN`
- Project token: `Project-Access-Token: $RAILWAY_TOKEN`
- Pengu project token: `Project-Access-Token: $RAILWAY_PENGU_TOKEN`

## Known projects
- `hermes-agent` - this deployment. Project id:
  `38d7b20d-c9a4-4d1b-8c25-179c7b65d94f`
  - service `hermes-agent`: `e44f8be5-4379-4a69-9873-66ecd311032f`
  - environment `production`: `4f7c4722-a82e-44ca-b461-14dd09bc46ce`
- `confident-creativity` - Hermes Workspace service in the Hermes project.
  - service id: `18dd544e-a2ea-479f-94bd-4769bdf3cdb8`
  - public URL: `https://confident-creativity-production-8b68.up.railway.app`
- `hearty-truth` / `pengu-lite-v2.2` - separate project. Verify target service before touching.
  - project id: `2e55b27a-b1d6-4f53-a31f-50a1a7cdc478`
  - environment id: `95f33876-ab3b-4307-a346-97ed1a50ef11`
  - token env var in Hermes: `RAILWAY_PENGU_TOKEN`
  - for Railway CLI commands, prefix with:
    `RAILWAY_TOKEN="$RAILWAY_PENGU_TOKEN" railway <command> ...`

## Common ops

### Preferred helper script

Use this instead of hand-writing curl:

```bash
python /data/.hermes/skills/devops/railway-ops/scripts/hearty_truth.py services
python /data/.hermes/skills/devops/railway-ops/scripts/hearty_truth.py deployments --limit 10
python /data/.hermes/skills/devops/railway-ops/scripts/hearty_truth.py logs --limit 80
python /data/.hermes/skills/devops/railway-ops/scripts/hearty_truth.py build-logs --limit 80
```

Deploy/redeploy commands are production-affecting. Only run them after the
operator explicitly asks for deploy/redeploy:

```bash
python /data/.hermes/skills/devops/railway-ops/scripts/hearty_truth.py redeploy-service --yes
python /data/.hermes/skills/devops/railway-ops/scripts/hearty_truth.py redeploy-deployment --deployment-id <deployment_id> --yes
```

### Verify hearty-truth token

```graphql
query {
  projectToken {
    projectId
    environmentId
  }
}
```

HTTP header: `Project-Access-Token: $RAILWAY_PENGU_TOKEN`.

Expected:
- `projectId`: `2e55b27a-b1d6-4f53-a31f-50a1a7cdc478`
- `environmentId`: `95f33876-ab3b-4307-a346-97ed1a50ef11`

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
- `railway whoami` failing with `RAILWAY_TOKEN` does not prove the project token is invalid; use `RAILWAY_API_TOKEN` for `whoami`, or test token scope with GraphQL `projectToken`.
- `railway variable list` / `railway logs` returning `Unauthorized` with `RAILWAY_PENGU_TOKEN` does not prove the token is invalid; use GraphQL with `Project-Access-Token`.
- `Unauthorized` from GraphQL `projectToken` means the token is invalid/expired or not a Railway project token.
- `Forbidden` means the token is recognized but lacks scope for the operation.
- 5xx means Railway flake; retry once with backoff before reporting.
EOF
echo "[seed] skills/devops/railway-ops/SKILL.md synced"

cat > /data/.hermes/skills/devops/railway-ops/scripts/hearty_truth.py <<'PYEOF'
#!/usr/bin/env python3
"""Railway GraphQL helper for hearty-truth / pengu-bot-v2.

Uses Project-Access-Token, because Railway CLI 4.58.0 is unreliable for this
project-scoped token in the Hermes container.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request

ENDPOINT = "https://backboard.railway.com/graphql/v2"
PROJECT_ID = "2e55b27a-b1d6-4f53-a31f-50a1a7cdc478"
ENVIRONMENT_ID = "95f33876-ab3b-4307-a346-97ed1a50ef11"
SERVICE_ID = "5df3ff90-3642-4d3e-ba08-9aa47c10b6e1"
SERVICE_NAME = "pengu-bot-v2"


def token() -> str:
    value = os.environ.get("RAILWAY_PENGU_TOKEN") or os.environ.get("RAILWAY_TOKEN") or ""
    if not value.strip():
        raise SystemExit("RAILWAY_PENGU_TOKEN is not set")
    return value.strip()


def gql(query: str, variables: dict | None = None) -> dict:
    body = json.dumps({"query": query, "variables": variables or {}}).encode("utf-8")
    req = urllib.request.Request(
        ENDPOINT,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Project-Access-Token": token(),
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=45) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        text = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"Railway HTTP {exc.code}: {text}") from exc
    if data.get("errors"):
        raise SystemExit(json.dumps(data["errors"], indent=2, ensure_ascii=False))
    return data["data"]


def print_json(data: object) -> None:
    print(json.dumps(data, indent=2, ensure_ascii=False))


def latest_deployment_id() -> str:
    data = gql(
        """
        query($input: DeploymentListInput!, $first: Int) {
          deployments(input: $input, first: $first) {
            edges { node { id status createdAt serviceId url } }
          }
        }
        """,
        {"input": {"projectId": PROJECT_ID, "environmentId": ENVIRONMENT_ID, "serviceId": SERVICE_ID}, "first": 1},
    )
    edges = data["deployments"]["edges"]
    if not edges:
        raise SystemExit("No deployments found")
    return edges[0]["node"]["id"]


def cmd_verify(_: argparse.Namespace) -> None:
    print_json(gql("query { projectToken { projectId environmentId } }"))


def cmd_services(_: argparse.Namespace) -> None:
    print_json(gql(
        """
        query($projectId: String!) {
          project(id: $projectId) {
            id
            name
            services { edges { node { id name } } }
          }
        }
        """,
        {"projectId": PROJECT_ID},
    ))


def cmd_deployments(args: argparse.Namespace) -> None:
    print_json(gql(
        """
        query($input: DeploymentListInput!, $first: Int) {
          deployments(input: $input, first: $first) {
            edges { node { id status createdAt serviceId url } }
          }
        }
        """,
        {
            "input": {"projectId": PROJECT_ID, "environmentId": ENVIRONMENT_ID, "serviceId": SERVICE_ID},
            "first": args.limit,
        },
    ))


def _logs(kind: str, args: argparse.Namespace) -> None:
    deployment_id = args.deployment_id or latest_deployment_id()
    field = "buildLogs" if kind == "build" else "deploymentLogs"
    print_json(gql(
        f"""
        query($deploymentId: String!, $limit: Int, $filter: String) {{
          {field}(deploymentId: $deploymentId, limit: $limit, filter: $filter) {{
            timestamp
            severity
            message
          }}
        }}
        """,
        {"deploymentId": deployment_id, "limit": args.limit, "filter": args.filter},
    ))


def cmd_logs(args: argparse.Namespace) -> None:
    _logs("runtime", args)


def cmd_build_logs(args: argparse.Namespace) -> None:
    _logs("build", args)


def _require_yes(args: argparse.Namespace) -> None:
    if not args.yes:
        raise SystemExit("Refusing production deploy without --yes")


def cmd_redeploy_service(args: argparse.Namespace) -> None:
    _require_yes(args)
    print_json(gql(
        """
        mutation($serviceId: String!, $environmentId: String!) {
          serviceInstanceRedeploy(serviceId: $serviceId, environmentId: $environmentId)
        }
        """,
        {"serviceId": SERVICE_ID, "environmentId": ENVIRONMENT_ID},
    ))


def cmd_redeploy_deployment(args: argparse.Namespace) -> None:
    _require_yes(args)
    deployment_id = args.deployment_id or latest_deployment_id()
    print_json(gql(
        """
        mutation($id: String!, $usePreviousImageTag: Boolean) {
          deploymentRedeploy(id: $id, usePreviousImageTag: $usePreviousImageTag)
        }
        """,
        {"id": deployment_id, "usePreviousImageTag": args.use_previous_image_tag},
    ))


def main() -> None:
    parser = argparse.ArgumentParser(description=f"Railway helper for {SERVICE_NAME}")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("verify").set_defaults(func=cmd_verify)
    sub.add_parser("services").set_defaults(func=cmd_services)
    p = sub.add_parser("deployments")
    p.add_argument("--limit", type=int, default=10)
    p.set_defaults(func=cmd_deployments)
    for name, func in (("logs", cmd_logs), ("build-logs", cmd_build_logs)):
        p = sub.add_parser(name)
        p.add_argument("--deployment-id", default="")
        p.add_argument("--limit", type=int, default=100)
        p.add_argument("--filter", default=None)
        p.set_defaults(func=func)
    p = sub.add_parser("redeploy-service")
    p.add_argument("--yes", action="store_true")
    p.set_defaults(func=cmd_redeploy_service)
    p = sub.add_parser("redeploy-deployment")
    p.add_argument("--deployment-id", default="")
    p.add_argument("--use-previous-image-tag", action="store_true")
    p.add_argument("--yes", action="store_true")
    p.set_defaults(func=cmd_redeploy_deployment)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
PYEOF
chmod +x /data/.hermes/skills/devops/railway-ops/scripts/hearty_truth.py
echo "[seed] skills/devops/railway-ops/scripts/hearty_truth.py synced"
# Migrate existing .env + config.yaml to the current Hermes contract:
# .env stores secrets only; model/provider live in config.yaml. Older Railway
# setup versions wrote LLM_MODEL / LLM_PROVIDER into /data/.hermes/.env, so we
# move those values into config.yaml and remove the legacy .env keys.
#
# What this does on every container start:
#   1. Read /data/.hermes/.env
#   2. Seed config.yaml from legacy LLM_* keys only when config is missing.
#   3. Remove LLM_MODEL / LLM_PROVIDER from .env.
#   4. Leave existing config.yaml model choices untouched.
python3 - <<'PYEOF'
import sys
sys.path.insert(0, "/app")
from pathlib import Path
import yaml
from server import (
    read_env, write_env, write_config_yaml, read_model_config, normalize_model_id,
    ENV_FILE, PROVIDER_KEYS, PROVIDER_KEY_TO_ID,
)

data = read_env(ENV_FILE)
changed = False


def ensure_railway_token_passthrough(config_path: Path) -> bool:
    """Allow Hermes terminal commands to see Railway tokens.

    Hermes intentionally strips secrets from terminal subprocesses unless a
    skill registers them or config.yaml explicitly allows them. Railway ops are
    deployment-admin tasks for this image, so keep the token available to the
    terminal without depending on whether the model remembered to call
    skill_view first.
    """
    cfg = {}
    if config_path.exists():
        loaded = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
        if isinstance(loaded, dict):
            cfg = loaded
    terminal = cfg.get("terminal")
    if not isinstance(terminal, dict):
        terminal = {}
    passthrough = terminal.get("env_passthrough")
    if not isinstance(passthrough, list):
        passthrough = []
    changed = False
    for name in ("RAILWAY_TOKEN", "RAILWAY_API_TOKEN", "RAILWAY_PENGU_TOKEN"):
        if name not in passthrough:
            passthrough.append(name)
            changed = True
    if not changed:
        return False
    terminal["env_passthrough"] = passthrough
    cfg["terminal"] = terminal
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(yaml.safe_dump(cfg, sort_keys=False, allow_unicode=True), encoding="utf-8")
    return True


def ensure_railway_session_stability(config_path: Path) -> list[str]:
    """Disable Railway-specific session killers in the persistent config.

    Hermes has explicit /reset and /stop commands. On Railway, implicit idle
    resets and inactivity timeouts are a bad default because long hosted turns
    can look like a dead session from Telegram/dashboard. Keep the config
    stable across redeploys unless a user later edits it intentionally.
    """
    cfg = {}
    if config_path.exists():
        loaded = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
        if isinstance(loaded, dict):
            cfg = loaded

    changes: list[str] = []

    session_reset = cfg.get("session_reset")
    if not isinstance(session_reset, dict):
        session_reset = {}
    if session_reset.get("mode") != "none":
        session_reset["mode"] = "none"
        changes.append("session_reset.mode=none")
    session_reset.setdefault("idle_minutes", 10080)
    session_reset.setdefault("at_hour", 4)
    cfg["session_reset"] = session_reset

    agent = cfg.get("agent")
    if not isinstance(agent, dict):
        agent = {}
    if agent.get("gateway_timeout") != 0:
        agent["gateway_timeout"] = 0
        changes.append("agent.gateway_timeout=0")
    if agent.get("gateway_timeout_warning") != 0:
        agent["gateway_timeout_warning"] = 0
        changes.append("agent.gateway_timeout_warning=0")
    agent.setdefault("max_iterations", 50)
    cfg["agent"] = agent

    if changes:
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_path.write_text(
            yaml.safe_dump(cfg, sort_keys=False, allow_unicode=True),
            encoding="utf-8",
        )
    return changes

config_path = Path("/data/.hermes/config.yaml")
model_cfg = read_model_config()
legacy_model = (data.get("LLM_MODEL") or "").strip()
legacy_provider = (data.get("LLM_PROVIDER") or "").strip()
if legacy_model and not legacy_provider:
    for key in PROVIDER_KEYS:
        if data.get(key):
            legacy_provider = PROVIDER_KEY_TO_ID.get(key, "auto")
            print(f"[migrate] inferred model.provider='{legacy_provider}' from {key}")
            break
legacy_payload = dict(data)
if legacy_model:
    legacy_payload["LLM_MODEL"] = legacy_model
if legacy_provider:
    legacy_payload["LLM_PROVIDER"] = legacy_provider

needs_config_patch = not config_path.exists()
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
if legacy_model and not read_model_config().get("LLM_MODEL"):
    needs_config_patch = True

if needs_config_patch:
    write_config_yaml(legacy_payload)
    cfg_model = read_model_config()
    print(
        "[migrate] config.yaml patched — "
        f"provider={cfg_model.get('LLM_PROVIDER') or 'auto'}, model={cfg_model.get('LLM_MODEL', '')!r}"
    )
else:
    cfg_model = read_model_config()
    cfg_provider = cfg_model.get("LLM_PROVIDER", "")
    cfg_model_id = cfg_model.get("LLM_MODEL", "")
    normalized_model = normalize_model_id(cfg_provider, cfg_model_id)
    if normalized_model != cfg_model_id:
        write_config_yaml({"LLM_PROVIDER": cfg_provider, "LLM_MODEL": normalized_model})
        print(f"[migrate] config.yaml model normalized: {cfg_model_id!r} → {normalized_model!r}")
    else:
        print("[migrate] config.yaml left unchanged")

removed = []
for legacy_key in ("LLM_MODEL", "LLM_PROVIDER"):
    if legacy_key in data:
        data.pop(legacy_key, None)
        removed.append(legacy_key)
if removed:
    write_env(ENV_FILE, data)
    print("[migrate] removed non-secret model settings from .env: " + ", ".join(removed))

try:
    if ensure_railway_token_passthrough(config_path):
        print("[migrate] terminal.env_passthrough added Railway tokens")
    else:
        print("[migrate] terminal.env_passthrough already includes Railway tokens")
except Exception as exc:
    print(f"[migrate] WARN: could not ensure Railway token passthrough: {exc}")

try:
    stability_changes = ensure_railway_session_stability(config_path)
    if stability_changes:
        print("[migrate] railway session stability applied: " + ", ".join(stability_changes))
    else:
        print("[migrate] railway session stability already configured")
except Exception as exc:
    print(f"[migrate] WARN: could not ensure Railway session stability: {exc}")
PYEOF

if command -v railway >/dev/null 2>&1; then
  echo "[railway] cli available: $(railway --version 2>/dev/null || true)"
  if [ -n "${RAILWAY_TOKEN:-}" ]; then
    railway variable list --service "${RAILWAY_SERVICE_NAME:-hermes-agent}" --environment "${RAILWAY_ENVIRONMENT_NAME:-production}" >/tmp/railway-token-check.txt 2>&1 \
      && echo "[railway] project token accepted by CLI" \
      || { echo "[railway] project token check failed"; sed 's/[[:alnum:]_=-]\{12,\}/[redacted]/g' /tmp/railway-token-check.txt; }
  elif [ -n "${RAILWAY_API_TOKEN:-}" ]; then
    railway whoami >/tmp/railway-token-check.txt 2>&1 \
      && echo "[railway] api token accepted by CLI" \
      || { echo "[railway] api token check failed"; sed 's/[[:alnum:]_=-]\{12,\}/[redacted]/g' /tmp/railway-token-check.txt; }
  else
    echo "[railway] no Railway token set in process env"
  fi
else
  echo "[railway] WARN: railway CLI missing from image"
fi

# ── Volume cleanup ────────────────────────────────────────────────────────────
# image_cache and audio_cache grow unbounded — delete files older than 30 days.
find /data/.hermes/image_cache -type f -mtime +30 -delete 2>/dev/null || true
find /data/.hermes/audio_cache -type f -mtime +30 -delete 2>/dev/null || true

# Package-manager caches should never live on the persistent volume. Older
# deployments wrote these under /data because HOME=/data; prune them on every
# boot so Railway's 5GB volume is reserved for durable state.
rm -rf /data/.local/share/pnpm/store/v10 \
       /data/.cache/electron \
       /data/.cache/pip \
       /data/.npm/_cacache \
       /data/.npm/_npx 2>/dev/null || true

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
