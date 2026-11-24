# Tuna Hue Control privacy

Tuna Hue Control runs inside Tuna on your Mac. macOS may ask you to give Tuna access to your local network so the extension can reach your Hue Bridge.

- **Bridge discovery.** Automatic setup contacts Philips Hue at `https://discovery.meethue.com` to find the bridge ID and local address. The extension may contact the same service to recover after a saved bridge address stops responding. You can enter the bridge address, ID, and application key manually during setup.
- **Bridge access.** The extension connects directly to your Hue Bridge over local HTTPS to pair, read room and zone names and light status, and send on/off commands. Your application key is sent to the bridge to authenticate those requests. The extension does not send your application key or room and zone names to the discovery service.
- **Local storage.** Each bridge’s application key is saved in macOS Keychain. Its name, ID, address, and optional certificate file path are saved in local settings. **Manage Hue Bridges → Disconnect** removes the saved connection and its key from your Mac.

The extension includes no analytics or advertising.
