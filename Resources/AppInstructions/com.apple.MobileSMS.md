## Messages

Return in the composer sends immediately. Never send `wisp type` text containing newline characters to the composer, and never press Return without the user's confirmation for that message.

- Conversations are `row`s in the sidebar; the composer is the text field at the bottom (placeholder 'iMessage' or 'Text Message', inferred).
- Stage the message with `wisp set --app Messages --el <composer> 'text'`, run `wisp state --app Messages` to check the conversation and the text, get confirmation, then `wisp key --app Messages Return`.
- New conversation: cmd+n, type a name or number in the To field, pick the match from the suggestions, then Tab to the composer.
- Reactions, deleting conversations and read-receipt changes also need confirmation.
