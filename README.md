# claude-box

Run Claude Code in a Docker container per project, separated from your host setup.
The container only sees the project folder and its own home volume: no host `~/.claude`
(plugins, skills, memory), no SSH keys, no git, gh or glab config. Secrets come from your macOS
Keychain at start-up and are never baked into an image.

The base image has Claude Code, git, gh, glab, uv, the Docker CLI, kubectl and k9s. The Google
Cloud CLI is opt-in per workspace (see [Google Cloud](#google-cloud-opt-in)).

## Install

Needs [uv](https://docs.astral.sh/uv/) and Docker Desktop. This installs the `claude-box` and
`claude-box-mcp` commands, pinned to a release:

```sh
uv tool install git+https://github.com/roytouw/claude-box@v0.7.0
```

To update, install the newer tag over it (`uv tool upgrade` keeps the pinned tag). Check your
version with `uv tool list`; releases are listed under the repo's tags.

```sh
uv tool install --force git+https://github.com/roytouw/claude-box@v0.7.0
```

Workspaces live in `~/claude-box/workspaces` (override with `CLAUDE_BOX_WORKSPACES`).

## Setup with Claude (MCP)

Register the MCP server yourself:

```sh
claude mcp add claude-box -- claude-box-mcp
```

Then ask Claude, e.g. *"set up a claude-box for gitlab.com/acme/shop"*. Claude checks your system
first, clones the repo, asks about profile, connectors, Docker and color, and walks you through the
tokens. Secrets go from your clipboard straight into the Keychain; Claude never sees them. Later,
"my claude-box for shop doesn't work" makes Claude run the checks and tell you what to fix.

## Manual setup

```sh
claude-box doctor                      # checks your system (changes nothing)

claude-box init <repo-url>             # one repo: workspace named after the repo, .claude-box/ generated (Go, pnpm)
claude-box init <name> <url> <url>...  # repos worked on together: one workspace <name>, a folder per repo (named after it)
claude-box secret <name> GITLAB_TOKEN  # copy the token first: stores the clipboard, checks it, clears it
claude-box set <name> git-email jane@acme.com   # git identity (also: git-name "Jane Doe")
claude-box set <name> signing on       # signed commits: makes an SSH signing key, shows where to add it
claude-box set <name> docker on        # profile | connectors | docker | gcloud | color | env
claude-box gcloud-login <name>         # with gcloud on: log gcloud in for this workspace only
claude-box doctor <name>               # checks remotes, secrets (against GitHub/GitLab/Jira), image
claude-box list                        # all workspaces
claude-box profiles                    # profiles and the Claude account in each
```

## Use

```sh
claude-box myproject           # agent view in ~/claude-box/workspaces/myproject
claude-box --chat myproject    # a plain new chat instead
claude-box --shell myproject   # bash instead
```

Edit the code with any IDE on the host; the folder is mounted into the container. From inside the
box, `code .` (or `!code .` in Claude, or `code <repo>/<file>`) opens that path in VS Code on your
Mac. Use another editor by exporting e.g. `CLAUDE_BOX_EDITOR=cursor` (or `zed`) before starting the
box. Only paths inside the workspace can be opened.

An agent in the box can run `code` too, and it can write `.vscode/` settings and tasks. Keep VS
Code's Workspace Trust on and don't trust `~/claude-box/workspaces`, so a task the agent added
can't run on your Mac when the folder opens.

**Images**: copy or screenshot an image on the Mac (e.g. ⌃⇧⌘4), then press **Ctrl+V** (not ⌘V)
in Claude Code. The launcher hands the box the image from your Mac clipboard on request. Only
images are shared that way, never clipboard text, but anything in the box can ask for the current
clipboard image while the box runs. Links the box opens go to your Mac's browser, and copying in
the box (`xclip`) reaches your Mac clipboard.

**Profiles** keep accounts apart. A profile is a named Docker volume with its own Claude login,
plugins and memory (`private` by default). The name is only a label: the account is whatever you
log in with on its first start. Run two side by side with different accounts:

```sh
claude-box myproject                 # profile "private"
claude-box --profile acme teamstuff  # profile "acme", asks for a Claude login the first time
claude-box profiles                  # which account each profile is logged in to
```

Workspaces on one profile share its plugins, memory and history. To keep a workspace apart
(opt-in), give it its own profile, named after it; the same Claude account works fine:
`claude-box init --own-profile …` or `claude-box set <workspace> profile own`.

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
  gcloud       "on" to add the Google Cloud CLI, logged in per workspace (off by default, see below)
  color        terminal background while the box runs, e.g. #6E2A0C
  git-name     git user.name in the box, e.g. Jane Doe
  git-email    git user.email in the box (verified on your GitHub/GitLab account)
  signing      "on" to sign commits and tags (see below); signing-key.pub is its public key
```

Inside the box `.claude-box/` is read-only, so an agent can't change its own settings, secrets or
image; change them on the host with `claude-box set`/`secret` or the MCP server.

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

## Git identity and signed commits

The box doesn't use your Mac's git config, so each workspace sets its own identity. The email
must be a verified email on your GitHub/GitLab account (for client work, often the client
address):

```sh
claude-box set <workspace> git-name "Jane Doe"
claude-box set <workspace> git-email jane.doe@client.com
```

To sign commits and tags (they then show as **Verified**), turn on signing:

```sh
claude-box set <workspace> signing on
```

This makes a new ed25519 SSH key just for this workspace, stores the private key in your Keychain
(`claude-box/<workspace>/GIT_SIGNING_KEY`) and prints the public key (and copies it) with where to
add it: GitLab → Preferences → SSH Keys with **Usage type: Signing**, or GitHub → Settings → SSH
and GPG keys with **Key type: Signing Key**. A signing-only key can't push or log in. At start the
key is written to the container's own `/tmp`, never to the profile, and git is set up with
`gpg.format ssh`, `commit.gpgsign` and `tag.gpgsign`.

An agent in the box signs commits as you; that's why the key is separate per workspace: remove
it from your account to revoke just that box. `claude-box doctor <workspace>` checks that the key
is registered and the email verified, if the token may read them (GitLab: `read_user` or `api`;
GitHub fine-grained: account permissions **SSH signing keys** and **Email addresses**, read-only).
To make a new key: delete the Keychain item and `.claude-box/signing-key.pub`, then turn signing
on again.

## Docker inside the box (opt-in)

With `docker` set to `on`, the box gets its own Docker daemon (`docker:dind`), never your host's
Docker Desktop socket. `docker build`, `docker run -v $(PWD):…` and `docker compose` work, and
published ports are reachable on `localhost` inside the box. The daemon only sees the workspace,
caches images per workspace, and stops when the last box using it exits.

The daemon runs **privileged** in the Docker Desktop VM. That is a trade-off: an agent that
abuses it could reach the VM, and the VM can see the folders Docker Desktop shares from your Mac.
To shrink that, limit Docker Desktop → Settings → Resources → File sharing to `~/claude-box`
(this also affects other bind mounts you use on the Mac). Only turn it on where you need it.

## Google Cloud (opt-in)

`claude-box set <workspace> gcloud on` adds the Google Cloud CLI and the GKE auth plugin to the
box (an extra image layer, built once on the next start). Then log in, in a terminal:

```sh
claude-box gcloud-login <workspace>    # open the printed link, sign in, paste the code back
claude-box set <workspace> env CLOUDSDK_CORE_PROJECT=my-project   # optional default project
```

The login (also used as Application Default Credentials) and the kubeconfig live in a Docker
volume of that workspace (`claude-box-gcloud-<workspace>`), not in the profile, so other
workspaces never see it. An agent in the box can do whatever that Google account can: use an
account or project with only the access the work needs. For GKE, run
`gcloud container clusters get-credentials <cluster>` in the box and kubectl/k9s work. To log
out, remove the volume: `docker volume rm claude-box-gcloud-<workspace>`.

## Troubleshooting

**"Workspace not trusted"** when sending an agent to a repo folder: trust is kept per folder in the
workspace's profile (not on your Mac). Run `claude-box trust <workspace>` (also fine while the box
runs) to trust the workspace and all its repo folders at once. A repo added later with
`claude-box init <workspace> <url>` is trusted automatically when the workspace already is.

## Develop

Work from a clone: `bin/claude-box` runs directly, and the MCP server runs standalone with
`claude mcp add claude-box-dev -- uv run --script <clone>/mcp/server.py`. Try an install of your
checkout with `uv tool install --force .`. Releases are git tags (`v0.1.0`, …) matching the
version in `pyproject.toml`.

This repo ships its own `.claude-box/` (the `GH_TOKEN` it needs and a terminal color), so you can
work on claude-box in a claude-box: `claude-box init https://github.com/roytouw/claude-box`, store a
fine-grained GitHub token for this repo (Contents + Pull requests read/write) with
`claude-box secret claude-box GH_TOKEN`, then `claude-box claude-box`. Personal settings such as
`profile`, `connectors`, `git-name`, `git-email`, `signing` and `signing-key.pub` stay out of
git: add them to `.git/info/exclude`.
