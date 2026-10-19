---
name: git-commit
description: Create a well-formed git commit from the current working-tree changes. Use when the user explicitly asks to commit, stage, or commit their changes.
---
# Git Commit

Create a single, well-formed git commit from the working tree.

Only follow this skill when the user explicitly asked to commit. Never push, amend, rebase, or rewrite history as part of it.

## Procedure

1. **Survey the changes.**
   - Run `git status --porcelain` to list modified, added, and untracked files.
   - Run `git diff` (and `git diff --staged` if something is already staged) to understand what changed.
   - If the working tree is clean, stop and tell the user there is nothing to commit.

2. **Decide what to stage.**
   - If the user named specific files or paths, stage only those.
   - Otherwise stage the changes that belong to the work just done.
   - If a file that looks like a secret (`.env`, `*.pem`, `*.key`, credentials, tokens) is in the change set, stop and warn the user before staging it.

3. **Stage the files.**

   ```sh
   git add <paths>
   ```

4. **Write the commit message.**
   - First run `git log --oneline -10` and match the repository's existing style.
   - If the repo uses Conventional Commits, use `<type>(<scope>): <summary>` with types `feat`, `fix`, `docs`, `refactor`, `test`, `perf`, `chore`, or `ci`.
   - Keep the summary in imperative mood, 72 characters or fewer, with no trailing period.
   - Add a body only when the *why* is not obvious from the diff; wrap it at 72 columns.

5. **Commit.**

   ```sh
   git commit -m "<type>(<scope>): <summary>"
   ```

   For a multi-line message, pass one `-m` flag per paragraph.

6. **Verify and report.**
   - Run `git log -1 --stat` to confirm the commit landed.
   - Report the short hash and the final message to the user. Do not push unless asked.
