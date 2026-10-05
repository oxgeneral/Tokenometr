# Tokenometr

See how fast Codex writes, right in your Mac's menu bar.

Tokenometr shows the speed of incoming text in tokens per second. It works with **Codex Desktop and Codex CLI**.

**[Download for Mac (Apple Silicon)](https://github.com/oxgeneral/Tokenometr/releases/download/v0.2.1/Tokenometr-0.2.1-macOS-arm64.zip)**

macOS 13 or later · About 4 MB

<img src="docs/screenshots/tokenometr-cli.png" alt="Tokenometr showing speed, a chart, and response statistics" width="342" />

*Demo screenshot.*

## Get started

1. Unzip the download and move `Tokenometr.app` to Applications.
2. Open Tokenometr, then use Codex as usual.
3. Click the menu bar icon to see your stats or enable launch at login.

The app follows your Mac's language: English or Russian. No API key or extra setup needed. This release is unsigned, so macOS may warn you on first launch.

## What you can see

- Live speed, with minimum, average, and maximum values.
- The current model and selected reasoning effort, such as High or XHigh.
- A chart you can hover over to check stats for a short interval.
- Saved measurements that remain after a response ends or the app restarts.

## Good to know

Speed is an estimate (`≈`) based on text as it reaches you. It excludes time spent waiting for the response to start, tool output, and hidden reasoning.

Keep your Codex Desktop chat open. CLI support is for standard local sessions; `codex exec`, `--no-daemon`, and remote servers are not supported. Codex updates may require a Tokenometr update.

## Privacy

Measurements are saved on your Mac. Tokenometr doesn't save conversation text, send it over the internet, or change your Codex settings.

## For developers

See the [technical notes](docs/technical-notes.md) for build instructions, tests, and details about how measurements work.
