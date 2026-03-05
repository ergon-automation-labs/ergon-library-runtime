# Development Setup

## Initial Setup

After cloning the repository, run:

```bash
make install
```

This will:
1. Install git hooks for automated pre-push validation
2. Install dependencies (`mix deps.get`)

## Git Hooks

This repository uses git hooks to automate validation and release publishing.

### Pre-push Hook

**Installed:** `git-hooks/pre-push`  
**Configured via:** `git config core.hooksPath git-hooks`

#### What it does:

- **On main branch pushes:**
  - Runs `mix deps.get` to ensure dependencies are up-to-date
  - Compiles code with `mix compile --force`
  - Runs linter with `mix credo --strict`
  - Builds documentation with `mix docs`
  - Creates version-stamped tarball with source code and compiled artifacts
  - Publishes release to GitHub using `gh release create`
  - Proceeds with push only if all checks pass

- **On feature branch pushes:**
  - Skips validation (tests run in GitHub Actions)
  - Allows push to proceed

#### Bypassing the hook:

If needed, you can skip the pre-push hook:

```bash
git push --no-verify
```

**Note:** This is not recommended for main branch pushes, as it skips the validation and release publishing.

## Reinstalling Hooks

If you accidentally delete or corrupt the hooks:

```bash
make setup-hooks
```

This will reconfigure git to use the `git-hooks/` directory.
