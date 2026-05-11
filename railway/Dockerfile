FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

# Which hermes-agent revision to install. Accepts any git ref the source
# repo publishes — a release tag (recommended for reproducibility) or a
# branch name (`main`) for bleeding edge.
#
# Source repo: yoydich/hermes-agent (fork with personal fixes for this
# Railway deployment). To bump or rebase, push to that fork's `main`.
ARG HERMES_REF=main
ARG HERMES_REPO=https://github.com/yoydich/hermes-agent.git

# tini = tiny init that we run as PID 1. Without it, hermes's grandchild
# processes (MCP stdio servers, git, bun, browser daemons spawned by tools)
# reparent to PID 1 when their parents exit and pile up as zombies. After
# weeks of uptime that exhausts the kernel's PID table → "fork: cannot
# allocate memory" and the container dies. tini reaps zombies in the
# background and forwards SIGTERM/SIGINT to our entrypoint so Railway's
# stop signal still triggers our graceful shutdown. Standard container init
# (same as Docker's `--init` flag and Kubernetes' pause container).
#
# Node.js is required only at build time to compile the Hermes React dashboard.
# We strip the source + apt lists afterwards to keep the image lean.
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates git tini && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install hermes-agent (provides the `hermes` CLI) and pre-build its React
# dashboard so `hermes dashboard` has nothing to build at runtime.
# Deleting web/ afterwards makes hermes's internal _build_web_ui skip the
# rebuild step (it early-returns when package.json is absent), so container
# startup is fast and no runtime npm dependency is needed.
RUN git clone --depth 1 --branch ${HERMES_REF} ${HERMES_REPO} /opt/hermes-agent

# Cache-bust: Railway sets RAILWAY_GIT_COMMIT_SHA per build, so this ARG
# changes every commit and invalidates every layer below it. Without
# this, Docker keeps reusing the `git clone` layer from the first build
# and /opt/hermes-agent never reflects new commits — only files inserted
# via COPY get refreshed. With this ARG in place, every push pulls the
# latest tip of HERMES_REF and reinstalls deps, so docker/SOUL.md,
# AGENTS.md, hermes_cli/, etc. always match the pushed commit.
ARG RAILWAY_GIT_COMMIT_SHA=unknown
RUN cd /opt/hermes-agent && \
    git fetch origin ${HERMES_REF} && \
    git reset --hard origin/${HERMES_REF} && \
    echo "Refreshed /opt/hermes-agent to ${RAILWAY_GIT_COMMIT_SHA} (origin/${HERMES_REF})"

# Diagnostic: trace every step of pty_ws() so we can pinpoint where the
# /api/pty WebSocket handshake stalls. The proxy reports
# "TimeoutError('timed out during opening handshake')" without saying
# which line of the upstream handler took >5s.  Sprinkle stderr prints
# (which Railway captures into the [dashboard] log stream) right before
# each await/blocking call so the bottleneck shows up by elimination.
# Remove this block once the root cause is known.
RUN python3 - <<'PY'
from pathlib import Path
path = Path("/opt/hermes-agent/hermes_cli/web_server.py")
text = path.read_text()
needle = '@app.websocket("/api/pty")\nasync def pty_ws(ws: WebSocket) -> None:\n'
inject = (
    '@app.websocket("/api/pty")\n'
    'async def pty_ws(ws: WebSocket) -> None:\n'
    '    import sys\n'
    '    print("[pty_ws] enter", flush=True, file=sys.stderr)\n'
)
if needle in text and inject not in text:
    text = text.replace(needle, inject, 1)
    # Trace each pre-accept step.
    text = text.replace(
        '    if not _DASHBOARD_EMBEDDED_CHAT_ENABLED:\n        await ws.close(code=4403)\n        return\n\n    # --- auth + loopback check',
        '    print(f"[pty_ws] embedded={_DASHBOARD_EMBEDDED_CHAT_ENABLED}", flush=True, file=sys.stderr)\n'
        '    if not _DASHBOARD_EMBEDDED_CHAT_ENABLED:\n'
        '        await ws.close(code=4403)\n'
        '        return\n\n'
        '    # --- auth + loopback check',
        1,
    )
    text = text.replace(
        '    token = ws.query_params.get("token", "")\n    expected = _SESSION_TOKEN\n',
        '    print("[pty_ws] read query_params", flush=True, file=sys.stderr)\n'
        '    token = ws.query_params.get("token", "")\n'
        '    expected = _SESSION_TOKEN\n'
        '    print(f"[pty_ws] token_ok={bool(token) and hmac.compare_digest(token.encode(), expected.encode())}", flush=True, file=sys.stderr)\n',
        1,
    )
    text = text.replace(
        '    if not _ws_client_is_allowed(ws):\n        await ws.close(code=4403)\n        return\n\n    await ws.accept()\n',
        '    print(f"[pty_ws][{__import__(\"time\").monotonic():.3f}] before client_is_allowed", flush=True, file=sys.stderr)\n'
        '    if not _ws_client_is_allowed(ws):\n'
        '        await ws.close(code=4403)\n'
        '        return\n'
        '    print(f"[pty_ws][{__import__(\"time\").monotonic():.3f}] before accept", flush=True, file=sys.stderr)\n'
        '    await ws.accept()\n'
        '    print(f"[pty_ws][{__import__(\"time\").monotonic():.3f}] accepted, yielding to event loop", flush=True, file=sys.stderr)\n'
        '    # Yield once so uvicorn flushes the 101 Switching Protocols\n'
        '    # response into the TCP socket before this handler does any\n'
        '    # more sync work.  Without this, the proxy can time out\n'
        '    # waiting for the handshake to complete even though accept()\n'
        '    # already finished on this side.\n'
        '    import asyncio as _asyncio_local\n'
        '    await _asyncio_local.sleep(0)\n'
        '    print(f"[pty_ws][{__import__(\"time\").monotonic():.3f}] after sleep(0)", flush=True, file=sys.stderr)\n',
        1,
    )
    # Trace post-accept blocking points.  Inserted between `accepted`
    # marker and the PTY spawn so we can see which sync call freezes
    # the event loop and prevents the 101 from flushing to the proxy.
    text = text.replace(
        '    # --- spawn PTY ------------------------------------------------------\n'
        '    resume = ws.query_params.get("resume") or None\n'
        '    channel = _channel_or_close_code(ws)\n'
        '    sidecar_url = _build_sidecar_url(channel) if channel else None\n',
        '    # --- spawn PTY ------------------------------------------------------\n'
        '    print("[pty_ws] post-accept: reading resume", flush=True, file=sys.stderr)\n'
        '    resume = ws.query_params.get("resume") or None\n'
        '    print("[pty_ws] post-accept: getting channel", flush=True, file=sys.stderr)\n'
        '    channel = _channel_or_close_code(ws)\n'
        '    print(f"[pty_ws] post-accept: channel={channel}", flush=True, file=sys.stderr)\n'
        '    sidecar_url = _build_sidecar_url(channel) if channel else None\n'
        '    print(f"[pty_ws] post-accept: sidecar_url={sidecar_url}", flush=True, file=sys.stderr)\n',
        1,
    )
    text = text.replace(
        '    try:\n        argv, cwd, env = _resolve_chat_argv(resume=resume, sidecar_url=sidecar_url)\n',
        '    print("[pty_ws] post-accept: BEFORE _resolve_chat_argv (sync)", flush=True, file=sys.stderr)\n'
        '    try:\n'
        '        argv, cwd, env = _resolve_chat_argv(resume=resume, sidecar_url=sidecar_url)\n'
        '        print(f"[pty_ws] post-accept: _resolve_chat_argv DONE argv0={argv[0] if argv else None}", flush=True, file=sys.stderr)\n',
        1,
    )
    text = text.replace(
        '    try:\n        bridge = PtyBridge.spawn(argv, cwd=cwd, env=env)\n',
        '    print("[pty_ws] post-accept: BEFORE PtyBridge.spawn (sync)", flush=True, file=sys.stderr)\n'
        '    try:\n'
        '        bridge = PtyBridge.spawn(argv, cwd=cwd, env=env)\n'
        '        print("[pty_ws] post-accept: PtyBridge.spawn DONE", flush=True, file=sys.stderr)\n',
        1,
    )
    path.write_text(text)
    print("Patched pty_ws with diagnostics")
else:
    print("WARN: pty_ws patch target not found or already applied")
PY

# npm_config_install_links=false forces npm to install file: deps as
# symlinks (the npm 10+ default) even on the bundled npm 9.x that ships
# with this Debian base. The host-side package-lock.json was generated
# with a newer npm that uses symlinks; an install-as-copy produces a
# hidden node_modules/.package-lock.json that permanently disagrees
# with the root lock on the @hermes/ink entry. That disagreement makes
# _tui_need_npm_install() return True at runtime, so the very first
# /api/pty WebSocket request triggers a synchronous subprocess.run(npm
# install) on the asyncio event loop — which freezes the loop long
# enough for the upstream WS handshake response to never flush to the
# proxy, surfacing as "TimeoutError('timed out during opening
# handshake')" in the [ws-proxy] log. Setting this env BEFORE npm
# install makes the build-time and runtime lockfiles agree, so the
# runtime reinstall never fires.
ENV npm_config_install_links=false

RUN uv venv /opt/hermes-agent/venv && \
    cd /opt/hermes-agent && \
    uv pip install --python /opt/hermes-agent/venv/bin/python --no-cache -e ".[all]" && \
    cd /opt/hermes-agent/web && \
    npm install --silent && \
    npm run build && \
    cd /opt/hermes-agent/ui-tui && \
    npm install --silent --no-fund --no-audit --progress=false && \
    npm run build && \
    rm -rf /opt/hermes-agent/web /root/.npm

# Keep /opt/hermes-agent/.git so the in-app "Update" button (which runs
# `git fetch origin` + `git checkout -B main origin/main` + `git pull`)
# can pull new commits at runtime. Convert the shallow clone to a full
# clone so fetch works without `--unshallow` on every update.
RUN cd /opt/hermes-agent && \
    git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*' && \
    git fetch --unshallow origin || true

# Why pre-build ui-tui (and why we don't delete it after):
# - The dashboard's embedded Chat tab spawns `node ui-tui/dist/entry.js`
#   on every WebSocket connect to /api/pty.
# - hermes's _make_tui_argv runs `npm install` + `npm run build` via
#   *synchronous* subprocess.run if dist/entry.js is missing or stale —
#   that would block the dashboard's asyncio event loop for 30-60s on
#   the first chat-open, freezing every other request.
# - Pre-building at image time costs ~200-300 MB of node_modules but
#   makes first-chat-open instant and surfaces any build failure here
#   instead of at user request time.
# - We keep ui-tui/ entirely (node_modules + dist + src) so hermes's
#   freshness checks don't trigger a re-install at runtime.

COPY requirements.txt /app/requirements.txt
RUN uv pip install --system --no-cache -r /app/requirements.txt

RUN mkdir -p /data/.hermes

COPY server.py /app/server.py
COPY templates/ /app/templates/
COPY start.sh /app/start.sh
RUN sed -i 's/\r$//' /app/start.sh && chmod +x /app/start.sh

ENV HOME=/data
ENV HERMES_HOME=/data/.hermes
# Put the hermes venv's bin first on PATH so both:
#   - server.py's `hermes gateway` subprocess resolves to the venv's CLI, and
#   - the in-app Update flow's `uv pip install -e .` finds VIRTUAL_ENV at
#     /opt/hermes-agent/venv (PROJECT_ROOT/venv) and can install into it.
ENV PATH="/opt/hermes-agent/venv/bin:${PATH}"
ENV VIRTUAL_ENV="/opt/hermes-agent/venv"

# tini wraps start.sh so it runs as PID 1's child instead of as PID 1 itself.
# `-g` propagates signals to the whole process group so `docker stop` /
# Railway's SIGTERM cleanly terminates the entire tree, not just start.sh.
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/app/start.sh"]
