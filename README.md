# claude-box

Run Claude Code in a Docker container per project, separated from your host setup.
The container only sees the project folder and its own home volume: no host `~/.claude`
(plugins, skills, memory), no SSH keys, no git or gh config. Secrets come from your macOS
Keychain at start-up and are never baked into an image.

## Install

```sh
git clone https://github.com/roytouw/claude-box ~/claude-box
ln -s ~/claude-box/bin/claude-box ~/.local/bin/claude-box
```

## Use

```sh
claude-box myproject           # claude in ~/claude-box/workspaces/myproject
claude-box --shell myproject   # bash instead (first time: run `claude` to log in)
```

Your Claude login lives in a Docker volume (`claude-box-home-private`); switch with `--profile`.
Edit the code with any IDE on the host; the folder is mounted into the container.

## Configure a project

Add a `.claude-box/` folder to the project repo:

```
.claude-box/
  Dockerfile   FROM ghcr.io/roytouw/claude-box:base  + your project's tools
  secrets.txt  one env var name per line, e.g. GH_TOKEN
  mcp.json     MCP servers, using ${VAR} for secrets
  color        terminal background while the box runs, e.g. #4A2208
```

Store each secret once in your Keychain; claude-box prints the command when one is missing:

```sh
security add-generic-password -s claude-box/<workspace>/<VAR> -a "$USER" -w
```

Example `Dockerfile` for a Go project:

```dockerfile
FROM ghcr.io/roytouw/claude-box:base
USER root
RUN curl -fsSL "https://go.dev/dl/go1.26.2.linux-$(dpkg --print-architecture).tar.gz" | tar -C /usr/local -xz
USER agent
ENV PATH="/usr/local/go/bin:${PATH}"
```

## GitHub access

Give the box a fine-grained token so an agent can only touch the repos you pick:

1. https://github.com/settings/personal-access-tokens/new: resource owner = your account,
   **Only select repositories**, permissions **Contents** + **Pull requests** read/write
   (add **Workflows** if it may edit `.github/workflows`), expiry 90 days.
2. List `GH_TOKEN` in `.claude-box/secrets.txt` and store the token:
   `security add-generic-password -s claude-box/<workspace>/GH_TOKEN -a "$USER" -w`
3. Clone over HTTPS (the box has no SSH keys) and run `gh auth setup-git` once in the box.
