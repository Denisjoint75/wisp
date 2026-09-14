## Google Chrome via accessibility

- For browser automation prefer `wisp chrome launch` and `--tab`: DOM-backed indices, proper input events, uploads and `wisp chrome eval`. Use this accessibility path only for the user's existing Chrome windows.
- Wisp enables Chrome's full accessibility tree on first read. If the page tree is empty, run `wisp state --app 'Google Chrome' --full` again.
- Address bar: cmd+l then type, or `set` the field named 'Address and search bar' (inferred from Chrome's omnibox label); Return navigates. cmd+t new tab, cmd+w close, cmd+shift+] / cmd+shift+[ switch tabs, cmd+r reload, cmd+[ / cmd+] back and forward.
- Web content is under the `web` node; canvas-heavy pages need `--screenshot` and pixel clicks.
- Uploads open a system Open panel: cmd+shift+g, absolute path, Return, Open. Confirm with the user first.
