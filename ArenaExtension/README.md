# Are.na Extension

Browse your Are.na channels and their blocks from Tuna. “Resolve” stages a block's underlying text,
URL, image, or attachment; images and attachments are downloaded first. “Save to Are.na” captures
a URL, text, image file, or clipboard image into a selected channel and requests a channel refresh
as target selection begins.

Build and install against Tuna's current local TunaKit:

```bash
make ext-local TARGET=ArenaExtension TUNA_ROOT=../Tuna
```

The OAuth application must allow this redirect URI:

```text
tuna://extension-oauth/callback
```

The connection requests `read` and `write` scopes. Existing read-only development connections must
be reconnected before using “Save to Are.na.”

The extension requires TunaKit 1.15 for direct PKCE and per-channel grid presentation APIs.
