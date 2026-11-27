# Strongbox Changelog

## 0.2

- **Search Strongbox Passwords** is now **Password from Strongbox**. Instead of entering it, type
  the entry name in the third pane. Each command copies only its own field. `pass` and `otp`
  still find them.
- New: **Username from Strongbox** (`user`) copies an entry's username.
- Vaults are now switched from the Strongbox app: select it, press Right Arrow, and pick
  **Use `<vault>`**. The commands no longer list vaults.
- Or start from the Strongbox app: press Tab and choose **Copy Password…**,
  **Copy Username…**, or **Copy OTP…**. Enter on the app still opens Strongbox.
- Or type an entry name in Text Mode and choose **Search Password in Strongbox**,
  **Search Username in Strongbox**, or **Search OTP in Strongbox**.
- If you had the Strongbox commands in global search, they stay there. On a fresh install they
  start outside it; include **Strongbox Commands** under **Settings → Sources** to add them.

## 0.1

- Find a Strongbox entry by name and copy its password, username, or one-time code.
- Search one remembered vault, chosen in the launcher, and ask again when it is no longer offered.
- Show a short notice after each copy or failure.
- Clear copied values from the clipboard after 30 seconds.
