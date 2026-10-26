# Contributing

Solo-dev workflow — `main` is protected, so everything lands via PR.

## Flow

1. Branch off `main`: `git checkout -b feat/<thing>` (or `fix/`, `chore/`)
2. Commit early, push the branch, open a PR: `gh pr create --fill`
3. Merge when green; branches auto-delete on merge
4. Rebase local work on `main` — history is required to be linear

## Rules enforced on `main`

- Pull requests required (direct pushes rejected)
- No force pushes, no branch deletion
- Linear history (rebase or squash)

## Style

- Commit messages: conventional-ish (`feat:`, `fix:`, `chore:`) — keep them short and say *why*
- Small PRs over big ones, even solo
