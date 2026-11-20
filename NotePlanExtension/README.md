# NotePlan Extension

Search and open [NotePlan](https://noteplan.co) notes, folders, and calendar notes from Tuna, and capture text into NotePlan.

## What it adds

**Sources**

- **NotePlan Notes** — every project note and folder, as NotePlan lists them. In global search by default.
- **NotePlan Calendar Notes** — Today, Tomorrow, Yesterday, This Month, This Quarter, This Year.

Select NotePlan in Tuna and press → to browse both.

**Actions**

| Subject | Action |
| --- | --- |
| Note, folder, calendar note | Open in NotePlan |
| Note, calendar note | Open in New NotePlan Window, Open in NotePlan Split View, Append Text... |
| Text | Add to Today in NotePlan, Add Task to Today in NotePlan, Append to NotePlan Note..., Create NotePlan Note, Search NotePlan |
| NotePlan (the app) + text | Search, Create Note, Add to Today, Add Task to Today |

## How it reads NotePlan

The extension never opens NotePlan's storage (local folder, iCloud Drive, CloudKit, or a shared space). It asks the running NotePlan through Apple Events:

```applescript
tell application id "co.noteplan.NotePlan3"
  listNotes
  listNotes of type "folders"
end tell
```

Both commands return JSON (`title`, `filename`, `folder`, `modifiedAt`). All actions open `noteplan://x-callback-url/…` links (`openNote`, `addText`, `addNote`, `search`).

Consequences:

- macOS asks once to let Tuna control NotePlan (Privacy & Security › Automation). No Full Disk Access is needed.
- The list refreshes only while NotePlan is running. Tuna does not launch NotePlan to scan. The last list is cached in `~/Library/Caches/com.brnbw.tuna.plugins.noteplan/notes.json` (titles and paths only, no note content), so notes stay searchable while NotePlan is closed.
- NotePlan returns an empty list without a subscription or trial.
- Both the App Store / direct build (`co.noteplan.NotePlan3`) and the Setapp build (`co.noteplan.NotePlan-setapp`) are supported.

## Limitations

- Weekly notes are not offered: their numbering follows NotePlan's first-day-of-week setting.
- Tasks are added as `- [ ] text`, which NotePlan reads as a task with every task-marker setting.
- Notes in `@Trash` are left out.

## Development

From the repository root:

```bash
./scripts/tuna-extension install --scheme NotePlanExtension --restart
./scripts/tuna-extension logs --last 20m
```

In Tuna, type `.` to enter text mode before you run a text action.
