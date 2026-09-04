# GIPHY for Tuna

Browse trending GIFs, search GIPHY, preview the selected animation, and paste it into the active
application. Rich editors receive HTML containing the original GIF URL; plain-text destinations
receive the URL itself. Use the **Resolve** action to download the original GIF and restage it as a
local file for file-based actions. Quick Look downloads the original GIF on demand.

## Setup

GIPHY works immediately with Tuna's public shared beta key. GIPHY limits that key to 100 requests
per hour across all Tuna users. To use your own quota, create a key in the
[GIPHY developer dashboard](https://developers.giphy.com/dashboard/) and add it under GIPHY's
extension settings in Tuna; personal keys stay in your Mac Keychain. Search, trending, media, and
analytics requests go directly from your Mac to GIPHY, and Tuna's service does not receive them.

Build and install against a Tuna checkout containing the animated-preview API:

```bash
make ext-local TARGET=GiphyExtension TUNA_ROOT=/absolute/path/to/Tuna
```

Restart Tuna, browse **GIPHY**, and type to search. GIPHY beta keys are limited to 100 API calls per
hour, so the extension waits 500 ms after typing before searching.

## Privacy and provider behavior

The shared or personal API key, search text, selected content rating, anonymous installation
identifier, interaction analytics, and network metadata are sent directly to GIPHY under its
developer terms. GIF media is loaded directly from the URLs returned by GIPHY. Using **Resolve**
downloads the selected original GIF into Tuna's temporary directory. Beyond that user-requested
temporary download, the extension does not upload, delete, modify, persist, reorder, or mix GIPHY
content.

GIPHY requires “Powered by GIPHY” attribution. This extension displays attribution in its source
description, browse root, and GIF details, and reports the provider's view, click, and successful
paste analytics events without delaying user actions.
