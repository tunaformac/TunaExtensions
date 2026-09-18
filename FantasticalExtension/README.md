# Fantastical

Fantastical brings your agenda into Tuna and turns typed text into events and tasks through
Fantastical's natural language parser.

## Agenda

Browse **Fantastical** (or select Fantastical.app and press →) for **Today**, **Tomorrow**,
**This Week**, **Next 7 Days**, **This Month**, **This Quarter**, **This Year**, **Tasks**, and
**By Calendar**, each with its count. Opening the root runs one query per group, so groups open instantly.
Fantastical answers at most 99 items per query; a group at that limit says so. Type inside the root to search every event and task by name. Each item shows its day,
time, calendar, and location.

Actions on an item:

- **Show in Fantastical** (default): reveals the item's day.
- **Reschedule...**, **Rename...**, **Change Location...**: type the new value as the target.
  Reschedule takes natural language such as `tomorrow 15h` or `next monday 9h to 10h`.
- **Delete from Fantastical**: asks for confirmation first.
- **Add to Fantastical Calendar**: on typed text, pick one of your writable calendars as the
  target. The text goes through the same parser and fields as Add to Fantastical, into that
  calendar; a task list makes it a task. The calendar list lives only inside this picker, not in
  global search.

The agenda comes from Fantastical's built-in MCP helper (Fantastical 4.1.17 or later). The first
time Tuna uses it, Fantastical asks whether to allow Tuna; refuse and the agenda shows a message
instead. Fantastical does not expose notes, links, or a done flag through the helper, so those are
not shown and tasks cannot be completed from Tuna.

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
it in settings). Fantastical ignores most structured URL parameters while its preview is open, so
the fields are written into the sentence in its own grammar (`todo`, a quoted title, `from X to Y`,
`all day`, `/Calendar`); only `notes:` and `url:` travel as parameters.

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
- `alert:` (or `alarm:`), repeatable: `alert: 30 minutes -- alert: 1 day before at 9am`.

Emoji badges (the emoji button next to the title) are private Flexibits data with no URL, AppleScript,
Shortcuts, or helper access, so they cannot be set from Tuna; an emoji typed in the text stays in
the title. macOS may auto-convert `--` into an em dash while you type; both are accepted. Keys are
case-insensitive. A misspelled key fails the action with "Unknown field" instead of
silently landing in the title. The separator only counts when it stands alone between spaces, so
`https://x.com/a--b` is safe.

**Links**: Add to Fantastical and Add Task also take a link item (Safari tab, bookmark, a URL from
the clipboard). Its title becomes the sentence and its address is attached as the event URL.

## Views

The **Fantastical Views** source lists Today, Tomorrow, Calendar (main window), Mini Window, and one
`Set: Name` entry per calendar set you add in settings. Select one to open it; its Fantastical URL is
the copy and text value.

The same source has **New Event** and **New Task** entries, shown with Fantastical's icon: select
one, press Enter, type the sentence (fields allowed), Enter. Same result as Add to Fantastical and
Add Task to Fantastical, for when you prefer to pick the action before typing.

Select Fantastical.app in Tuna and press → to browse the agenda and the views.

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

Everything stays on this Mac: the URL scheme for creating items and views, and Fantastical's own
MCP helper (`Fantastical.app/Contents/Helpers/FantasticalMCP.app`) over standard input and output
for the agenda. No network access from the extension, no credentials, no EventKit. Agenda results
live in memory only while the browse or search is open. Writes: reschedule, rename, change
location, and delete (confirmed) through the helper; every create goes through the URL scheme.

## Limitations

- Agenda reads go through Fantastical's helper because Tuna's host app declares no calendar usage
  description, so EventKit is unavailable to extensions. The helper needs a date range in plain
  words; Tuna asks for the next 7 days. Items without a date only appear in search.
- Verified against Fantastical 4.2 (`com.flexibits.fantastical2.mac`, direct download). The Mini
  Window scheme is registered by Fantastical's helper login item, which is enabled by default.

## Development

```bash
TUNA_CODE_SIGN_IDENTITY=- ./scripts/tuna-extension install --scheme FantasticalExtension --restart
./scripts/tuna-extension logs --last 20m
```

Ad hoc signing (`TUNA_CODE_SIGN_IDENTITY=-`) is enough for a dev install because Tuna disables
library validation. Enable the extension under Tuna Settings > Extensions after the first install.
