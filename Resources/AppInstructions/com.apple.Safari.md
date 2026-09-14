## Safari

### Address bar and tabs
- Focus the address field with `wisp key --app Safari cmd+l`, or `wisp set --app Safari --el <field named 'Address and Search'> 'https://example.com'` (field name as observed in earlier Wisp work), then `wisp key --app Safari Return`.
- Tabs are `tab` elements in the toolbar. cmd+t new tab, cmd+w close tab, cmd+shift+] / cmd+shift+[ next and previous tab, cmd+r reload, cmd+[ / cmd+] back and forward.
- Moving to another site or an unrelated task: open a new tab instead of reusing the current one, unless the user asked to continue there or the current page is clearly the next step of the same workflow.

### Page content
- Web content appears under the `web` node. Use `--query` to find controls on long pages and `wisp scroll --app Safari --el <web> --down` to move.
- If the `web` node is empty or the page is canvas-drawn, add `--screenshot` and click by pixels.
- Password AutoFill fields are secure fields; Wisp never reads or types into them. Hand logins to the user unless the user explicitly asked you to sign in to that site.
- Downloads: cmd+option+l shows the list. Uploads open a system Open panel: cmd+shift+g, type the absolute path, Return, then click Open. Confirm with the user before uploading.
