# Encore

A Windows macro recorder in the system tray: record what you do — keystrokes, mouse movements, clicks, scrolling and window switches — and play it back. *Encore!*

- **Shift+F12** starts recording; the same key stops it. **F12** plays the selected recording; F12 again — or **Esc** — aborts. Both hotkeys are configurable.
- **Playback modes**: original timing (with an adjustable speed factor) or a fixed pause between events.
- **Repeat**: play 1–N times or until aborted, with a configurable pause between repetitions (tray menu → *Repeat*).
- **Every recording is kept**: each one is saved as a timestamped file in `macros\` and selectable from the tray menu (*Recordings*). Give the selected recording a proper name with *Name recording…*, export it with *Save copy as…*, or load a `.macro` file from anywhere with *Load macro file…* — the file name is the menu name, so managing the files in Explorer works too.
- **Alt+Tab is smart-replayed**: an Alt+Tab app switch in the recording is stripped and replaced by its window anchor — playback jumps straight to the right window without ever opening the window switcher. Taskbar clicks used for window switching are handled the same way (the button order on the taskbar is never trusted).
- **Programs are started when needed**: anchors record the full process path, so if the target program is not running at playback, Encore starts it and waits for its window.
- **Double-clicks stay double-clicks**: two rapid clicks are fused into one atomic double-click event, so they survive fixed-delay playback intact.
- **Window geometry is corrected**: moving, resizing, maximizing or minimizing a window during recording adds a corrective anchor — playback snaps the window to the exact recorded position, size and state after the replayed drag.
- **Window anchors**: at the start of a recording and at every window switch, Encore records *which program* was active. During playback it re-activates that program (matched by process name, with title-substring fallback) and waits until it is active — so switching to Excel mid-recording reliably switches to Excel mid-playback, even if a replayed Alt+Tab would have landed elsewhere.
- The tray icon shows the state: blue square = idle, red dot = recording, green triangle = playing.
- **Management window** (double-click the tray icon, or tray → *Open Encore*): browse the recordings with event counts and durations, read the selected macro as human-readable steps ("Switch to EXCEL.EXE", "Type hello", "Ctrl+C", "Double-click at (512, 300)", "Maximize"), select steps and delete them, rename/delete recordings, set per-recording playback overrides (repeat, pause, speed, mode — empty = global) and edit all global settings without touching the ini file. Requires the Microsoft Edge WebView2 Runtime (preinstalled on Windows 10/11 with Edge).
- **Data-driven playback**: open the *Data* panel (the Data button; it also opens by itself when a recording has a list or a {value} step, and your choice is remembered) and paste a list — one value per row, columns tab-separated, stored as `<name>.data` beside the macro. Add a *Next data value* step where the value should be typed. Playback then runs **once per row**, typing that row's value each time — paste 50 sample IDs, press play, done. `{value}` steps can pick a column for multi-column rows, the list follows the recording on rename/delete, and standalone exports bake the current list in.
- **Per-recording hotkeys**: give a recording its own global hotkey (the *Hotkey* field in the window, AutoHotkey syntax like `^!1`) — pressing it selects and plays that macro from anywhere.
- **Window-relative playback**: set *Coords: window-relative* on a recording and its mouse actions replay relative to the anchored window's current position — the macro works even when the window has moved.
- **Progress overlay and countdown**: playback shows a small "▶ name — 123/456 · rep 1/3 — Esc aborts" overlay, and starts after a configurable countdown (default 1 s) so you can settle focus. Both in Settings.
- **Wait-for-window steps**: add a step that waits (with timeout) until a window with a given title/program exists or is active — robust macros against slow applications.
- **Wait-for-clipboard steps**: Ctrl+C in e.g. Excel is asynchronous — at playback speed the paste sometimes beats the copy and a row is skipped. Add a *Wait for clipboard* step after the copy: it waits (with timeout) until the clipboard sequence number actually changes, re-baselining every loop pass.
- **Repeat a block of steps**: select steps and press *Repeat…* — a red bracket appears in the left gutter spanning the block, with a ×N badge. Click the badge to change the count (0 removes the bracket); nesting works. (The whole macro is repeated with the *Repeat* property.)
- **Reorder and trim**: move a selected step up/down with the *Move up*/*Move down* buttons (its pause travels with it and the timeline is rebuilt), and *Trim* removes the dead mouse movements before the first and after the last real action — typically the path toward the stop button.
- **Drag steps to another macro**: select steps and drag them onto another recording in the list — dropping **moves** them, **Ctrl+drop copies**. The block keeps its internal timing and is appended after the target's last event. (If the two macros use different coordinate modes, mouse positions may need adjusting — the confirmation says so.)
- **Multi-select recordings**: Ctrl-click or Shift-click in the recordings list to select several, then *Delete macro* removes them all in one confirmed sweep.
- **Schedule macros**: *Schedule…* creates a Windows Task Scheduler job (grouped under an "Encore" folder) that plays the macro via the command line — daily, weekly or once, with status shown in the dialog and one-click removal. The dialog also lists **every** Encore schedule with a ✕ next to each, so you can remove any of them without hunting through Task Scheduler; a schedule whose macro no longer exists is highlighted. Renaming a macro carries its schedule along, and deleting a macro removes it.
- **Editable delays**: the time column shows the pause before each step — click it, type a new value in milliseconds and press Enter. All later timestamps shift along, so the step's internal timing is untouched. (Hover shows the cumulative time.)
- **Edit and add steps**: a "Type …" step can be edited — its raw keystrokes are replaced by a text event played back with SendText, so you can change what a macro types without re-recording. New steps can be inserted anywhere: typed text, an explicit pause, raw keys in AutoHotkey Send syntax (e.g. `^s` or `{Enter}`), or a program switch. These appear in the macro file as `t`/`d`/`s`/`w` lines and can be hand-edited too.

## Installation

### Option A — portable exe (no AutoHotkey required)

1. Download the latest `Encore-x.y.z.zip` from [Releases](https://github.com/ibst1/encore/releases) and extract it anywhere.
2. Run `Encore.exe`.

`Encore.exe` is the unmodified official AutoHotkey v2 interpreter, renamed — when started it loads the `Encore.ahk` script beside it. All application code ships as readable text, and the binary is byte-identical to the official AutoHotkey release (which also keeps antivirus false positives away).

### Option B — run the script

1. Windows with [AutoHotkey v2](https://www.autohotkey.com/) installed.
2. Run `Encore.ahk`.

## Configuration

`Encore config.ini` is created next to the script on first start (UTF-16 — keep that encoding). Edit it via the tray menu (*Open configuration*) and reload with *Reload configuration*.

| Key | Default | Meaning |
|---|---|---|
| `RecordHotkey` | `+F12` | Starts/stops recording. AutoHotkey syntax: `+` Shift, `^` Ctrl, `#` Win, `!` Alt. Empty disables |
| `PlayHotkey` | `F12` | Plays the selected recording; during playback it aborts, and during recording it stops the recording |
| `Mode` | `original` | `original` (recorded timing) or `fixed` (fixed pause between events) |
| `Speed` | `1.0` | Playback speed factor in original mode — `2` = twice as fast |
| `FixedDelayMs` | `50` | The pause between events in fixed mode |
| `MaxWaitMs` | `5000` | Longest single pause replayed in original mode |
| `MousePollMs` | `15` | Mouse sampling interval while recording |
| `MaxEvents` | `100000` | Safety cap on the number of recorded events |
| `MacroFolder` | *(empty)* | Where recordings are stored. Empty = `macros\` beside the script; relative paths resolve against the script folder. Change it via Settings (with a Browse button) or tray → Recordings → *Change macro folder…* — existing recordings are not moved |
| `WindowAnchors` | `1` | Record and replay "switch to program X" anchors |
| `Repeat` | `1` | Playback repetitions; `0` = until aborted |
| `RepeatPauseMs` | `1000` | Pause between repetitions |

## Command line and standalone use

The window's **CLI** button shows all of this as ready-to-copy commands for the selected recording.

- `Encore.exe MyMacro` (a name in `macros\`, or any path to a `.macro` file) plays that macro and exits — for Task Scheduler, desktop shortcuts or other scripts. A CLI run coexists with the tray instance. Running the script install instead of the portable exe, give the interpreter the script and the macro: `AutoHotkey64.exe Encore.ahk MyMacro`.
- `Encore.exe --export MyMacro out.ahk` exports the macro as a **standalone AutoHotkey script**: the events plus a minimal embedded player, playable on any machine with AutoHotkey v2 and no Encore at all (Esc aborts; repeat/speed/mode are baked in at export time). Also available interactively: *Export .ahk* in the window, or tray → Recordings → *Export as standalone script…*.

### Calling a macro from another AutoHotkey script

Play a macro by name — `Run` is fire-and-forget, `RunWait` blocks until playback finishes:

```ahk
; portable exe install
Run '"C:\Tools\Encore\Encore.exe" "MyMacro"'

; script install — reuse the interpreter that runs your own script
RunWait '"' A_AhkPath '" "C:\Tools\Encore\Encore.ahk" "MyMacro"'
```

So a plain AutoHotkey v2 hotstring that plays a macro looks like this — typing `.rapport` anywhere fires it:

```ahk
::.rapport:: {
    Run '"C:\Tools\Encore\Encore.exe" "Rapportmall"'
}
```

The running tray instance can also be driven without starting a process — post the registered window message `ENCORE_CMD` with wParam `2` (see *Notes*) — but that plays the *currently selected* recording, so `Run` with an explicit macro name is the reliable route from scripts.

**Expanto users**: an [Expanto](https://github.com/ibst1/expanto) phrase can launch a macro with a `{run:...}` field — the command runs after the insert and is never typed:

```
{run:"C:\Tools\Encore\Encore.exe" "Rapportmall"}
```

Alternatively, give the recording a **per-recording hotkey** in Encore's own window (the *Hotkey* field, e.g. `^!1`); pressing it plays the macro from anywhere with no extra script at all.

## Notes

- Recording deliberately uses AutoHotkey's native input mechanisms (InputHook, polling, pass-through hotkeys) instead of custom low-level hooks — Windows silently kills slow script hooks mid-recording, while the native path cannot be killed.
- Replayed input is sent at `SendLevel 1`, so other AutoHotkey scripts (hotstring expanders and similar) react to it like real typing.
- The macro files are plain tab-separated text: `k` lines are keys, `m` lines mouse events, `w` lines window anchors (`w <tab> 0 <tab> program.exe <tab> title part`) — editable by hand.
- Mouse presses shorter than `MousePollMs` can be missed; physical clicks last 50–150 ms, so the default 15 ms leaves ample margin.
- Other programs can control Encore by posting the registered window message `ENCORE_CMD` to its hidden window: wParam `1` = toggle recording, `2` = play, `3` = abort playback, `4` = reload the configuration.
