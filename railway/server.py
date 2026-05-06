     1|"""
     2|Hermes Agent — Railway admin server.
     3|
     4|Responsibilities:
     5|  - Admin UI / setup wizard at /setup (Starlette + Jinja, cookie-auth guarded)
     6|  - Management API at /setup/api/* (config, status, logs, gateway, pairing)
     7|  - Reverse proxy at / and /* → native Hermes dashboard (hermes_cli/web_server, on 127.0.0.1:9119)
     8|  - Managed subprocesses: `hermes gateway` (agent) and `hermes dashboard` (native UI)
     9|  - Cookie-based session auth at /login (HMAC-signed, 7-day expiry, httponly)
    10|
    11|Auth model: Basic Auth was dropped in favor of cookies because the Hermes React
    12|SPA's plain fetch() calls do not reliably include basic-auth creds across browsers,
    13|and basic-auth's per-directory protection space forced separate prompts for
    14|/setup and /. Cookies auto-include on every same-origin request, so both the
    15|setup UI and the proxied dashboard work with a single login. The cookie signing
    16|secret is regenerated on every process start, so any ADMIN_PASSWORD change on
    17|Railway (which triggers a redeploy) invalidates all existing sessions.
    18|
    19|First-visit behavior: if no provider+model config exists, GET / redirects to /setup.
    20|Once configured, / proxies to the Hermes dashboard. A small "← Setup" widget is
    21|injected into every proxied HTML response so users can always return to the wizard.
    22|"""
    23|
    24|import asyncio
    25|import json
    26|import os
    27|import re
    28|import secrets
    29|import signal
    30|import time
    31|from collections import deque
    32|from contextlib import asynccontextmanager
    33|from pathlib import Path
    34|
    35|import httpx
    36|import websockets
    37|import websockets.exceptions
    38|from starlette.applications import Starlette
    39|from starlette.requests import Request
    40|from starlette.responses import (
    41|    HTMLResponse,
    42|    JSONResponse,
    43|    RedirectResponse,
    44|    Response,
    45|)
    46|from starlette.routing import Route, WebSocketRoute

# Grid bot dashboard routes
import sys
sys.path.insert(0, "/data/solana-grid-bot")
from grid_dashboard import ROUTES as GRID_ROUTES
    47|from starlette.templating import Jinja2Templates
    48|from starlette.websockets import WebSocket, WebSocketDisconnect, WebSocketState
    49|
    50|ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;]*m")
    51|templates = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))
    52|
    53|HERMES_HOME = os.environ.get("HERMES_HOME", str(Path.home() / ".hermes"))
    54|ENV_FILE = Path(HERMES_HOME) / ".env"
    55|PAIRING_DIR = Path(HERMES_HOME) / "pairing"
    56|PAIRING_TTL = 3600
    57|
    58|# Native Hermes dashboard — runs on loopback, fronted by our reverse proxy.
    59|HERMES_DASHBOARD_HOST = "127.0.0.1"
    60|HERMES_DASHBOARD_PORT = int(os.environ.get("HERMES_DASHBOARD_PORT", "9119"))
    61|HERMES_DASHBOARD_URL = f"http://{HERMES_DASHBOARD_HOST}:{HERMES_DASHBOARD_PORT}"
    62|
    63|# Hermes gateway HTTP API — exposes OpenAI-compatible /v1/* endpoints.
    64|# Proxied at /v1/* so hermes-workspace can reach it via the public Railway URL.
    65|HERMES_GATEWAY_HOST = "127.0.0.1"
    66|HERMES_GATEWAY_PORT = int(os.environ.get("HERMES_GATEWAY_PORT", "8642"))
    67|HERMES_GATEWAY_URL = f"http://{HERMES_GATEWAY_HOST}:{HERMES_GATEWAY_PORT}"
    68|
    69|# Mirror dashboard-ref-only/auth_proxy.py: strip only `host` (httpx sets it)
    70|# and `transfer-encoding` (httpx recomputes it from the body). Keep everything
    71|# else — notably `authorization`, because the SPA uses Bearer tokens against
    72|# hermes's own /api/env/reveal and OAuth endpoints, and keep `cookie` since
    73|# some hermes endpoints read it. Aggressive stripping was masking requests in
    74|# ways that produced spurious 401s.
    75|HOP_BY_HOP = {"host", "transfer-encoding"}
    76|
    77|ADMIN_USERNAME = os.environ.get("ADMIN_USERNAME", "admin")
    78|ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "")
    79|if not ADMIN_PASSWORD:
    80|    ADMIN_PASSWORD = secrets.token_urlsafe(16)
    81|    print(f"[server] Admin credentials — username: {ADMIN_USERNAME}  password: {ADMIN_PASSWORD}", flush=True)
    82|else:
    83|    print(f"[server] Admin username: {ADMIN_USERNAME}", flush=True)
    84|
    85|# ── Env var registry ──────────────────────────────────────────────────────────
    86|# (key, label, category, is_secret)
    87|ENV_VARS = [
    88|    ("LLM_MODEL",               "Model",                    "model",     False),
    89|    ("LLM_PROVIDER",            "Provider",                 "model",     False),
    90|    ("OPENROUTER_API_KEY",       "OpenRouter",               "provider",  True),
    91|    ("DEEPSEEK_API_KEY",         "DeepSeek",                 "provider",  True),
    92|    ("DASHSCOPE_API_KEY",        "DashScope",                "provider",  True),
    93|    ("GLM_API_KEY",              "GLM / Z.AI",               "provider",  True),
    94|    ("KIMI_API_KEY",             "Kimi",                     "provider",  True),
    95|    ("MINIMAX_API_KEY",          "MiniMax",                  "provider",  True),
    96|    ("HF_TOKEN",                 "Hugging Face",             "provider",  True),
    97|    # Added in v2026.4.23 (hermes v0.11.0). All plain API-key auth — hermes
    98|    # auto-routes by env-var presence, no extra config needed on our side.
    99|    # OAuth-based providers (Gemini CLI, Qwen OAuth, Claude Code, Copilot)
   100|    # are reachable via the dashboard's Keys tab and not exposed here.
   101|    ("NVIDIA_API_KEY",           "NVIDIA NIM",               "provider",  True),
   102|    ("ARCEE_API_KEY",            "Arcee AI",                 "provider",  True),
   103|    ("STEPFUN_API_KEY",          "Step Plan",                "provider",  True),
   104|    ("AI_GATEWAY_API_KEY",       "Vercel AI Gateway",        "provider",  True),
   105|    ("GEMINI_API_KEY",           "Google AI Studio",         "provider",  True),
   106|    ("PARALLEL_API_KEY",         "Parallel (search)",        "tool",      True),
   107|    ("FIRECRAWL_API_KEY",        "Firecrawl (scrape)",       "tool",      True),
   108|    ("TAVILY_API_KEY",           "Tavily (search)",          "tool",      True),
   109|    ("FAL_KEY",                  "FAL (image gen)",          "tool",      True),
   110|    ("BROWSERBASE_API_KEY",      "Browserbase key",          "tool",      True),
   111|    ("BROWSERBASE_PROJECT_ID",   "Browserbase project",      "tool",      False),
   112|    ("GITHUB_TOKEN",             "GitHub token",             "tool",      True),
   113|    ("VOICE_TOOLS_OPENAI_KEY",   "OpenAI (voice/TTS)",       "tool",      True),
   114|    ("HONCHO_API_KEY",           "Honcho (memory)",          "tool",      True),
   115|    ("TELEGRAM_BOT_TOKEN",       "Bot Token",                "telegram",  True),
   116|    ("TELEGRAM_ALLOWED_USERS",   "Allowed User IDs",         "telegram",  False),
   117|    ("DISCORD_BOT_TOKEN",        "Bot Token",                "discord",   True),
   118|    ("DISCORD_ALLOWED_USERS",    "Allowed User IDs",         "discord",   False),
   119|    ("SLACK_BOT_TOKEN",          "Bot Token (xoxb-...)",     "slack",     True),
   120|    ("SLACK_APP_TOKEN",          "App Token (xapp-...)",     "slack",     True),
   121|    ("WHATSAPP_ENABLED",         "Enable WhatsApp",          "whatsapp",  False),
   122|    ("EMAIL_ADDRESS",            "Email Address",            "email",     False),
   123|    ("EMAIL_PASSWORD",           "Email Password",           "email",     True),
   124|    ("EMAIL_IMAP_HOST",          "IMAP Host",                "email",     False),
   125|    ("EMAIL_SMTP_HOST",          "SMTP Host",                "email",     False),
   126|    ("MATTERMOST_URL",           "Server URL",               "mattermost",False),
   127|    ("MATTERMOST_TOKEN",         "Bot Token",                "mattermost",True),
   128|    ("MATRIX_HOMESERVER",        "Homeserver URL",           "matrix",    False),
   129|    ("MATRIX_ACCESS_TOKEN",      "Access Token",             "matrix",    True),
   130|    ("MATRIX_USER_ID",           "User ID",                  "matrix",    False),
   131|    ("GATEWAY_ALLOW_ALL_USERS",  "Allow all users",          "gateway",   False),
   132|    # API server — exposes an OpenAI-compatible HTTP API on port 8642 so that
   133|    # hermes-workspace (or any other client) can connect to the gateway.
   134|    # Set API_SERVER_ENABLED=true and API_SERVER_KEY=<secret> in Railway
   135|    # service variables, then use Railway private networking from other services.
   136|    ("API_SERVER_ENABLED",       "Enable API server",        "api",       False),
   137|    ("API_SERVER_HOST",          "API server host",          "api",       False),
   138|    ("API_SERVER_KEY",           "API server key",           "api",       True),
   139|    ("ADMIN_USERNAME",           "Admin username",           "admin",     False),
   140|    ("ADMIN_PASSWORD",           "Admin password",           "admin",     True),
   141|]
   142|
   143|SECRET_KEYS  = {k for k, _, _, s in ENV_VARS if s}
   144|PROVIDER_KEYS = [k for k, _, c, _ in ENV_VARS if c == "provider"]
   145|PROVIDER_KEY_TO_ID = {
   146|    "OPENROUTER_API_KEY": "openrouter",
   147|    "DEEPSEEK_API_KEY": "deepseek",
   148|    "DASHSCOPE_API_KEY": "dashscope",
   149|    "GLM_API_KEY": "zai",
   150|    "KIMI_API_KEY": "kimi-coding",
   151|    "MINIMAX_API_KEY": "minimax",
   152|    "HF_TOKEN": "huggingface",
   153|    "NVIDIA_API_KEY": "nvidia",
   154|    "ARCEE_API_KEY": "arcee",
   155|    "STEPFUN_API_KEY": "stepfun",
   156|    "AI_GATEWAY_API_KEY": "ai-gateway",
   157|    "GEMINI_API_KEY": "gemini",
   158|}
   159|CHANNEL_MAP  = {
   160|    "Telegram":    "TELEGRAM_BOT_TOKEN",
   161|    "Discord":     "DISCORD_BOT_TOKEN",
   162|    "Slack":       "SLACK_BOT_TOKEN",
   163|    "WhatsApp":    "WHATSAPP_ENABLED",
   164|    "Email":       "EMAIL_ADDRESS",
   165|    "Mattermost":  "MATTERMOST_TOKEN",
   166|    "Matrix":      "MATRIX_ACCESS_TOKEN",
   167|}
   168|
   169|
   170|# ── .env helpers ──────────────────────────────────────────────────────────────
   171|def read_env(path: Path) -> dict[str, str]:
   172|    if not path.exists():
   173|        return {}
   174|    out = {}
   175|    for line in path.read_text().splitlines():
   176|        line = line.strip()
   177|        if not line or line.startswith("#") or "=" not in line:
   178|            continue
   179|        k, _, v = line.partition("=")
   180|        v = v.strip()
   181|        if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
   182|            v = v[1:-1]
   183|        out[k.strip()] = v
   184|    return out
   185|
   186|
   187|def write_config_yaml(data: dict[str, str]) -> None:
   188|    """Write a minimal config.yaml so hermes picks up the model and provider."""
   189|    provider = (data.get("LLM_PROVIDER", "") or "auto").strip() or "auto"
   190|    model = (data.get("LLM_MODEL", "") or "").strip()
   191|    # Direct providers expect native model IDs, not OpenRouter-style prefixes.
   192|    if provider in {"deepseek", "gemini", "zai", "dashscope", "minimax", "nvidia", "arcee", "stepfun"}:
   193|        if model.startswith("models/"):
   194|            model = model.split("/", 1)[1]
   195|        if model.startswith(provider + "/"):
   196|            model = model[len(provider) + 1:]
   197|        if provider == "deepseek" and model.startswith("deepseek/"):
   198|            model = model.split("/", 1)[1]
   199|    config_path = Path(HERMES_HOME) / "config.yaml"
   200|    config_path.parent.mkdir(parents=True, exist_ok=True)
   201|    config_path.write_text(f"""\
   202|model:
   203|  default: "{model}"
   204|  provider: "{provider}"
   205|
   206|terminal:
   207|  backend: "local"
   208|  timeout: 60
   209|  cwd: "/tmp"
   210|
   211|agent:
   212|  max_iterations: 50
   213|
   214|data_dir: "{HERMES_HOME}"
   215|""")
   216|
   217|
   218|def write_env(path: Path, data: dict[str, str]) -> None:
   219|    path.parent.mkdir(parents=True, exist_ok=True)
   220|    cat_order = ["model", "provider", "tool",
   221|                 "telegram", "discord", "slack", "whatsapp",
   222|                 "email", "mattermost", "matrix", "gateway"]
   223|    cat_labels = {
   224|        "model": "Model", "provider": "Providers", "tool": "Tools",
   225|        "telegram": "Telegram", "discord": "Discord", "slack": "Slack",
   226|        "whatsapp": "WhatsApp", "email": "Email",
   227|        "mattermost": "Mattermost", "matrix": "Matrix", "gateway": "Gateway",
   228|    }
   229|    key_cat = {k: c for k, _, c, _ in ENV_VARS}
   230|    grouped: dict[str, list[str]] = {c: [] for c in cat_order}
   231|    grouped["other"] = []
   232|
   233|    for k, v in data.items():
   234|        if not v:
   235|            continue
   236|        cat = key_cat.get(k, "other")
   237|        grouped.setdefault(cat, []).append(f"{k}={v}")
   238|
   239|    lines: list[str] = []
   240|    for cat in cat_order:
   241|        entries = sorted(grouped.get(cat, []))
   242|        if entries:
   243|            lines.append(f"# {cat_labels.get(cat, cat)}")
   244|            lines.extend(entries)
   245|            lines.append("")
   246|    if grouped["other"]:
   247|        lines.append("# Other")
   248|        lines.extend(sorted(grouped["other"]))
   249|        lines.append("")
   250|
   251|    path.write_text("\n".join(lines))
   252|
   253|
   254|def is_config_complete(data: dict[str, str] | None = None) -> bool:
   255|    """Single source of truth for 'ready to run the gateway'.
   256|
   257|    Used by: GET / redirect, auto_start on boot, admin API status.
   258|    """
   259|    if data is None:
   260|        data = read_env(ENV_FILE)
   261|    has_model = bool(data.get("LLM_MODEL"))
   262|    has_provider = any(data.get(k) for k in PROVIDER_KEYS)
   263|    return has_model and has_provider
   264|
   265|
   266|def mask(data: dict[str, str]) -> dict[str, str]:
   267|    return {
   268|        k: (v[:8] + "***" if len(v) > 8 else "***") if k in SECRET_KEYS and v else v
   269|        for k, v in data.items()
   270|    }
   271|
   272|
   273|def unmask(new: dict[str, str], existing: dict[str, str]) -> dict[str, str]:
   274|    return {
   275|        k: (existing.get(k, "") if k in SECRET_KEYS and v.endswith("***") else v)
   276|        for k, v in new.items()
   277|    }
   278|
   279|
   280|# ── Auth (cookie-based) ───────────────────────────────────────────────────────
   281|# We use HMAC-signed cookies instead of HTTP Basic Auth because:
   282|#   1. Basic auth's per-directory protection space means browsers cache creds
   283|#      for /setup/* separately from /*, forcing re-prompt on navigation.
   284|#   2. Browser behavior for sending Basic auth on XHR/fetch is inconsistent;
   285|#      the Hermes React SPA's plain fetch() calls don't reliably include it,
   286|#      causing every proxied API call to 401.
   287|# Cookies are auto-included on every same-origin request (navigation + XHR)
   288|# so both the setup UI and the proxied Hermes dashboard work with one login.
   289|#
   290|# The SECRET is regenerated on every process start. That means any ADMIN_PASSWORD
   291|# change via Railway → redeploy → all existing cookies invalidate → users re-login.
   292|import hashlib as _hashlib
   293|import hmac as _hmac
   294|from urllib.parse import quote as _url_quote, urlparse as _urlparse
   295|
   296|COOKIE_NAME = "hermes_auth"
   297|COOKIE_MAX_AGE = 7 * 86400  # 7 days
   298|COOKIE_SECRET = secrets.token_bytes(32)
   299|
   300|# Public paths — no auth required. Everything else is behind the cookie gate.
   301|PUBLIC_PATHS = {"/health", "/login", "/logout"}
   302|
   303|
   304|def _make_auth_token() -> str:
   305|    """Build a cookie value: `<expires>.<hmac-sha256>`."""
   306|    expires = str(int(time.time()) + COOKIE_MAX_AGE)
   307|    sig = _hmac.new(COOKIE_SECRET, expires.encode(), _hashlib.sha256).hexdigest()
   308|    return f"{expires}.{sig}"
   309|
   310|
   311|def _verify_auth_token(token: str) -> bool:
   312|    try:
   313|        expires_s, sig = token.rsplit(".", 1)
   314|        if int(expires_s) < time.time():
   315|            return False
   316|        expected = _hmac.new(COOKIE_SECRET, expires_s.encode(), _hashlib.sha256).hexdigest()
   317|        return _hmac.compare_digest(sig, expected)
   318|    except Exception:
   319|        return False
   320|
   321|
   322|def _is_authenticated(request: Request) -> bool:
   323|    return _verify_auth_token(request.cookies.get(COOKIE_NAME, ""))
   324|
   325|
   326|def _safe_return_to(value: str) -> str:
   327|    """Reject open-redirect attempts — only allow same-origin relative paths."""
   328|    if not value or not value.startswith("/") or value.startswith("//"):
   329|        return "/"
   330|    # Strip any scheme/netloc that slipped through.
   331|    p = _urlparse(value)
   332|    if p.scheme or p.netloc:
   333|        return "/"
   334|    return value
   335|
   336|
   337|def guard(request: Request) -> Response | None:
   338|    """Enforce auth on protected routes.
   339|
   340|    - HTML navigation: 302 to /login?returnTo=<path>
   341|    - API / XHR: 401 JSON (so the SPA's fetch() can surface it cleanly)
   342|    """
   343|    if _is_authenticated(request):
   344|        return None
   345|    accept = request.headers.get("accept", "").lower()
   346|    wants_html = "text/html" in accept
   347|    if wants_html:
   348|        rt = request.url.path
   349|        if request.url.query:
   350|            rt = f"{rt}?{request.url.query}"
   351|        return RedirectResponse(f"/login?returnTo={_url_quote(rt)}", status_code=302)
   352|    return JSONResponse({"error": "Unauthorized"}, status_code=401)
   353|
   354|
   355|LOGIN_PAGE_HTML = """<!DOCTYPE html>
   356|<html lang="en"><head>
   357|<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
   358|<title>Hermes Agent — Sign in</title>
   359|<link rel="preconnect" href="https://fonts.googleapis.com">
   360|<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
   361|<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans:wght@400;500;600&display=swap" rel="stylesheet">
   362|<style>
   363|*{box-sizing:border-box;margin:0;padding:0}
   364|body{background:#0d0f14;color:#c9d1d9;font-family:'IBM Plex Sans',sans-serif;
   365|  min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}
   366|.card{background:#14181f;border:1px solid #252d3d;border-radius:12px;padding:36px 32px;width:100%;max-width:380px;
   367|  box-shadow:0 20px 40px rgba(0,0,0,0.4)}
   368|.brand{text-align:center;margin-bottom:28px}
   369|.brand-logo{display:inline-flex;align-items:center;gap:10px;font-family:'IBM Plex Mono',monospace;font-weight:600;font-size:18px;color:#6272ff}
   370|.brand-logo span{color:#6b7688;font-weight:400}
   371|.brand-sub{font-family:'IBM Plex Mono',monospace;font-size:11px;color:#6b7688;margin-top:8px;letter-spacing:1.5px;text-transform:uppercase}
   372|label{display:block;font-family:'IBM Plex Mono',monospace;font-size:11px;color:#6b7688;
   373|  letter-spacing:0.05em;text-transform:uppercase;margin-bottom:6px;margin-top:16px}
   374|input{width:100%;background:#0d0f14;border:1px solid #252d3d;border-radius:6px;color:#c9d1d9;
   375|  font-family:'IBM Plex Mono',monospace;font-size:13px;padding:9px 11px;outline:none;transition:border-color .15s}
   376|input:focus{border-color:#6272ff}
   377|button{width:100%;margin-top:24px;background:#6272ff;border:1px solid #6272ff;border-radius:6px;color:#fff;
   378|  font-family:'IBM Plex Mono',monospace;font-size:13px;font-weight:500;padding:10px;cursor:pointer;
   379|  transition:background .15s,border-color .15s}
   380|button:hover{background:#7b8fff;border-color:#7b8fff}
   381|.err{background:rgba(248,81,73,0.08);border:1px solid rgba(248,81,73,0.3);border-radius:6px;
   382|  color:#f85149;font-family:'IBM Plex Mono',monospace;font-size:12px;padding:8px 12px;margin-bottom:14px;text-align:center}
   383|.footnote{margin-top:18px;font-family:'IBM Plex Mono',monospace;font-size:10px;color:#6b7688;text-align:center;line-height:1.6}
   384|</style></head>
   385|<body>
   386|<div class="card">
   387|  <div class="brand">
   388|    <div class="brand-logo">hermes<span>/admin</span></div>
   389|    <div class="brand-sub">Sign in to continue</div>
   390|  </div>
   391|  __ERROR__
   392|  <form method="POST" action="/login">
   393|    <input type="hidden" name="returnTo" value="__RETURN_TO__">
   394|    <label for="username">Username</label>
   395|    <input id="username" name="username" type="text" autocomplete="username" autofocus required>
   396|    <label for="password">Password</label>
   397|    <input id="password" name="password" type="password" autocomplete="current-password" required>
   398|    <button type="submit">Sign in</button>
   399|  </form>
   400|  <p class="footnote">Credentials are the <code>ADMIN_USERNAME</code> and <code>ADMIN_PASSWORD</code><br>Railway service variables.</p>
   401|</div>
   402|</body></html>"""
   403|
   404|
   405|def _html_escape(s: str) -> str:
   406|    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
   407|             .replace('"', "&quot;").replace("'", "&#39;"))
   408|
   409|
   410|async def page_login(request: Request) -> Response:
   411|    """GET /login — render the sign-in form."""
   412|    # Already signed in? Bounce to returnTo (or /).
   413|    if _is_authenticated(request):
   414|        return RedirectResponse(_safe_return_to(request.query_params.get("returnTo", "/")), status_code=302)
   415|    rt = _safe_return_to(request.query_params.get("returnTo", "/"))
   416|    error_html = ('<div class="err">Invalid username or password</div>'
   417|                  if request.query_params.get("error") else "")
   418|    html = (LOGIN_PAGE_HTML
   419|            .replace("__ERROR__", error_html)
   420|            .replace("__RETURN_TO__", _html_escape(rt)))
   421|    return HTMLResponse(html)
   422|
   423|
   424|async def login_post(request: Request) -> Response:
   425|    """POST /login — validate creds and set the auth cookie."""
   426|    form = await request.form()
   427|    username = str(form.get("username", ""))
   428|    password = str(form.get("password", ""))
   429|    return_to = _safe_return_to(str(form.get("returnTo", "/")))
   430|
   431|    valid_user = _hmac.compare_digest(username, ADMIN_USERNAME)
   432|    valid_pw = _hmac.compare_digest(password, ADMIN_PASSWORD)
   433|    if valid_user and valid_pw:
   434|        resp = RedirectResponse(return_to, status_code=302)
   435|        resp.set_cookie(
   436|            COOKIE_NAME,
   437|            _make_auth_token(),
   438|            max_age=COOKIE_MAX_AGE,
   439|            httponly=True,
   440|            samesite="lax",
   441|            path="/",
   442|        )
   443|        return resp
   444|    return RedirectResponse(f"/login?returnTo={_url_quote(return_to)}&error=1", status_code=302)
   445|
   446|
   447|async def logout(request: Request) -> Response:
   448|    """GET /logout — clear cookie and bounce to login."""
   449|    resp = RedirectResponse("/login", status_code=302)
   450|    resp.delete_cookie(COOKIE_NAME, path="/")
   451|    return resp
   452|
   453|
   454|# ── Gateway manager ───────────────────────────────────────────────────────────
   455|
   456|
   457|class Gateway:
   458|    def __init__(self):
   459|        self.proc: asyncio.subprocess.Process | None = None
   460|        self.state = "stopped"
   461|        self.logs: deque[str] = deque(maxlen=500)
   462|        self.started_at: float | None = None
   463|        self.last_log_at: float | None = None
   464|        self.restarts = 0
   465|
   466|    async def start(self):
   467|        if self.proc and self.proc.returncode is None:
   468|            return
   469|        self.state = "starting"
   470|        try:
   471|            # .env values take priority over Railway env vars.
   472|            # We build the env this way so hermes's own dotenv loading
   473|            # (which reads the same file) doesn't shadow our values.
   474|            env = {**os.environ, "HERMES_HOME": HERMES_HOME}
   475|            env.update(read_env(ENV_FILE))
   476|            model = env.get("LLM_MODEL", "")
   477|            provider_key = next((env.get(k, "") for k in PROVIDER_KEYS if env.get(k)), "")
   478|            print(f"[gateway] model={model or '⚠ NOT SET'} | provider_key={'set' if provider_key else '⚠ NOT SET'}", flush=True)
   479|            # Write config.yaml so hermes picks up the model (env vars alone aren't always enough)
   480|            write_config_yaml(read_env(ENV_FILE))
   481|            self.proc = await asyncio.create_subprocess_exec(
   482|                "hermes", "gateway",
   483|                stdout=asyncio.subprocess.PIPE,
   484|                stderr=asyncio.subprocess.STDOUT,
   485|                env=env,
   486|            )
   487|            self.state = "running"
   488|            self.started_at = time.time()
   489|            self.last_log_at = time.time()
   490|            asyncio.create_task(self._drain())
   491|        except Exception as e:
   492|            self.state = "error"
   493|            self.logs.append(f"[error] Failed to start: {e}")
   494|
   495|    async def stop(self):
   496|        if not self.proc or self.proc.returncode is not None:
   497|            self.state = "stopped"
   498|            return
   499|        self.state = "stopping"
   500|        self.proc.terminate()
   501|        try:
   502|            await asyncio.wait_for(self.proc.wait(), timeout=10)
   503|        except asyncio.TimeoutError:
   504|            self.proc.kill()
   505|            await self.proc.wait()
   506|        self.state = "stopped"
   507|        self.started_at = None
   508|
   509|    async def restart(self):
   510|        await self.stop()
   511|        self.restarts += 1
   512|        await self.start()
   513|
   514|    async def _drain(self):
   515|        assert self.proc and self.proc.stdout
   516|        async for raw in self.proc.stdout:
   517|            line = ANSI_ESCAPE.sub("", raw.decode(errors="replace").rstrip())
   518|            self.logs.append(line)
   519|            self.last_log_at = time.time()
   520|        # Gateway process exited — auto-restart if it wasn't intentionally stopped.
   521|        if self.state == "running":
   522|            rc = self.proc.returncode
   523|            self.state = "error"
   524|            msg = f"[error] Gateway exited unexpectedly (code {rc}) — restarting in 5s"
   525|            self.logs.append(msg)
   526|            print(f"[gateway] {msg}", flush=True)
   527|            await asyncio.sleep(5)
   528|            self.restarts += 1
   529|            await self.start()
   530|
   531|    def status(self) -> dict:
   532|        uptime = int(time.time() - self.started_at) if self.started_at and self.state == "running" else None
   533|        silent = int(time.time() - self.last_log_at) if self.last_log_at and self.state == "running" else None
   534|        return {
   535|            "state":    self.state,
   536|            "pid":      self.proc.pid if self.proc and self.proc.returncode is None else None,
   537|            "uptime":   uptime,
   538|            "silent_secs": silent,
   539|            "restarts": self.restarts,
   540|        }
   541|
   542|
   543|gw = Gateway()
   544|cfg_lock = asyncio.Lock()
   545|
   546|
   547|# ── Hermes dashboard subprocess ───────────────────────────────────────────────
   548|class Dashboard:
   549|    """Manages the `hermes dashboard` subprocess (native Hermes web UI).
   550|
   551|    Bound to loopback only — we expose it to the public internet through our
   552|    reverse proxy on $PORT, where edge basic auth guards every request.
   553|    The dashboard is independent of the gateway: it reads config files
   554|    directly and tolerates a stopped gateway.
   555|
   556|    All subprocess output is streamed to our stdout (→ Railway logs) with a
   557|    `[dashboard]` prefix AND retained in a ring buffer for diagnostics.
   558|    Unexpected exits are explicitly logged with their return code.
   559|    """
   560|
   561|    def __init__(self):
   562|        self.proc: asyncio.subprocess.Process | None = None
   563|        self.logs: deque[str] = deque(maxlen=300)
   564|        self._drain_task: asyncio.Task | None = None
   565|
   566|    async def start(self):
   567|        if self.proc and self.proc.returncode is None:
   568|            return
   569|        try:
   570|            self.proc = await asyncio.create_subprocess_exec(
   571|                "hermes", "dashboard",
   572|                "--host", HERMES_DASHBOARD_HOST,
   573|                "--port", str(HERMES_DASHBOARD_PORT),
   574|                "--no-open",
   575|                # --tui exposes /api/pty + /api/ws + /api/events so the
   576|                # dashboard's embedded Chat tab works end-to-end. Requires
   577|                # hermes >= v2026.4.23 — older releases exit immediately
   578|                # with "unrecognized arguments: --tui". The Dockerfile
   579|                # pre-builds ui-tui/dist/ so PTY spawn is instant.
   580|                "--tui",
   581|                stdout=asyncio.subprocess.PIPE,
   582|                stderr=asyncio.subprocess.STDOUT,
   583|            )
   584|            print(f"[dashboard] spawned pid={self.proc.pid} → {HERMES_DASHBOARD_URL}", flush=True)
   585|            self._drain_task = asyncio.create_task(self._drain())
   586|        except Exception as e:
   587|            print(f"[dashboard] FAILED to spawn: {e!r}", flush=True)
   588|
   589|    async def _drain(self):
   590|        """Stream subprocess output to Railway logs (prefixed) and a ring buffer."""
   591|        assert self.proc and self.proc.stdout
   592|        try:
   593|            async for raw in self.proc.stdout:
   594|                line = ANSI_ESCAPE.sub("", raw.decode(errors="replace").rstrip())
   595|                self.logs.append(line)
   596|                print(f"[dashboard] {line}", flush=True)
   597|        except Exception as e:
   598|            print(f"[dashboard] drain error: {e!r}", flush=True)
   599|        finally:
   600|            rc = self.proc.returncode if self.proc else None
   601|            if rc is not None and rc != 0:
   602|                print(f"[dashboard] EXITED with code {rc} — reverse proxy will return 503 until restart", flush=True)
   603|            elif rc == 0:
   604|                print(f"[dashboard] exited cleanly (code 0)", flush=True)
   605|
   606|    async def stop(self):
   607|        if not self.proc or self.proc.returncode is not None:
   608|            return
   609|        self.proc.terminate()
   610|        try:
   611|            await asyncio.wait_for(self.proc.wait(), timeout=5)
   612|        except asyncio.TimeoutError:
   613|            self.proc.kill()
   614|            await self.proc.wait()
   615|
   616|
   617|dash = Dashboard()
   618|
   619|# Shared async HTTP client for the reverse proxy. Created lazily so we pick up
   620|# the running event loop, torn down in lifespan.
   621|_http_client: httpx.AsyncClient | None = None
   622|
   623|
   624|def get_http_client() -> httpx.AsyncClient:
   625|    global _http_client
   626|    if _http_client is None:
   627|        _http_client = httpx.AsyncClient(
   628|            timeout=httpx.Timeout(30.0, connect=5.0),
   629|            follow_redirects=False,
   630|        )
   631|    return _http_client
   632|
   633|
   634|# ── Route handlers ────────────────────────────────────────────────────────────
   635|async def page_index(request: Request):
   636|    if err := guard(request): return err
   637|    return templates.TemplateResponse(request, "index.html")
   638|
   639|
   640|async def route_health(request: Request):
   641|    return JSONResponse({"status": "ok", "gateway": gw.state})
   642|
   643|
   644|async def api_config_get(request: Request):
   645|    if err := guard(request): return err
   646|    async with cfg_lock:
   647|        data = read_env(ENV_FILE)
   648|    defs = [{"key": k, "label": l, "category": c, "secret": s} for k, l, c, s in ENV_VARS]
   649|    return JSONResponse({"vars": mask(data), "defs": defs})
   650|
   651|
   652|async def api_config_put(request: Request):
   653|    if err := guard(request): return err
   654|    try:
   655|        body = await request.json()
   656|    except Exception:
   657|        return JSONResponse({"error": "Invalid JSON"}, status_code=400)
   658|    try:
   659|        restart = body.pop("_restart", False)
   660|        new_vars = body.get("vars", {})
   661|        async with cfg_lock:
   662|            existing = read_env(ENV_FILE)
   663|            merged = unmask(new_vars, existing)
   664|            if not merged.get("LLM_PROVIDER"):
   665|                for key in PROVIDER_KEYS:
   666|                    if merged.get(key):
   667|                        merged["LLM_PROVIDER"] = PROVIDER_KEY_TO_ID.get(key, "auto")
   668|                        break
   669|            for k, v in existing.items():
   670|                if k not in merged:
   671|                    merged[k] = v
   672|            write_env(ENV_FILE, merged)
   673|            write_config_yaml(merged)
   674|        if restart:
   675|            asyncio.create_task(gw.restart())
   676|        return JSONResponse({"ok": True, "restarting": restart})
   677|    except Exception as e:
   678|        return JSONResponse({"error": str(e)}, status_code=500)
   679|
   680|
   681|async def api_status(request: Request):
   682|    if err := guard(request): return err
   683|    data = read_env(ENV_FILE)
   684|    providers = {
   685|        k.replace("_API_KEY","").replace("_TOKEN","").replace("HF_","HuggingFace ").replace("_"," ").title():
   686|        {"configured": bool(data.get(k))}
   687|        for k in PROVIDER_KEYS
   688|    }
   689|    channels = {
   690|        name: {"configured": bool(v := data.get(key,"")) and v.lower() not in ("false","0","no")}
   691|        for name, key in CHANNEL_MAP.items()
   692|    }
   693|    return JSONResponse({"gateway": gw.status(), "providers": providers, "channels": channels})
   694|
   695|
   696|async def api_logs(request: Request):
   697|    if err := guard(request): return err
   698|    return JSONResponse({"lines": list(gw.logs)})
   699|
   700|
   701|async def api_gw_start(request: Request):
   702|    if err := guard(request): return err
   703|    asyncio.create_task(gw.start())
   704|    return JSONResponse({"ok": True})
   705|
   706|
   707|async def api_gw_stop(request: Request):
   708|    if err := guard(request): return err
   709|    asyncio.create_task(gw.stop())
   710|    return JSONResponse({"ok": True})
   711|
   712|
   713|async def api_gw_restart(request: Request):
   714|    if err := guard(request): return err
   715|    asyncio.create_task(gw.restart())
   716|    return JSONResponse({"ok": True})
   717|
   718|
   719|async def api_config_reset(request: Request):
   720|    if err := guard(request): return err
   721|    asyncio.create_task(gw.stop())
   722|    async with cfg_lock:
   723|        if ENV_FILE.exists():
   724|            ENV_FILE.unlink()
   725|        write_config_yaml({})
   726|    return JSONResponse({"ok": True})
   727|
   728|
   729|# ── Pairing ───────────────────────────────────────────────────────────────────
   730|def _pjson(path: Path) -> dict:
   731|    try:
   732|        return json.loads(path.read_text()) if path.exists() else {}
   733|    except Exception:
   734|        return {}
   735|
   736|
   737|def _wjson(path: Path, data: dict):
   738|    path.parent.mkdir(parents=True, exist_ok=True)
   739|    path.write_text(json.dumps(data, indent=2, ensure_ascii=False))
   740|    try: os.chmod(path, 0o600)
   741|    except OSError: pass
   742|
   743|
   744|def _platforms(suffix: str) -> list[str]:
   745|    if not PAIRING_DIR.exists(): return []
   746|    return [f.stem.rsplit(f"-{suffix}", 1)[0] for f in PAIRING_DIR.glob(f"*-{suffix}.json")]
   747|
   748|
   749|async def api_pairing_pending(request: Request):
   750|    if err := guard(request): return err
   751|    now = time.time()
   752|    out = []
   753|    for p in _platforms("pending"):
   754|        for code, info in _pjson(PAIRING_DIR / f"{p}-pending.json").items():
   755|            if now - info.get("created_at", now) <= PAIRING_TTL:
   756|                out.append({"platform": p, "code": code,
   757|                            "user_id": info.get("user_id",""), "user_name": info.get("user_name",""),
   758|                            "age_minutes": int((now - info.get("created_at", now)) / 60)})
   759|    return JSONResponse({"pending": out})
   760|
   761|
   762|async def api_pairing_approve(request: Request):
   763|    if err := guard(request): return err
   764|    try: body = await request.json()
   765|    except Exception: return JSONResponse({"error": "Invalid JSON"}, status_code=400)
   766|    platform, code = body.get("platform",""), body.get("code","").upper().strip()
   767|    if not platform or not code:
   768|        return JSONResponse({"error": "platform and code required"}, status_code=400)
   769|    pending_path = PAIRING_DIR / f"{platform}-pending.json"
   770|    pending = _pjson(pending_path)
   771|    if code not in pending:
   772|        return JSONResponse({"error": "Code not found"}, status_code=404)
   773|    entry = pending.pop(code)
   774|    _wjson(pending_path, pending)
   775|    approved = _pjson(PAIRING_DIR / f"{platform}-approved.json")
   776|    approved[entry["user_id"]] = {"user_name": entry.get("user_name",""), "approved_at": time.time()}
   777|    _wjson(PAIRING_DIR / f"{platform}-approved.json", approved)
   778|    return JSONResponse({"ok": True})
   779|
   780|
   781|async def api_pairing_deny(request: Request):
   782|    if err := guard(request): return err
   783|    try: body = await request.json()
   784|    except Exception: return JSONResponse({"error": "Invalid JSON"}, status_code=400)
   785|    platform, code = body.get("platform",""), body.get("code","").upper().strip()
   786|    p = PAIRING_DIR / f"{platform}-pending.json"
   787|    pending = _pjson(p)
   788|    if code in pending:
   789|        del pending[code]
   790|        _wjson(p, pending)
   791|    return JSONResponse({"ok": True})
   792|
   793|
   794|async def api_pairing_approved(request: Request):
   795|    if err := guard(request): return err
   796|    out = []
   797|    for p in _platforms("approved"):
   798|        for uid, info in _pjson(PAIRING_DIR / f"{p}-approved.json").items():
   799|            out.append({"platform": p, "user_id": uid,
   800|                        "user_name": info.get("user_name",""), "approved_at": info.get("approved_at",0)})
   801|    return JSONResponse({"approved": out})
   802|
   803|
   804|async def api_pairing_revoke(request: Request):
   805|    if err := guard(request): return err
   806|    try: body = await request.json()
   807|    except Exception: return JSONResponse({"error": "Invalid JSON"}, status_code=400)
   808|    platform, uid = body.get("platform",""), body.get("user_id","")
   809|    if not platform or not uid:
   810|        return JSONResponse({"error": "platform and user_id required"}, status_code=400)
   811|    p = PAIRING_DIR / f"{platform}-approved.json"
   812|    approved = _pjson(p)
   813|    if uid in approved:
   814|        del approved[uid]
   815|        _wjson(p, approved)
   816|    return JSONResponse({"ok": True})
   817|
   818|
   819|# ── Reverse proxy → Hermes dashboard ──────────────────────────────────────────
   820|_WIDGET_LINK_STYLE = (
   821|    "background:rgba(20,24,31,0.92);backdrop-filter:blur(8px);"
   822|    "border:1px solid #252d3d;border-radius:6px;padding:6px 12px;"
   823|    "color:#c9d1d9;text-decoration:none;display:inline-flex;"
   824|    "align-items:center;gap:6px;"
   825|)
   826|BACK_TO_SETUP_WIDGET = (
   827|    '<div id="hermes-back-widget" style="position:fixed;bottom:14px;right:14px;'
   828|    'z-index:99999;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;'
   829|    'font-size:11px;display:flex;gap:8px;">'
   830|    f'<a href="/setup" style="{_WIDGET_LINK_STYLE}">← Setup</a>'
   831|    f'<a href="/logout" style="{_WIDGET_LINK_STYLE}">Sign out</a>'
   832|    '</div>'
   833|)
   834|
   835|DASHBOARD_UNAVAILABLE_HTML = """<!DOCTYPE html>
   836|<html lang="en"><head><meta charset="UTF-8"><title>Dashboard starting…</title>
   837|<style>body{background:#0d0f14;color:#c9d1d9;font-family:ui-monospace,Menlo,monospace;
   838|display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}
   839|.card{max-width:480px;padding:32px;border:1px solid #252d3d;border-radius:12px;
   840|background:#14181f;text-align:center}
   841|h1{font-size:16px;color:#d29922;margin:0 0 12px;font-weight:600}
   842|p{font-size:13px;color:#6b7688;line-height:1.6;margin:0 0 16px}
   843|a{color:#6272ff;text-decoration:none;border:1px solid #252d3d;border-radius:6px;
   844|padding:7px 14px;font-size:12px;display:inline-block}
   845|a:hover{border-color:#6272ff}</style></head>
   846|<body><div class="card">
   847|<h1>⚠ Hermes dashboard unavailable</h1>
   848|<p>The native Hermes dashboard is not responding on port %d.<br>
   849|It may still be starting up, or it may have crashed.</p>
   850|<p>Try refreshing in a few seconds, or head back to setup.</p>
   851|<a href="/setup">← Back to Setup</a>
   852|</div>
   853|<script>setTimeout(()=>location.reload(),4000);</script>
   854|</body></html>""" % HERMES_DASHBOARD_PORT
   855|
   856|
   857|async def _proxy_to_dashboard(request: Request) -> Response:
   858|    """Forward an authenticated request to the Hermes dashboard subprocess.
   859|
   860|    Assumes edge auth (basic auth middleware) has already validated the caller.
   861|    HTTP-only: the native Hermes dashboard does not use WebSockets.
   862|    """
   863|    client = get_http_client()
   864|    target = f"{HERMES_DASHBOARD_URL}{request.url.path}"
   865|    if request.url.query:
   866|        target = f"{target}?{request.url.query}"
   867|
   868|    req_headers = {
   869|        k: v for k, v in request.headers.items()
   870|        if k.lower() not in HOP_BY_HOP
   871|    }
   872|    body = await request.body()
   873|
   874|    try:
   875|        upstream = await client.request(
   876|            request.method,
   877|            target,
   878|            headers=req_headers,
   879|            content=body,
   880|        )
   881|    except (httpx.ConnectError, httpx.ConnectTimeout):
   882|        return HTMLResponse(DASHBOARD_UNAVAILABLE_HTML, status_code=503)
   883|    except httpx.RequestError as e:
   884|        print(f"[proxy] upstream error for {request.method} {request.url.path}: {e}", flush=True)
   885|        return HTMLResponse(DASHBOARD_UNAVAILABLE_HTML, status_code=502)
   886|
   887|    # Surface non-2xx responses from hermes into Railway logs so we can
   888|    # diagnose 401/500s without needing browser DevTools access.
   889|    if upstream.status_code >= 400:
   890|        body_snip = upstream.content[:200].decode("utf-8", errors="replace")
   891|        print(
   892|            f"[proxy] {request.method} {request.url.path} -> {upstream.status_code} "
   893|            f"body={body_snip!r}",
   894|            flush=True,
   895|        )
   896|
   897|    # Strip hop-by-hop and length/encoding headers — Starlette recomputes them.
   898|    resp_headers = {
   899|        k: v for k, v in upstream.headers.items()
   900|        if k.lower() not in HOP_BY_HOP
   901|        and k.lower() not in ("content-encoding", "content-length")
   902|    }
   903|
   904|    content = upstream.content
   905|    content_type = upstream.headers.get("content-type", "").lower()
   906|
   907|    # Inject the "← Setup" widget into HTML pages so users can always return.
   908|    if "text/html" in content_type and b"</body>" in content:
   909|        try:
   910|            text = content.decode("utf-8", errors="replace")
   911|            text = text.replace("</body>", BACK_TO_SETUP_WIDGET + "</body>", 1)
   912|            content = text.encode("utf-8")
   913|        except Exception:
   914|            pass  # on any error, fall back to raw upstream content
   915|
   916|    return Response(
   917|        content=content,
   918|        status_code=upstream.status_code,
   919|        headers=resp_headers,
   920|    )
   921|
   922|
   923|async def route_gateway_api(request: Request) -> Response:
   924|    """Proxy /v1/* to the hermes gateway HTTP API (port 8642).
   925|
   926|    Used by hermes-workspace to reach the OpenAI-compatible gateway API
   927|    without private networking. Auth is handled by the gateway's own
   928|    API_SERVER_KEY check (Bearer token in Authorization header).
   929|    No cookie auth here — workspace sends its own API_SERVER_KEY.
   930|    """
   931|    client = get_http_client()
   932|    target = f"{HERMES_GATEWAY_URL}{request.url.path}"
   933|    if request.url.query:
   934|        target = f"{target}?{request.url.query}"
   935|    req_headers = {k: v for k, v in request.headers.items() if k.lower() not in HOP_BY_HOP}
   936|    body = await request.body()
   937|    try:
   938|        upstream = await client.request(request.method, target, headers=req_headers, content=body)
   939|    except (httpx.ConnectError, httpx.ConnectTimeout):
   940|        return JSONResponse({"error": "Gateway unavailable"}, status_code=503)
   941|    except httpx.RequestError as e:
   942|        print(f"[gateway-proxy] error for {request.method} {request.url.path}: {e}", flush=True)
   943|        return JSONResponse({"error": "Gateway error"}, status_code=502)
   944|    resp_headers = {
   945|        k: v for k, v in upstream.headers.items()
   946|        if k.lower() not in HOP_BY_HOP and k.lower() not in ("content-encoding", "content-length")
   947|    }
   948|    return Response(content=upstream.content, status_code=upstream.status_code, headers=resp_headers)
   949|
   950|
   951|async def route_root(request: Request) -> Response:
   952|    """GET /: first-visit smart redirect, otherwise proxy to the dashboard.
   953|
   954|    - Unconfigured + bare GET `/` → bounce to `/setup` so new users land on
   955|      the wizard instead of a half-empty dashboard.
   956|    - Sidebar / in-app links pass `?force=1` to opt out of that redirect —
   957|      users who explicitly want the dashboard (e.g. to set providers via
   958|      the Keys tab) can still reach it without saving config first.
   959|    - Non-GET (SPA API calls, etc.) always proxy through.
   960|    """
   961|    if err := guard(request): return err
   962|    if (request.method == "GET"
   963|            and request.query_params.get("force") != "1"
   964|            and not is_config_complete()):
   965|        return RedirectResponse("/setup", status_code=302)
   966|    return await _proxy_to_dashboard(request)
   967|
   968|
   969|async def route_proxy(request: Request) -> Response:
   970|    """Catch-all: forward any unmatched path to the Hermes dashboard."""
   971|    if err := guard(request): return err
   972|    return await _proxy_to_dashboard(request)
   973|
   974|
   975|async def route_setup_404(request: Request) -> Response:
   976|    """Typos under /setup/* should 404 here — not fall through to the proxy."""
   977|    if err := guard(request): return err
   978|    return Response("Not Found", status_code=404, media_type="text/plain")
   979|
   980|
   981|# ── App lifecycle ─────────────────────────────────────────────────────────────
   982|async def auto_start():
   983|    if is_config_complete():
   984|        asyncio.create_task(gw.start())
   985|    else:
   986|        print("[server] Config incomplete — gateway not started. Configure provider + model in the admin UI.", flush=True)
   987|
   988|
   989|@asynccontextmanager
   990|async def lifespan(app):
   991|    # Dashboard runs always — it's the user-facing UI after setup is done,
   992|    # and it's independent of gateway state.
   993|    asyncio.create_task(dash.start())
   994|    await auto_start()
   995|    try:
   996|        yield
   997|    finally:
   998|        await asyncio.gather(
   999|            gw.stop(),
  1000|            dash.stop(),
  1001|            return_exceptions=True,
  1002|        )
  1003|        global _http_client
  1004|        if _http_client is not None:
  1005|            await _http_client.aclose()
  1006|            _http_client = None
  1007|
  1008|
  1009|# ── WebSocket reverse proxy ──────────────────────────────────────────────────
  1010|# The hermes dashboard exposes 4 WebSocket endpoints when started with --tui.
  1011|# Three are opened by the browser SPA and need to flow through our reverse
  1012|# proxy; the fourth (/api/pub) is opened only by the PTY child against
  1013|# loopback and is intentionally NOT proxied — exposing it would let an
  1014|# authed user spam events into channels.
  1015|#
  1016|#   /api/pty     binary stream — embedded TUI keystrokes/output
  1017|#   /api/ws      JSON-RPC      — gateway sidecar driving Chat metadata
  1018|#   /api/events  text frames   — dashboard subscriber for /api/pub fan-out
  1019|#
  1020|# Auth model (matches the HTTP proxy):
  1021|#   * Edge: our HMAC cookie via _is_authenticated. WebSocket inherits .cookies
  1022|#     from starlette HTTPConnection so the same helper works unchanged.
  1023|#   * Upstream: hermes's own ?token=<_SESSION_TOKEN> query param. The SPA
  1024|#     fetches that token via /api/auth/session-token and includes it in the
  1025|#     WS URL, so we just forward path + query verbatim.
  1026|PROXIED_WS_PATHS = ("/api/pty", "/api/ws", "/api/events")
  1027|
  1028|
  1029|async def _ws_pump_client_to_upstream(
  1030|    client: WebSocket,
  1031|    upstream: websockets.WebSocketClientProtocol,
  1032|) -> None:
  1033|    """Forward client → upstream until the client side disconnects.
  1034|
  1035|    Handles both binary (PTY bytes) and text (JSON-RPC) frames.
  1036|    """
  1037|    try:
  1038|        while True:
  1039|            msg = await client.receive()
  1040|            if msg.get("type") == "websocket.disconnect":
  1041|                return
  1042|            data = msg.get("bytes")
  1043|            if data is not None:
  1044|                await upstream.send(data)
  1045|                continue
  1046|            text = msg.get("text")
  1047|            if text is not None:
  1048|                await upstream.send(text)
  1049|    except (WebSocketDisconnect, websockets.exceptions.ConnectionClosed):
  1050|        return
  1051|    except Exception as e:
  1052|        print(f"[ws-proxy] client→upstream error on {client.url.path}: {e!r}", flush=True)
  1053|        return
  1054|
  1055|
  1056|async def _ws_pump_upstream_to_client(
  1057|    upstream: websockets.WebSocketClientProtocol,
  1058|    client: WebSocket,
  1059|) -> None:
  1060|    """Forward upstream → client until upstream closes."""
  1061|    try:
  1062|        async for msg in upstream:
  1063|            if isinstance(msg, bytes):
  1064|                await client.send_bytes(msg)
  1065|            else:
  1066|                await client.send_text(msg)
  1067|    except (websockets.exceptions.ConnectionClosed, WebSocketDisconnect):
  1068|        return
  1069|    except Exception as e:
  1070|        print(f"[ws-proxy] upstream→client error on {client.url.path}: {e!r}", flush=True)
  1071|        return
  1072|
  1073|
  1074|async def ws_proxy(websocket: WebSocket) -> None:
  1075|    """Reverse-proxy a single WebSocket from browser → hermes dashboard.
  1076|
  1077|    Order matters: connect upstream BEFORE accepting the client. If hermes
  1078|    is wedged or rejects the upgrade, we close the client with a meaningful
  1079|    code instead of accepting and then dropping silently.
  1080|
  1081|    Connection lifecycle:
  1082|      1. Verify edge cookie auth → 4401 close on failure
  1083|      2. Open upstream WS with bounded open_timeout → 1011 on failure
  1084|      3. Accept client
  1085|      4. Spawn two pump tasks (bidirectional byte forwarding)
  1086|      5. When either direction ends (client navigates away, upstream PTY
  1087|         exits, etc.), cancel the other task and close both sockets
  1088|    """
  1089|    # 1. Edge auth.
  1090|    if not _is_authenticated(websocket):
  1091|        # Close before accept — browser sees the handshake fail (expected
  1092|        # for unauthenticated calls).
  1093|        await websocket.close(code=4401)
  1094|        return
  1095|
  1096|    # 2. Build upstream URL preserving the SPA's path + query (the query
  1097|    #    contains the hermes session token + channel id).
  1098|    path = websocket.url.path
  1099|    qs = websocket.url.query
  1100|    upstream_url = f"ws://{HERMES_DASHBOARD_HOST}:{HERMES_DASHBOARD_PORT}{path}"
  1101|    if qs:
  1102|        upstream_url = f"{upstream_url}?{qs}"
  1103|
  1104|    try:
  1105|        upstream = await websockets.connect(
  1106|            upstream_url,
  1107|            open_timeout=5,
  1108|            # Don't forward client cookies/headers — hermes WS auth is
  1109|            # purely token-based via the URL, and forwarding random
  1110|            # headers risks future upstream surprises.
  1111|        )
  1112|    except (asyncio.TimeoutError, OSError, websockets.exceptions.WebSocketException) as e:
  1113|        # Hermes dashboard down, restarting, or rejected the upgrade
  1114|        # (e.g. bad/missing session token).
  1115|        print(f"[ws-proxy] upstream connect failed for {path}: {e!r}", flush=True)
  1116|        # 1011 = internal error; client SPA will surface a generic close.
  1117|        await websocket.close(code=1011)
  1118|        return
  1119|
  1120|    # 3. Both sides ready — accept and start pumping.
  1121|    await websocket.accept()
  1122|
  1123|    pump_in = asyncio.create_task(_ws_pump_client_to_upstream(websocket, upstream))
  1124|    pump_out = asyncio.create_task(_ws_pump_upstream_to_client(upstream, websocket))
  1125|
  1126|    try:
  1127|        # First side to finish wins; cancel the other.
  1128|        done, pending = await asyncio.wait(
  1129|            (pump_in, pump_out),
  1130|            return_when=asyncio.FIRST_COMPLETED,
  1131|        )
  1132|        for task in pending:
  1133|            task.cancel()
  1134|            try:
  1135|                await task
  1136|            except (asyncio.CancelledError, Exception):
  1137|                pass
  1138|    finally:
  1139|        # websockets.connect() outside `async with` doesn't auto-close;
  1140|        # do it explicitly. Same for the client side if still open.
  1141|        try:
  1142|            await upstream.close()
  1143|        except Exception:
  1144|            pass
  1145|        if websocket.client_state == WebSocketState.CONNECTED:
  1146|            try:
  1147|                await websocket.close()
  1148|            except Exception:
  1149|                pass
  1150|
  1151|
  1152|ANY_METHOD = ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]
  1153|
  1154|routes = [
  1155|    # Public — no auth required.
  1156|    Route("/health",                            route_health),
  1157|    Route("/login",                             page_login,          methods=["GET"]),
  1158|    Route("/login",                             login_post,          methods=["POST"]),
  1159|    Route("/logout",                            logout),
  1160|
  1161|    # Our setup wizard + management API, all under /setup/* (cookie-auth guarded).
  1162|    Route("/setup",                             page_index),
  1163|    Route("/setup/",                            page_index),
  1164|    Route("/setup/api/config",                  api_config_get,      methods=["GET"]),
  1165|    Route("/setup/api/config",                  api_config_put,      methods=["PUT"]),
  1166|    Route("/setup/api/status",                  api_status),
  1167|    Route("/setup/api/logs",                    api_logs),
  1168|    Route("/setup/api/gateway/start",           api_gw_start,        methods=["POST"]),
  1169|    Route("/setup/api/gateway/stop",            api_gw_stop,         methods=["POST"]),
  1170|    Route("/setup/api/gateway/restart",         api_gw_restart,      methods=["POST"]),
  1171|    Route("/setup/api/config/reset",            api_config_reset,    methods=["POST"]),
  1172|    Route("/setup/api/pairing/pending",         api_pairing_pending),
  1173|    Route("/setup/api/pairing/approve",         api_pairing_approve, methods=["POST"]),
  1174|    Route("/setup/api/pairing/deny",            api_pairing_deny,    methods=["POST"]),
  1175|    Route("/setup/api/pairing/approved",        api_pairing_approved),
  1176|    Route("/setup/api/pairing/revoke",          api_pairing_revoke,  methods=["POST"]),
  1177|
  1178|    # /setup/* typos return a real 404 — not a silent proxy fallthrough.
  1179|    Route("/setup/{path:path}",                 route_setup_404,     methods=ANY_METHOD),
  1180|
  1181|    # Reverse-proxy hermes's dashboard WebSockets (Chat tab + sidecar).
  1182|    # WebSocketRoute is matched independently of HTTP routes, so order
  1183|    # relative to the catch-all HTTP `Route("/{path:path}", ...)` below
  1184|    # doesn't matter — but listing them as a group keeps the surface
  1185|    # area auditable. Only paths in PROXIED_WS_PATHS are forwarded;
  1186|    # /api/pub is intentionally omitted.
  1187|    WebSocketRoute("/api/pty",                  ws_proxy),
  1188|    WebSocketRoute("/api/ws",                   ws_proxy),
  1189|    WebSocketRoute("/api/events",               ws_proxy),
  1190|
  1191|    # Gateway HTTP API proxy — for hermes-workspace (no cookie auth, uses API_SERVER_KEY).
  1192|    Route("/v1/{path:path}",                    route_gateway_api,   methods=ANY_METHOD),
  1193|
  1194|    # Root: redirect to /setup if unconfigured, otherwise proxy the dashboard.
  1195|    Route("/",                                  route_root,          methods=ANY_METHOD),
  1196|
  1197|    # Catch-all: everything else proxies to the Hermes dashboard subprocess.
  1198|    Route("/{path:path}",                       route_proxy,         methods=ANY_METHOD),
  1199|]
  1200|
  1201|# No middleware — auth is enforced per-handler via guard(). This keeps /health
  1202|# and /login truly unauthenticated without middleware gymnastics.
  1203|app = Starlette(routes=routes, lifespan=lifespan)
  1204|
  1205|if __name__ == "__main__":
  1206|    import uvicorn
  1207|    port = int(os.environ.get("PORT", "8080"))
  1208|    loop = asyncio.new_event_loop()
  1209|    asyncio.set_event_loop(loop)
  1210|    config = uvicorn.Config(app, host="0.0.0.0", port=port, log_level="info", loop="asyncio")
  1211|    server = uvicorn.Server(config)
  1212|
  1213|    def _shutdown():
  1214|        loop.create_task(gw.stop())
  1215|        loop.create_task(dash.stop())
  1216|        server.should_exit = True
  1217|
  1218|    for sig in (signal.SIGTERM, signal.SIGINT):
  1219|        loop.add_signal_handler(sig, _shutdown)
  1220|
  1221|    loop.run_until_complete(server.serve())
  1222|