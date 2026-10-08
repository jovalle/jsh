# Spicetify Enhancements

| Enhancement               | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`Add`](add.js)           | Playlist picker and native + menu for adding or removing tracks and albums.<br><img src="../../assets/add.png" alt="Lyrics Preview" />                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| [`Like`](like.js)         | Star toggle for Liked Songs; press **⌘⇧L** (**Ctrl+Shift+L** elsewhere) to toggle the playing track.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| [`Love`](love.js)         | Heart toggle for a Loved Songs playlist (created on demand); loving a track also likes it, and unliking a track removes Love. Press **⌘⌥⇧L** (**Ctrl+Alt+Shift+L** elsewhere) to toggle the playing track.                                                                                                                                                                                                                                                                                                                                                                               |
| [`Lyrics`](lyrics.js)     | Movable, resizable live lyrics window; press **⌘⌥L** in Spotify (**Ctrl+Alt+L** elsewhere). The shortcut toggles the panel; **Esc** closes it while focused. Select lyric text to copy. Right-click in the lyrics area to sync. **Alt+/−** changes only lyric text size; **Alt+0** resets it. On macOS **Ctrl+/−/0** also works. Spotify intercepts **⌘+/−** on macOS and zooms its main window, so use the panel shortcuts instead. **S** resumes following. PiP remains always on top because Spotify exposes no toggle.<br><img src="../../assets/lyrics.png" alt="Lyrics Preview" /> |
| [`Play`](play.js)         | Starts (`spotifix play`) a random source in sequential, shuffle, or smart shuffle mode. Clicking the now-playing track title opens the playing playlist, album, or Liked Songs at that track instead of its original album.                                                                                                                                                                                                                                                                                                                                                              |
| [`Settings`](settings.js) | Applies consistent playback, audio quality, crossfade, volume, zoom, and compact-view preferences.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |

## Native mini player (macOS)

Run `spotifix mini install` to build the native companion with Xcode Command Line Tools, apply the managed Spotify
extensions, and enable login startup. Installation restarts Spotify. `spotifix mini` starts it manually;
`spotifix mini stop` stops it; `spotifix mini uninstall` disables startup and the local bridge while preserving a preferences backup. The source and build stay in Jsh.

The square cover-art window shows track, artist, album, and Love/Like/Add/Remove. Missing track metadata is explicitly
unavailable. It can remain visible beside the Lyrics PiP window. A transparent drag lip overlays
the top of the artwork without a title or extra height. Drag the lip or background to move it and resize its edges;
the outer window keeps a 1:1 ratio and remembers its geometry.
Escape or the toggle shortcut hides it. Buttons grow slightly on hover and shrink on press. Love/Like change fill and
color immediately on click; Remove/Undo immediately swaps its icon. The requested state stays visible while Spotify
confirms it, with no dimming, progress ring, or delayed pop. Every Like/Love click changes the visible target immediately;
Spotify writes run in order, including rapid clicks. Unliking also removes the track from Loved Songs and clears both
icons. Add and Remove/Undo block repeats while pending. Failed or expired updates restore the confirmed state; failures appear as compact text above the buttons.
Successful actions show no banner or Spotify toast. Motion respects the system Reduce Motion preference.

| Default shortcut | Action                              | Scope                                     |
| ---------------- | ----------------------------------- | ----------------------------------------- |
| **⌃⌥⌘M**         | Toggle mini player                  | While the companion runs                  |
| **⌃⌥⌘H**         | Toggle Love                         | Mini player visible and Spotify connected |
| **⌃⌥⌘L**         | Toggle Like                         | Mini player visible and Spotify connected |
| **⌃⌥⌘P**         | Activate Spotify and toggle Add     | Mini player visible and Spotify connected |
| **⌃⌥⌘R**         | Remove playing entry / Undo removal | Mini player visible and Spotify connected |

Use **Shortcuts…** in the companion's music-note menu to change modifier keys and M/H/L/P/R. Keys use physical US
positions, matching the Lyrics handling of Option key transformations. Existing Spotify-only shortcuts remain available.
A shortcut registration failure is reported in the floating window; use the music-note menu if the toggle key is
unavailable.

Remove targets the playlist playback context, rather than the displayed playlist. It requires
verified removal/addition permissions and the playing entry's UID; album, queue, autoplay, unknown entries, and read-only
contexts disable it. It removes only that occurrence, including when a playlist contains duplicates. The trash control
becomes **Undo** while the same playback occurrence remains active, including pause/resume. Changing track, occurrence,
playlist, account, or provider expires Undo. Undo restores membership beside a surviving original neighbor; reversed or
missing neighbors produce a clear conflict. It creates a new playlist entry, so original added-at/added-by history is
not restored. Uncertain writes are checked before another mutation; an uncertain Undo is never blindly retried. The
feature issues no playback commands. Undo is kept in the Spotify renderer and expires when Spotify reloads or restarts.
Existing four-letter shortcut preferences gain an unused Remove/Undo letter (R by default), preserving custom bindings.

The companion uses registered macOS hotkeys and an authenticated loopback bridge, without an external service, event-tap
keylogger, or remote-debugging port. The bridge token is generated locally and never committed. Disconnection disables
scoped actions. Requests expire, changes detected before mutation are rejected, and repeated command delivery does not repeat a
mutation. The older `spotifai-quick-save.js` picker is disabled on configuration because it duplicates Add's shortcut;
its source is backed up under Spicetify's `retired-extensions` directory.
