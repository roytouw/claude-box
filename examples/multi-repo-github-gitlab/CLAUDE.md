# Workspace: example-team

This workspace holds several repositories of one team. Each folder is its own git repo; commit,
branch and open PRs/MRs per repo.

| Folder | Host | What it is |
|---|---|---|
| `service-api/` | GitLab (gitlab.example.com) | backend service |
| `shared-lib/` | GitLab (gitlab.example.com) | library used by service-api |
| `web-app/` | GitHub | frontend |

- Use `glab` for the GitLab repos and `gh` for the GitHub repo.
- Work on feature branches; never push to `main`.
- Jira and other team tools come from the claude.ai connectors of the work account.
