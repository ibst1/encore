# Changelog

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
