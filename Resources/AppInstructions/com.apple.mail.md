## Mail

### Layout
Mailboxes are a sidebar `outline`, messages a `table` of `row`s, and the message pane is rendered with WebKit (content under a `web` node). Search the mailbox with `wisp key --app Mail cmd+option+f`.

### Composing
- New message cmd+n; reply cmd+r; reply all cmd+shift+r; forward cmd+shift+f.
- To, Cc and Subject are `field`s; the body is a `textarea`. Return inside To commits the recipient token; it does not send.
- Send is cmd+shift+d or the Send button. Sending is outward-facing: fill everything, read the state to check recipients and text, and confirm with the user before sending.
- Long bodies: `wisp paste --app Mail --format md 'text'` for rich text or `--format text`.
- Attachments: the Attach toolbar button opens an Open panel (cmd+shift+g, path, Return, Open).

### Deleting and moving
The Delete key or cmd+delete moves the selected message to Trash; confirm before deleting.
