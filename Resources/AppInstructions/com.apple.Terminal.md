## Terminal

Wisp's default policy denies Terminal (see the `deny` list in `wisp policy get`). If you already have a shell, run commands there instead of driving Terminal's window. Only when the user explicitly asks: `wisp policy set --allow ...` replaces the whole allow list, so run `wisp policy get` first and pass the existing entries plus com.apple.Terminal (allow entries take precedence over deny entries).

- The window content is one `textarea` whose value is the screen buffer; read it with `wisp state --app Terminal --query 'text'`.
- `wisp type` followed by `wisp key Return` executes a command. Treat every command as irreversible and confirm before anything that changes state. ctrl+c cancels a running command; cmd+k clears the buffer.
