# Fantastical

Fantastical turns text typed in Tuna into calendar events and tasks through Fantastical's natural
language parser, and jumps to Fantastical views without touching the mouse.

## Actions on typed text

- **Add to Fantastical**: sends the text to Fantastical's parser. `Lunch with Sam friday 12h30`
  becomes an event. By default Fantastical shows how it read the sentence and Enter confirms.
- **Add Task to Fantastical**: same, but creates a task (Reminders, Todoist, or whichever task
  source Fantastical uses). Due dates in the text are honored.
- **Search Fantastical**: opens Fantastical's search with the text.
- **Show Date in Fantastical**: available when the text is one date, either `2026-10-03` or natural
  language such as `tomorrow` or `next friday`. Reveals that day.

## Fields

Add details the parser cannot guess by appending fields after the separator (default `--`, change
it in settings):

```
Dentist tomorrow 15h -- notes: bring the card -- cal: Perso -- url: https://doctolib.fr/x -- allday
```

- `title:` exact title. With no sentence before the separator nothing is parsed, so pair it with
  `start:` / `end:`.
- `start:` / `end:` (also `from:` / `to:`) and `due:` for tasks. Fantastical accepts
  `2026-10-03 14:00`, `2026-10-03`, or natural language such as `next friday 9h`.
- `allday` flag (or `allday: no`).
- `cal:` or `calendar:` calendar name as shown in Fantastical.
- `url:` or `link:`, and `notes:` or `note:`.

Keys are case-insensitive. A misspelled key fails the action with "Unknown field" instead of
silently landing in the title. The separator only counts when it stands alone between spaces, so
`https://x.com/a--b` is safe.

**Links**: Add to Fantastical and Add Task also take a link item (Safari tab, bookmark, a URL from
the clipboard). Its title becomes the sentence and its address is attached as the event URL.

## Views

The **Fantastical Views** source lists Today, Tomorrow, Calendar (main window), Mini Window, and one
`Set: Name` entry per calendar set you add in settings. Select one to open it; its Fantastical URL is
the copy and text value.

Select Fantastical.app in Tuna to browse the views, or use the app-scoped **New Event**, **New
Task**, and **Search** actions with typed text as the target.

## Settings

- **Add without confirmation** (default off): when on, items are added silently with `add=1`
  instead of showing Fantastical's parse preview.
- **Use the Mini Window** (default on): parse and search open in the menu bar Mini Window
  (`x-fantastical-mini`). Turn off to use the main window.
- **Field separator** (default `--`): the token that starts the fields block. Pick anything, `>>` or
  `;;` work too.
- **Calendar sets**: comma-separated names exactly as they appear in Fantastical. Fantastical does
  not expose sets programmatically, so they are typed once here. Rescan the source after editing.

## Privacy and permissions

Everything runs through Fantastical's documented URL scheme on this Mac. No network access, no
credentials, no calendar reads, and nothing is cached or indexed. Writes only ever create items;
nothing is edited or deleted.

## Limitations

- The extension cannot list your events. Tuna's host app declares no calendar usage description, so
  EventKit access is unavailable to extensions. Event browsing would need Tuna to add
  `NSCalendarsFullAccessUsageDescription`.
- Verified against Fantastical 4.2 (`com.flexibits.fantastical2.mac`, direct download). The Mini
  Window scheme is registered by Fantastical's helper login item, which is enabled by default.

## Development

```bash
TUNA_CODE_SIGN_IDENTITY=- ./scripts/tuna-extension install --scheme FantasticalExtension --restart
./scripts/tuna-extension logs --last 20m
```

Ad hoc signing (`TUNA_CODE_SIGN_IDENTITY=-`) is enough for a dev install because Tuna disables
library validation. Enable the extension under Tuna Settings > Extensions after the first install.
