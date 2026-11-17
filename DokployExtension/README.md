# Dokploy

Search the applications and compose services on your [Dokploy](https://dokploy.com) servers and
deploy, restart, or open them from Tuna.

## Setup

1. In the Dokploy panel, open **Settings > Profile**, find **API/CLI**, and generate an API key.
   Pick the organization whose services you want to see.
2. In Tuna, open **Settings > Extensions > Dokploy** and choose **Add Server**.
3. Enter the server address (for example `https://dokploy.example.com`; a trailing `/api` is
   removed automatically) and paste the API key.

Tuna rescans after the connection changes. You can add more than one server; results then show the
server name in their detail line.

## Catalogs

| ID | Name | What it contains |
| --- | --- | --- |
| `dokploy-apps` | Dokploy Services | Every application and compose service, one result each. |
| `dokploy` | Dokploy | Browse root: Dokploy > (server >) project > service. |

Each result shows project, environment, service kind, and the last known status (Idle, Deploying,
Deployed, Error). Result IDs are the Dokploy IDs (`application/<applicationId>`,
`compose/<composeId>`), so renaming a service does not break history or rankings.

`Dokploy Services` is not part of global search by default. Browse it through the **Dokploy** root,
or turn on global search for it in **Settings > Sources**.

## Actions

All actions accept Dokploy services only.

| ID | Title | Dokploy API |
| --- | --- | --- |
| `deploy` | Deploy | `application.deploy` / `compose.deploy` |
| `redeploy` | Redeploy | `application.redeploy` / `compose.redeploy` |
| `start` | Start | `application.start` / `compose.start` |
| `stop` | Stop | `application.stop` / `compose.stop`, after confirmation |
| `open-in-dokploy` | Open in Dokploy | Opens the service page in the panel |
| `open-domain` | Open Domain | `domain.byApplicationId` / `domain.byComposeId`, first enabled domain |
| `copy-url` | Copy Domain URL | Same lookup, copies the URL |

Deploy and redeploy are queued by Dokploy; success means Dokploy accepted the job, not that the
build finished. Follow progress with **Open in Dokploy**.

## Privacy

- The API key is stored in the macOS Keychain by Tuna and is only sent to your Dokploy server in
  the `x-api-key` header. It is never logged or shown in error messages.
- The extension talks only to the server URLs you configure.

## Known limitations

- Status comes from the last scan; rescan to refresh it.
- Only applications and compose services are listed. Databases are not.
- Dokploy's API is unversioned. Tested against the v0.30.7 response shape, with a fallback for the
  pre-v0.25 shape without environments.
- An API key sees only its organization. Keys for non-admin members see only the services they can
  access.

## Development

```bash
./scripts/tuna-extension build --scheme DokployExtension
./scripts/tuna-extension install --scheme DokployExtension --restart
./scripts/run-xcodebuild test -project DokployExtension/DokployExtension.xcodeproj \
  -scheme DokployExtension -destination "platform=macOS,arch=$(uname -m)" CODE_SIGNING_ALLOWED=NO
```

Restart Tuna after every code change; a rescan only reloads catalog data.

## Store packaging

The store icon belongs at `DokployExtension/icon.png` (square PNG, like the other extensions in this
repository). Packaging needs a signed Release build and Tuna installed in `/Applications`:

```bash
./scripts/tuna-extension package --scheme DokployExtension
```

The `.tunaextension` archive is written to `dist/store/`.
