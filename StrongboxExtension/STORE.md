---
categories: [security]
support_url: https://github.com/tunaformac/TunaExtensions/tree/main/StrongboxExtension
requires_app: true
---
Select the Strongbox app in Tuna, press Tab, and choose **Copy Password…**, **Copy Username…**, or **Copy OTP…**. Type an entry name in the third pane and press Enter. You can also start with an entry name in Text Mode and choose **Search Password in Strongbox**, **Search Username in Strongbox**, or **Search OTP in Strongbox**. If one entry clearly matches, it's copied, and a notice tells you which one. If several match, you choose. Press Right Arrow on the Strongbox app to choose a vault.

To start with `pass`, `user`, or `otp` in the first pane, include **Strongbox Commands** in global search under **Tuna Settings → Sources**.

Nothing is looked up while you type, and entries never appear in Tuna's search. Copied values are cleared from the clipboard after 30 seconds, and Tuna's Clipboard History skips them. Strongbox stays in charge of approvals, unlocking, and locking. Nothing is ever written to your vault.

You need the App Store version of Strongbox, free or paid. In Strongbox's settings, turn on MCP and pick the vaults to search. Each needs AutoFill turned on. Then approve Tuna as a paired host the first time you search. Any extension running in Tuna can use that pairing, so only pair if you trust the extensions you have installed. Not affiliated with Strongbox.
