# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=2.0,<3"]
# ///
"""claude-box MCP server: lets Claude set up and check claude-box workspaces for the user.

A thin layer over the `claude-box` CLI (doctor, init, set, secret, list), so the CLI and this
server always behave the same. No tool accepts or returns a secret value: secrets go from the
user's clipboard straight into the macOS Keychain.

Register it yourself (claude-box never does this for you):
    claude mcp add claude-box -- claude-box-mcp                              # installed package
    claude mcp add claude-box -- uv run --script ~/claude-box/mcp/server.py  # from a clone
"""

import os
import re
import subprocess
from pathlib import Path

from mcp.server.mcpserver import MCPServer

_HERE = Path(__file__).resolve().parent
# Installed package: bundled next to this module. Clone: the repo's bin/.
CLI = next(
    p for p in (_HERE / "data" / "bin" / "claude-box", _HERE.parent / "bin" / "claude-box") if p.exists()
)
ANSI = re.compile(r"\x1b\[[0-9;]*m")

mcp = MCPServer(
    "claude-box",
    instructions="""\
claude-box runs Claude Code in a Docker container per project ("workspace"), separated from the
user's host setup. Use these tools to set up and check workspaces for the user.

Typical setup flow:
0. Start with doctor (no workspace) to check the user's system. Relay anything missing with its
   fix (e.g. start Docker Desktop). The user may never have used the claude-box CLI: if it isn't
   on their PATH, give them the ln command doctor prints to run themselves, or use the full path
   in the start command at the end. Don't run commands on their machine for them.
1. create_workspace with the repo URL. If cloning fails because the repo is private, the user
   needs a token first (step 3), then call create_workspace again.
2. Ask the user what matters, then configure_workspace: which profile (their private Claude
   account, or a separate one such as "work"), whether claude.ai connectors (Slack, Jira, ...)
   should be available, whether the project needs Docker (create_workspace reports compose
   files), and a terminal color (dark enough for white text).
3. For each secret, tell the user exactly which token to create (link and minimal scopes, with an
   expiry), to COPY it and to say when done. NEVER ask the user to paste a secret into the chat.
   Then call store_secret_from_clipboard; it validates the token and clears the clipboard.
4. Run doctor on the workspace and fix what it reports, then tell the user to start the box with
   `claude-box <workspace>` (first start on a new profile asks for a Claude login in the box).

When the user says a box doesn't work, run doctor on that workspace (list_workspaces if unsure
which) and explain the problems and fixes in plain words.

Token guidance: GitHub fine-grained token (only the needed repos; Contents + Pull requests
read/write); GitLab token with read_repository + write_repository (+ api for merge requests);
Atlassian API token created while signed in as the account used for JIRA_USERNAME.
""",
)


def run(*args: str) -> str:
    """Run the claude-box CLI and return its output (without colors) plus the exit status."""
    proc = subprocess.run(
        ["/bin/bash", str(CLI), *args], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=900,
        env={**os.environ, "CLAUDE_BOX_VIA_MCP": "1"},
    )
    out = ANSI.sub("", (proc.stdout + proc.stderr).strip())
    return out + ("" if proc.returncode == 0 else f"\n(exit status {proc.returncode})")


@mcp.tool()
def doctor(workspace: str | None = None) -> str:
    """Check the user's claude-box setup and report problems with concrete next steps.

    Without a workspace it checks the system (Docker, Keychain, uv, PATH, MCP registration).
    With a workspace it also checks git remotes, whether secrets exist and actually work against
    GitHub/GitLab/Jira, and whether the project image builds. Changes nothing.
    """
    return run("doctor", workspace) if workspace else run("doctor")


@mcp.tool()
def list_workspaces() -> str:
    """List the user's claude-box workspaces with profile, connectors, docker and secrets status."""
    return run("list")


@mcp.tool()
def create_workspace(repo_url: str, name: str | None = None) -> str:
    """Create a workspace for a repo: clone it over HTTPS into ~/claude-box/workspaces/<name>,
    generate .claude-box/ (Dockerfile with detected Go/pnpm versions, required token names) and keep
    .claude-box/ out of the repo's git. Safe to call again, e.g. after storing a token for a
    private repo. SSH URLs (git@host:path) are converted to HTTPS.
    """
    return run("init", repo_url, *([name] if name else []))


@mcp.tool()
def configure_workspace(
    workspace: str,
    profile: str | None = None,
    connectors: bool | None = None,
    docker: bool | None = None,
    color: str | None = None,
    env: dict[str, str] | None = None,
) -> str:
    """Change workspace settings. Only the given settings change.

    profile: which Claude account/home to use ("private" by default, e.g. "work").
    connectors: allow the Claude account's claude.ai connectors in the box (off by default).
    docker: give the box its own private Docker daemon (off by default; privileged in the
      Docker Desktop VM, so only when the project needs Docker).
    color: terminal background as #RRGGBB while the box runs; pick a dark color so white text
      stays readable (contrast 7:1 or more).
    env: non-secret environment variables, e.g. {"GITLAB_HOST": "gitlab.example.com"}.
    """
    results = []
    if profile is not None:
        results.append(run("set", workspace, "profile", profile))
    if connectors is not None:
        results.append(run("set", workspace, "connectors", "on" if connectors else "off"))
    if docker is not None:
        results.append(run("set", workspace, "docker", "on" if docker else "off"))
    if color is not None:
        results.append(run("set", workspace, "color", color))
    for key, value in (env or {}).items():
        results.append(run("set", workspace, "env", f"{key}={value}"))
    return "\n".join(results) or "Nothing to change."


@mcp.tool()
def store_secret_from_clipboard(workspace: str, var: str) -> str:
    """Store the secret the user has COPIED as <var> for <workspace> in the macOS Keychain.

    Reads the clipboard on the user's machine, rejects obvious mistakes (a pasted command,
    whitespace, a truncated Atlassian token), stores it, clears the clipboard and checks the
    token against GitHub/GitLab/Jira where possible. The value is never returned or shown.
    Before calling, tell the user which token to create and to copy it; never ask them to paste it.
    var is an env var name such as GH_TOKEN, GITLAB_TOKEN, JIRA_USERNAME or JIRA_API_TOKEN.
    """
    return run("secret", workspace, var)


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
