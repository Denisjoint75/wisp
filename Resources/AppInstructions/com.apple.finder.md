## Finder

Shortcuts below are the standard ones shown in Finder's menus; tree-structure notes are inferred from AppKit and should be checked with `wisp state --app Finder --full`.

### Navigation
- The sidebar is an `outline` of `row`s; the file area is a `table`/`outline` in list view or a group of icons in icon view. List view gives the most readable tree: `wisp key --app Finder cmd+2` (cmd+1 icons, cmd+3 columns, cmd+4 gallery).
- Go to a path: `wisp key --app Finder cmd+shift+g`, `wisp type --app Finder '/Users/me/Documents'`, `wisp key --app Finder Return`. Parent folder: cmd+up. Open the selection: cmd+down or `wisp click --el N --double`.
- Search the current folder: cmd+f, then `set` the search field.

### Files
- Rename: select the item, press Return, type the new name, press Return.
- New folder: cmd+shift+n. Get Info: cmd+i. Quick Look: space.
- Move to Trash: cmd+delete. Empty Trash: cmd+shift+delete. Deleting is an always-confirm action; emptying the Trash is irreversible. Moving or renaming files needs explicit approval too.
- Copy/paste: cmd+c then cmd+v; move instead of copy with cmd+option+v. Prefer these over `wisp drag`.

### Dialogs
Open and Save panels are separate windows drawn by a helper process; Wisp routes events to them automatically. Inside a panel, cmd+shift+g opens a path field.
