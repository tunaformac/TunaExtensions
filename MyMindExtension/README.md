# mymind Extension

Search and browse your mymind library from Tuna, resolve saved objects into native URLs, text, or
files, and save URLs, text, images, PDFs, and supported files with an optional Space target.

## Setup

1. Open [mymind Extensions](https://access.mymind.com/extensions) and create an access key.
2. Choose **Read only** for search, browse, and Resolve, or **Full access** to also save objects.
3. Copy the Key ID and Private Key immediately. mymind only shows the private key once.
4. Open Tuna Settings → Extensions → mymind and enter both values.
5. Set Access Level to the same level selected in mymind.

The private key is stored in your local Mac Keychain. It is used to generate a fresh, short-lived,
method-and-path-bound JWT for every request and is never sent directly to mymind. Version 0.1
supports one mymind account.

API requests consume mymind credits. Tuna loads the library once when it scans the catalog, then
type-to-search filters those local items without making another API request. Requested thumbnails
are cached. When a quota is exhausted, Tuna reports the reset interval supplied by mymind rather
than retrying.

## Usage

- Browse **mymind** for the complete library, with newest items first as in mymind.
- Type while browsing **mymind** to filter the loaded library.
- Browse **mymind Spaces** to reveal a lazy **Spaces** parent; Spaces and their contents are shown
  newest first and individual Spaces are not indexed into the main catalog.
- Browsing the installed mymind app goes directly to the main library. Both catalogs and Space
  contents use Tuna's grid presentation and support type-to-search.
- Use **Resolve** to stage an object's original URL, note text, or downloaded file.
- Press Quick Look on an object to prepare and preview its image, file, note, or web snapshot without
  running Resolve first. Image objects always resolve to their image data rather than their source URL.
- Use **Save to mymind** with no target, or select a Space as the optional target. It remains an
  additional action rather than replacing the standard default action for images or files.

Video uploads are accepted by the extension but require mymind's Mastermind plan.

## Development

Build and install against Tuna's current local TunaKit:

```bash
make ext-local TARGET=MyMindExtension TUNA_ROOT=../Tuna
```

Never commit or place a real access key in test fixtures. Live smoke tests should use local
extension settings only.
