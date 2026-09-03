# GIPHY for Tuna

Browse trending GIFs, search GIPHY, preview the selected animation, and paste it into the active
application. Rich editors receive HTML containing the original GIF URL; plain-text destinations
receive the URL itself. Use the **Resolve** action to download the original GIF and restage it as a
local file for file-based actions. Quick Look downloads the original GIF on demand.

## Development setup

Search and trending requests use Tuna's API proxy so the GIPHY key is never included in this
open-source extension. The proxy reads `giphy_api_key` from the Tuna web app's Rails credentials.

Build and install against a Tuna checkout containing the animated-preview API:

```bash
make ext-local TARGET=GiphyExtension TUNA_ROOT=/absolute/path/to/Tuna
```

Restart Tuna, browse **GIPHY**, and type to search. GIPHY beta keys are limited to 100 API calls per
hour, so the extension waits 500 ms after typing before searching.

## Privacy and provider behavior

Search text, the selected content rating, and network metadata are sent directly from Tuna to
Tuna's API proxy and then to GIPHY. GIF media is loaded directly from the URLs returned by GIPHY.
Using **Resolve** downloads the selected original GIF into Tuna's temporary directory. The extension
does not upload, delete, or modify GIPHY content.

GIPHY requires “Powered by GIPHY” attribution. This extension displays attribution in its source
description, browse root, and GIF details. GIPHY analytics integration remains incomplete in this
development build, so it is not ready for public store distribution.
