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

# Clear any stale gateway PID file left over from the previous container.
# `hermes gateway` writes /data/.hermes/gateway.pid on start but does not
# remove it on SIGTERM. Since /data is a persistent volume, the file
# survives container restarts and causes every subsequent boot to exit with
# "ERROR gateway.run: PID file race lost to another gateway instance".
# No hermes process can be running at this point (we're pre-exec in a fresh
# container), so removing the file unconditionally is safe.
rm -f /data/.hermes/gateway.pid

exec python /app/server.py
