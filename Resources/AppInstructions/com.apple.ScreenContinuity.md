## iPhone Mirroring

- The mirrored phone is a video stream: the window exposes no controls in the accessibility tree (inferred from the app's nature; verify with `wisp state --full`). Wisp attaches a window screenshot automatically when a tree has no actionable elements (Screen Recording permission required); request one explicitly with `wisp state --app 'iPhone Mirroring' --screenshot`.
- Click by pixels of that screenshot: `wisp click --app 'iPhone Mirroring' --at x,y --space screenshot`. Take a new screenshot after every action before choosing the next point.
- Keyboard shortcuts: `wisp key --app 'iPhone Mirroring' cmd+1` Home Screen, `cmd+2` App Switcher, `cmd+3` Spotlight.
- Scroll with `wisp scroll --app 'iPhone Mirroring' --at x,y --down`, not with `wisp drag`.
- On the Home Screen click the centre of an app icon, not its label.
