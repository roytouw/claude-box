# Example: Go project with GitHub and Jira

A complete `.claude-box/` for a Go project that uses GitHub and Jira/Confluence. Copy the
`.claude-box/` folder into your repo and replace the placeholders.

| File | What it does |
|---|---|
| `Dockerfile` | base image + Go, make, psql and a preinstalled `mcp-atlassian` |
| `mcp.json` | Jira/Confluence MCP server; credentials come in as `${VAR}`, never in the file |
| `secrets.txt` | names of the env vars to inject, read from your Keychain at start |
| `color` | terminal background while the box runs (ember, 10.5:1 with white text) |

## Set up

1. In `mcp.json`, replace `your-site.atlassian.net` with your Atlassian site.
2. Clone your repo over HTTPS (the box has no SSH keys):
   `gh repo clone your-org/your-repo ~/claude-box/workspaces/myproject`
3. Create the tokens and store each one from the clipboard:
   - `GH_TOKEN`: [fine-grained token](https://github.com/settings/personal-access-tokens/new),
     only this repo, Contents + Pull requests read/write.
   - `JIRA_API_TOKEN`: [Atlassian API token](https://id.atlassian.com/manage-profile/security/api-tokens),
     created while signed in with the account you put in `JIRA_USERNAME`.
   ```sh
   security add-generic-password -U -s claude-box/myproject/GH_TOKEN -a "$USER" -w "$(pbpaste)"
   ```
   Use `-w "$(pbpaste)"` rather than the interactive prompt: the prompt silently cuts input at
   128 characters, and Atlassian tokens are 192.
4. Once, inside the box (`claude-box --shell myproject`): `gh auth setup-git`.
5. Run `claude-box myproject` and check `/mcp` shows `jira` connected.
