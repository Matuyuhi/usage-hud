# usage-hud

[日本語](README.ja.md)

[![CI](https://github.com/Matuyuhi/usage-hud/actions/workflows/ci.yml/badge.svg)](https://github.com/Matuyuhi/usage-hud/actions/workflows/ci.yml)

A macOS background app that shows the remaining Copilot / Claude Code / Codex usage together with CPU, memory, battery, disk and network load, all on one panel.
It adds no menu bar icon — press `⌃⌥U` whenever you want to see it.

<img src="docs/panel.png" alt="usage-hud panel" width="346">

## Install

```sh
brew install --cask matuyuhi/tools/usage-hud
```

From source:

```sh
git clone https://github.com/Matuyuhi/usage-hud.git
cd usage-hud && scripts/install.sh
```

## Usage

- `⌃⌥U` toggles the panel (clicking outside it closes it too)
- Click a service name to expand its details (raw credit counts, reset time, and so on)
- Click "System" to expand the memory breakdown and the top 5 apps by CPU and by memory (the process list is only collected while that section is open)
- Pick what to show from "Display items" in the gear menu — anything you turn off is not fetched or sampled at all, so unused services cost nothing
- Turn on "Launch at login" from the gear menu
- Add the Notification Center widget from "Edit Widgets → Usage HUD"

## Display items

| Item | Shown by default | Source |
|---|---|---|
| Claude Code / Codex / Copilot | Yes | Each tool's own credentials (see below) |
| CPU / Memory | Yes | Kernel statistics |
| Battery | Yes | IOKit power sources (skipped on Macs with no built-in battery) |
| Disk | No | Startup volume capacity |
| Network | No | Throughput across the physical interfaces |

Turning an item off stops its fetching and sampling, not just its row.
The top process lists come from `ps`, so they follow CPU and Memory: they show up under "System" only while that section is expanded, and only for the metrics you kept on.
Rows are named after the application rather than the executable, and helper processes of the same app (the Renderer / GPU helpers of Electron apps, for instance) are merged into a single row whose total is annotated with the process count (`×3`).

## Requirements

Usage is read from the credentials each tool already stores, so signing in to only the tools you care about is enough.

| Shown | Requires |
|---|---|
| Claude Code | Signed in to Claude Code |
| Codex | Signed in with the `codex` CLI |
| Copilot | `gh auth login` completed |

All of them are read-only: credentials are never rewritten or refreshed.

## Language

The interface follows the system language and ships with English and Japanese.
To pin one of them, use System Settings > General > Language & Region > Applications.

## Notes

The usage APIs of these services are not public specifications, so a change on their side can stop the fetch from working.
A service that fails to fetch keeps showing its last value next to the error.

## Development

```sh
scripts/install.sh            # build (Release) and install into /Applications
scripts/check-invariants.sh   # the signing / sandbox / credential rules CI enforces
scripts/bump-version.sh patch # raise VERSION and the xcodeproj version together
```

Every pull request runs both: the universal Release build on macOS, and the invariant check.
Releases are driven by `VERSION` — run the "Bump version" workflow, and merging the PR it opens
publishes the release and updates the Homebrew cask. The bump moves the xcodeproj's
`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` along with it, so a locally installed build
reports the same version as the release.

## License

MIT
