## Spotify

### The UI lags behind playback requests
Spotify updates its window a moment after a play or pause request, so the diff returned by a click may still show the previous track or a paused state. Do not click again: run `wisp state --app Spotify` and check; the change is usually visible by then. Do not add sleeps, Wisp already waits for the UI to settle.

### Search
Make sure the search field is the `focused` element before `wisp key --app Spotify Return`; a Return with nothing focused can start or stop playback. Prefer `wisp set --app Spotify --el <search field> 'query'` followed by Return.

### Network-backed views
Search results and lists come from the network. A momentary 'No results' is not final; re-read the state before changing approach.

### Links
Links copied from the app only work outside it as regular web links: use `https://open.spotify.com/...` addresses rather than `xpui.app.spotify.com` ones, and quote only links that appear verbatim in the state text.
