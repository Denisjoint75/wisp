## Notion

Notion's desktop app is Electron-based; Wisp enables its full accessibility tree on first read (re-run `wisp state --app Notion --full` if the first read is empty).

### Pages are blocks
- A page is a list of blocks. Clicking a block selects it; `wisp key --app Notion Return` starts editing the selected block's text.
- A new page has an empty title showing the placeholder 'New page'. Click the text element inside the heading to focus the title, `wisp type` the title, then press Return to move into the body.
- Enter body text one line per step: `wisp type --app Notion 'line'` then `wisp key --app Notion Return`. Put the alternating `type` and `key` steps in one `wisp batch --app Notion` call; do not send several lines in a single `type`.
- Markdown shortcuts apply while typing (`#` headings, `-` bullets, `**bold**`) with two differences: a leading `>` creates a toggle block, and a leading `|` creates a quote block.

### Lists
Return at the end of a list item creates the next item with its bullet already in place, so type only the text. Return on an empty list item ends the list.

### Selection: cmd+a depends on context
- Caret in an empty block: selects every block on the page.
- Caret in a non-empty block: selects that block's content; pressing cmd+a again selects every block.

### Placeholders
Empty elements show placeholder text: 'New page' (title), 'List' (list item), 'To-do' (checklist item), 'Write, ...' (empty line). Typing replaces it; never try to select and delete it.

### Code and quote blocks
In a code block Return adds a line inside the block and Shift+Return leaves it. Quote blocks are the reverse: Return leaves, Shift+Return stays inside.

### Moving the caret
- Top or bottom of the page: focus the document, press cmd+a twice, then Up or Down, then Return to edit the first or last block.
- A specific block: cmd+a twice, then click that block once.
- Or `wisp key --app Notion cmd+f`, type the text to find, press Escape: the match stays selected and becomes the caret position.
