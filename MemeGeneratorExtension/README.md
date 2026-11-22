# Meme Generator for Tuna

Pick a meme template, type the text for each box separated by `|`, and get the finished image as
a file you can paste, copy, share, or Quick Look. Based on the Raycast Meme Generator extension.

## Use

1. Search **Make Meme** and browse into it for a thumbnail grid of templates (type to filter).
   Templates themselves stay out of global search.
2. Pick a template and choose **Make Meme**. The text pane is pre-filled with one numbered
   placeholder per box, e.g. `[Text 1] | [Text 2]`. Replace the ones you want; any placeholder
   left as-is uses the template's example text (or stays blank). Press Enter without typing to
   use the example text for every box.
3. The meme replaces the template as the subject. **Copy Image** (default) or **Copy URL**, or use
   Tuna's file actions to paste, share, or reveal it.

Extra `|` segments are kept in the last box; missing ones are left blank. New lines also separate
boxes. **Add to Favorites** pins a template to the top of the grid and the template source.

## Providers

- **Memegen** ([memegen.link](https://memegen.link)) works with no account. Images are rendered from
  a URL that contains your text.
- **Imgflip** is optional. Add your Imgflip username and password in the extension settings to add
  Imgflip's 100 most popular templates (Imgflip's API returns only those). The password stays in
  your Mac Keychain and is sent only to `api.imgflip.com` over HTTPS when you caption an Imgflip
  template; that request refuses redirects so the password can't be replayed elsewhere.

## Caching

Template lists and downscaled thumbnails are cached indefinitely in
`~/Library/Application Support/Tuna/ExtensionData/MemeGenerator`, so the grid loads instantly and
works offline. All thumbnails are prefetched in the background after the first load. A template list
older than a day is still used and refreshed once in the background. Favorites are stored in Tuna's
preferences.

## Privacy

Meme text goes directly from your Mac to the chosen provider. Generated images are written to
Tuna's temporary folder. Nothing is uploaded anywhere else.

## Limitations

- Requires Tuna 0.113 or later (the version this was tested with).
- Errors (for example no network) are reported by Tuna as a beep; the message is visible when the
  action is run with the `tuna` CLI.
- There is no live preview while typing; the meme is rendered when you run Make Meme.

## Development

```bash
./scripts/tuna-extension build --scheme MemeGeneratorExtension
./scripts/tuna-extension install --scheme MemeGeneratorExtension --restart
make test-extensions
```
