# Fantastical

Fantastical brings your agenda into Tuna and turns typed text into events and tasks through
Fantastical's natural language parser. Reads use Fantastical's built-in MCP helper, writes use its
URL scheme; nothing leaves this Mac.

## Adding events and tasks

Type a sentence in Tuna, then pick an action:

- **Add to Fantastical**: `Lunch with Sam friday 12h30` becomes an event. Fantastical shows how it
  read the sentence and Enter confirms (turn on *Add without confirmation* to skip the preview).
- **Add Task to Fantastical**: same, as a task in whichever task source Fantastical uses
  (Reminders, Google Tasks, Todoist...). A date in the text becomes the due date.
- **Add to Fantastical Calendar**: pick one of your writable calendars or task lists as the target.
  A task list makes the item a task.
- **Search Fantastical**: opens Fantastical's search with the text.
- **Show Date in Fantastical**: offered when the text is one date, `2026-10-03` or words such as
  `tomorrow` or `next friday`. Reveals that day.

Prefer choosing before typing? Search for **New Event** or **New Task** (both in the Fantastical
Views source):

- Select the entry, Enter, type the sentence, Enter: the item goes to Fantastical's default
  calendar or list.
- Press → on the entry first to choose where it goes: New Task lists your task lists, New Event
  your event calendars. Pick one, Enter, type, Enter.

**Links**: Add to Fantastical and Add Task also accept a link item (a Safari tab, a bookmark, a URL
from the clipboard). Its title becomes the sentence and its address is attached to the item.

Anything Fantastical's parser understands works in the sentence: `at Quick Cuts` for a location,
`/Perso` for a calendar, `alert 30 minutes`, `every tuesday`, `"quoted words"` to keep them in the
title. Emoji badges are private Flexibits data with no outside access, so an emoji you type stays in
the title.

## Fields

Details the parser cannot guess go after a **separator**. The default is `--` (two hyphens):

```
Dentist tomorrow 15h -- notes: bring the card -- cal: Perso -- alert: 30 minutes
buy printer paper -- due: next friday -- cal: My Tasks
Board meeting -- start: 2026-10-03 14:00 -- end: 2026-10-03 15:30 -- url: https://meet.example.com/x
```

Each field is `key: value`, separated from the next by another separator. Keys are case-insensitive
and a misspelled key stops the action with "Unknown field" instead of silently landing in the title.

- `title:` exact title. With no sentence before the separator nothing else is parsed, so pair it
  with `start:` / `end:` or `due:`.
- `start:` / `end:` (also `from:` / `to:`) for events, `due:` for tasks. Use `2026-10-03 14:00`,
  `2026-10-03`, or words such as `next friday 9h`.
- `allday` flag (or `allday: no`).
- `cal:` or `calendar:` the calendar or task list name as shown in Fantastical.
- `alert:` (or `alarm:`), repeatable: `alert: 30 minutes -- alert: 1 day before at 9am`.
- `url:` or `link:`, and `notes:` or `note:`.

**Changing the separator**: Tuna Settings > Extensions > Fantastical > *Field separator*. Any token
without spaces works, for example `>>` or `;;`. The separator only counts when it stands alone
between spaces, so `https://x.com/a--b` is safe. macOS may turn `--` into an em dash while you type;
both are accepted.

Fantastical's own words (`/Calendar`, `at Place`, `alert 30 minutes`, `todo`) belong in the sentence,
before the first separator; text after a field key is taken literally, so `notes: test /Perso` puts
`/Perso` in the note. A partial calendar name is enough: `cal: Perso` picks "Personnel".

Fields are translated into Fantastical's own grammar (`todo`, a quoted title, `from X to Y`,
`all day`, `alert`, `/Calendar`) because Fantastical ignores most structured URL parameters while
its preview is open; only notes and the URL travel as parameters.

## Agenda

Search for **Fantastical** and press → (or select Fantastical.app and press →) to browse **Today**,
**Tomorrow**, **This Week**, **Next 7 Days**, **This Month**, **This Quarter**, **This Year**,
**Tasks**, and **By Calendar**, each with its count. Type inside the root to search every event and
task by name. Each item shows its day, time, calendar, and location. Fantastical answers at most 99
items per query; a group at that limit says so.

Actions on an item:

- **Show in Fantastical** (default): reveals the item's day.
- **Reschedule...**, **Rename...**, **Change Location...**: type the new value as the target.
  Reschedule takes words such as `tomorrow 15h` or `next monday 9h to 10h`.
- **Delete from Fantastical**: asks for confirmation first.

The agenda comes from Fantastical's built-in MCP helper (Fantastical 4.1.17 or later). The first
time Tuna uses it, Fantastical asks whether to allow Tuna; refuse and the agenda shows a message
instead. The helper does not expose notes, links, or a done flag, so those are not shown and tasks
cannot be completed from Tuna.

## Views

The **Fantastical Views** source lists Today, Tomorrow, Calendar (main window), Mini Window, one
`Set: Name` entry per calendar set you add in settings, plus the New Event and New Task entries.
Select a view to open it; its Fantastical URL is the copy and text value.

## Settings

Tuna Settings > Extensions > Fantastical:

- **Add without confirmation** (default off): when on, items are added immediately instead of
  showing Fantastical's parse preview.
- **Use the Mini Window** (default on): parse and search open in the menu bar Mini Window. Turn off
  to use the main window.
- **Field separator** (default `--`): the token that starts the fields block.
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
  words, so Tuna asks one range per group; items without a date only appear in search.
- Verified against Fantastical 4.2 (`com.flexibits.fantastical2.mac`, direct download). The Mini
  Window scheme is registered by Fantastical's helper login item, which is enabled by default.

## Development

```bash
TUNA_CODE_SIGN_IDENTITY=- ./scripts/tuna-extension install --scheme FantasticalExtension --restart
./scripts/tuna-extension logs --last 20m
```

Ad hoc signing (`TUNA_CODE_SIGN_IDENTITY=-`) is enough for a dev install because Tuna disables
library validation. Enable the extension under Tuna Settings > Extensions after the first install.
