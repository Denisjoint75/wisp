## Xcode

- Prefer `xcodebuild`, `xcrun` and `swift` from a shell for builds and tests. Drive the UI only for things without a command line (simulator interaction, interface editors, signing dialogs).
- The tree is very large: always use `--query` and `--max-lines`. cmd+0 toggles the navigator, cmd+option+0 the inspector, cmd+shift+y the debug area, cmd+1 the project navigator, cmd+shift+o Open Quickly.
- The source editor is a `textarea`. Do not `wisp type` code into it: auto-indent and completion rewrite what is typed. Use `wisp select-text` to place the caret and `wisp paste --format text`, or edit the files on disk.
- cmd+b build, cmd+r run, cmd+. stop, cmd+shift+k clean.
- Signing and keychain prompts are secure dialogs: hand them to the user.
