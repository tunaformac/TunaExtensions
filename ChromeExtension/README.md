# Google Chrome Extension

Adds Chrome bookmarks, profiles, the current page, and browser commands to Tuna.

The extension reads Chrome's `Local State` and per-profile `Bookmarks` files. It never modifies
Chrome data. Current Page uses macOS Automation and may prompt for permission to control Chrome.

Chrome, Chromium, Helium, Arc, and Dia are intentionally separate Tuna extensions. Shared,
verified Chromium storage and launch behavior lives in `ChromiumExtensionSupport`.
