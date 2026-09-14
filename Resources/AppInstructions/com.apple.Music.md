## Music

### Searching
- Click the 'Search' row in the sidebar, then `wisp set --app Music --el <search field> 'query'`; the search runs on its own. If results are not in the returned diff, run `wisp state --app Music` again.
- If the search row is not visible, scroll the sidebar to the top. The field revealed by the filter button (identifiers `filterBtn` / `filterField`) only filters the current view; it does not search the library or the catalog.
- To find a playlist, search with 'Your Library' selected in the results, or scroll the sidebar.

### Navigation
- Scroll lists with `wisp scroll --app Music --el <list> --down --pages 2`. When an element lists `{ScrollUp, ScrollDown}` actions, `wisp action --app Music --el N ScrollDown` works too. Batch several scroll steps with `wisp batch`.
- Selecting a sidebar item can drop you into a sub-view. Use the back button (identifier `backBtn`) to return to the root level.

### Playback
- Play a track with a double click: `wisp click --app Music --el N --double`.
- To queue a track ('Playing Next'), use the track's 'More' button and choose 'Play Next' or 'Play Last'. If no More button is exposed, right-click the track: `wisp click --app Music --el N --right`.
