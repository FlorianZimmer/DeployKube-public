# Parallel work with worktrees (Codex/ChatGPT-safe)

Goal: work on multiple parts of DeployKube in parallel without losing changes or later having to guess “what’s newer”.

## Core rules (non-negotiable)

1. **One task = one branch + one worktree**
   - Never do multi-task work on `main`.

2. **Commits are the only durable state**
   - Uncommitted changes are not part of the commit graph, so they can’t be compared/merged cleanly later.
   - `git stash` is a short-lived escape hatch, not a storage mechanism.

3. **Push early (remote branch = backup)**
   - A pushed task branch makes “newer” obvious (`main..task/<x>` shows exactly what isn’t merged).
   - If a laptop dies, a pushed branch survives. A stash does not (unless you export it).

## Quick start

Create a fresh task worktree:

```bash./scripts/dev/task-new.sh <slug>
```

From inside the new worktree, checkpoint (commit + push) whenever you pause/switch:

```bash./scripts/dev/task-checkpoint.sh -m "wip: <what changed>"
```

See all task worktrees, what’s dirty, and what’s ahead/behind `main`:

```bash./scripts/dev/task-status.sh
```

## How to tell what’s newer

- **If work is committed**, Git can tell you exactly what isn’t on `main`:
  - `git log --oneline main..task/<slug>`
- **If work is uncommitted or stashed**, Git can’t order it relative to `main` in a way that supports safe merges.
  - Fix: checkpoint commit (and push) before you switch tasks.

## Ending a task (no cleanup surprises)

Preferred (GitHub-first):
1. Open a PR for `task/<slug>`.
2. Merge it via GitHub.
3. Ensure the repo setting “delete head branches” is enabled (or delete the branch in the PR UI).
4. Remove the local worktree and branch:
   - `./scripts/dev/task-close.sh task/<slug> --delete-remote`

Local merge (when appropriate):
- `./scripts/dev/task-merge.sh task/<slug>`
  - auto-closes by default (removes the worktree + deletes the local branch)
  - add `--keep` if you want to keep the worktree around temporarily

## Automatic cleanup (recommended)

If a task is merged on GitHub, you still need a local cleanup step.

Prune all merged task worktrees (safe; skips dirty worktrees):

```bash./scripts/dev/task-prune.sh --fetch
```

Optional: enable versioned git hooks so pruning runs automatically after `git pull` / merges:

```bash./scripts/dev/setup-githooks.sh
```

## Stash policy

- Allowed only as a short-lived emergency step (e.g., “I must switch now”).
- Before removing a worktree or ending a session, **stash must be eliminated**:
  - apply stash → checkpoint commit → push.

If you see `git stash list` is non-empty, treat it as “there is hidden work that is not safely tracked”.
