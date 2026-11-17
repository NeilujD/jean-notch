# JeanNotch

A small macOS app that sits around the MacBook notch and shows the status of every
running [Jean](https://github.com/coollabsio/jean) session. It is separate from Jean: it only reads
Jean's built-in WebSocket server.

- **Collapsed:** a black shape that blends with the notch. Left: a spinner and the number of
  running sessions. Right: a dot for the most urgent state (orange = waiting for you,
  red = failed, green = done and not seen yet). A gray bolt means Jean is offline.
- **Expanded** (on hover, and for ~4 s after an alert): sessions grouped by
  project › worktree, sorted waiting → failed → running → done. Idle and seen sessions are hidden.
- **Alert:** when a session starts waiting, finishes, or fails, the notch expands and plays a
  soft system sound (mute it in the menu). A finished session stays "unseen" until you click
  its row or bring Jean to the front.
- **Click a row:** brings Jean to the front and asks it to select that session.
- **Gear or right-click:** Mute Sounds, Launch at Login, Quit.

## Requirements

- macOS 14 or later. A notched MacBook screen is best; other screens get a small pill at the
  top center.
- Swift 6 toolchain (Command Line Tools are enough; Xcode is not needed).
- Jean with its HTTP server enabled.

## Build and run

```sh
swift build            # debug build
swift test             # reducer and protocol tests
scripts/bundle.sh      # release build → build/JeanNotch.app (ad-hoc signed)
open build/JeanNotch.app
```

"Launch at Login" works only from the bundled app. Logs:

```sh
log stream --level debug --predicate 'subsystem == "build.jean.notch"'
```

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
- No animations in v1; the panel resizes instantly.
