; Encore — v1.0.0 (2026-08-24)
;
; Records keyboard and mouse activity (keys, clicks, movements, wheel) and
; plays it back — at the original speed (adjustable factor) or with a fixed
; pause between events.
;   - RecordHotkey (default Shift+F12) starts recording; the same key
;     stops it.
;   - PlayHotkey (default F12) plays the selected recording; pressing
;     it again — or Esc — aborts playback. Repeat count and the pause
;     between repetitions are configurable (tray menu / config).
;   - Every recording is saved as a timestamped file in macros\ beside the
;     script; pick which one to play in the tray menu (Recordings).
;
; Recording uses AutoHotkey's native InputHook for keys, a position-polling
; timer for the mouse and pass-through hotkeys for the wheel — deliberately
; NO SetWindowsHookEx callbacks: Windows silently kills low-level hooks
; whose script callbacks respond too slowly (recordings died mid-movement
; after ~350 ms), while the native mechanisms cannot be killed.
;
; Config: "Encore config.ini" next to the script (created on first
; start, UTF-16 — the Windows ini API requires it for non-ASCII text).
#Requires AutoHotkey v2.0
#SingleInstance Force
CoordMode "Mouse", "Screen"
CoordMode "ToolTip", "Screen"

global g_configFile  := A_ScriptDir "\Encore config.ini"
global g_macroDir    := A_ScriptDir "\macros"
global g_currentFile := ""     ; path of the selected recording
global g_events      := []     ; recorded events: {t, kind "k"/"m"/"w", ...}
global g_recording  := false
global g_playing    := false
global g_stopPlay   := false
global g_ih         := 0       ; InputHook while recording
global g_lastX      := ""      ; last recorded cursor position
global g_lastY      := ""
global g_btnState   := Map()   ; button name -> was-down at the last poll
global g_lastActive := 0       ; hwnd of the last recorded foreground window

; config values (see WriteDefaultConfig for meaning)
global g_recordKey     := ""
global g_playKey       := ""
global g_mode          := "original"
global g_speed         := 1.0
global g_fixedDelayMs  := 50
global g_maxWaitMs     := 5000
global g_pollMs        := 15
global g_maxEvents     := 100000
global g_windowAnchors := true
global g_repeat        := 1    ; playback repetitions, 0 = until aborted
global g_repeatPauseMs := 1000

OnError(LogError)
OnExit(Cleanup)
LoadConfig()
macros := ListMacros()
if macros.Length {
    g_currentFile := macros[1].p
    LoadMacroFile(g_currentFile)
}
InitTray()

; External control: PostMessage the registered window message
; "ENCORE_CMD" to the script's hidden window — wParam 1 = toggle
; recording, 2 = play, 3 = abort playback, 4 = reload the configuration.
OnMessage(DllCall("RegisterWindowMessageW", "str", "ENCORE_CMD", "uint"), IpcCmd)

IpcCmd(wParam, lParam, msg, hwnd) {
    global g_stopPlay
    switch wParam {
        case 1: SetTimer(ToggleRecord, -1)
        case 2: SetTimer(Play, -1)       ; detached — playback blocks for its duration
        case 3:
            if g_playing
                g_stopPlay := true
        case 4: SetTimer(() => LoadConfig(true), -1)
    }
}

; ── Recording ───────────────────────────────────────────────────────────
ToggleRecord(*) {
    global g_recording
    if g_playing
        return
    if g_recording
        StopRecording()
    else
        StartRecording()
}

StartRecording() {
    global g_events, g_recording, g_ih, g_lastX, g_lastY, g_btnState, g_lastActive
    g_events := []
    ; keys: AHK's own hook does the capture in C; the callbacks arrive as
    ; ordinary AHK threads and cannot make Windows drop the hook
    g_ih := InputHook("V L0")
    g_ih.KeyOpt("{All}", "N")
    g_ih.OnKeyDown := RecKeyDown
    g_ih.OnKeyUp := RecKeyUp
    g_ih.Start()
    ; mouse: poll position and button edges; a held button at start is not an edge
    g_lastX := "", g_lastY := ""
    for b in ["LButton", "RButton", "MButton", "XButton1", "XButton2"]
        g_btnState[b] := GetKeyState(b)
    SetTimer(PollMouse, g_pollMs)
    ; wheel: pass-through hotkeys (~ lets the rotation reach the app as usual)
    Hotkey("~*WheelUp",    RecWheel.Bind(120,  0x20A), "On")
    Hotkey("~*WheelDown",  RecWheel.Bind(-120, 0x20A), "On")
    Hotkey("~*WheelLeft",  RecWheel.Bind(-120, 0x20E), "On")
    Hotkey("~*WheelRight", RecWheel.Bind(120,  0x20E), "On")
    g_recording := true
    if g_windowAnchors {
        ; anchor to the window that is active as the macro begins, then to
        ; every switch — playback re-activates that program at each anchor
        g_lastActive := 0
        RecordActiveWindow()
        SetTimer(RecordActiveWindow, 150)
    }
    InitTray()
    Notify("● Recording — " g_recordKey " stops", 2500)
}

StopRecording() {
    global g_recording, g_ih
    SetTimer(PollMouse, 0)
    SetTimer(RecordActiveWindow, 0)
    for hk in ["~*WheelUp", "~*WheelDown", "~*WheelLeft", "~*WheelRight"]
        try Hotkey(hk, "Off")
    if g_ih {
        try g_ih.Stop()
        g_ih := 0
    }
    g_recording := false
    CleanUnmatched()
    if g_events.Length {
        SaveMacro()
        Notify("■ Recorded " g_events.Length " events", 2000)
    } else {
        Notify("■ Nothing recorded", 2000)
    }
    InitTray()
}

RecKeyDown(ih, vk, sc) {
    global g_events
    if (g_recording && g_events.Length < g_maxEvents)
        g_events.Push({t: A_TickCount, kind: "k", vk: vk, sc: sc, up: false})
}

RecKeyUp(ih, vk, sc) {
    global g_events
    if (g_recording && g_events.Length < g_maxEvents)
        g_events.Push({t: A_TickCount, kind: "k", vk: vk, sc: sc, up: true})
}

; Samples the cursor and the button states. Logical button state is used on
; purpose: it also reflects synthetic clicks, which keeps the recorder
; scriptable/testable, and physical state would require a mouse hook.
; Presses shorter than MousePollMs can be missed — physical clicks last
; 50-150 ms, so 15 ms leaves ample margin.
PollMouse() {
    global g_events, g_lastX, g_lastY, g_btnState
    static BTN := Map("LButton",  [0x201, 0x202, 0]
                    , "RButton",  [0x204, 0x205, 0]
                    , "MButton",  [0x207, 0x208, 0]
                    , "XButton1", [0x20B, 0x20C, 0x10000]
                    , "XButton2", [0x20B, 0x20C, 0x20000])
    if (!g_recording || g_events.Length >= g_maxEvents)
        return
    mx := "", my := ""
    try MouseGetPos(&mx, &my)
    if (mx = "")
        return
    if (mx != g_lastX || my != g_lastY) {
        g_lastX := mx, g_lastY := my
        g_events.Push({t: A_TickCount, kind: "m", msg: 0x200, x: mx, y: my, data: 0})
    }
    for b, def in BTN {
        now := false
        try now := GetKeyState(b)
        if (now != g_btnState[b]) {
            g_btnState[b] := now
            g_events.Push({t: A_TickCount, kind: "m", msg: def[now ? 1 : 2]
                , x: mx, y: my, data: def[3]})
        }
    }
}

RecWheel(delta, msg, *) {
    global g_events
    if (!g_recording || g_events.Length >= g_maxEvents)
        return
    mx := 0, my := 0
    try MouseGetPos(&mx, &my)
    g_events.Push({t: A_TickCount, kind: "m", msg: msg, x: mx, y: my
        , data: (delta & 0xFFFF) << 16})
}

; Records a "switch to program X" anchor whenever the foreground window
; changes during recording. Tabs are stripped from titles (TSV storage).
RecordActiveWindow() {
    global g_events, g_lastActive
    if !g_recording
        return
    hwnd := 0
    try hwnd := WinGetID("A")
    if (!hwnd || hwnd = g_lastActive)
        return
    g_lastActive := hwnd
    exe := "", title := ""
    try exe := WinGetProcessName(hwnd)
    try title := StrReplace(WinGetTitle(hwnd), "`t", " ")
    if (exe = "" && title = "")
        return
    g_events.Push({t: A_TickCount, kind: "w", exe: exe, title: title})
}

; Drop key/button events without a counterpart in the recording: the tail
; of the start hotkey (its releases), the head of the stop hotkey (its
; presses) and any half-captured press. Auto-repeat (many downs, one up)
; is preserved: matching is per key, not one-to-one.
CleanUnmatched() {
    global g_events
    BTN_DOWN := Map(0x201, "L", 0x204, "R", 0x207, "M", 0x20B, "X")
    BTN_UP   := Map(0x202, "L", 0x205, "R", 0x208, "M", 0x20C, "X")
    keep := []
    for i, e in g_events {
        if (e.kind = "k") {
            if e.up {
                ok := false
                loop i - 1 {
                    p := g_events[A_Index]
                    if (p.kind = "k" && !p.up && p.vk = e.vk) {
                        ok := true
                        break
                    }
                }
            } else {
                ok := false
                loop g_events.Length - i {
                    n := g_events[i + A_Index]
                    if (n.kind = "k" && n.up && n.vk = e.vk) {
                        ok := true
                        break
                    }
                }
            }
            if ok
                keep.Push(e)
        } else if (e.kind = "m" && BTN_DOWN.Has(e.msg)) {
            ok := false
            loop g_events.Length - i {
                n := g_events[i + A_Index]
                if (n.kind = "m" && BTN_UP.Has(n.msg) && BTN_UP[n.msg] = BTN_DOWN[e.msg]) {
                    ok := true
                    break
                }
            }
            if ok
                keep.Push(e)
        } else if (e.kind = "m" && BTN_UP.Has(e.msg)) {
            ok := false
            loop i - 1 {
                p := g_events[A_Index]
                if (p.kind = "m" && BTN_DOWN.Has(p.msg) && BTN_DOWN[p.msg] = BTN_UP[e.msg]) {
                    ok := true
                    break
                }
            }
            if ok
                keep.Push(e)
        } else {
            keep.Push(e)
        }
    }
    g_events := keep
}

; ── Playback ────────────────────────────────────────────────────────────
Play(*) {
    global g_playing, g_stopPlay
    if g_recording {
        Notify("Encore: still recording — " g_recordKey " stops it first")
        return
    }
    if g_playing {
        g_stopPlay := true   ; the play hotkey doubles as abort
        return
    }
    if !g_events.Length {
        Notify("Encore: nothing recorded yet")
        return
    }
    g_playing := true
    g_stopPlay := false
    InitTray()
    ; wait until the play hotkey's own modifiers are physically released —
    ; a still-held Win/Ctrl would combine with the replayed keys
    for m in ["LWin", "RWin", "LShift", "RShift", "LCtrl", "RCtrl", "LAlt", "RAlt"]
        KeyWait m, "T2"
    reps := g_repeat
    Notify("▶ Playing " g_events.Length " events"
        (reps = 0 ? " (until aborted)" : reps > 1 ? " ×" reps : "") "…", 1500)
    SendLevel 1   ; replayed input is visible to other AHK scripts, like real typing
    list := (g_mode = "fixed") ? FixedModeList() : g_events
    downKeys := Map()      ; vk → sc for keys currently sent down
    downBtns := Map()      ; button name → true
    ; the try guarantees the cleanup below always runs — an error midway
    ; must never leave g_playing stuck (every later Play would silently
    ; be treated as an abort request)
    err := 0
    stopped := false
    try {
        rep := 0
        loop {
            rep += 1
            prevT := list.Length ? list[1].t : 0
            for e in list {
                if (stopped := (g_stopPlay || GetKeyState("Escape", "P")))
                    break
                if (g_mode = "fixed") {
                    Sleep g_fixedDelayMs
                } else {
                    wait := Round((e.t - prevT) / g_speed)
                    if (wait > 0)
                        Sleep Min(wait, g_maxWaitMs)
                    prevT := e.t
                }
                if (e.kind = "k") {
                    key := Format("vk{:X}sc{:03X}", e.vk, e.sc)
                    Send "{" key (e.up ? " up" : " down") "}"
                    if e.up
                        downKeys.Delete(e.vk)
                    else
                        downKeys[e.vk] := e.sc
                } else if (e.kind = "w") {
                    ReplayWindowSwitch(e)
                } else {
                    ReplayMouse(e, downBtns)
                }
            }
            if (stopped || (reps != 0 && rep >= reps))
                break
            ; pause between repetitions, abortable in short slices
            waited := 0
            while (waited < g_repeatPauseMs) {
                Sleep 50
                waited += 50
                if (stopped := (g_stopPlay || GetKeyState("Escape", "P")))
                    break
            }
            if stopped
                break
        }
    } catch as err {
    }
    ; safety: release anything still held if playback stopped midway
    aborted := stopped || g_stopPlay
    for vk, sc in downKeys
        try Send "{" Format("vk{:X}sc{:03X}", vk, sc) " up}"
    for btn in downBtns
        try Click btn " Up"
    g_playing := false
    InitTray()
    if err {
        LogError(err, "")
        Notify("Encore: playback error — see error.log")
    } else {
        Notify(aborted ? "■ Playback aborted" : "■ Playback finished", 1500)
    }
}

ReplayMouse(e, downBtns) {
    static DOWN := Map(0x201, "Left", 0x204, "Right", 0x207, "Middle")
    static UP   := Map(0x202, "Left", 0x205, "Right", 0x208, "Middle")
    if (e.msg = 0x200) {                       ; move
        MouseMove(e.x, e.y, 0)
    } else if DOWN.Has(e.msg) {
        MouseMove(e.x, e.y, 0)
        Click DOWN[e.msg] " Down"
        downBtns[DOWN[e.msg]] := true
    } else if UP.Has(e.msg) {
        MouseMove(e.x, e.y, 0)
        Click UP[e.msg] " Up"
        downBtns.Delete(UP[e.msg])
    } else if (e.msg = 0x20B || e.msg = 0x20C) {   ; X buttons
        btn := ((e.data >> 16) & 0xFFFF) = 2 ? "X2" : "X1"
        MouseMove(e.x, e.y, 0)
        Click btn (e.msg = 0x20B ? " Down" : " Up")
        if (e.msg = 0x20B)
            downBtns[btn] := true
        else
            downBtns.Delete(btn)
    } else if (e.msg = 0x20A || e.msg = 0x20E) {   ; wheel / horizontal wheel
        delta := (e.data >> 16) & 0xFFFF
        if (delta > 0x7FFF)
            delta -= 0x10000
        notches := Abs(delta) // 120
        if (notches < 1)
            notches := 1
        MouseMove(e.x, e.y, 0)
        if (e.msg = 0x20A)
            Click (delta > 0 ? "WheelUp " : "WheelDown ") notches
        else
            Click (delta > 0 ? "WheelRight " : "WheelLeft ") notches
    }
}

; "Switch to program X": activate the anchored window — matched by title
; substring + process name, falling back to the process alone, then to the
; title alone — and wait until it is actually active. Already active or not
; found: no-op, the rest of the macro plays on.
ReplayWindowSwitch(e) {
    hwnd := 0
    try {
        if (e.title != "" && e.exe != "" && WinExist(e.title " ahk_exe " e.exe))
            hwnd := WinExist()
        else if (e.exe != "" && WinExist("ahk_exe " e.exe))
            hwnd := WinExist()
        else if (e.title != "" && WinExist(e.title))
            hwnd := WinExist()
    }
    if (!hwnd || WinActive(hwnd))
        return
    try {
        WinActivate(hwnd)
        WinWaitActive(hwnd, , 2)
    }
}

; Fixed-pause mode plays discrete actions, not the mouse path: pure moves
; are dropped except the last one before each click/key, which keeps every
; action landing at its recorded position.
FixedModeList() {
    list := []
    pendingMove := 0
    for e in g_events {
        if (e.kind = "m" && e.msg = 0x200) {
            pendingMove := e
        } else {
            if pendingMove {
                list.Push(pendingMove)
                pendingMove := 0
            }
            list.Push(e)
        }
    }
    return list
}

; ── Macro persistence (tab-separated, one event per line) ───────────────
; Each recording becomes its own timestamped file in macros\ and is
; selected as the current one; the tray menu lists them all.
SaveMacro() {
    global g_currentFile
    out := ""
    for e in g_events {
        if (e.kind = "k")
            out .= "k`t" e.t "`t" e.vk "`t" e.sc "`t" (e.up ? 1 : 0) "`n"
        else if (e.kind = "w")
            out .= "w`t" e.t "`t" e.exe "`t" e.title "`n"
        else
            out .= "m`t" e.t "`t" e.msg "`t" e.x "`t" e.y "`t" e.data "`n"
    }
    try DirCreate(g_macroDir)
    path := g_macroDir "\" FormatTime(, "yyyy-MM-dd HH.mm.ss") ".macro"
    try FileDelete(path)
    try FileAppend(out, path, "UTF-8")
    g_currentFile := path
}

; Newest first. (Array has no built-in sort in v2.0 — insertion sort.)
ListMacros() {
    arr := []
    loop files g_macroDir "\*.macro"
        arr.Push({p: A_LoopFileFullPath, name: SubStr(A_LoopFileName, 1, -6)
            , t: A_LoopFileTimeModified})
    i := 2
    while (i <= arr.Length) {
        j := i
        while (j > 1 && arr[j].t > arr[j - 1].t) {
            tmp := arr[j], arr[j] := arr[j - 1], arr[j - 1] := tmp
            j -= 1
        }
        i += 1
    }
    return arr
}

SelectMacro(path, *) {
    global g_events, g_currentFile
    if (g_recording || g_playing)
        return
    g_events := []
    LoadMacroFile(path)
    g_currentFile := path
    InitTray()
}

LoadMacroFile(path) {
    global g_events
    if !FileExist(path)
        return
    try {
        loop parse FileRead(path, "UTF-8"), "`n", "`r" {
            f := StrSplit(A_LoopField, "`t")
            if (f.Length >= 5 && f[1] = "k")
                g_events.Push({t: Integer(f[2]), kind: "k", vk: Integer(f[3])
                    , sc: Integer(f[4]), up: f[5] = "1"})
            else if (f.Length >= 6 && f[1] = "m")
                g_events.Push({t: Integer(f[2]), kind: "m", msg: Integer(f[3])
                    , x: Integer(f[4]), y: Integer(f[5]), data: Integer(f[6])})
            else if (f.Length >= 4 && f[1] = "w")
                g_events.Push({t: Integer(f[2]), kind: "w", exe: f[3], title: f[4]})
        }
    }
}

; ── Config ──────────────────────────────────────────────────────────────
LoadConfig(reread := false) {
    global g_recordKey, g_playKey, g_mode, g_speed, g_fixedDelayMs
    global g_maxWaitMs, g_pollMs, g_maxEvents, g_windowAnchors
    if !FileExist(g_configFile)
        WriteDefaultConfig()
    g_mode := IniRead(g_configFile, "Settings", "Mode", "original") = "fixed" ? "fixed" : "original"
    try g_speed := Number(IniRead(g_configFile, "Settings", "Speed", "1.0"))
    catch
        g_speed := 1.0
    if (g_speed <= 0)
        g_speed := 1.0
    try g_fixedDelayMs := Integer(IniRead(g_configFile, "Settings", "FixedDelayMs", "50"))
    catch
        g_fixedDelayMs := 50
    try g_maxWaitMs := Integer(IniRead(g_configFile, "Settings", "MaxWaitMs", "5000"))
    catch
        g_maxWaitMs := 5000
    try g_pollMs := Integer(IniRead(g_configFile, "Settings", "MousePollMs", "15"))
    catch
        g_pollMs := 15
    if (g_pollMs < 5)
        g_pollMs := 5
    try g_maxEvents := Integer(IniRead(g_configFile, "Settings", "MaxEvents", "100000"))
    catch
        g_maxEvents := 100000
    g_windowAnchors := IniRead(g_configFile, "Settings", "WindowAnchors", "1") != "0"
    try g_repeat := Integer(IniRead(g_configFile, "Settings", "Repeat", "1"))
    catch
        g_repeat := 1
    if (g_repeat < 0)
        g_repeat := 1
    try g_repeatPauseMs := Integer(IniRead(g_configFile, "Settings", "RepeatPauseMs", "1000"))
    catch
        g_repeatPauseMs := 1000
    ApplyHotkey(&g_recordKey, Trim(IniRead(g_configFile, "Settings", "RecordHotkey", "+F12")), ToggleRecord)
    ApplyHotkey(&g_playKey,   Trim(IniRead(g_configFile, "Settings", "PlayHotkey",   "F12")), Play)
    if reread
        InitTray()
}

ApplyHotkey(&stored, newKey, fn) {
    if (stored != "" && stored != newKey)
        try Hotkey(stored, "Off")
    if (newKey != "") {
        try {
            Hotkey(newKey, fn, "On")
            stored := newKey
        } catch {
            Notify("Encore: invalid hotkey in the config: " newKey)
            stored := ""
        }
    } else {
        stored := ""
    }
}

WriteDefaultConfig() {
    defaults := "
(LTrim
; Encore - configuration
; Changes are loaded via the tray menu: Reload configuration.
;
; RecordHotkey: starts/stops recording. AHK syntax: + = Shift, ^ = Ctrl,
;   # = Win, ! = Alt. Empty disables the hotkey.
; PlayHotkey: plays the last recording. Pressing it during playback - or
;   Esc - aborts.
; Mode: original (recorded timing) or fixed (fixed pause between events).
; Speed: playback speed factor in original mode - 2 = twice as fast.
; FixedDelayMs: the pause between events in fixed mode.
; MaxWaitMs: longest single pause replayed in original mode.
; MousePollMs: mouse sampling interval while recording (position/buttons).
; MaxEvents: safety cap on the number of recorded events.
; Repeat: how many times a playback runs (0 = until aborted).
; RepeatPauseMs: pause between the repetitions.
; WindowAnchors=1: record "switch to program X" anchors at the start and at
;   every active-window change - playback re-activates that program (matched
;   by process name, with title-substring fallback) and waits until it is
;   active. The anchors are the "w" lines in last.macro and can be edited
;   or added by hand: w <tab> 0 <tab> program.exe <tab> title part
[Settings]
RecordHotkey=+F12
PlayHotkey=F12
Mode=original
Speed=1.0
FixedDelayMs=50
MaxWaitMs=5000
MousePollMs=15
MaxEvents=100000
WindowAnchors=1
Repeat=1
RepeatPauseMs=1000
)"
    try FileAppend(defaults "`n", g_configFile, "UTF-16")
}

; ── Tray ────────────────────────────────────────────────────────────────
InitTray() {
    ; three states: red dot = recording, green triangle = playing,
    ; blue square = idle (stopped)
    icon := A_ScriptDir "\" (g_recording ? "rec.ico" : g_playing ? "play.ico" : "app.ico")
    if FileExist(icon)
        try TraySetIcon(icon, , 1)
    recLabel  := (g_recording ? "Stop recording" : "Record") (g_recordKey != "" ? "`t" g_recordKey : "")
    playLabel := (g_playing ? "Abort playback" : "Play") (g_playKey != "" ? "`t" g_playKey : "")
    recsMenu := Menu()
    shown := 0
    for m in ListMacros() {
        if (shown >= 25)
            break
        shown += 1
        recsMenu.Add(m.name, SelectMacro.Bind(m.p))
        if (m.p = g_currentFile)
            recsMenu.Check(m.name)
    }
    if !shown {
        recsMenu.Add("(no recordings)", (*) => 0)
        recsMenu.Disable("(no recordings)")
    }
    recsMenu.Add()
    recsMenu.Add("Open recordings folder", OpenMacroDir)
    repMenu := Menu()
    for n in [1, 2, 3, 5, 10, 25] {
        lbl := n "×"
        repMenu.Add(lbl, SetRepeat.Bind(n))
        if (n = g_repeat)
            repMenu.Check(lbl)
    }
    repMenu.Add("Until aborted", SetRepeat.Bind(0))
    if (g_repeat = 0)
        repMenu.Check("Until aborted")
    A_TrayMenu.Delete()
    A_TrayMenu.Add(recLabel, ToggleRecord)
    A_TrayMenu.Add(playLabel, Play)
    A_TrayMenu.Add()
    A_TrayMenu.Add("Recordings", recsMenu)
    A_TrayMenu.Add("Repeat", repMenu)
    A_TrayMenu.Add("Playback: original speed", SetMode.Bind("original"))
    A_TrayMenu.Add("Playback: fixed delay", SetMode.Bind("fixed"))
    A_TrayMenu.Add()
    A_TrayMenu.Add("Open configuration", (*) => Run(g_configFile))
    A_TrayMenu.Add("Reload configuration", (*) => LoadConfig(true))
    A_TrayMenu.Add("Start with Windows", ToggleAutostart)
    A_TrayMenu.Add()
    A_TrayMenu.Add("Exit", (*) => ExitApp())
    A_TrayMenu.Check("Playback: " (g_mode = "fixed" ? "fixed delay" : "original speed"))
    if FileExist(StartupShortcut())
        A_TrayMenu.Check("Start with Windows")
    A_TrayMenu.Default := recLabel
    cur := g_currentFile != "" ? SubStr(g_currentFile, InStr(g_currentFile, "\", , -1) + 1) : ""
    A_IconTip := "Encore — " (g_recording ? "recording…"
        : g_playing ? "playing…"
        : cur != "" ? cur " (" g_events.Length " events)" : "no recordings")
}

OpenMacroDir(*) {
    try DirCreate(g_macroDir)
    try Run(g_macroDir)
}

SetRepeat(n, *) {
    global g_repeat := n
    try IniWrite(n, g_configFile, "Settings", "Repeat")
    InitTray()
}

SetMode(mode, *) {
    global g_mode := mode
    try IniWrite(mode, g_configFile, "Settings", "Mode")
    InitTray()
}

StartupShortcut() => A_Startup "\Encore.lnk"

ToggleAutostart(*) {
    lnk := StartupShortcut()
    if FileExist(lnk) {
        try FileDelete(lnk)
    } else {
        try FileCreateShortcut(A_AhkPath, lnk, A_ScriptDir, '"' A_ScriptFullPath '"')
    }
    InitTray()
}

; Notices go to the top center of the screen, away from the mouse — a
; tooltip at the pointer swallows the click the user aims right after it.
Notify(msg, ms := 3000) {
    ToolTip(msg, A_ScreenWidth // 2 - 120, 8)
    SetTimer(() => ToolTip(), -ms)
}

Cleanup(*) {
    global g_ih
    if g_ih {
        try g_ih.Stop()
        g_ih := 0
    }
}

; Silent tray app: log errors to a file instead of a dialog box.
LogError(err, mode) {
    try FileAppend(FormatTime() "  " (IsObject(err) ? err.Message " (" err.File ":" err.Line ")" : String(err)) "`n"
        , A_ScriptDir "\error.log", "UTF-8")
    return 1
}
