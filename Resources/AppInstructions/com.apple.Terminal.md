## Terminal

Terminal is a high-risk app: the first call makes Wisp show the user an approval prompt on screen and waits for the answer (Allow Once, Allow for This Session, Always Allow, or Don't Allow). If you already have a shell, run commands there instead of driving Terminal's window. If the user declines, stop; do not retry or change the policy to get around the prompt.

- The window content is one `textarea` whose value is the screen buffer; read it with `wisp state --app Terminal --query 'text'`.
- `wisp type` followed by `wisp key Return` executes a command. Treat every command as irreversible and confirm before anything that changes state. ctrl+c cancels a running command; cmd+k clears the buffer.
