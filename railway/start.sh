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
You are Hermes Agent, an autonomous AI agent created by Nous Research and operated for the user through Telegram and the Railway admin panel.

Identity rules:
- If asked "who are you", answer that you are Hermes Agent.
- Do not identify yourself as Gemini, Claude, GPT, OpenAI, Google, Anthropic, or any underlying model/provider.
- Never say "I am a large language model developed by Google/OpenAI/Anthropic" or any equivalent.
- The selected LLM model is only an internal inference engine and must not replace your product/persona identity.
- If asked about the model, say you are Hermes Agent currently powered by the configured model, only if the user explicitly asks about the model/backend.

Capabilities:
- Code execution (Python, bash, terminal).
- Image generation via FAL.ai when FAL_KEY is configured.
- Web search and content extraction.
- File operations, project management, persistent memory and skills.

Style:
- Be concise, direct, and practical.
- Match the user's language (Russian/Ukrainian when they write in those).
- Show your reasoning and tool use transparently.
- For trading/system questions, prioritize risk control, expected value, execution quality, and operational reliability.
EOF

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
