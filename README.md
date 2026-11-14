# claude-box

Run Claude Code in a Docker container per project, separated from your host setup.
The container only sees the project folder and its own home volume: no host `~/.claude`
(plugins, skills, memory), no SSH keys, no git, gh or glab config. Secrets come from your macOS
Keychain at start-up and are never baked into an image.

## Install

```sh
git clone https://github.com/roytouw/claude-box ~/claude-box
~/claude-box/bin/claude-box doctor   # checks your system and tells you what's still needed
```

`doctor` changes nothing; it prints the commands to run yourself (putting `claude-box` on your
PATH, optionally registering the MCP server).

## Set up a workspace

**With Claude** (optional MCP server, needs [uv](https://docs.astral.sh/uv/)): register it once
yourself, then just ask Claude, e.g. *"set up a claude-box for gitlab.com/acme/shop"*. Claude
clones the repo, asks about profile, connectors, Docker and color, and walks you through the
tokens. Secrets go from your clipboard straight into the Keychain; Claude never sees them.

```sh
claude mcp add claude-box -- uv run --script ~/claude-box/mcp/server.py
```

**Or by hand:**

```sh
claude-box init <repo-url> [name]      # clone over HTTPS, generate .claude-box/ (detects Go, pnpm)
claude-box secret <name> GITLAB_TOKEN  # copy the token first: stores the clipboard, checks it, clears it
claude-box set <name> docker on        # profile | connectors | docker | color | env
claude-box doctor <name>               # checks remotes, secrets (against GitHub/GitLab/Jira), image
claude-box list                        # all workspaces
```

## Use

```sh
claude-box myproject           # agent view in ~/claude-box/workspaces/myproject
claude-box --chat myproject    # a plain new chat instead
claude-box --shell myproject   # bash instead
```

Edit the code with any IDE on the host; the folder is mounted into the container.

**Profiles** keep accounts apart. Each profile is its own Docker volume with its own Claude login,
plugins and memory (`private` by default). Run two side by side, e.g. a private and a work account:

```sh
claude-box myproject                 # profile "private"
claude-box --profile work teamstuff  # profile "work", logs in separately the first time
```

## Configure a workspace

Add a `.claude-box/` folder to the workspace: inside the repo, or next to several clones when you
can't change the repos (see [multi-repo example](examples/multi-repo-github-gitlab)).

```
.claude-box/
  Dockerfile   FROM ghcr.io/roytouw/claude-box:base  + your project's tools
  secrets.txt  env var names, one per line, read from the Keychain (e.g. GH_TOKEN, GITLAB_TOKEN)
  env          non-secret env vars, KEY=value per line (e.g. GITLAB_HOST=gitlab.example.com)
  mcp.json     MCP servers, using ${VAR} for secrets
  profile      profile to use, e.g. work (--profile overrides it)
  connectors   "on" to allow the Claude account's claude.ai connectors (off by default)
  docker       "on" to give the box its own private Docker daemon (off by default, see below)
  color        terminal background while the box runs, e.g. #6E2A0C
```

Store each secret once in your Keychain: copy it, then run `claude-box secret <workspace> <VAR>`.
It refuses obvious mistakes (a copied command, whitespace, a truncated token), checks the token
against GitHub/GitLab/Jira and clears the clipboard. (Avoid the interactive `security -w` prompt:
it silently cuts input at 128 characters.)

Examples: [Go + GitHub + Jira MCP](examples/go-with-jira) ·
[several repos, GitHub + GitLab, work profile](examples/multi-repo-github-gitlab).

## Git access

git gets the right token per host automatically: `github.com` uses `GH_TOKEN`, `GITLAB_HOST`
(default `gitlab.com`) uses `GITLAB_TOKEN`. Clone over HTTPS; the box has no SSH keys. `gh` and
`glab` never keep a login in the profile, so a workspace without a token can't reach the host.

Scope the tokens so an agent can only touch what you pick:

- **GitHub**: [fine-grained token](https://github.com/settings/personal-access-tokens/new),
  **Only select repositories**, **Contents** + **Pull requests** read/write (add **Workflows** if
  it may edit `.github/workflows`), expiry 90 days.
- **GitLab**: personal or group access token with `read_repository` + `write_repository`
  (add `api` for `glab` merge requests), with an expiry date.

## Docker inside the box (opt-in)

With `docker` set to `on`, the box gets its own Docker daemon (`docker:dind`), never your host's
Docker Desktop socket. `docker build`, `docker run -v $(PWD):…` and `docker compose` work, and
published ports are reachable on `localhost` inside the box. The daemon only sees the workspace,
caches images per workspace, and stops when the last box using it exits.

The daemon runs **privileged** in the Docker Desktop VM. That is a trade-off: an agent that
abuses it could reach the VM, and the VM can see the folders Docker Desktop shares from your Mac.
To shrink that, limit Docker Desktop → Settings → Resources → File sharing to `~/claude-box`
(this also affects other bind mounts you use on the Mac). Only turn it on where you need it.
