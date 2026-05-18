"""Sync a fork with upstream and push it for platform auto-deploys.

This module is intentionally small and subprocess-driven because it is run by
the dashboard as a background action. Its stdout/stderr become the user-facing
action log.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


DEFAULT_UPSTREAM_URL = "https://github.com/NousResearch/hermes-agent.git"
DEFAULT_BRANCH = "main"


class GitHubUpdateError(RuntimeError):
    pass


def _run(args: list[str], cwd: Path, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=str(cwd),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=check,
    )


def _out(args: list[str], cwd: Path) -> str:
    return _run(args, cwd).stdout.strip()


def _masked_remote(repo: str) -> str:
    return f"https://github.com/{repo}.git"


def _github_push_url(repo: str, token: str) -> str:
    return f"https://x-access-token:{token}@github.com/{repo}.git"


def _configured_token() -> str:
    token = (
        os.getenv("HERMES_GITHUB_UPDATE_TOKEN")
        or os.getenv("GITHUB_TOKEN")
        or os.getenv("GH_TOKEN")
        or ""
    ).strip()
    if not token:
        raise GitHubUpdateError(
            "Missing GitHub write token. Set HERMES_GITHUB_UPDATE_TOKEN in Railway "
            "with repo write access so dashboard updates can push to GitHub."
        )
    return token


def _repo_name() -> str:
    repo = (
        os.getenv("HERMES_GITHUB_UPDATE_REPO")
        or os.getenv("GITHUB_REPOSITORY")
        or "yoydich/hermes-agent"
    ).strip()
    if "/" not in repo:
        raise GitHubUpdateError(
            "Invalid HERMES_GITHUB_UPDATE_REPO. Expected owner/repo, for example yoydich/hermes-agent."
        )
    return repo.removeprefix("https://github.com/").removesuffix(".git")


def _fetch_full_history(remote: str, branch: str, repo_root: Path) -> None:
    """Fetch a branch and remove shallow boundaries when Railway cloned depth=1."""
    _run(
        ["git", "fetch", "--prune", remote, f"+refs/heads/{branch}:refs/remotes/{remote}/{branch}"],
        repo_root,
    )
    if (repo_root / ".git" / "shallow").exists():
        unshallow = _run(["git", "fetch", "--unshallow", remote], repo_root, check=False)
        if unshallow.returncode != 0:
            _run(["git", "fetch", "--deepen=100000", remote, branch], repo_root, check=False)
        _run(
            ["git", "fetch", "--prune", remote, f"+refs/heads/{branch}:refs/remotes/{remote}/{branch}"],
            repo_root,
        )


def sync_github(repo_root: Path) -> int:
    repo_root = repo_root.resolve()
    token = _configured_token()
    repo = _repo_name()
    branch = (os.getenv("HERMES_GITHUB_UPDATE_BRANCH") or DEFAULT_BRANCH).strip() or DEFAULT_BRANCH
    upstream_url = (os.getenv("HERMES_GITHUB_UPSTREAM_URL") or DEFAULT_UPSTREAM_URL).strip()

    print("⚕ Updating Hermes GitHub fork for Railway auto-deploy...")
    print(f"→ Repository: {_masked_remote(repo)}")
    print(f"→ Branch: {branch}")
    print(f"→ Upstream: {upstream_url}")

    dirty = _out(["git", "status", "--porcelain"], repo_root)
    if dirty:
        raise GitHubUpdateError(
            "Working tree is dirty; refusing to auto-merge. Manual update is required."
        )

    _run(["git", "config", "user.name", os.getenv("HERMES_GITHUB_UPDATE_USER", "Hermes Dashboard Update")], repo_root)
    _run(
        [
            "git",
            "config",
            "user.email",
            os.getenv("HERMES_GITHUB_UPDATE_EMAIL", "hermes-dashboard@users.noreply.github.com"),
        ],
        repo_root,
    )

    _run(["git", "remote", "set-url", "origin", _masked_remote(repo)], repo_root, check=False)
    if _run(["git", "remote", "get-url", "upstream"], repo_root, check=False).returncode == 0:
        _run(["git", "remote", "set-url", "upstream", upstream_url], repo_root)
    else:
        _run(["git", "remote", "add", "upstream", upstream_url], repo_root)

    print("→ Fetching origin and upstream...")
    _fetch_full_history("origin", branch, repo_root)
    _fetch_full_history("upstream", branch, repo_root)
    _run(["git", "checkout", "-B", branch, f"origin/{branch}"], repo_root)

    current = _out(["git", "rev-parse", "--short", "HEAD"], repo_root)
    upstream = _out(["git", "rev-parse", "--short", f"upstream/{branch}"], repo_root)
    if _run(["git", "merge-base", "--is-ancestor", f"upstream/{branch}", "HEAD"], repo_root, check=False).returncode == 0:
        print(f"✓ GitHub fork already contains upstream/{branch} ({upstream}).")
        print(f"✓ Current fork commit: {current}")
        return 0

    print(f"→ Merging upstream/{branch} ({upstream}) into fork ({current})...")
    merge = _run(["git", "merge", "--no-edit", f"upstream/{branch}"], repo_root, check=False)
    print(merge.stdout, end="")
    if merge.returncode != 0:
        _run(["git", "merge", "--abort"], repo_root, check=False)
        raise GitHubUpdateError(
            "Automatic merge failed. Manual conflict resolution is required before Railway can auto-deploy."
        )

    merged = _out(["git", "rev-parse", "--short", "HEAD"], repo_root)
    print(f"→ Pushing merged commit {merged} to GitHub...")
    push_url = _github_push_url(repo, token)
    push = _run(["git", "push", push_url, f"HEAD:{branch}"], repo_root, check=False)
    sanitized = push.stdout.replace(token, "***")
    if sanitized:
        print(sanitized, end="")
    if push.returncode != 0:
        raise GitHubUpdateError("GitHub push failed. Check token permissions and branch protection.")

    print("✓ GitHub updated. Railway auto-deploy should start from the pushed commit.")
    return 0


def main() -> int:
    repo_root = Path(os.getenv("HERMES_UPDATE_REPO_ROOT") or Path(__file__).parent.parent)
    try:
        return sync_github(repo_root)
    except GitHubUpdateError as exc:
        print(f"✗ {exc}", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as exc:
        output = (exc.stdout or "").strip()
        if output:
            print(output, file=sys.stderr)
        print(f"✗ Command failed: {' '.join(exc.cmd)}", file=sys.stderr)
        return exc.returncode or 1


if __name__ == "__main__":
    raise SystemExit(main())
