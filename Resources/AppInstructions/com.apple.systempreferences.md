## System Settings

- Changing a system setting is an always-confirm action: read the current value, confirm with the user, then change it.
- Jump to a pane directly with a settings URL, then read it: `open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'` followed by `wisp state --app 'System Settings'`. Otherwise use the search field at the top of the sidebar.
- Sidebar entries are `row`s; panes use `switch`, `checkbox` and `popup` controls (inferred; verify with `--full`).
- Panes that ask for the user's password show a secure field; Wisp blocks it. Ask the user to unlock.
- Permission toggles for apps (Accessibility, Screen Recording, Full Disk Access) change security posture: confirm each one individually.
