# Messages 2FA

Messages 2FA finds recent two-factor authentication codes in incoming Apple Messages and makes
them available to Tuna's Paste and Copy actions.

## Privacy and permissions

The extension reads `~/Library/Messages/chat.db` locally and only after you browse **Recent 2FA
Codes**. It does not send, change, cache, or index message contents, and concrete codes do not appear
in Tuna's global search. Tuna needs **Full Disk Access** in System Settings to read Messages.

Only the extracted code, sender, and received time are shown. The surrounding message stays hidden.

## Settings

- **Look back:** Search messages received in the last 5, 10, 30, or 60 minutes (default: 10).
- **Ignore read messages:** Only include unread incoming messages (default: off).

Browse the extension directly or select Messages.app in Tuna and browse **Messages 2FA**. Select a
code to paste or copy it with Tuna's standard text actions.

Email codes and verification links are intentionally outside this extension's scope.
