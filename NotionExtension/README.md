# Notion Extension

Standalone Tuna extension project for local Notion development.

Useful commands from the repo root:

- `./scripts/tuna-extension build --scheme NotionExtension`
- `./scripts/tuna-extension install --scheme NotionExtension`

Debug Tuna builds use `http://localhost:3038/api` for the extension OAuth broker, so OAuth testing
also needs a local checkout of the Tuna Rails app running with `just web-dev`.

Current scope:

- OAuth connection flow for one or more Notion workspaces
- `Notion` browse catalog for recently edited shared pages and data sources, merged across
  connections and sorted by last edit time
- `Notion` scoped search over connected workspaces
- Right-arrow browse from the Notion app via bundle id `notion.id`

The Notion integration needs the `Read content` capability enabled, and the pages or data sources
you want to see must be shared with the integration inside Notion.
