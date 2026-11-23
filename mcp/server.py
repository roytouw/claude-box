# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=2.0,<3"]
# ///
"""claude-box MCP server: lets Claude set up and check claude-box workspaces for the user.

A thin layer over the `claude-box` CLI (doctor, init, set, secret, trust, list, profiles, status,
stop), so the CLI and this server always behave the same. No tool accepts or returns a secret value: secrets go from the
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
1. create_workspace. Resolve what the user names ("the hue monorepo") to actual repo URLs; ask
   if unsure. Repo folders are always named after the repository (remote-access-monorepo), never
   after how the user described it; claude-box does this itself.
   - One repo: pass no name, so the workspace is named after the repo.
   - Repos the user works on together (one team, one product, code that spans repos) belong in
     ONE workspace: pass all their URLs in one call with a name for the top folder. Propose a
     short name and confirm it with the user before calling. Only make separate workspaces for
     unrelated projects; if unsure, ask.
   - To add a repo to an existing multi-repo workspace, pass that workspace's name and the URL.
     If the workspace is trusted, the new repo folder is trusted with it (the result says so) and
     can be used right away, even in a running box; then skip the other steps unless asked.
   If cloning fails because a repo is private, the user needs a token first (step 3), then call
   create_workspace again with the same arguments.
2. Ask the user what matters, then configure_workspace:
   - Profile: call list_profiles first. A profile is just a named Claude home; its name says
     nothing about which account is in it (a profile called "private" can hold a work login).
     Sharing a profile is the default: workspaces on one profile share its plugins, memory,
     history and agent list. Offer the existing profiles as they are, with the login
     list_profiles reports, and as an opt-in "its own profile for just this workspace"
     (profile "own", named after the workspace; it can use the same Claude account), or a new
     profile under a name the user picks. Don't guess which one is work or private, and don't
     invent names. A new or own profile asks for a Claude login on the box's first start.
   - Whether claude.ai connectors (Slack, Jira, ...) of that profile's account should be
     available, whether the project needs Docker (create_workspace reports compose files), and a
     terminal color (dark enough for white text).
   - Whether the project uses Google Cloud (GCP, GKE, Cloud Run, gcloud in scripts or CI; look
     for hints such as cloudbuild.yaml or gcloud in the repos). If yes: gcloud=True, and ask for
     the default GCP project to set as env CLOUDSDK_CORE_PROJECT. kubectl, k9s and grpcurl are always
     in the box; nothing to turn on for them.
   - Git identity (always): the name and email for commits in the box (git_name, git_email).
     The email must be a verified email on the user's account at the repo host (GitHub/GitLab),
     often a client address for client work. doctor shows the Mac's git identity; offer it as a
     suggestion, but ask which email this account uses.
   - Signed commits: ask whether commits must be signed (show as "Verified"; some clients or
     protected branches require it). If yes, signing=True (needs git_email). This makes a new
     SSH key just for this workspace; the result shows the public key (also copied to the
     clipboard) and where to add it. Tell the user to add it there as a SIGNING key (GitHub:
     Key type "Signing Key"; GitLab: Usage type "Signing"), which can't be used to push or log
     in. An agent in the box can sign commits as the user, which is the point; that is why the
     key is separate per workspace and can be revoked on its own.
3. For each secret, tell the user exactly which token to create (link and minimal scopes, with an
   expiry), to COPY it and to say when done. NEVER ask the user to paste a secret into the chat.
   Then call store_secret_from_clipboard; it validates the token and clears the clipboard.
   gcloud on: there is no token to copy. Tell the user to run `claude-box gcloud-login
   <workspace>` themselves in a terminal (it opens the sign-in in their browser; later, when
   the login expires, `! gcloud auth login --update-adc` in the box works too). The login is kept for that workspace only, and an agent in the box can
   do whatever that Google account can, so suggest an account or project with only the access
   the work needs. For GKE, kubectl in the box works after `gcloud container clusters
   get-credentials <cluster>` there.
4. Run doctor on the workspace and fix what it reports.
5. Before the first start, ask whether to trust the workspace and its repo folders in the box
   (otherwise each repo folder prompts "Workspace not trusted" once, e.g. when sending an agent
   to it). Explain that trusting lets the repos' .claude/ settings and hooks run in the box, and
   call trust_workspace only on yes.
6. Tell the user to start the box with `claude-box <workspace>` (first start on a new profile
   asks for a Claude login in the box).

When the user says a box doesn't work, run doctor on that workspace (list_workspaces if unsure
which) and explain the problems and fixes in plain words.

CLI shape, when you tell the user a command: `claude-box <command> <workspace> [args]` for the
commands (init, set, secret, trust, gcloud-login, doctor, status, logs, stop), and
`claude-box <workspace> [options]` to start a box. `claude-box <command> -h` shows one command's
usage. A workspace must exist before it can start (create_workspace), except "scratch".

Detached boxes (an always-on agent or any long-running script, without a terminal):
- The user starts one themselves:
    claude-box <workspace> --detached '<script> [args]' [--exit '<script> [args]']
  Each is ONE quoted string: a script path relative to the workspace, then its arguments (split
  on spaces; arguments can't contain spaces). --exit is optional: what `claude-box stop` runs in
  the box first, e.g. --detached 'agent/agent.sh run' --exit 'agent/agent.sh stop'.
- The script must stay in the FOREGROUND (exec its long-running process, or end with `wait`).
  A script that starts something in the background and returns makes Docker restart it in a loop
  ("Restarting (0)" in docker ps); the start command notices this in its first seconds, shows the
  output and removes the box again. Help the user change the script, not claude-box.
- It keeps running after the terminal closes and comes back when Docker Desktop restarts (with
  Docker Desktop's "Start when you sign in" on, also after a Mac restart). It has the workspace's
  secrets, settings and Docker daemon, but nothing that needs the Mac terminal (browser links,
  clipboard, `code`). Secrets are read at start: after changing one, stop and start it again.
- Ports: a box opens none by default. To reach e.g. a dev server in the box from the Mac's
  browser, the user adds `--port <mac>[:<box>]` (repeatable or a comma list) when starting it,
  with or without --detached: `claude-box <ws> --port 3000` makes http://localhost:3000 on the
  Mac reach localhost:3000 in the box (also when the server listens on localhost only).
- detached_status shows whether it runs, its restarts and its last output; doctor on the
  workspace also flags one that keeps exiting. stop_detached stops it (only when the user asks).
  To follow the output live, the user runs `claude-box logs <workspace>`.

"Workspace not trusted" in a box (e.g. when sending an agent to a repo folder): trust is kept
per folder in the workspace's profile. Offer trust_workspace; call it only when the user agrees,
since trusting lets the repos' .claude/ settings and hooks run in the box.

Token guidance: GitHub fine-grained token (only the needed repos; Contents + Pull requests
read/write; with signing, also account permissions "SSH signing keys" and "Email addresses"
read-only so doctor can check them); GitLab token with read_repository + write_repository
(+ api for merge requests, or read_user so doctor can check signing keys and emails);
Atlassian API token created while signed in as the account used for JIRA_USERNAME.
""",
)


def run(*args: str) -> str:
    """Run the claude-box CLI and return its output (without colors) plus the exit status.

    It runs in its own session without a controlling terminal, so nothing it starts (git, docker,
    security) can ever read from or wait on the user's Claude terminal.
    """
    try:
        proc = subprocess.run(
            ["/bin/bash", str(CLI), *args], capture_output=True, text=True, stdin=subprocess.DEVNULL,
            timeout=900, start_new_session=True,
            env={**os.environ, "CLAUDE_BOX_VIA_MCP": "1", "GIT_TERMINAL_PROMPT": "0"},
        )
    except subprocess.TimeoutExpired:
        return f"claude-box {' '.join(args[:1])} took longer than 15 minutes and was stopped."
    out = ANSI.sub("", (proc.stdout + proc.stderr).strip())
    return out + ("" if proc.returncode == 0 else f"\n(exit status {proc.returncode})")


@mcp.tool()
def doctor(workspace: str | None = None) -> str:
    """Check the user's claude-box setup and report problems with concrete next steps.

    Without a workspace it checks the system (Docker, Keychain, uv, PATH, MCP registration).
    With a workspace it also checks git remotes, whether secrets exist and actually work against
    GitHub/GitLab/Jira, whether a multi-repo workspace's CLAUDE.md lists all its repos, and whether
    the project image builds. Changes nothing.
    """
    return run("doctor", workspace) if workspace else run("doctor")


@mcp.tool()
def list_workspaces() -> str:
    """List the user's claude-box workspaces with profile, connectors, docker, gcloud, secrets status
    and the state of their detached box (running, restarting, or - for none)."""
    return run("list")


@mcp.tool()
def list_profiles() -> str:
    """List the user's claude-box profiles (named Claude homes), which Claude account is logged in
    to each (organization and email domain only) and which workspaces use them. Use it before
    asking which profile a workspace should use; profile names don't tell which account they hold.
    """
    return run("profiles")


@mcp.tool()
def create_workspace(repo_urls: list[str], name: str | None = None, own_profile: bool = False) -> str:
    """Create a workspace in ~/claude-box/workspaces/<name> with one or more repos, cloned over HTTPS.

    Repo folders are always named after the repository. One repo and no name: the workspace is
    that repo, named after it; .claude-box/ is kept out of its git. Several repos, or a name that
    differs from the repo: name is the top folder (confirm it with the user first) and each repo
    goes in its own subfolder, with .claude-box/ and a CLAUDE.md describing the layout on top. Generates a
    Dockerfile with the Go/pnpm versions found and lists the tokens needed per host (GH_TOKEN for
    GitHub, GITLAB_TOKEN for GitLab). Safe to call again: after storing a token for private repos,
    or with an existing multi-repo workspace's name to add repos (each added repo also gets a row in
    the workspace's CLAUDE.md; what's written there is kept). SSH URLs are converted to HTTPS.
    own_profile: opt-in; give the workspace its own profile named after it (separate plugins,
    memory, history and agents) instead of sharing the default one. Only when the user chose it.
    """
    return run("init", *(["--own-profile"] if own_profile else []), *([name] if name else []), *repo_urls)


@mcp.tool()
def configure_workspace(
    workspace: str,
    profile: str | None = None,
    connectors: bool | None = None,
    docker: bool | None = None,
    gcloud: bool | None = None,
    sync: bool | None = None,
    git_name: str | None = None,
    git_email: str | None = None,
    signing: bool | None = None,
    color: str | None = None,
    env: dict[str, str] | None = None,
    skills: list[str] | None = None,
) -> str:
    """Change workspace settings. Only the given settings change.

    profile: name of the Claude home to use: an existing one from list_profiles, "own" for a
      profile of its own named after the workspace (opt-in), or a new name the user chose (a new
      profile asks for a Claude login on first start). Default "private", shared.
    connectors: allow the Claude account's claude.ai connectors in the box (off by default).
    docker: give the box its own private Docker daemon (off by default; privileged in the
      Docker Desktop VM, so only when the project needs Docker).
    gcloud: add the Google Cloud CLI (with the GKE auth plugin) to the box, logged in per
      workspace (off by default). The user then logs in with `claude-box gcloud-login <ws>`.
    sync: on start, fetch the repos and fast-forward the ones on their default branch without
      local changes (on by default). Only turn it off when the user asks.
    git_name, git_email: git identity for commits in the box. The email must be verified on the
      user's GitHub/GitLab account.
    signing: sign commits and tags with an SSH key made for this workspace (off by default;
      needs git_email). Turning it on returns the public key and where to register it.
    color: terminal background as #RRGGBB while the box runs; pick a dark color so white text
      stays readable (contrast 7:1 or more).
    env: non-secret environment variables, e.g. {"GITLAB_HOST": "gitlab.example.com"}.
    skills: names of the user's own Claude skills (folders in ~/.claude/skills on the Mac) to use
      in the box, mounted read-only. Replaces the list; [] for none. Only skills the user names.
    """
    results = []
    if profile is not None:
        results.append(run("set", workspace, "profile", profile))
    if connectors is not None:
        results.append(run("set", workspace, "connectors", "on" if connectors else "off"))
    if docker is not None:
        results.append(run("set", workspace, "docker", "on" if docker else "off"))
    if gcloud is not None:
        results.append(run("set", workspace, "gcloud", "on" if gcloud else "off"))
    if sync is not None:
        results.append(run("set", workspace, "sync", "on" if sync else "off"))
    if git_name is not None:
        results.append(run("set", workspace, "git-name", git_name))
    if git_email is not None:
        results.append(run("set", workspace, "git-email", git_email))
    if signing is not None:  # after git_email: signing needs it
        results.append(run("set", workspace, "signing", "on" if signing else "off"))
    if color is not None:
        results.append(run("set", workspace, "color", color))
    if skills is not None:
        results.append(run("set", workspace, "skills", ",".join(skills) if skills else "off"))
    for key, value in (env or {}).items():
        results.append(run("set", workspace, "env", f"{key}={value}"))
    return "\n".join(results) or "Nothing to change."


@mcp.tool()
def trust_workspace(workspace: str) -> str:
    """Accept Claude's folder trust prompt for a workspace and its repo folders, in the workspace's
    profile, so agents can be sent to the repo folders without "Workspace not trusted". Only call
    it when the user agreed. Works while boxes on that profile are running.
    """
    return run("trust", workspace)


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


@mcp.tool()
def detached_status(workspace: str) -> str:
    """Show the workspace's detached box (started with `claude-box <ws> --detached '<script>'`):
    running or not, since when, how often it restarted, the script and --exit script it runs, and
    its last 20 lines of output. A box that restarts means its script doesn't stay in the
    foreground. Changes nothing.
    """
    return run("status", workspace)


@mcp.tool()
def stop_detached(workspace: str) -> str:
    """Stop the workspace's detached box: runs its --exit script in the box (if it has one, at
    most 2 minutes), then gives the main script SIGTERM and 30 seconds to exit, and removes the
    box. Only call it when the user asked to stop it. Starting one again is the user's command:
    `claude-box <workspace> --detached '<script> [args]'`.
    """
    return run("stop", workspace)


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
