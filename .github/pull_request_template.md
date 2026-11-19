<!--
Title: Conventional Commit, it sets the next version.
  feat: …      New (minor)          fix: …       Fix (patch)
  perf: / refactor: …  Improvement (patch)
  feat!: / fix!: …     Breaking change (major), needs a "### Migration" part below
  docs: / ci: / chore: / test: / build: / style: / revert: …  not in the release notes
-->

## Summary

<!-- The smallest view that makes the change clear: a call tree, a diff sketch, a file tree or a diagram, with one or two lines of text. -->

## Evidence

<!-- Proof that it works: screenshots for visual changes, else test or command output. -->

- **Before:**
  **After:**

## Merge Danger

**Door:** <!-- one-way (hard to undo) or two-way (easy to revert) -->

**Blast Radius:** <!-- one word, then what could break -->

## Release notes

<!-- User-facing text for the GitHub Release, in Markdown. It goes under a heading made from the PR title.
Write "none" for a change users do not see. Leave it empty to use only the title.
For a breaking change, add a level-3 heading named Migration that says what users must do.
Image URLs must point to main, not to this branch. -->
