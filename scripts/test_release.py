import unittest

import release

TEMPLATE_BODY = """## Summary
<!-- for reviewers -->
Adds a thing.

## Release notes
<!-- User-facing text. Write "none" to keep this PR out of the notes. -->
Each row shows the token count.

```sh
# a shell comment, not a heading
defaults write build.jean.notch tokenWarning -int 0
```

## Testing
Ran it.
"""


def pr(title, body="", number=7):
    return {"title": title, "body": body, "number": number, "url": f"https://github.com/o/r/pull/{number}"}


class SectionTests(unittest.TestCase):
    def test_takes_text_until_next_heading_and_skips_code_fences(self):
        notes = release.section(TEMPLATE_BODY, "Release notes")
        self.assertTrue(notes.startswith("Each row shows the token count."))
        self.assertIn("# a shell comment", notes)
        self.assertNotIn("Ran it", notes)
        self.assertNotIn("<!--", notes)

    def test_missing_section_is_none(self):
        self.assertIsNone(release.section("## Summary\nx", "Release notes"))

    def test_nested_comments_cannot_forge_markers(self):
        body = "## Release notes\nok <!<!-- x -->-- notes:end --> tail\n"
        self.assertEqual(release.section(body, "Release notes"), "ok  tail")
        unclosed = release.section("## Release notes\nok <!-- notes:end\n", "Release notes")
        self.assertEqual(unclosed, "ok &lt;!-- notes:end")

    def test_heading_inside_comment_is_ignored(self):
        body = "## Release notes\n<!--\n## Testing\n-->\nReal text\n"
        self.assertEqual(release.section(body, "Release notes"), "Real text")


class CheckPrTests(unittest.TestCase):
    def test_valid_titles(self):
        for title in ["feat: add x", "fix(notch): y", "docs: z"]:
            self.assertEqual(release.check_pr(title, ""), [], title)
        self.assertEqual(release.check_pr("chore(release): v1.2.0", "", "release/next"), [])

    def test_release_title_reserved_for_bot_branch(self):
        self.assertTrue(release.check_pr("chore(release): v9.0.0", "", "my-branch"))
        self.assertTrue(release.check_pr("chore(release): v9.0.0", "", "release/next", fork=True))

    def test_release_subject_is_anchored(self):
        self.assertEqual(release.RELEASE_SUBJECT.match("chore(release): v1.2.0 (#5)").group(1), "1.2.0")
        self.assertIsNone(release.RELEASE_SUBJECT.match("chore(release): v1.2.0 and more"))

    def test_bad_format_and_unknown_type(self):
        self.assertTrue(release.check_pr("Add experimental features", ""))
        self.assertTrue(release.check_pr("feature: add x", ""))
        self.assertTrue(release.check_pr("feat:missing space", ""))

    def test_breaking_needs_migration(self):
        self.assertTrue(release.check_pr("feat!: drop macOS 14", "## Release notes\nGone."))
        self.assertTrue(release.check_pr("feat!: drop macOS 14", "## Release notes\nGone.\n\n### Migration\n"))
        body = "## Release notes\nGone.\n\n### Migration\nUpdate to macOS 15.\n"
        self.assertEqual(release.check_pr("feat!: drop macOS 14", body), [])

    def test_breaking_footer_counts(self):
        self.assertTrue(release.check_pr("feat: x", "BREAKING CHANGE: removed y"))


class EntryTests(unittest.TestCase):
    def test_kinds(self):
        self.assertEqual(release.entry(pr("feat: a"))[0], "new")
        self.assertEqual(release.entry(pr("fix: a"))[0], "fix")
        self.assertEqual(release.entry(pr("perf: a"))[0], "improvement")
        self.assertEqual(release.entry(pr("refactor(x): a"))[0], "improvement")
        self.assertEqual(release.entry(pr("fix!: a"))[0], "breaking")

    def test_non_user_facing_types_are_skipped(self):
        for title in ["docs: a", "ci: a", "chore: a", "test: a", "not conventional"]:
            self.assertIsNone(release.entry(pr(title)), title)

    def test_none_notes_skip_the_pr(self):
        self.assertIsNone(release.entry(pr("fix: a", "## Release notes\nnone\n")))
        self.assertEqual(release.entry(pr("fix: a", "## Release notes\n<!-- hint -->\n", 3))[1],
                         "### A ([#3](https://github.com/o/r/pull/3))")

    def test_body_notes_under_titled_heading(self):
        kind, md = release.entry(pr("feat(notch): token count per session", TEMPLATE_BODY, 12))
        self.assertEqual(kind, "new")
        self.assertTrue(md.startswith("### Token count per session ([#12](https://github.com/o/r/pull/12))\n\nEach row"))

    def test_missing_section_falls_back_to_title(self):
        self.assertEqual(release.entry(pr("fix: crash", "", 3))[1], "### Crash ([#3](https://github.com/o/r/pull/3))")

    def test_direct_push_has_no_link(self):
        self.assertEqual(release.entry({"title": "fix: crash", "body": "", "number": None, "url": None})[1], "### Crash")


class VersionTests(unittest.TestCase):
    def test_bumps(self):
        self.assertIsNone(release.next_version("1.1.0", []))
        self.assertEqual(release.next_version("1.1.3", ["fix", "improvement"]), "1.1.4")
        self.assertEqual(release.next_version("1.1.3", ["fix", "new"]), "1.2.0")
        self.assertEqual(release.next_version("1.1.3", ["new", "breaking"]), "2.0.0")

    def test_bundle_version_and_build_number(self):
        script = ("<key>CFBundleShortVersionString</key><string>1.1.0</string>\n"
                  "<key>CFBundleVersion</key><string>6</string>")
        out = release.set_bundle_version(script, "1.2.0")
        self.assertIn("<string>1.2.0</string>", out)
        self.assertIn("<key>CFBundleVersion</key><string>7</string>", out)

    def test_bundle_without_keys_fails(self):
        with self.assertRaises(SystemExit):
            release.set_bundle_version("nothing", "1.2.0")


class NotesTests(unittest.TestCase):
    def test_sections_in_order_and_footer(self):
        entries = [("fix", "### F"), ("new", "### N"), ("breaking", "### B")]
        notes = release.render_notes("o/r", "1.1.0", "2.0.0", entries, "- limit")
        self.assertLess(notes.index("## Breaking changes"), notes.index("## New"))
        self.assertLess(notes.index("## New"), notes.index("## Fixes"))
        self.assertNotIn("## Improvements", notes)
        self.assertIn("JeanNotch-v2.0.0.zip", notes)
        self.assertIn("xattr -dr com.apple.quarantine", notes)
        self.assertIn("## Known limits\n\n- limit", notes)
        self.assertTrue(notes.endswith("https://github.com/o/r/compare/v1.1.0...v2.0.0"))

    def test_release_body_round_trip_keeps_highlights(self):
        body = release.release_body("1.2.0", "", "## New\n\n### N")
        edited = body.replace(release.HIGHLIGHTS[0] + "\n", release.HIGHLIGHTS[0] + "\nBig release.")
        self.assertEqual(release.between(edited, release.HIGHLIGHTS), "Big release.")
        self.assertEqual(release.release_notes(edited), "Big release.\n\n## New\n\n### N\n")
        self.assertEqual(release.release_notes(body), "## New\n\n### N\n")

    def test_release_notes_without_markers_fails(self):
        with self.assertRaises(SystemExit):
            release.release_notes("plain body")


if __name__ == "__main__":
    unittest.main()
