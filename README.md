# claude-box

Run Claude Code in a Docker container per project, separated from your host setup.
The container only sees the project folder and its own home volume: no host `~/.claude`
(plugins, skills, memory), no SSH keys, no git, gh or glab config. Secrets come from your macOS
Keychain at start-up and are never baked into an image.

## Install

```sh
git clone https://github.com/roytouw/claude-box ~/claude-box
ln -s ~/claude-box/bin/claude-box ~/.local/bin/claude-box
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
  color        terminal background while the box runs, e.g. #6E2A0C
```

Store each secret once in your Keychain. Copy it, then store it from the clipboard (the
interactive `-w` prompt silently cuts input at 128 characters):

```sh
security add-generic-password -U -s claude-box/<workspace>/<VAR> -a "$USER" -w "$(pbpaste)"
```

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
