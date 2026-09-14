## Numbers

### Cells
- One click selects a cell; typing then appends (or fills an empty cell). A triple click (`wisp click --app Numbers --el N --triple`) selects the existing contents so typing replaces them.
- Enter a value in one round trip with `wisp batch --app Numbers`: a `click` step (count 1 or 3) followed by a `type` step.
- Enter a whole row at once by separating cells with tab characters in the typed text. Do not put several rows, or several formulas, in one `type` step; it fails.
- Values are stored immediately; Return is not needed to confirm a cell. Press it only when you are done with the sheet.
- Checkbox cells accept a typed `0` or `1`.

### Reading state
A focused cell may expose an extra 'text entry area' element carrying formatting artifacts (Markdown-style bold in header cells, for example); ignore it.
