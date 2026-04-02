# AppleScript (macOS)

Automate Ghostty on macOS with AppleScript. This guide covers
the object model, available commands, and practical examples.

Source: https://ghostty.org/docs/features/applescript

## Overview

Ghostty on macOS exposes a native AppleScript dictionary so scripts can
query and control terminal windows, tabs, and split panes.
This makes it easy to integrate Ghostty with tools such as `osascript`,
launcher workflows, editor plugins, and custom automation scripts.

AppleScript support was introduced in Ghostty 1.3.0.

## Scripting Dictionary

The source of truth for the AppleScript API is the Ghostty scripting
definition file: [Ghostty.sdef](https://github.com/ghostty-org/ghostty/blob/main/macos/Ghostty.sdef).
The best way to view this is to load it into Script Editor and browse
the API using the macOS GUI.

To inspect the dictionary from an installed app bundle:

```bash
sdef /Applications/Ghostty.app | less
```

To verify that scripting works:

```bash
osascript -e 'tell application "Ghostty" to get version'
```

## Object Model

Ghostty's AppleScript model is hierarchical:

```
application -> windows -> tabs -> terminals
```

| Object | Key Properties | Key Elements |
| --- | --- | --- |
| `application` | `name`, `frontmost`, `front window`, `version` | `windows`, `terminals` |
| `window` | `id`, `name`, `selected tab` | `tabs`, `terminals` |
| `tab` | `id`, `name`, `index`, `selected`, `focused terminal` | `terminals` |
| `terminal` | `id`, `name`, `working directory` | None |

`front window` returns the frontmost Ghostty window. `focused terminal`
returns the active terminal in a tab, which is useful for scripts that
operate on whatever terminal currently has focus.

### Object Query Examples

```applescript
tell application "Ghostty"
    set win to front window
    set tab1 to selected tab of win
    set term1 to focused terminal of tab1
    set allTermsInWin to terminals of win

    set cwdMatches to every terminal whose working directory contains "ghostty"
end tell
```

These two properties make active-context scripting concise:

```applescript
tell application "Ghostty"
    set term to focused terminal of selected tab of front window
    input text "pwd\n" to term
end tell
```

```applescript
tell application "Ghostty"
    set currentTerm to focused terminal of selected tab of front window
    set newTerm to split currentTerm direction right
    input text "echo split-ready\n" to newTerm
end tell
```

## Commands

### Creation and Layout

| Command | Purpose | Example Syntax |
| --- | --- | --- |
| `new surface configuration` | Create a reusable surface configuration record. | `set cfg to new surface configuration` |
| `new window` | Create a new window. | `set win to new window with configuration cfg` |
| `new tab` | Create a new tab in an optional target window. | `set t to new tab in win with configuration cfg` |
| `split` | Split a terminal and return the new terminal. | `set t2 to split t1 direction right with configuration cfg` |

`split direction` values are `right`, `left`, `down`, and `up`.

### Focus, Selection, and Lifecycle

| Command | Purpose | Example Syntax |
| --- | --- | --- |
| `focus` | Focus a terminal and bring its window to front. | `focus t1` |
| `activate window` | Bring a window to the front. | `activate window (window 1)` |
| `select tab` | Select a tab. | `select tab (tab 2 of window 1)` |
| `close` | Close a terminal. | `close (terminal 2 of selected tab of window 1)` |
| `close tab` | Close a tab. | `close tab (tab 2 of window 1)` |
| `close window` | Close a window. | `close window (window 1)` |

### Input and Actions

| Command | Purpose | Example Syntax |
| --- | --- | --- |
| `input text` | Send paste-style text input to a terminal. | `input text "echo hello" to t1` |
| `send key` | Send key press/release events with optional modifiers. | `send key "enter" to t1` |
| `send mouse button` | Send mouse button events. | `send mouse button left button to t1` |
| `send mouse position` | Send pointer position updates. | `send mouse position x 240 y 120 to t1` |
| `send mouse scroll` | Send scroll events with precision/momentum options. | `send mouse scroll x 0 y -8 precision true to t1` |
| `perform action` | Execute a Ghostty action string on a terminal. | `perform action "toggle_fullscreen" on t1` |

For `send key` and `send mouse button`, `action` can be `press` or
`release`. `modifiers` is a comma-separated string containing any of:
`shift`, `control`, `option`, `command`.

For `perform action`, action strings match the action names used in keybind
configuration. See [Keybind Action Reference](https://ghostty.org/docs/config/keybind/reference).

## Perform Action Reference

`perform action` is the most powerful extension point — it exposes all keybind
actions via AppleScript. Syntax: `perform action "action_name" on <terminal>`.
Actions that take parameters use a colon separator: `"action_name:param"`.

### Terminal Content Export

These actions write terminal content to a temporary file. The sub-action
determines what happens with the file path:
- `:copy` — copies the temp file path to the clipboard
- `:paste` — pastes the temp file path into the terminal
- `:open` — opens the temp file with the default editor

| Action | Description |
| --- | --- |
| `write_screen_file:copy\|paste\|open` | Write **visible screen** content to temp file |
| `write_scrollback_file:copy\|paste\|open` | Write **entire scrollback** (including screen) to temp file |
| `write_selection_file:copy\|paste\|open` | Write **selected text** to temp file |

Example — read the current screen content:

```applescript
tell application "Ghostty"
    set t to focused terminal of selected tab of front window
    perform action "write_screen_file:copy" on t
    -- The temp file path is now on the clipboard
    -- Read it with: do shell script "cat " & (the clipboard)
end tell
```

### Clipboard and Selection

| Action | Description |
| --- | --- |
| `copy_to_clipboard` | Copy selected text (default format) |
| `copy_to_clipboard:plain` | Copy as plain text |
| `copy_to_clipboard:html` | Copy as HTML |
| `copy_to_clipboard:mixed` | Copy as both plain + HTML |
| `paste_from_clipboard` | Paste clipboard content |
| `paste_from_selection` | Paste from selection clipboard |
| `copy_url_to_clipboard` | Copy URL under cursor |
| `copy_title_to_clipboard` | Copy terminal title to clipboard |
| `select_all` | Select all text in terminal |

### Title Management

| Action | Description |
| --- | --- |
| `set_surface_title:My Title` | Set terminal surface title programmatically |
| `set_tab_title:My Title` | Set tab title programmatically |
| `prompt_surface_title` | Pop-up dialog to change surface title |
| `prompt_tab_title` | Pop-up dialog to change tab title |

Example:

```applescript
tell application "Ghostty"
    set t to focused terminal of selected tab of front window
    perform action "set_surface_title:Build Server" on t
end tell
```

### Terminal Control

| Action | Description |
| --- | --- |
| `reset` | Reset terminal state (like the `reset` command) |
| `clear_screen` | Clear screen **and** all scrollback |
| `toggle_readonly` | Toggle read-only mode |
| `toggle_secure_input` | Toggle secure input mode |
| `toggle_mouse_reporting` | Toggle mouse reporting |

### Font Size

| Action | Description |
| --- | --- |
| `set_font_size:14.5` | Set font size to specific value |
| `increase_font_size:1` | Increase font size by amount |
| `decrease_font_size:1` | Decrease font size by amount |
| `reset_font_size` | Reset to configured default |

### Scrolling and Navigation

| Action | Description |
| --- | --- |
| `scroll_to_top` | Scroll to top of scrollback |
| `scroll_to_bottom` | Scroll to bottom |
| `scroll_to_selection` | Scroll to current selection |
| `scroll_to_row:N` | Scroll to 0-based absolute row |
| `scroll_page_up` | Scroll one page up |
| `scroll_page_down` | Scroll one page down |
| `scroll_page_fractional:0.5` | Scroll by fraction of page (negative = up) |
| `scroll_page_lines:N` | Scroll by N lines (negative = up) |
| `jump_to_prompt:N` | Jump by N prompts (requires shell integration) |

### Search

| Action | Description |
| --- | --- |
| `start_search` | Open search UI |
| `end_search` | Close search UI |
| `search:text` | Search for specific text |
| `search_selection` | Search for currently selected text |

### Raw Input

| Action | Description |
| --- | --- |
| `text:string` | Send arbitrary text (Zig string literal syntax) |
| `csi:sequence` | Send CSI escape sequence (e.g. `csi:0m`) |
| `esc:sequence` | Send ESC escape sequence |

### Split Management

| Action | Description |
| --- | --- |
| `new_split:right\|left\|down\|up\|auto` | Create new split |
| `goto_split:previous\|next\|top\|bottom\|left\|right` | Navigate between splits |
| `resize_split:direction,amount` | Resize split (e.g. `resize_split:up,10`) |
| `equalize_splits` | Make all splits equal size |
| `toggle_split_zoom` | Zoom/unzoom current split |

### Tab Management

| Action | Description |
| --- | --- |
| `new_tab` | Create new tab |
| `next_tab` | Switch to next tab |
| `previous_tab` | Switch to previous tab |
| `last_tab` | Switch to last tab |
| `goto_tab:N` | Switch to tab by index |
| `move_tab:N` | Move tab by offset (e.g. `1`, `-1`) |
| `toggle_tab_overview` | Toggle tab overview |

### Window Management

| Action | Description |
| --- | --- |
| `new_window` | Create new window |
| `close_surface` | Close current terminal |
| `close_tab` | Close current tab |
| `close_window` | Close current window |
| `close_all_windows` | Close all windows |
| `toggle_fullscreen` | Toggle fullscreen |
| `toggle_maximize` | Toggle maximize |
| `toggle_window_decorations` | Toggle window decorations |
| `toggle_window_float_on_top` | Toggle always-on-top |
| `reset_window_size` | Reset window to default size |

### Application

| Action | Description |
| --- | --- |
| `open_config` | Open config file |
| `reload_config` | Reload configuration |
| `inspector` | Open terminal inspector |
| `toggle_command_palette` | Toggle command palette |
| `toggle_quick_terminal` | Toggle quick terminal |
| `toggle_visibility` | Toggle app visibility |
| `toggle_background_opacity` | Toggle background opacity |
| `check_for_updates` | Check for updates |
| `quit` | Quit application |

### Key Tables

| Action | Description |
| --- | --- |
| `activate_key_table` | Activate a key table |
| `activate_key_table_once` | Activate key table for one key |
| `deactivate_key_table` | Deactivate current key table |
| `deactivate_all_key_tables` | Deactivate all key tables |
| `end_key_sequence` | End current key sequence |

### Other

| Action | Description |
| --- | --- |
| `ignore` | Ignore key combination |
| `unbind` | Unbind a previously bound key |
| `undo` | Undo |
| `redo` | Redo |

## Surface Configuration Records

`new surface configuration` creates a reusable value record that can be passed
to `new window`, `new tab`, and `split`.

Supported fields are:

* `font size`
* `initial working directory`
* `command`
* `initial input`
* `wait after command`
* `environment variables` (list of `KEY=VALUE` strings)

Example:

```applescript
tell application "Ghostty"
    set cfg to new surface configuration
    set initial working directory of cfg to POSIX path of (path to home folder) & "src/ghostty"
    set font size of cfg to 13
    set environment variables of cfg to {"EDITOR=nvim", "FZF_DEFAULT_OPTS=--height 40%"}

    set win to new window with configuration cfg
end tell
```

## Security

AppleScript support is enabled by default on macOS.
macOS protects app-to-app automation using Automation permissions (TCC), so
the system will prompt before another app can control Ghostty.

If you want to disable AppleScript support entirely, set:

```
macos-applescript = false
```

## Examples

### Build a Tmux-style Layout

```applescript
set projectDir to POSIX path of (path to home folder) & "src/ghostty"

tell application "Ghostty"
    activate

    set cfg to new surface configuration
    set initial working directory of cfg to projectDir

    set win to new window with configuration cfg
    set paneEditor to terminal 1 of selected tab of win
    set paneBuild to split paneEditor direction right with configuration cfg
    set paneGit to split paneEditor direction down with configuration cfg
    set paneLogs to split paneBuild direction down with configuration cfg

    input text "nvim ." to paneEditor
    send key "enter" to paneEditor

    input text "zig build -Demit-macos-app=false" to paneBuild
    send key "enter" to paneBuild

    input text "git status -sb" to paneGit
    send key "enter" to paneGit

    input text "tail -f /tmp/dev.log" to paneLogs
    send key "enter" to paneLogs

    focus paneEditor
end tell
```

### Broadcast a Command to Every Terminal

```applescript
set cmd to "date"

tell application "Ghostty"
    set allTerms to terminals

    repeat with t in allTerms
        input text cmd to t
        send key "enter" to t
    end repeat

    display dialog ("Broadcasted to " & (count of allTerms) & " terminal(s).")
end tell
```

### Jump to a Terminal by Working Directory

```applescript
set needle to "ghostty"

tell application "Ghostty"
    set matches to every terminal whose working directory contains needle

    if (count of matches) = 0 then
        set matches to every terminal whose name contains needle
    end if

    if (count of matches) > 0 then
        set t to item 1 of matches
        focus t
        input text "echo '[focused by AppleScript]'" to t
        send key "enter" to t
    end if
end tell
```
