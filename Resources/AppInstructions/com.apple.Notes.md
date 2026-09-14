## Notes

- Folders are a sidebar `outline`, notes a `table` of `row`s, the editor a `textarea`. New note: `wisp key --app Notes cmd+n`; the first line becomes the title.
- Search: cmd+option+f.
- Formatting shortcuts (Format menu): title cmd+shift+t, heading cmd+shift+h, body cmd+shift+b, checklist cmd+shift+l, bulleted list cmd+shift+7, dashed list cmd+shift+8, numbered list cmd+shift+9.
- Notes does not interpret Markdown. `wisp paste --app Notes --format html '<b>x</b>'` keeps formatting; `--format md` pastes rendered HTML with a plain-text fallback (inferred: the editor accepts the HTML pasteboard type).
- Deleting a note (cmd+delete) moves it to Recently Deleted; confirm first.
- Locked notes need the user's password: hand off.
