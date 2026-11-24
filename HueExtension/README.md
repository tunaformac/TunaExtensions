# Tuna Hue Control

Control Philips Hue rooms and zones from the [Tuna launcher](https://tunaformac.com) on your Mac. Connect one or more Hue Bridges, then search for a room or zone by name to turn its lights on or off.

## Connect your first Hue Bridge

You’ll need macOS 15 or later, Tuna 0.113 or later, and a Philips Hue Bridge on the same network as your Mac. The extension is currently installed from source. From the TunaExtensions root, run `./scripts/tuna-extension install --scheme TunaHue --restart`.

1. In Tuna, search for **Hue** and choose **Connect First Hue Bridge**. If the command is missing, open Tuna’s **Sources** settings and set **Hue Groups → In global search** to **All**.

   <img src="https://raw.githubusercontent.com/bjesuiter/tuna-hue/main/packages/website/src/assets/screenshots/01-find-hue-command-light.png" alt="Connect First Hue Bridge selected in Tuna search" width="480">

2. Select your bridge and choose **Continue**. When prompted, press the physical link button on that bridge. You have about 90 seconds. If the prompt times out, choose **Try Again**.

   <img src="https://raw.githubusercontent.com/bjesuiter/tuna-hue/main/packages/website/src/assets/screenshots/02-choose-bridge-light.png" alt="Add Hue Bridge dialog with a discovered bridge selected" width="360">
   <img src="https://raw.githubusercontent.com/bjesuiter/tuna-hue/main/packages/website/src/assets/screenshots/03-press-link-button-light.png" alt="Tuna waiting for you to press the bridge’s physical link button" width="360">

3. Allow Tuna to access the local network if macOS asks. Once the bridge is connected, its rooms and zones appear in Tuna search.

   <img src="https://raw.githubusercontent.com/bjesuiter/tuna-hue/main/packages/website/src/assets/screenshots/04-bridge-connected-light.png" alt="Tuna confirms the Hue Bridge is connected" width="320">

## Turn a room on or off

1. Search for the room by name in Tuna and select the **Hue Room** result.
2. Press **Tab**, then choose **Turn On** or **Turn Off**. To switch it back, search for the room again and choose the other action.

   <img src="https://raw.githubusercontent.com/bjesuiter/tuna-hue/main/packages/website/src/assets/screenshots/05-turn-on-light.png" alt="Bedroom selected in Tuna with the Turn On action" width="360">
   <img src="https://raw.githubusercontent.com/bjesuiter/tuna-hue/main/packages/website/src/assets/screenshots/06-turn-off-light.png" alt="Living room selected in Tuna with the Turn Off action" width="360">

See the [full walkthrough](https://bjesuiter.github.io/tuna-hue/how-it-works/) for manual pairing, bridge management, and checking offline lights.

## Privacy

Tuna Hue Control uses local network access to read rooms, zones, and light status from your Hue Bridge and send on/off commands. Automatic discovery contacts Philips Hue at `discovery.meethue.com` to find bridge addresses, including when recovering from a changed address. Bridge requests use HTTPS, and your bridge application keys are stored in macOS Keychain. [Full privacy details](PRIVACY.md)
