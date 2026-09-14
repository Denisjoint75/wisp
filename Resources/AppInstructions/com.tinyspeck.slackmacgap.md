## Slack

Slack is an Electron app. Wisp switches on its full accessibility tree the first time it reads it; if the first `wisp state --app Slack` looks empty, run `wisp state --app Slack --full` once more.

### The composer sends on Return
- When no text field is focused, typed text goes into the message composer. Before `wisp key --app Slack Return`, check in the latest state that the element you mean (search field, thread reply, edit box) is the one marked `focused`; otherwise Return may send a message.
- Prefer `wisp set --app Slack --el <composer> 'text'` over `wisp type` for the composer. `set` writes the value directly: a newline inside the value becomes a line break and nothing is sent. `wisp type` presses Return for every newline character, which sends the message in Slack's default configuration.
- `set` leaves Markdown syntax as literal characters. To convert it to Slack formatting afterwards, press `wisp key --app Slack cmd+shift+f` with the composer focused, then re-read the state.
- Sending is an outward-facing action: stage the text with `set`, read the state to confirm the composer shows exactly what you intend, and get the user's confirmation before pressing Return or clicking Send, unless the user already approved that specific message.

### Which key sends
Users can configure Slack so that either Return or Shift+Return sends. When the composer under a channel or direct message holds at least three characters, a button below it shows a hint of the form '<key combination> to add a new line'; the combination that is not mentioned is the one that sends. The hint is absent for thread replies and message edits. Find it with `wisp state --app Slack --query 'new line'`.

### When the tree misbehaves
If the accessibility text does not match what you expect (stale messages, missing composer), take `wisp state --app Slack --screenshot` and treat the picture as the source of truth; click by pixels with `--at x,y --space screenshot` when needed.
