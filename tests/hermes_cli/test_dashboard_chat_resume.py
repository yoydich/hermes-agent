"""Regression tests for dashboard /chat sticky session resume."""

from __future__ import annotations

import hermes_state


def test_dashboard_chat_without_explicit_resume_uses_latest_tui_session(
    monkeypatch, _isolate_hermes_home
):
    """A plain /chat reload must not silently start history=0.

    The browser PTY endpoint often reconnects without a `resume=` query param
    (tab reload, websocket rebuild, dashboard refresh). In that case it should
    continue the latest real TUI chat session instead of spawning a fresh one.
    """
    from hermes_constants import get_hermes_home
    from hermes_state import SessionDB
    import hermes_cli.main as main
    import hermes_cli.web_server as web_server

    monkeypatch.setattr(
        hermes_state,
        "DEFAULT_DB_PATH",
        get_hermes_home() / "state.db",
    )
    monkeypatch.setattr(
        main,
        "_make_tui_argv",
        lambda *args, **kwargs: (["node", "entry.js"], None),
    )

    db = SessionDB()
    try:
        db.create_session("old_tui", "tui")
        db.append_message("old_tui", "user", "old chat")
        db.create_session("latest_tui", "tui")
        db.append_message("latest_tui", "user", "latest chat")
        db.create_session("latest_telegram", "telegram")
        db.append_message("latest_telegram", "user", "not dashboard chat")
    finally:
        db.close()

    _argv, _cwd, env = web_server._resolve_chat_argv(resume=None)

    assert env["HERMES_TUI_RESUME"] == "latest_tui"


def test_dashboard_chat_explicit_resume_still_wins(monkeypatch, _isolate_hermes_home):
    """Opening /chat?resume=<id> must not be overridden by the sticky default."""
    from hermes_constants import get_hermes_home
    from hermes_state import SessionDB
    import hermes_cli.main as main
    import hermes_cli.web_server as web_server

    monkeypatch.setattr(
        hermes_state,
        "DEFAULT_DB_PATH",
        get_hermes_home() / "state.db",
    )
    monkeypatch.setattr(
        main,
        "_make_tui_argv",
        lambda *args, **kwargs: (["node", "entry.js"], None),
    )

    db = SessionDB()
    try:
        db.create_session("latest_tui", "tui")
        db.append_message("latest_tui", "user", "latest chat")
        db.create_session("requested_tui", "tui")
        db.append_message("requested_tui", "user", "requested chat")
    finally:
        db.close()

    _argv, _cwd, env = web_server._resolve_chat_argv(resume="requested_tui")

    assert env["HERMES_TUI_RESUME"] == "requested_tui"
