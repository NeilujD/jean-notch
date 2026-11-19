# JeanNotch

macOS notch panel for Jean sessions. Swift package; see README.md for build, test and release.

## Pull requests

Releases are built from PR titles and bodies (README "Releasing", `scripts/release.py`), so every PR follows these rules.

- **Title:** Conventional Commit. It sets the version bump: `feat:` minor, `fix:` / `perf:` / `refactor:` patch, `!` after the type major. `docs:`, `ci:`, `chore:`, `test:`, `build:`, `style:`, `revert:` stay out of the release notes.
- **Body:** invoke the `mattpocock-skills:pr` skill and use its template: `## Summary`, `## Evidence`, `## Merge Danger`.
- **Release notes:** always end the body with `## Release notes`. Write user-facing Markdown: what changed, how to use it, limits. Write `none` when users do not see the change. A breaking change needs a `### Migration` part. Image URLs must point to `main`, because the notes outlive the branch.
- **Check before opening:** `PR_TITLE='…' PR_BODY="$(cat body.md)" PR_HEAD=<branch> python3 scripts/release.py check-pr`.
- **Merge:** squash only. Never merge or edit the bot's `chore(release): vX.Y.Z` PR content by hand, except the highlights block.
