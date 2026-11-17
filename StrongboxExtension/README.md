# Strongbox

Strongbox finds an entry in [Strongbox](https://strongboxsafe.com) and copies its password,
username, or one-time code. It talks only to Strongbox's local MCP interface. No language model
or cloud service is involved. Not affiliated with or endorsed by Strongbox.

## Use it

1. Type `pass` to find **Search Strongbox Passwords**, or `otp` to find **OTP from Strongbox**.
2. Enter the root, type an entry name, and press Enter. Approve in Strongbox if it asks.
3. A single clear match is copied, and a notice names the entry. Several matches are listed to
   choose from. If nothing can be copied, the notice says why.

Each root offers all three copies, with its own first.

- **Typing contacts nothing.** Entries are requested only when you press Enter, and no entry is
  ever indexed. An empty query reads vault names.
- **Enter never guesses.** It copies the only entry whose title exactly matches, or the only
  result. Otherwise it lists up to 20 matches. When there are 20, the list may be cut off, so you
  always choose.
- **Username or email** copies the username. If that is empty, it asks for a custom field named
  `Email`.
- **The clipboard is cleared after 30 seconds**, unless something newer replaced it.

With several MCP-enabled vaults, the first search asks you to choose one. To switch, enter a root
and pick **Use `<vault>`** before typing. If the remembered vault is no longer offered, the next
search asks again instead of using another vault.

## Setup

Requires Strongbox with MCP (tested with 1.65.2). The free version includes MCP. Each vault it
uses needs AutoFill on.

1. In Strongbox, open **Settings → Extensions**, enable MCP, and enable only the vaults you want
   to search. A vault can be ticked only with AutoFill on; if it stays greyed out after turning
   AutoFill on, restart Strongbox.
2. Search once in Tuna, then approve **Tuna** under **Paired MCP Hosts**. Pairing lasts for the
   session unless you also click **Allow after restart**. Read the privacy notes below first: the
   pairing covers all of Tuna.

Strongbox labels Tuna a "Terminal or command-line host". That appears to come from Tuna being able
to load extensions, and the warning is fair.

## Privacy and permissions

- **Code inside Tuna can use Tuna's pairing.** Every extension runs in the same process. Only pair
  Tuna if you trust what it has loaded.
- **Approvals stay with Strongbox.** It decides when to ask, unlock, and lock. Nothing here
  automates an approval, locks a vault, or writes to a vault.
- **The helper is verified.** The `strongbox-mcp` helper's Apple signing, Team ID, and identifier
  are checked before it launches.
- **Copied values** are marked concealed and transient, and limited to this Mac. The markers are
  only a request to clipboard managers; Tuna's own Clipboard History skips them. Quitting Tuna
  clears a value that is still on the clipboard. If Tuna crashes within the 30 seconds, the value
  stays until something replaces it.
- **Values pass through Tuna's process** and are never logged or stored. Titles and usernames
  appear in results. Only the selected vault's ID is remembered.
- **Diagnostics never include values.** An unexpected response is described by its known keys and
  types only.

Turn off Strongbox's browser AutoFill proxy server unless you use its browser extension. Its
`afproxy` helper doesn't check who calls it. This extension doesn't use it.

## Limitations

- Strongbox's MCP source isn't public. Error kinds are told apart by Strongbox's English error
  text, and a changed text falls back to a generic message. Nothing is copied in either case.
- Field references aren't expanded and are refused.
- `pass github` on one line isn't possible; the entry name is typed inside the root.
- TunaKit has no toast API, so the extension shows its own short notice after a copy or failure.
- A fingerprint prompt hides the launcher. When matches arrive after one, the extension opens
  `tuna://search` to bring the list back, which collapses it to the first match; press Down.
