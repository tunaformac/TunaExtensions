# Fantastical

Fantastical brings your agenda into Tuna and turns typed text into events and tasks through
Fantastical's natural language parser. Reads use Fantastical's built-in MCP helper, your Reminders
lists and Fantastical's own database, creates use its URL scheme; nothing leaves this Mac.

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

Search for **Fantastical** and press → to browse **Today**, **Tomorrow**, **This Week**,
**This Month**, **This Quarter**, **Tasks**, **This Year**, **By Calendar** and **Next 7 Days**,
each with its count. Selecting Fantastical.app and pressing → reaches the same groups, one level
further in. Type inside the root to search events and tasks by name; search shows the first 60
matches. Each item shows its day, time, calendar, and location.

- **Tasks** shows your open tasks the way Fantastical does: an **Overdue** group first, then one
  group per task list, each row saying the due date, the list and the priority, undated tasks
  after the dated ones. An overdue task is in both places: the Overdue group and its own list.
  Finished tasks are left out. Reminders lists are read through the system Reminders permission,
  which Tuna asks for once; lists Fantastical syncs itself (Google Tasks, Todoist, CalDAV tasks)
  are read from Fantastical's local database. When neither is available a list falls back to
  Fantastical's helper, which only reports dated tasks, those overdue or due in the next 30 days,
  and no completion state, and its row says `completion unknown`.
- **Today** and **Tomorrow** split at midnight, and an item that runs across midnight or over
  several days is listed under every day it covers.
- **By Calendar** groups the next 7 days by calendar, read-only calendars included. Writability
  only decides where a new item can be created, and which items can be edited or deleted.
- All-day items keep the day Fantastical gives them, even when this Mac is in another timezone.
- Fantastical answers at most 99 items per query, and a group at that limit says so. Today,
  Tomorrow and By Calendar are drawn from those answers, so a very busy period can leave them
  short without a warning of their own.

Actions on an item:

- **Show in Fantastical** (default): reveals the item's day.
- **Reschedule...**, **Rename...**, **Change Location...**: type the new value as the target.
  Reschedule takes words such as `tomorrow 15h` or `next monday 9h to 10h`. Change Location is
  offered on events only, since Fantastical keeps no location on a task.
- **Complete Task**: finishes a task read from Reminders and keeps Tuna open for the next one.
  Offered on Reminders tasks in a writable list only.
- **Delete from Fantastical**: asks for confirmation first.

Reschedule, Rename, Change Location and Delete are offered only on items in calendars Fantastical
can write to. An item in a read-only calendar keeps Show in Fantastical and nothing else.

The agenda comes from Fantastical's built-in MCP helper (Fantastical 4.1.17 or later). The first
time Tuna uses it, Fantastical asks whether to allow Tuna; refuse and the agenda shows a message
instead. The helper does not expose notes, links or a done flag, so open tasks come from EventKit
(Reminders lists) and from Fantastical's local database instead, and Complete Task is offered on
Reminders tasks only. Refuse the Reminders permission and the Tasks group shows a **Reminders
access needed** row at the top; a Reminders list then falls back to Fantastical's helper, which
only reports dated tasks and no completion state, until you allow Tuna under System Settings,
Privacy & Security, Reminders.

## Views

The **Fantastical Views** source lists Today, Tomorrow, Calendar (main window), Mini Window, one
`Set: Name` entry per calendar set you add in settings, plus the New Event and New Task entries.
Select a view to open it; its Fantastical URL is the copy and text value.

Selecting **Fantastical.app** itself adds **Open Mini Window** to its actions.

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

Everything stays on this Mac: the URL scheme for creating items and views, Fantastical's own MCP
helper (`Fantastical.app/Contents/Helpers/FantasticalMCP.app`) over standard input and output for
the agenda, and EventKit for your Reminders lists and Fantastical's own database, read only, for
open tasks. No network access from the extension, no credentials. Agenda results live in memory
only while the browse or search is open. Writes: reschedule, rename, change location, and delete
(confirmed) through the helper, Complete Task through EventKit; every create goes through the URL
scheme. Helper diagnostics are logged privately, so event and calendar text never reaches the
public log. Reminders are read with the system permission Tuna already declares; nothing from
EventKit or from Fantastical's database is logged.

## Limitations

- Event reads go through Fantastical's helper because Tuna's host app declares no calendar usage
  description, so EventKit's calendars are unavailable to extensions; Reminders, whose permission
  Tuna does declare, are read directly. The helper needs a date range in plain words, so Tuna asks
  one range per group; an event without a date only appears in search.
- Open tasks in lists Fantastical syncs itself are read from
  `~/Library/Group Containers/85C27NK92C.com.flexibits.fantastical2.mac/Database/Fantastical-8.fcdata`,
  read only, never written. That file is Fantastical's own and its layout may change with a
  Fantastical update; when it cannot be read the list falls back to the helper.
- A Reminders list is recognised by the source name Fantastical's helper reports for it,
  `Calendar`. A Reminders list reported under another name is read from Fantastical's database
  and, when that database does not hold it, from the helper. The extension log names the source
  chosen for every list.
- Verified against Fantastical 4.2 (`com.flexibits.fantastical2.mac`, direct download). The Mini
  Window scheme is registered by Fantastical's helper login item, which is enabled by default.

## Development

```bash
TUNA_CODE_SIGN_IDENTITY=- ./scripts/tuna-extension install --scheme FantasticalExtension --restart
./scripts/tuna-extension logs --last 20m
```

Ad hoc signing (`TUNA_CODE_SIGN_IDENTITY=-`) is enough for a dev install because Tuna disables
library validation. Enable the extension under Tuna Settings > Extensions after the first install.
