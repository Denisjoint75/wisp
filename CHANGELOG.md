# Changelog

All notable changes to Wisp are documented here. The section for each released version is shown in the Sparkle
update dialog and in the GitHub release. This project follows [Semantic Versioning](https://semver.org).

## [0.0.3] - 2026-09-14

### Added
- The `wisp` command-line tool now ships inside `Wisp.app`, so the Homebrew cask installs the app and the CLI
  together and the CLI always finds its bundled daemon.
- Release notes are now driven by this changelog: each release shows its section in the Sparkle update dialog.
- Install instructions in the README: Homebrew cask (`brew install --cask owo-network/brew/wisp`), the Claude Code
  skill, and the MCP server. The skill now checks that `wisp` is installed and tells the user how to install it.

## [0.0.2] - 2026-09-14

### Fixed
- Web forms now fill at normal zoom. Controls below the fold were being dropped from a tab's state; they are kept
  and marked offscreen, and clicking one scrolls it into view first.

### Added
- The menu bar shows which app Wisp is currently controlling, and returns to idle when the session ends.

### Changed
- Synthesized pointer events are routed to the window under the point, ignoring unrelated windows and system
  backstops such as the Dock and menu bar.

## [0.0.1] - 2026-09-14

### Added
- First release: the `wispd` daemon, the `wisp` CLI, the `wisp mcp` server, an animated agent cursor, Chrome
  control over the DevTools Protocol, signed and notarized builds, and Sparkle auto-updates.
