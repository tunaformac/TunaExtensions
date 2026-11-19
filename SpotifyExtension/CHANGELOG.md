# Changelog

## 0.2.0

- Spotify controls work with no account setup: Now Playing, play/pause, next, previous, and new
  Toggle Shuffle and Toggle Repeat. The controls say so when the Spotify app isn't installed.
- Play and Open in Spotify work on any `spotify:` URI or open.spotify.com link.
- Search and Your Library now use your own Spotify app: paste its client ID in the extension's
  settings and run Sign In to Spotify. Sign-in uses PKCE with a loopback redirect, and tokens
  refresh on your Mac with no Tuna server involved. Earlier Spotify connections need a new sign-in.
- Save to Library works on Now Playing once you're signed in.
- Without the Spotify app, Play starts playback on your active Spotify device.

## 0.1.0

- Add Spotify search, library browsing, playback controls, saves, queueing, and playlist actions.
