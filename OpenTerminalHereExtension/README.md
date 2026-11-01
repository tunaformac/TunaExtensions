# Open Terminal Here

Open a folder in your terminal from Tuna. A file opens the folder that contains it.

Requires Tuna 0.108 or later.

## Action

**Open Terminal Here** opens the subject in the terminal chosen in the extension's **Terminal**
setting. The default is Terminal.

It applies to:

- file and folder subjects, including Current Selection and items staged with **Stage in Tuna**;
- text that is an existing absolute path, a `~` path, or a `file:` URL. Text is tried exactly as
  written first, because a name can end in a space. If no such path exists, it is tried again with
  surrounding whitespace removed.

If the chosen terminal is not installed, the action fails and says so. It never opens a different
app.

## Terminals

| Terminal | How the folder is passed |
| --- | --- |
| Alacritty | `alacritty msg create-window --working-directory`, or a new instance with `--working-directory` when no instance answers |
| Ghostty | Opens the folder with the app |
| iTerm2 | Opens the folder with the app |
| kitty | Opens the folder with the app |
| Terminal | Opens the folder with the app |
| Warp | `warp://action/new_window?path=` |
| WezTerm | `wezterm-gui start --cwd`, which reuses a running WezTerm |

Notes:

- **Several subjects:** each distinct folder is passed to the terminal as its own open request.
  Whether that becomes a tab or a window follows the app's own settings, such as Ghostty's
  `macos-dock-drop-behavior`.
- **Alacritty:** the window request to a running instance has a 5 second deadline. If it times out
  or Tuna cancels the action, the extension stops without opening a fallback window, because the
  request may still be pending and a second window could be a duplicate.
- **iTerm2:** iTerm2 imports a folder whose name ends in `.its`, `.itermtab`, `.itr`,
  `.iterm2arrangement`, `.it2triggers`, `.iterm2passwords`, or `.itermcolors` as a settings file
  instead of opening it. The action reports an error for those folders. Choose another terminal to
  open them.

## Privacy

The action reads only the subject's path, checks that it exists, and hands the folder to the chosen
app. It needs no permissions and makes no network requests.
