# Changelog

## 0.5.10

- Press Return on the Tasks group to see every open task in one list, due soonest first with
  undated tasks last. The right arrow still opens the Overdue group and the per list groups. Each
  row keeps the same actions it has under its list.
- Tasks read from Fantastical's own database (Google Tasks and the other lists Fantastical syncs
  itself) now show their due date and priority. The archive stores those as objects and the
  reader asked for plain numbers, so every such task read as undated.

## 0.5.9

- The Tasks group now shows the open tasks Fantastical shows, list by list, with an Overdue
  group first and finished tasks left out. Reminders lists are read through the system Reminders
  permission (Tuna asks once), and the lists Fantastical syncs itself, such as Google Tasks, are
  read from Fantastical's own local database. The helper is only asked when neither is
  available, and such a list says so in its row.
- Undated tasks are listed too, after the dated ones; a task row reads due date, list and
  priority, and an overdue one turns red.
- Complete Task finishes a Reminders task from Tuna and leaves Tuna open. Rename, Reschedule and
  Delete keep going through Fantastical.

## 0.5.8

- Today and Tomorrow split at midnight, and an item running across midnight or over several days
  now appears under every day it covers.
- All-day items keep the day Fantastical gives them, whatever timezone this Mac is in.
- By Calendar lists every calendar with items in the next 7 days, read-only ones included.
  Writability now only decides where a new item can be created, and which items can be edited or
  deleted: Reschedule, Rename, Change Location and Delete are no longer offered on items
  Fantastical will refuse to change.
- The Tasks group lists dated tasks that are overdue or due within 30 days, asking each task list
  on its own so events elsewhere cannot crowd the answer, and its row says how many are overdue.
  Fantastical decides whether a finished task is still reported; its helper carries no completion
  state.
- Creating an item refreshes the agenda, as renaming, rescheduling and deleting already did, and
  an open group refreshes itself once a write lands instead of holding its old rows.
- Items running from before today are kept when filling Today and Tomorrow, and timestamps
  carrying fractional seconds or no offset at all are read instead of dropped.
- New Event and New Task show their calendars as soon as Fantastical answers, instead of asking
  you to leave the pane and come back.
- Fantastical.app gains an Open Mini Window action.
- A stalled request no longer affects the ones after it: the helper is restarted. Helper
  diagnostics stay out of the public log.

## 0.5.7

- Initial release.
- Agenda: search events and tasks as you type, or browse Today, Tomorrow, This Week, Next 7 Days,
  This Month, This Quarter, This Year, Tasks, and By Calendar, through Fantastical's built-in MCP
  helper. Reschedule, rename, change location, and delete (with confirmation) items.
- Add to Fantastical, Add Task to Fantastical, Add to Fantastical Calendar, Search Fantastical, and
  Show Date in Fantastical text actions with inline fields (title, start, end, due, allday, alert,
  cal, url, notes) after a configurable separator; link items become events with the address attached.
- New Event and New Task search entries that take the typed text as their target, and browse
  to the task lists or event calendars to add into a chosen one; Today,
  Tomorrow, Calendar, Mini Window, and calendar set views; app browse and action
  enrichment for Fantastical.app. Requires Tuna 0.99 / TunaKit 1.22.0 and Fantastical 4.1.17.
