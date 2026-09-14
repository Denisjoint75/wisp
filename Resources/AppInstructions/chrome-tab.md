## Chrome tab (DevTools)

- Element indices refer to DOM-backed accessibility nodes. `set` writes an input's value and fires input/change events; `type` inserts text at the focus; `key` sends key events (Return submits forms).
- Navigate with `wisp chrome goto --tab T URL`. Do not `goto` the URL the tab already shows: it reloads and loses form state. Use `wisp chrome reload` when a reload is intended.
- A new site or separate task belongs in a new tab (`wisp chrome new URL`) unless the user asked to continue in this one.
- Tabs you open are ephemeral and are closed by `wisp end`. Keep a page that is the user's deliverable with `wisp chrome mark --tab T deliverable`, or a page where work continues later with `--tab T handoff`. Never mark research or intermediate tabs.
- File inputs: `wisp chrome upload --tab T --el <file input> /absolute/path` (no native panel opens). Uploads need the user's confirmation unless the user named the file and the site up front.
- JavaScript alerts and confirms block the page; the state header reports an open dialog and `wisp chrome dialog --tab T accept|dismiss` closes it.
- Screenshots are viewport pixels; `--at x,y` uses those pixels. Ask for `--screenshot` only when the tree lacks the context you need.
- Keep the browser in the background unless the user wants to watch; `wisp chrome show --tab T` brings it forward.
