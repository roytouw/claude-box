# Example: several repos, GitHub + GitLab, own profile

A workspace for a team whose code lives in several repos on both GitHub and a self-hosted GitLab,
where you can't (or don't want to) add `.claude-box/` to the repos themselves. The config sits in
the workspace folder, next to the clones:

```
~/claude-box/workspaces/example-team/   not a repo; the box mounts this whole folder
  .claude-box/
    Dockerfile    base image + Go
    secrets.txt   GH_TOKEN, GITLAB_TOKEN (from the Keychain)
    env           GITLAB_HOST=gitlab.example.com (not secret)
    profile       work  → own Claude login, plugins and memory, apart from your private profile
    connectors    on    → the work account's claude.ai connectors (Jira, Slack, ...) are available
    color         #0F2E2E
  CLAUDE.md       how the repos fit together; Claude reads it at start
  service-api/    clone (GitLab)
  shared-lib/     clone (GitLab)
  web-app/        clone (GitHub)
```

## Set up

1. Copy this folder to `~/claude-box/workspaces/example-team`, set `GITLAB_HOST` in
   `.claude-box/env` and describe your repos in `CLAUDE.md`.
2. Clone the repos into it over HTTPS (the box has no SSH keys).
3. Create the tokens and store each one from the clipboard:
   - `GH_TOKEN`: [fine-grained token](https://github.com/settings/personal-access-tokens/new),
     only the GitHub repos you need, Contents + Pull requests read/write.
   - `GITLAB_TOKEN`: GitLab → Preferences → Access tokens, scopes `read_repository`,
     `write_repository` (add `api` if Claude should open MRs with `glab`).
   ```sh
   claude-box secret example-team GITLAB_TOKEN   # copy the token first; it reads the clipboard
   claude-box secret example-team GH_TOKEN
   ```
4. `claude-box example-team`. The first run on the `work` profile asks you to log in: use the
   work Claude account.

git pushes to github.com with `GH_TOKEN` and to `GITLAB_HOST` with `GITLAB_TOKEN` automatically.
If the GitLab is only reachable over VPN, keep the VPN on: the box uses the Mac's network.
