<p align="center">
  <img src="assets/icon/wisp-icon-1024.png" alt="Wisp icon" width="128" height="128">
</p>

<h1 align="center">Wisp</h1>

<p align="center">A computer-use toolkit for macOS: a daemon, a CLI and an MCP server that let AI agents see and drive native apps and Chrome.</p>

Wisp is a computer-use toolkit for macOS: a daemon (`wispd`) that reads app windows as an indexed accessibility
tree and performs UI actions with an animated agent cursor, plus a CLI (`wisp`) and an MCP server (`wisp mcp`)
that any agent (Claude Code, Codex, scripts) can call. Chrome tabs can also be driven over the DevTools Protocol.

It is a from-scratch implementation of the ideas documented in [DESIGN.md](DESIGN.md) (how the ChatGPT/Codex
desktop app's Computer Use works): indexed AX trees with diffs, window-targeted synthesized input that does not
hijack the user's pointer, a glowing cursor with spring motion and click gating, settle detection, Esc to stop,
and a policy file.

## Install

### Homebrew (recommended)

```bash
brew install --cask owo-network/brew/wisp
```

This installs `Wisp.app` and the `wisp` command-line tool together (both signed and notarized). Updates arrive
automatically through Sparkle. Then open the app once and grant permissions:

```bash
open -a Wisp        # menu bar app; guides you through permissions on first run
wisp doctor         # shows what is still missing
```

Grant **Accessibility** (required) and **Screen Recording** (optional, for screenshots) to *Wisp* in
System Settings → Privacy & Security. The menu bar item guides you: it asks for Accessibility with the system
prompt, shows a hint banner, and offers "Grant Accessibility access…" and "Grant Screen Recording…" items that
open the right Settings pane. Once every permission is granted the badge disappears.

### Use with Claude Code

Wisp ships a skill and an MCP server so an agent can drive the UI for you.

- **Skill** — copy the skill into Claude Code so it knows how and when to use `wisp`:

  ```bash
  git clone --depth 1 https://github.com/missuo/wisp /tmp/wisp && \
    mkdir -p ~/.claude/skills && cp -R /tmp/wisp/skills/wisp ~/.claude/skills/wisp
  ```

  (From a source checkout you already have: `cp -R skills/wisp ~/.claude/skills/wisp`.) The skill checks that `wisp`
  is installed and tells you how to install it if not.

- **MCP server** — expose the same operations as tools:

  ```bash
  claude mcp add wisp -- wisp mcp
  ```

### From source

```bash
scripts/bundle.sh            # builds release binaries, packages Wisp.app and installs ~/.local/bin/wisp
wisp doctor --request-permissions
```

During development you can run straight from the build tree:
`WISP_DAEMON=.build/debug/wispd .build/debug/wisp doctor` (a terminal that already has Accessibility permission
passes it on to child processes).

App icon: `assets/icon/wisp-icon.svg` is the source (with `wisp-glyph.svg` / `wisp-background.svg` as separate
layers); `assets/icon/*-1024.png` are the rasterized 1024×1024 versions; `assets/icon/Wisp.icon` is the Icon Composer
document. `scripts/bundle.sh` compiles the `.icon` with `actool` into `Assets.car` (Liquid Glass icon on macOS 26)
plus a `Wisp.icns` fallback, or builds the `.icns` from the PNG when the document is absent.

## Use

```bash
wisp apps                                  # running + recently used apps
wisp state --app Safari                    # indexed accessibility tree (diff on later calls)
wisp click --app Safari --el 12            # every action returns the new state diff
wisp set --app Safari --el 4 "openai.com"; wisp key --app Safari Return
wisp type --app Notes "Hello"; wisp paste --app Notes --format md "# Title"
wisp scroll --app Mail --el 22 --down --pages 2
wisp screenshot --app Preview -o shot.png; wisp click --app Preview --at 640,420   # pixels of that screenshot
wisp batch --app TextEdit <<'EOF'
{"kind":"key","key":"cmd+n"}
{"kind":"type","text":"hello"}
{"kind":"state"}
EOF
wisp end --app Safari
```

Chrome over DevTools (dedicated profile, no impact on your main Chrome windows):

```bash
wisp chrome launch                         # Chrome with --remote-debugging-port (first free port from 9222) and its own profile
wisp chrome new https://example.com        # -> tab id
wisp state --tab <id>; wisp click --tab <id> --el 5; wisp chrome eval --tab <id> "document.title"
```

The chosen port is remembered in `~/Library/Application Support/Wisp/chrome.json`; `wisp chrome launch` reuses a
running Wisp Chrome instead of starting another.

Your existing Chrome windows can be controlled through accessibility instead: `wisp state --app "Google Chrome"`.

`wisp --json …` prints machine-readable JSON. `wisp mcp` serves the same operations as MCP tools
(`wisp_state`, `wisp_click`, `wisp_set`, …); add it to Claude Code with
`claude mcp add wisp -- /path/to/wisp mcp`. The model-facing guide lives in [skills/wisp/SKILL.md](skills/wisp/SKILL.md).

## How it works

- **Tree:** `AXUIElementCopyMultipleAttributeValues` per element, visible-children subsets for large tables,
  transform passes (label association, text merging, pruning, child caps), one line per element with a stable
  index; diffs (`~` changed, `+` added, `- [a..b]` removed) against the previous revision.
- **Input:** `CGEvent`s posted with `CGEventPostToPid` to the process that owns the window under the pointer
  (sheets, menus and out-of-process Open/Save panels are separate windows and processes), tagged with a magic
  user-data value, carrying the target window in `kCGMouseEventWindowUnderMousePointer`; keys mapped through the
  active keyboard layout (`UCKeyTranslate`) and delivered to the process that owns keyboard focus; text typed as
  unicode key events or pasted through a restored clipboard. The real pointer never moves and the window is never
  raised: a synthetic app-activation event makes the target accept input while it stays in the background, so you
  can keep working. `--activate` opts into bringing an app forward for the rare one that ignores background input.
- **Vision fallback:** the accessibility tree is preferred, but when a window exposes no actionable elements
  (custom-drawn apps, canvases, games) Wisp attaches a window screenshot so the caller can look and click by pixel
  coordinates (`--at x,y --space screenshot`); `--screenshot` requests one on demand.
- **Cursor:** an overlay `NSPanel` at window level 102 with a glowing arrow; motion uses the spring/path constants
  recovered from Sky (`clickAngle -44°`, scoot under 196 pt, `closeEnough` at 99.5 % / 3.2 pt); the mouse-down is
  posted only when the cursor has visually arrived.
- **Settle:** `AXObserver` notifications plus busy flags; a quiet window of 0.3 s after at least 0.25 s, up to 5 s.
- **Safety:** listen-only event tap for Esc and real user input (`userIntervened`), policy file
  `~/.config/wisp/policy.json` (deny list defaults to password managers), secure fields are never read or typed
  into unless allowed, screen-lock check, display kept awake while a session runs.
- **Chrome:** `Accessibility.getFullAXTree` + `DOMSnapshot.captureSnapshot` rendered by the same engine;
  `Input.dispatch*` for actions; `Page.captureScreenshot`; `Runtime.evaluate` for `wisp chrome eval`.

## Releases and updates

- Pushing a tag `vX.Y.Z` (or running the *Release* workflow manually) builds universal (Apple silicon + Intel)
  `Wisp.app` and `wisp` CLI binaries on GitHub Actions, signs them with the Developer ID certificate, notarizes and
  staples them, produces
  `Wisp-X.Y.Z.zip`, `Wisp-X.Y.Z.dmg`, `wisp-cli-X.Y.Z.zip`, `SHA256SUMS.txt` and a Sparkle `appcast.xml`, and
  publishes everything as a GitHub release.
- The app updates itself with Sparkle (`Check for Updates…` in the menu bar; automatic daily checks). The feed is
  `https://github.com/missuo/wisp/releases/latest/download/appcast.xml`; updates are signed with the EdDSA key whose
  public half is in `assets/sparkle-public-key.txt`.
- Required repository secrets: `MACOS_CERTIFICATE_P12` (base64 .p12), `MACOS_CERTIFICATE_PASSWORD`,
  `KEYCHAIN_PASSWORD`, `NOTARY_APPLE_ID`, `NOTARY_PASSWORD` (app-specific password), `NOTARY_TEAM_ID`,
  `SPARKLE_PRIVATE_KEY` (exported with `generate_keys -x`).
- `scripts/package.sh` is the shared packaging step (used locally by `scripts/bundle.sh` with ad-hoc signing and by
  CI with the Developer ID); `scripts/set-version.sh` stamps `Sources/WispCore/Version.swift`.

## Layout

```
Sources/WispCore   protocol, JSON, framing, UI tree model, transforms, renderer, diff, key parser, policy
Sources/wispd      daemon: AX snapshot, input synthesis, cursor overlay, settle, screenshots, CDP, socket server
Sources/wisp       CLI + MCP server
skills/wisp        SKILL.md for agents
scripts/           package.sh (build+sign), bundle.sh (local install), set-version.sh, e2e.sh (TextEdit smoke test)
.github/workflows  release.yml (sign, notarize, Sparkle appcast, GitHub release)
assets/            app icon sources and the Sparkle public key
```

`swift test` runs the core unit tests; `scripts/e2e.sh` exercises the daemon against TextEdit.

## License

Wisp is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE.md): free to use for any noncommercial
purpose. See the license for the definition of noncommercial and for personal-use and noncommercial-organization
terms. For a commercial license, contact the maintainer.
