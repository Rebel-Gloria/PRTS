"""Select checks for one immutable checkout. Unknown evidence always costs a full run."""

import json
import os
import subprocess
from pathlib import Path


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def file_mode(changes):
    if changes and all(
        path == "README.md" or (path.startswith("docs/") and path.endswith(".md"))
        for _, path in changes
    ):
        return "docs"
    if changes and all(
        kind == "M"
        and path.startswith(("PRTS/", "PRTSTests/", "PRTSUITests/"))
        and path.endswith(".swift")
        for kind, path in changes
    ):
        return "source"
    return "full"


def verified_jobs(jobs, sha):
    names = {job["name"] for job in jobs if job["conclusion"] == "success"}
    return {
        f"Full checks {sha}",
        "style-and-boundaries",
        "spatial-tests",
        "app-build (Dev)",
        "app-build (Release)",
    } <= names


def verified_parent(parent):
    repo = os.environ["GITHUB_REPOSITORY"]
    runs = json.loads(
        output(
            "gh",
            "api",
            f"repos/{repo}/actions/workflows/code-quality.yml/runs?branch=main&head_sha={parent}&status=success&per_page=10",
        )
    )
    for run in runs["workflow_runs"]:
        if (
            run["event"] not in ("push", "workflow_dispatch")
            or run["head_sha"] != parent
            or run["head_branch"] != "main"
            or run["head_repository"]["full_name"] != repo
        ):
            continue
        jobs = json.loads(
            output(
                "gh",
                "api",
                f"repos/{repo}/actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs?per_page=100",
            )
        )
        if verified_jobs(jobs["jobs"], parent):
            return True
    return False


def scope(event, parents, base, sha):
    if event != "push" or len(parents) != 1:
        return "full", "non-push or not a single-parent commit"
    try:
        # With rename detection off a move contributes both deleted and added paths.
        data = subprocess.check_output(
            ["git", "diff", "--no-renames", "--name-status", "-z", base, sha, "--"]
        )
        tokens = data.decode().split("\0")[:-1]
        mode = file_mode(list(zip(tokens[::2], tokens[1::2], strict=True)))
        if mode != "full" and verified_parent(base):
            return mode, "direct parent completed full checks under unchanged rules"
        return "full", "inputs require full checks or direct parent lacks full evidence"
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError):
        return "full", "diff or baseline evidence unavailable"


def main():
    sha = output("git", "rev-parse", "HEAD")
    parents = output("git", "show", "-s", "--format=%P", sha).split()
    base = parents[0] if parents else output("git", "hash-object", "-t", "tree", "/dev/null")
    event = os.environ["GITHUB_EVENT_NAME"]
    if event == "pull_request":
        base = output("git", "merge-base", os.environ["PR_BASE"], sha)
    mode, reason = scope(event, parents, base, sha)
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as f:
        print(f"sha={sha}\nbase={base}\nmode={mode}", file=f)
    with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as f:
        print(f"Commit `{sha}` · comparison `{base}` · **{mode}**: {reason}.", file=f)
        print(
            {
                "docs": "Python and whitespace run; macOS checks reuse the parent and are not rerun.",
                "source": "Whole changed files are style checked; all build and functional checks run.",
                "full": "All style, build and functional checks run.",
            }[mode],
            file=f,
        )


if __name__ == "__main__":
    main()
