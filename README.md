# Tokenometr

A lightweight native macOS menu bar app that independently measures text arriving from Codex and displays an estimated token rate, such as `≈ 42.1 tok/s`. Built with Swift and AppKit, with no additional server, API key, Electron, or third-party runtime dependencies.

Supports Codex Desktop and Codex CLI. The popover shows the model, selected reasoning effort, minimum / average / maximum speed, a chart with interval statistics on hover, and the last saved measurement.

**macOS 13 or later · prebuilt app for Apple Silicon · approximately 4 MB.**

<img src="docs/screenshots/tokenometr-cli.png" alt="Tokenometr popover showing token speed, a chart, speed statistics, and the selected reasoning effort" width="342" />

*Demo data. The current app interface is in Russian.*

## Getting started

1. [Download Tokenometr 0.2.0 for Apple Silicon](https://github.com/oxgeneral/Tokenometr/releases/download/v0.2.0/Tokenometr-0.2.0-macOS-arm64.zip) and extract the archive.
2. Move `Tokenometr.app` to your Applications folder and open it.
3. Open a Codex chat or run the regular `codex` command in your terminal, then start a response.

Tokenometr appears in the menu bar. Click its icon to see the source, model, reasoning effort, chart, token count, minimum / average / maximum speed, and launch-at-login setting. The prebuilt app requires no terminal, Xcode, or API key.

The prebuilt app does not yet have an Apple Developer ID signature or notarization. macOS may require additional permission when you first open it.

To build from source, install Apple Command Line Tools and run:

```sh
git clone https://github.com/oxgeneral/Tokenometr.git
cd Tokenometr
./scripts/build.sh
```

Then open `dist/Tokenometr.app` or double-click `Open.command`. The build script targets your Mac's architecture; the published archive contains only the `arm64` build.

## How measurement works

Tokenometr connects to Codex Desktop's existing local IPC channel and subscribes to the most recently updated user chat. It receives text changes, counts tokens locally using OpenAI's published `o200k_base` BPE tokenizer, and measures elapsed time with a monotonic clock. Stream events are not treated as tokens. Duplicate events are discarded by revision, and the entire accumulated text is recounted to account for token merges across chunks.

While text arrives, the app displays the rate over the last two seconds. After a response fragment ends, its average rate remains visible. Time before the first text arrival, tool calls, tool output, and hidden reasoning tokens are excluded. The first chunk serves as the time and token-count baseline because the generation time of its individual tokens is unknown. Hidden tokens cannot be measured from visible text.

The popover shows minimum, average, and maximum speed in tokens per second below the chart. Minimum and maximum are recorded from rolling-window rates at observed text arrivals; waiting and UI refreshes do not create new extrema. The last measurable result remains visible after completion and when the next message begins, until that message provides enough data for a new measurement. The result is marked as saved, and its chart remains available for inspection. Every new measurement has its own extrema and timestamps; rates from separate fragments are not combined. If no saved result exists and there is not enough data yet, the app shows `—`.

One measurement is saved for each of the 32 most recent chats: token count, duration, average, minimum, maximum, and up to 512 chart samples. It survives new Codex state snapshots, reconnection, and app restarts. The file at `~/Library/Application Support/Tokenometr/statistics.json` contains only numeric measurements, identifiers, and model metadata; response text is never written to disk. Writes are coalesced at two-second intervals, and normal app termination flushes pending changes immediately.

The desktop subscription is restored when a Codex window reconnects or requests its list of observers. It is also renewed every 30 seconds to recover from silent subscription loss. A repeated snapshot at the same revision preserves the current measurement and chart. A change of stream owner, a reset of the window's revision counter, or missing events establishes a new baseline.

The reasoning effort selected in Codex (`Low`, `High`, `XHigh`, and others) appears next to the model. It comes from live response metadata and chat settings. If Codex leaves the stream field empty, Tokenometr uses that specific chat's saved `reasoning_effort` from the local database; global defaults are not substituted. The level updates without resetting the rate or chart. If neither source provides a value, it is shown as unknown.

The chart contains actual text-arrival timestamps from the last minute of the current fragment. Hover over a point to select an interval of approximately two seconds. Its boundaries and token count appear below the chart, and the minimum / average / maximum row shows statistics for that interval. The chart history freezes while the pointer is over it so you can inspect it comfortably. Moving the pointer away restores the whole-fragment summary. Time is measured from the first observed chunk; interval boundaries follow actual arrivals, and gaps are not filled with invented tokens. Hovering over the menu bar icon also shows the model, reasoning effort, and latest interval summary.

The `≈` symbol is always displayed: a Codex model's private tokenizer may differ from the published `o200k_base` tokenizer. Tokenometr measures the delivery of visible text to the user, which can also be affected by buffering. Server-side token usage counters are not used to calculate speed.

## Codex CLI

CLI sessions are detected automatically through the existing local app-server daemon. No wrapper, additional server, or change to the `codex` command is needed. Tested with `codex-cli 0.160.0`. Both new and resumed sessions are supported: modern terminal sessions on the shared server may retain the historical `vscode` source label, so that label is also recognized.

Tokenometr checks `$CODEX_HOME/app-server-control/app-server-control.sock` (`CODEX_HOME` defaults to `~/.codex`) and local Orca account homes. For a custom `CODEX_HOME`, launch the app with that environment variable set. Socket symlinks and long account paths are supported. Tokenometr subscribes only to user sessions already loaded by the daemon; it does not load closed stored chats or auxiliary agents. Up to eight user sessions are monitored per local server, including their current model and reasoning effort.

Both sources share the same interface and independent measurement logic. The CLI adapter counts only live `item/agentMessage/delta` and `item/plan/delta` events. Full text returned by a subscription, completion events, usage counters, reasoning, and tool output do not create speed samples. Measurements and chart history are saved in the same way as desktop chats. The displayed source follows the most recent observed text arrival, and `Codex` or `Codex CLI` appears in the popover and menu bar tooltip. Waiting, settings updates, and service events alone do not switch the source.

## Limitations and privacy

Tested with local Codex Desktop and Codex CLI on the development Mac. The desktop IPC protocol is internal, with stream version 11; Codex updates may require adapter changes. The chat must be open in Codex so its owner publishes changes. CLI support requires the local shared app-server daemon: `codex --no-daemon`, standalone `codex exec`, older versions without a shared server, and remote WebSocket servers are not monitored. If no compatible stream is available, the app shows a waiting state rather than fabricated values. Other clients using the same shared server can also publish observed text: the `Codex CLI` label identifies that channel, not the active terminal window.

Tokenometr does not change Codex settings, start responses, accept chat-control requests, persist conversation text, or make external network requests. To discover the latest desktop chat, it reads the chat ID, title, and saved reasoning effort from the local SQLite database in read-only mode. Text used for token counting exists only in process memory.

## Development

Apple Command Line Tools are required. No Xcode project or package manager is needed.

```sh
./scripts/build.sh
./scripts/test.sh
python3 scripts/integration-test.py
python3 scripts/cli-integration-test.py
./dist/Tokenometr.app/Contents/MacOS/Tokenometr --diagnose --duration 15
```

Diagnostics print only connection status, model and reasoning metadata, and numeric measurements. A terminal and Python are not required for normal app use.

The desktop integration test uses only Python's standard library and a temporary local IPC channel. It checks the native build, connection and subscription recovery without closing the socket, Codex window replacement, measurement retention during subscription refresh, chat switching, duplicate and missing events, Unicode, and tool-output exclusion. It does not modify real Codex settings or databases. Results are written to `artifacts/integration-results.json`.

The CLI test uses a temporary Unix WebSocket. It checks subscriptions without configuration overrides, masking, ping/pong, socket symlinks and long paths, exclusion of history and service events, independent speed measurement, persistence, reconnection, and restart recovery. Results are written to `artifacts/cli-integration-results.json`.

Tokenizer vocabulary: [OpenAI tiktoken](https://github.com/openai/tiktoken). Its MIT license is included in `Resources/tiktoken-LICENSE.txt`. App-server events are described in the [official documentation](https://learn.chatgpt.com/docs/app-server); the desktop IPC adapter was verified against the installed Codex version.
