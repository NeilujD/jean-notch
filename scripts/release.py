#!/usr/bin/env python3
"""Release automation for JeanNotch. See "Releasing" in README.md.

  release.py check-pr                 check PR_TITLE / PR_BODY (env)
  release.py prepare [--dry-run]      open or update the release PR from merges since the last release
  release.py publish-notes SHA FILE   write the notes of the merged release PR to FILE, print its version
"""
import json
import os
import re
import subprocess
import sys

TYPES = {"feat", "fix", "perf", "refactor", "docs", "chore", "ci", "test", "build", "style", "revert"}
TITLE_RE = re.compile(r"^(?P<type>[a-z]+)(?:\([^)]+\))?(?P<bang>!)?: (?P<desc>\S.*)$")
KIND_BY_TYPE = {"feat": "new", "fix": "fix", "perf": "improvement", "refactor": "improvement"}
SECTIONS = [("breaking", "Breaking changes"), ("new", "New"), ("improvement", "Improvements"), ("fix", "Fixes")]
BUMP_INDEX = {"breaking": 0, "new": 1, "improvement": 2, "fix": 2}  # major, minor, patch
SKIP_NOTES = {"none", "n/a", "-"}

RELEASE_PREFIX = "chore(release): v"
RELEASE_SUBJECT = re.compile(r"^chore\(release\): v(\d+\.\d+\.\d+)(?: \(#\d+\))?$")
BRANCH = "release/next"
BUNDLE = "scripts/bundle.sh"
HIGHLIGHTS = ("<!-- highlights:start -->", "<!-- highlights:end -->")
NOTES = ("<!-- notes:start -->", "<!-- notes:end -->")


# ---- pure logic (unit tested) ----

def parse_title(title):
    m = TITLE_RE.match(title.strip())
    return m.groupdict() if m else None


def strip_comments(text):
    """Remove HTML comments, then neutralise any left-over `<!--` so PR text cannot forge markers."""
    prev = None
    while prev != text:
        prev, text = text, re.sub(r"<!--.*?-->", "", text, flags=re.S)
    return text.replace("<!--", "&lt;!--").strip()


def section(markdown, heading, level=2):
    """Text under the `level` heading named `heading`, up to the next heading of that level
    or higher (ignoring `#` lines inside code fences), or None if absent."""
    found, lines, fenced = False, [], False
    for line in strip_comments(markdown or "").splitlines():
        if line.lstrip().startswith("```"):
            fenced = not fenced
        m = None if fenced else re.match(r"^(#{1,6})[ \t]+(.*?)[ \t]*$", line)
        if m and len(m.group(1)) <= level:
            if found:
                break
            found = len(m.group(1)) == level and m.group(2).lower() == heading.lower()
            continue
        if found:
            lines.append(line)
    return "\n".join(lines).strip() if found else None


def kind_of(title, body):
    """'breaking' | 'new' | 'improvement' | 'fix', or None when the PR stays out of the notes."""
    parsed = parse_title(title)
    if not parsed:
        return None
    if parsed["bang"] or re.search(r"^BREAKING[ -]CHANGE:", body or "", re.M):
        return "breaking"
    return KIND_BY_TYPE.get(parsed["type"])


def check_pr(title, body, head="", fork=False):
    """Errors for a PR title and body. Empty list = valid."""
    if title.startswith(RELEASE_PREFIX) and (head != BRANCH or fork):
        return [f'Only the bot release PR (branch {BRANCH}) may use a "{RELEASE_PREFIX}" title.']
    parsed = parse_title(title)
    if not parsed:
        return [f'Title "{title}" is not a Conventional Commit: use "type: description" or "type(scope)!: description".']
    if parsed["type"] not in TYPES:
        return [f'Type "{parsed["type"]}" is unknown. Use one of: {", ".join(sorted(TYPES))}.']
    if kind_of(title, body) == "breaking":
        if not section(section(body, "Release notes"), "Migration", level=3):
            return ['Breaking change: add a "### Migration" part under "## Release notes" that tells users what to do.']
    return []


def entry(pr):
    """(kind, markdown) for a merged PR, or None when it stays out of the notes."""
    kind = kind_of(pr["title"], pr["body"])
    if not kind:
        return None
    notes = section(pr["body"], "Release notes")
    if notes and notes.lower() in SKIP_NOTES and kind != "breaking":
        return None
    desc = parse_title(pr["title"])["desc"]
    desc = desc[0].upper() + desc[1:]
    ref = f" ([#{pr['number']}]({pr['url']}))" if pr.get("number") else ""
    return kind, f"### {desc}{ref}\n\n{notes or ''}".rstrip()


def next_version(current, kinds):
    if not kinds:
        return None
    parts = [int(p) for p in current.split(".")]
    i = min(BUMP_INDEX[k] for k in kinds)
    parts[i] += 1
    parts[i + 1:] = [0] * (2 - i)
    return ".".join(map(str, parts))


def render_notes(repo, prev, version, entries, known_limits):
    tag, out = f"v{version}", []
    for kind, heading in SECTIONS:
        items = [md for k, md in entries if k == kind]
        if items:
            out.append(f"## {heading}\n\n" + "\n\n".join(items))
    out.append(f"""## Install

Download `JeanNotch-{tag}.zip` below, unzip it and move `JeanNotch.app` to Applications. The app is ad-hoc signed, not notarized, so macOS blocks the downloaded copy until you remove the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/JeanNotch.app
open /Applications/JeanNotch.app
```

Or build it from source (macOS 14+, Swift 6 Command Line Tools):

```sh
git clone https://github.com/{repo}.git
cd {repo.split('/')[1]}
git checkout {tag}
scripts/bundle.sh
open build/JeanNotch.app
```""")
    if known_limits:
        out.append(f"## Known limits\n\n{known_limits}")
    out.append(f"**Full changelog:** https://github.com/{repo}/compare/v{prev}...{tag}")
    return "\n\n".join(out)


def between(text, markers):
    start, end = text.find(markers[0]), text.find(markers[1])
    if start < 0 or end < start:
        return None
    return text[start + len(markers[0]):end].strip()


def release_body(version, highlights, notes):
    return f"""Merging this PR tags `v{version}` and publishes the GitHub Release with the notes below.

Write a one-line intro for the release between the highlights markers (optional). Edits there are kept; the rest of this body is rebuilt after each merge to `main`.

{HIGHLIGHTS[0]}
{highlights}
{HIGHLIGHTS[1]}

---

{NOTES[0]}
{notes}
{NOTES[1]}
"""


def release_notes(body):
    notes = between(body or "", NOTES)
    if notes is None:
        raise SystemExit("The release PR body has no notes markers.")
    intro = strip_comments(between(body, HIGHLIGHTS) or "")
    return f"{intro}\n\n{notes}\n" if intro else f"{notes}\n"


def set_bundle_version(script, version):
    script, n = re.subn(r"(<key>CFBundleShortVersionString</key><string>)[^<]*(</string>)", rf"\g<1>{version}\g<2>", script)
    build = re.search(r"<key>CFBundleVersion</key><string>(\d+)</string>", script)
    if n != 1 or not build:
        raise SystemExit(f"{BUNDLE}: version keys not found.")
    return script.replace(build.group(0), f"<key>CFBundleVersion</key><string>{int(build.group(1)) + 1}</string>")


# ---- git / GitHub ----

def run(*cmd, stdin=None):
    return subprocess.run(cmd, input=stdin, check=True, capture_output=True, text=True).stdout.strip()


def last_release():
    """(version, ref) of the last release: the newest release commit on HEAD, else the newest v* tag."""
    for line in run("git", "log", "--first-parent", "--format=%H %s", "HEAD").splitlines():
        sha, _, subject = line.partition(" ")
        m = RELEASE_SUBJECT.match(subject)
        if m:
            return m.group(1), sha
    tag = run("git", "describe", "--tags", "--abbrev=0", "--match", "v*")
    return tag[1:], tag


def pr_for_commit(repo, sha):
    pulls = json.loads(run("gh", "api", f"repos/{repo}/commits/{sha}/pulls"))
    merged = [p for p in pulls if p.get("merge_commit_sha") == sha] or [p for p in pulls if p.get("merged_at")]
    return merged[0] if merged else None


def merged_prs(repo, ref):
    prs = []
    for sha in run("git", "log", "--reverse", "--format=%H", f"{ref}..HEAD").split():
        pr = pr_for_commit(repo, sha)
        if pr:
            prs.append({"number": pr["number"], "url": pr["html_url"], "title": pr["title"], "body": pr["body"] or ""})
        else:  # direct push: fall back to the commit message
            title, _, body = run("git", "log", "-1", "--format=%B", sha).partition("\n")
            prs.append({"number": None, "url": None, "title": title, "body": body})
    return [p for p in prs if not p["title"].startswith(RELEASE_PREFIX)]


def prepare(repo, dry_run):
    prev, ref = last_release()
    entries = [e for e in map(entry, merged_prs(repo, ref)) if e]
    version = next_version(prev, [k for k, _ in entries])
    if not version:
        print(f"No release: nothing user-facing merged since v{prev}.")
        return
    with open("README.md") as f:
        notes = render_notes(repo, prev, version, entries, section(f.read(), "Known limits"))
    existing = [p for p in json.loads(run("gh", "pr", "list", "--repo", repo, "--head", BRANCH, "--state", "open",
                                          "--json", "number,body,isCrossRepository"))
                if not p["isCrossRepository"]]
    highlights = between(existing[0]["body"], HIGHLIGHTS) if existing else ""
    body = release_body(version, highlights or "", notes)
    title = f"{RELEASE_PREFIX}{version}"
    if dry_run:
        print(f"{title}\n\n{body}")
        return
    with open(BUNDLE) as f:
        bundle = set_bundle_version(f.read(), version)
    run("git", "checkout", "-B", BRANCH)
    with open(BUNDLE, "w") as f:
        f.write(bundle)
    run("git", "-c", "user.name=github-actions[bot]",
        "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
        "commit", "-am", title)
    run("git", "push", "--force", "origin", BRANCH)
    if existing:
        run("gh", "pr", "edit", str(existing[0]["number"]), "--repo", repo, "--title", title, "--body-file", "-", stdin=body)
    else:
        run("gh", "pr", "create", "--repo", repo, "--base", "main", "--head", BRANCH, "--title", title, "--body-file", "-", stdin=body)
    print(f"Release PR ready: {title}")


def publish_notes(repo, sha, path):
    pr = pr_for_commit(repo, sha)
    if (not pr or pr["head"]["ref"] != BRANCH or (pr["head"]["repo"] or {}).get("full_name") != repo
            or not pr["title"].startswith(RELEASE_PREFIX)):
        raise SystemExit(f"{sha} is not a merged release PR from {BRANCH}.")
    with open(path, "w") as f:
        f.write(release_notes(pr["body"]))
    print(re.search(r"v(\d+\.\d+\.\d+)", pr["title"]).group(1))


def main(argv):
    repo = os.environ.get("GITHUB_REPOSITORY", "NeilujD/jean-notch")
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "check-pr":
        errors = check_pr(os.environ.get("PR_TITLE", ""), os.environ.get("PR_BODY", ""),
                          os.environ.get("PR_HEAD", ""), os.environ.get("PR_FORK") == "true")
        for e in errors:
            print(f"::error::{e}")
        return 1 if errors else 0
    if cmd == "prepare":
        prepare(repo, "--dry-run" in argv)
        return 0
    if cmd == "publish-notes" and len(argv) == 4:
        publish_notes(repo, argv[2], argv[3])
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
