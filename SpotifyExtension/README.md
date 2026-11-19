# Spotify

Control the Spotify app on your Mac from Tuna, and, with your own Spotify app, search Spotify and
browse your library.

## Local controls (no setup)

**Spotify Controls** shows **Now Playing** plus Play/Pause, Next Track, Previous Track, Toggle
Shuffle, and Toggle Repeat. Now Playing refreshes when Spotify changes track. Select Spotify in
Tuna and browse it for **Now Playing & Controls**. **Play** and **Open in Spotify** also work on
any `spotify:` URI or open.spotify.com link.

These use Spotify's AppleScript support, so they need the Spotify desktop app but no Spotify
account setup. macOS asks once for permission for Tuna to control Spotify. Without the app the
controls say Spotify isn't installed.

## Web API setup

Search, **Your Library**, **Save to Library**, **Remove from Library**, **Add to Playlist**,
**Add to Queue**, and **Play on Device** use Spotify's Web API through a Spotify app you create.
Spotify only gives shared apps like Tuna's to large companies, so each person uses their own.

1. Open the [Spotify developer dashboard](https://developer.spotify.com/dashboard) and create an
   app. Its owner needs Spotify Premium.
2. Under **Which API/SDKs are you planning to use?**, pick **Web API**.
3. Add the redirect URI `http://127.0.0.1/callback` exactly.
4. Copy the app's **Client ID** into Tuna: Settings › Sources › Spotify › Client ID.
5. Run **Sign In to Spotify** in Tuna and approve access in your browser.

The account that owns the app can sign in right away. To sign in with another Spotify account, add
it under the app's **User Management** first (up to five).

Sign-ins last six months; Tuna then asks you to sign in again. **Sign Out of Spotify** removes the
tokens. Changing the client ID signs you out.

## Privacy

Tuna signs in with Authorization Code + PKCE, so there is no client secret. During sign-in it
listens on 127.0.0.1 for Spotify's redirect, then stops. Tokens stay in your Keychain and refresh
directly with Spotify; no Tuna server is involved. Tuna asks for these scopes:
`playlist-modify-private`, `playlist-modify-public`, `playlist-read-collaborative`,
`playlist-read-private`, `user-follow-read`, `user-library-modify`, `user-library-read`,
`user-modify-playback-state`, and `user-read-playback-state`.

## Limitations

- Play goes to the Spotify app on this Mac. Without the app, it plays on your active Spotify
  device through the Web API, which needs Premium. So do Add to Queue and Play on Device.
- Spotify only shows the contents of playlists you own or collaborate on. Other playlists can still
  be played or opened in Spotify.
- Spotify's Web API quota for personal apps is small; heavy use can hit rate limits.
