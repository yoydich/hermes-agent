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
ADD https://api.github.com/repos/yoydich/hermes-agent/commits/main /tmp/hermes-main-commit.json
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
    npm install -g @railway/cli --silent --no-fund --no-audit --progress=false && \
    railway --version && \
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
# Keep package-manager and download caches off the persistent Railway volume.
# /data is only 5GB and must be reserved for durable Hermes state.
ENV XDG_CACHE_HOME=/tmp/.cache
ENV PIP_CACHE_DIR=/tmp/.cache/pip
ENV npm_config_cache=/tmp/.npm
ENV npm_config_store_dir=/tmp/.local/share/pnpm/store
ENV PNPM_HOME=/tmp/.local/share/pnpm
ENV PNPM_STORE_DIR=/tmp/.local/share/pnpm/store
ENV UV_CACHE_DIR=/tmp/.cache/uv
ENV ELECTRON_CACHE=/tmp/.cache/electron
ENV PLAYWRIGHT_BROWSERS_PATH=/tmp/.cache/ms-playwright
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
