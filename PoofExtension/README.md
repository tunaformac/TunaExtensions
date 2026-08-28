# Poof Extension

Find and manage [Poof](https://github.com/mikker/poof) text snippets from Tuna.

## What it does

- Keeps snippets out of global search until you explicitly enable the ones you want.
- Searches browsed snippets by description, trigger, and replacement text.
- Pastes a snippet as the default action, expanding Poof's date, time, UUID, and clipboard tokens at invocation time.
- Creates a snippet from selected or typed text with **Create Snippet**, then asks for its trigger.
- Deletes snippets without reformatting neighboring TOML entries.
- Opens the source TOML file in its default editor.
- Browses all snippets from the **Poof Snippets** catalog or by browsing the Poof app.

The extension follows Poof's configured directory, including a custom dotfiles location. New
snippets are written as individual files under its `snippets` subdirectory. Editing replacement
content stays file-based so Tuna never has to rewrite unrelated TOML formatting or comments.
Tuna removes `{{cursor}}` from pasted text, but its generic Paste action cannot reposition the
destination app's insertion point the way Poof's native event injector can.
