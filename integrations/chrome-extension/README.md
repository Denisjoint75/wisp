# Wisp Chrome extension

Lets Wisp read and operate the tabs of **your own** Chrome (or another Chromium browser) instead of a separate
DevTools-enabled instance. The extension is the same mechanism the Codex desktop app uses: a Manifest V3 service
worker that attaches `chrome.debugger` to the tab Wisp is working in and relays DevTools Protocol commands and
events to `wispd` through a native messaging host (`wisp native-host`).

The extension never reads or stores page content on its own; it only forwards what the daemon asks for, and only
while `wispd` runs on this Mac.

## Install

```bash
wisp chrome extension install        # copies the extension to ~/Library/Application Support/Wisp/chrome-extension
                                     # and registers the native messaging host for Chrome (and Brave/Edge/Chromium/Arc/Vivaldi if present)
```

Then in Chrome: open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked** and choose the
folder printed by the command. The toolbar icon shows a red `!` until the extension can reach `wispd`; click it
for status. `wisp chrome extension status` reports the same from the command line.

The host manifest (`~/Library/Application Support/<browser>/NativeMessagingHosts/sb.moe.wisp.json`) points at
`~/Library/Application Support/Wisp/native-host.sh`, a `#!/bin/sh` script that execs `wisp native-host`, rather than
at the `wisp` binary: Chrome starts hosts with `posix_spawn`, and on some macOS/Chrome combinations a Mach-O started
that way dies before it runs ("Native host has exited" in the popup), while a shell-script host works. If the popup
keeps saying that after an upgrade, run `wisp chrome extension install` again to rewrite the manifest.

After updating Wisp, run `wisp chrome extension install` again and click the reload icon of the extension on
`chrome://extensions`.

## Use

With the extension connected, `wisp chrome tabs` lists your tabs first (tagged `[user]`), `--tab active` is your
active tab, and `wisp chrome new URL` opens the page in your browser. `wisp chrome launch` still starts the
separate Wisp Chrome when you prefer to keep the agent out of your windows.

While Wisp is attached, Chrome shows its "Wisp started debugging this browser" bar; `wisp end` detaches from
every tab and the bar disappears.

## Files

- `manifest.json` - permissions: `debugger`, `tabs`, `nativeMessaging`, `alarms`. The `key` pins the extension id
  `onbeniodfnedfepagelnhdlahohkcnll`, which the native messaging host manifest allows.
- `background.js` - the service worker: native messaging connection with reconnect, tab listing, debugger attach
  and command relay, event forwarding.
- `popup.html` / `popup.js` - the toolbar popup with connection status and install hints.
