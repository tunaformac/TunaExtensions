# Music

Music puts your Music.app library, playback controls, and Apple Music search in Tuna. Music.app stays
the player: everything you play from Tuna plays in Music.

## What you get

- **Music Controls:** a Now Playing entry plus Play/Pause, Next Track, Previous Track, Toggle
  Shuffle, and Toggle Repeat. Now Playing refreshes whenever Music changes track.
- **Songs, Albums, Artists, Playlists:** browse roots for your library. Albums and artists browse
  into their tracks and albums; playlists browse into their songs. Library items stay out of global
  search by default; opt songs, albums, artists, or playlists in from Tuna's Sources pane.
- **Apple Music:** a search root that searches the Apple Music catalog as you type, and shows
  Recently Played and For You when the query is empty.
- Selecting Music.app in Tuna and browsing it lists all of the above.

## Actions

- **Play** and **Shuffle** on songs, albums, artists, and playlists. Play on Now Playing toggles
  play/pause.
- **Show in Music** reveals the song or playlist in Music.
- **Favorite** and **Unfavorite** set the song's favorite flag.
- **Add to Playlist** copies songs or albums into one of your regular playlists.
- **Open in Music** opens an Apple Music result in Music.app, where you can play it or add it to
  your library.

## How albums and artists play

Music.app has no scriptable album or artist object, so Play and Shuffle on an album or artist
rebuild a playlist named **Tuna** in your library with the album's or artist's tracks and play it.
The playlist is visible in Music and is emptied and refilled on every album or artist play. Songs
and playlists play directly, without touching it.

## Permissions and privacy

- **Automation:** the first playback or library read prompts "Tuna wants to control Music". Tuna
  reads the library only while Music is running and never launches Music for a scan. The last
  successful library snapshot is cached at `~/Library/Caches/Tuna/Music/library.json` so songs stay searchable while
  Music is closed.
- **Apple Music (MusicKit):** browsing the Apple Music root prompts for Media & Apple Music access.
  Catalog search, Recently Played, For You, and artwork talk to Apple's servers.
  Nothing else leaves your Mac. MusicKit requires Tuna's App ID to have the MusicKit service and
  Tuna's Info.plist to carry `NSAppleMusicUsageDescription`; without them the Apple Music root
  shows an error and the library catalogs work as before.
- Artwork for library items is looked up through MusicKit only after Apple Music access has been
  granted. Until then rows show symbols.

## Writes

Favorite, Unfavorite, and Add to Playlist change your library through Music.app. Play and Shuffle
on albums and artists rewrite the Tuna playlist. Nothing is deleted.

## Limitations

- Play Next and Play Later are not available; Music's queue is not scriptable.
- Apple Music results cannot be played or added to your library from Tuna; MusicKit has no library
  writes on macOS. Open them in Music instead.
- Music videos, radio shows, and podcasts are out of scope.
