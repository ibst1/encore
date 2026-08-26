# Changelog

## 1.6.0 (2026-08-26)

- The step tools (Add/Edit step, Move up/down, Trim, Delete step) moved
  to their own toolbar above the step list - "Delete steps" no longer
  sits four buttons from the macro-level "Delete", which is now labeled
  "Delete macro". Both destructive buttons turn red on hover, and all
  toolbar buttons got icons.
- Multi-select recordings with Ctrl/Shift-click; "Delete macro" removes
  the whole selection after one confirmation listing the names.
- Drag selected steps onto another recording in the list to move them
  there (Ctrl+drop copies). The block keeps its internal timing and is
  appended after the target's last event; a differing coordinate mode
  is called out in the confirmation.
- New CLI button: copy-ready commands for playing the selected macro
  from the command line or from another AutoHotkey script, plus a link
  to the README section - which now documents calling macros from other
  scripts (Run/RunWait, hotstring example, ENCORE_CMD).

## 1.4.0 (2026-08-24)

- Editable delays: the step list shows the pause before each step —
  click it and type a new value in milliseconds.
- Rename recordings by double-clicking or right-clicking them in the list.
- Command line: `Encore.exe <macro>` plays a macro and exits (coexists
  with the tray instance); `--export <macro> <dest>` exports it.
- Export as standalone .ahk (window button, tray menu or CLI): the events
  plus a minimal embedded player, runnable anywhere with AutoHotkey v2
  and no Encore.
- Fix: an unmatched key-up in a hand-edited macro could abort playback.

## 1.3.0 (2026-08-24)

- Step editing: "Type …" steps can be edited (the raw keystrokes are
  replaced by a text event played with SendText), and pause, send-keys
  and program-switch steps can be edited too.
- Add steps anywhere in a macro: typed text, an explicit pause, raw keys
  in AutoHotkey Send syntax, or a program switch. Stored as readable
  t/d/s/w lines in the macro file.

## 1.2.0 (2026-08-24)

- Management window (WebView2): browse recordings with event counts and
  durations, read the selected macro as human-readable steps, select and
  delete steps, rename/delete recordings, per-recording playback
  overrides (repeat, pause, speed, mode) stored in the macro file, and a
  settings dialog for everything that previously required editing the
  ini. Opens via tray double-click, the tray menu or IPC command 5.

## 1.1.0 (2026-08-24)

- The play key (F12) also stops an ongoing recording.
- Name recordings, export a copy and load macro files from the tray menu.
- Smart replay: Alt+Tab sequences and taskbar switch clicks are replaced
  by their window anchors (the switcher never opens — playback jumps
  straight to the right window); anchors record the process path and
  start the program when it is not running; rapid clicks are fused into
  atomic double-clicks; moved/resized/maximized/minimized windows get
  corrective geometry anchors. Shell surfaces (the switcher, Task View,
  the taskbar, Start) can no longer become anchors.

## 1.0.0 (2026-08-24)

- Initial release: records keyboard, mouse (movements, clicks, wheel) and
  window switches; plays back at original speed (adjustable factor) or
  with a fixed pause between events; repeat 1-N times or until aborted,
  with a configurable pause between repetitions. Every recording is saved
  as a timestamped file and selectable from the tray menu. Window anchors
  re-activate the right program during playback. Default hotkeys:
  Shift+F12 record/stop, F12 play/abort.
