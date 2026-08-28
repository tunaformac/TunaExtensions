# mymind Extension Changelog

## Unreleased

- Declare catalog presentation for Tuna 0.95's Sources pane; requires Tuna 0.95 / TunaKit 1.21.0.

## 0.3

- Load objects only when browsing the catalog and search mymind semantically as you type instead of
  downloading the full library into Tuna's global search index.
- Load additional semantic search results on demand without reloading earlier result objects.
- Make Search the default action for the mymind catalog, while the enriched app still defaults to
  Open and enters Search with Right Arrow; Browse remains available for recent objects.
- Require Tuna 0.93 and TunaKit 1.20.0.

## 0.2

- Split saving into direct and Space actions that run inline, show activity, and return the saved
  object's direct mymind URL.
- Add locally searchable, newest-first libraries and lazy Space browsing.
- Add direct mymind app browsing and action enrichment when the macOS app is installed.
- Present the mymind and mymind Spaces catalogs as searchable grids.
- Add on-demand Quick Look previews, and resolve image objects to their image instead of source URL.
- Add thumbnail previews and Resolve into URLs, text, and downloaded files.
- Add saving URLs, text, images, PDFs, and supported files with an optional Space without replacing
  their standard default actions.
