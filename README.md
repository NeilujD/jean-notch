<p align="center"><img src="assets/logo.png" width="160" alt="JeanNotch logo: a thin pixel J hanging from a notch"></p>

# JeanNotch

[![CI](https://github.com/NeilujD/jean-notch/actions/workflows/ci.yml/badge.svg)](https://github.com/NeilujD/jean-notch/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

> **Unofficial.** JeanNotch is a community companion app. It is not affiliated with or endorsed
> by coollabsio or the Jean project.

A small macOS app that sits around the MacBook notch and shows the status of every
running [Jean](https://github.com/coollabsio/jean) session. It is separate from Jean: it only reads
Jean's built-in WebSocket server.

<p align="center">
  <img src="assets/notch-collapsed.png" width="380" alt="Collapsed notch: the thin J, one running session, and an orange dot for a session waiting for you"><br>
  <img src="assets/notch-expanded.png" width="400" alt="Expanded notch: sessions grouped by project and worktree with their token counts, one over the warning limit in orange, and the Claude plan usage at the bottom (one project blurred)">
</p>

- **Collapsed:** a black shape that blends with the notch. Left: the J and the number of
  running sessions. Right: a dot for the most urgent state (orange = waiting for you,
  red = failed, green = done and not seen yet). A gray bolt means Jean is offline.
- **Expanded** (on hover, and for ~4 s after an alert): sessions grouped by
  project › worktree, sorted waiting → failed → running → done. Idle and seen sessions are hidden.
- **Tokens:** each row shows the session's total tokens, for example "3.2M"
  (k = thousand, M = million). The total counts input, output, and cache reads and
  writes, summed over all runs. Jean saves a run's usage when the run ends, so the count
  moves when a run finishes. Over the limit, the count turns orange with a ⚠ icon. The
  default limit is 10 million. Change it in the menu (**Token Warning**), or set any value with
  `defaults write build.jean.notch tokenWarning -int 3000000` (0 turns it off).
- **Alert:** when a session starts waiting, finishes, or fails, the notch expands and plays a
  soft system sound (mute it in the menu). A finished session stays "unseen" until you click
  its row or bring Jean to the front.
- **Click a row:** brings Jean to the front and asks it to select that session.
- **Plan usage:** the bottom of the expanded panel shows how much of each plan limit you
  used, for Claude, Codex and Grok, and the time until it resets
  (for example "Claude  5h 1% · 4h55  week 29% · 5d"). A provider you are not logged in to
  is not shown. Jean caches these values for 5 minutes, so they can lag a little. When any
  limit is over 80%, the collapsed notch shows an orange ⚠. Change the limit in the menu
  (**Usage Warning**) or with `defaults write build.jean.notch usageWarning -int 90`
  (0 turns it off). Jean's other agents (OpenCode, Cursor, Pi, and so on) give no usage data.
- **Gear or right-click:** Mute Sounds, Launch at Login, Token Warning, Usage Warning, Quit.

### The mascot

A flat pixel "J" sits next to the notch. It does not act out urgency (the dot does that):

| State | What it does |
|---|---|
| Sessions running | Pulses softly |
| Nothing running | Stays still |
| Jean offline | Dims |

While the notch is collapsed, the J pulses once every 15 s. It pulses all the time while the
notch is open. This keeps JeanNotch under 1% CPU. A finished session still gets a confetti burst.

The notch opens and closes with a spring. With **Reduce Motion** on (System Settings ›
Accessibility › Display), the J stays still, confetti is off, and the notch only fades.

## Requirements

- macOS 14 or later. A notched MacBook screen is best; other screens get a small pill at the
  top center.
- Swift 6 toolchain (Command Line Tools are enough; Xcode is not needed).
- Jean with its HTTP server enabled.

## Install

Download `JeanNotch-vX.Y.Z.zip` from the [latest release](https://github.com/NeilujD/jean-notch/releases/latest),
unzip it and move `JeanNotch.app` to Applications. The app is ad-hoc signed, not notarized, so
remove the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/JeanNotch.app
```

## Build and run

```sh
swift build            # debug build
swift test             # reducer and protocol tests
scripts/bundle.sh      # release build → build/JeanNotch.app (ad-hoc signed)
open build/JeanNotch.app
```

If `swift test` fails with `plugin for module 'TestingMacros' not found` or
`no such module 'Testing'`, your Command Line Tools do not give Swift Testing to SwiftPM
(seen with Swift 6.4.2). Then run:

```sh
CLT=/Library/Developer/CommandLineTools
swift test --build-system native \
  -Xswiftc -F$CLT/Library/Developer/Frameworks \
  -Xswiftc -plugin-path -Xswiftc $CLT/usr/lib/swift/host/plugins/testing \
  -Xlinker -rpath -Xlinker $CLT/Library/Developer/Frameworks
```

"Launch at Login" works only from the bundled app. Logs:

```sh
log stream --level debug --predicate 'subsystem == "build.jean.notch"'
```

## Logo

`assets/logo.svg`, `assets/logo.png` and `assets/AppIcon.icns` come from one pixel grid in
`scripts/make-logo.swift`. Edit the grid, then run `swift scripts/make-logo.swift`.
The pixel "J" and its palette are a nod to Jean's logo.

## How it connects

1. At each connection attempt it reads `~/Library/Application Support/com.jean.desktop/preferences.json`
   (`http_server_port`, `http_server_token`, `http_server_bind_host`). A changed port or a
   regenerated token is picked up on the next retry.
2. It connects only to localhost (`ws://127.0.0.1:<port>/ws`) and sends the token in an
   `Authorization: Bearer` header. If Jean binds to another host, JeanNotch refuses to connect.
   The token is never logged.
3. On connect and on `ws:resync`, it loads a snapshot with `list_all_sessions`. After that it
   follows live `chat:*` events. Structure events (`session-renamed`, `worktree:*`,
   `cache:invalidate`) trigger a debounced snapshot reload.
4. It reconnects with exponential backoff (1 s → 30 s) and drops a socket that is silent for 20 s.

## Known limits

- **Jumping to a session is best effort.** JeanNotch calls `set_active_session`, but Jean may
  not switch its visible session yet. A `jean://session/<id>` deep link in Jean is a planned
  follow-up.
- A session waiting on a Claude question or plan is detected from the `AskUserQuestion` /
  `ExitPlanMode` tool event or from the snapshot's `waiting_for_input`.
- The status list shows at most 12 sessions ("+N more" for the rest).

## Releasing

Releases are automated (`.github/workflows/release.yml`, `scripts/release.py`):

1. **PR title** is a Conventional Commit and sets the version bump: `feat:` → New (minor),
   `fix:` → Fix (patch), `perf:` / `refactor:` → Improvement (patch), `!` after the type or a
   `BREAKING CHANGE:` line → Breaking change (major). `docs:`, `ci:`, `chore:`, `test:`,
   `build:`, `style:`, `revert:` stay out of the notes. The `pr-title` check enforces it.
2. **`## Release notes`** in the PR body is the user-facing text (from the PR template). Write
   `none` to leave the PR out; leave it empty to use only the title. A breaking change needs a
   `### Migration` part.
3. PRs are **squash merged**. After each merge to `main`, a bot updates the release PR
   `chore(release): vX.Y.Z` (branch `release/next`): next version, build number in
   `scripts/bundle.sh`, and the full notes. Write an optional intro between its highlights markers.
4. **Merging the release PR** builds `JeanNotch-vX.Y.Z.zip`, tags the commit and publishes the
   GitHub Release. The notes copy this README's **Known limits** section.

Setup: a fine-grained token (this repo only; Contents and Pull requests: read and write) in the
`RELEASE_TOKEN` secret, so CI runs on the release PR. Run `scripts/setup-release-token.sh`: it
walks you through creating the token, checks it and saves the secret. Run it again to renew the
token before it expires.

## License

[Apache License 2.0](LICENSE). Copyright 2026 Julien Collard. See [NOTICE](NOTICE).
