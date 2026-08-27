; Encore — v1.6.0 (2026-08-26)
;
; Records keyboard and mouse activity (keys, clicks, movements, wheel) and
; plays it back — at the original speed (adjustable factor) or with a fixed
; pause between events.
;   - RecordHotkey (default Shift+F12) starts recording; the same key
;     stops it.
;   - PlayHotkey (default F12) plays the selected recording; pressing
;     it again — or Esc — aborts playback, and during recording it stops
;     the recording. Repeat count and the pause between repetitions are
;     configurable (tray menu / config).
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
#SingleInstance Off   ; instance handling is manual — see the CLI section below
CoordMode "Mouse", "Screen"
CoordMode "ToolTip", "Screen"

#Include "lib\WebView2.ahk"
#Include "lib\JSON.ahk"

global g_configFile  := A_ScriptDir "\Encore config.ini"
global g_macroDir    := A_ScriptDir "\macros"
global g_currentFile := ""     ; path of the selected recording
global g_events      := []     ; recorded events: {t, kind "k"/"m"/"w"/"g", ...}
global g_curProps    := Map()  ; per-recording playback overrides (repeat/pause/speed/mode)
global g_uiWin       := 0      ; management window (WebView2), created lazily
global g_uiCtrl      := 0
global g_uiCore      := 0
global g_uiReady     := false
global g_recording  := false
global g_playing    := false
global g_stopPlay   := false
global g_ih         := 0       ; InputHook while recording
global g_lastX      := ""      ; last recorded cursor position
global g_lastY      := ""
global g_btnState   := Map()   ; button name -> was-down at the last poll
global g_lastActive := 0       ; hwnd of the last recorded foreground window
global g_geoHwnd    := 0       ; geometry anchors: tracked foreground window
global g_geoSig     := ""      ; its last sampled "x|y|w|h|state"
global g_geoDirty   := false   ; geometry changed but not yet recorded
global g_geoStable  := 0       ; consecutive unchanged samples after a change

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
global g_countdownMs   := 1000 ; pause before playback starts (0 = none)
global g_playOsd       := true ; progress overlay during playback
global g_macroHotkeys  := Map()  ; registered per-macro hotkey -> file path
global g_fgX           := 0    ; recording: position of the foreground window
global g_fgY           := 0
global g_playRef       := 0    ; playback: hwnd of the last activated anchor window
global g_playRefX      := 0
global g_playRefY      := 0
global g_playRefT      := 0
global g_playCoords    := ""   ; "" = screen coordinates, "window" = relative
global g_playRow       := ""   ; current data row during data-driven playback

; Command line:
;   Encore.ahk <macro>                    play that macro and exit
;   Encore.ahk --export <macro> <dest>    export it as a standalone .ahk
; <macro> is a path, or a name (with or without .macro) in macros\.
; A CLI run coexists with the tray instance; a plain (tray) start replaces
; any previous tray instance, like #SingleInstance Force used to.
; Per-monitor-DPI v2: utan detta låses skalan vid processtart, och när en
; skärm med annan skala kopplas in/ur bitmap-sträcks fönstret - fel skärpa
; och WebView2-klick som hamnar bredvid pekaren. Måste sättas före första
; fönstret. WM_DPICHANGED tar systemets föreslagna rect; Size-eventet
; (Fill) storleksändrar sedan WebView2-ytan.
; OBS: process-nivån är LÅST av AutoHotkeys manifest (SYSTEM_AWARE) -
; SetProcessDpiAwarenessContext ger ACCESS_DENIED. Trådnivån går dock att
; ändra, och fönster ärver trådens kontext när de skapas. AHK kör allt på
; en enda OS-tråd, så ett anrop här täcker alla fönster skriptet skapar.
DllCall("SetThreadDpiAwarenessContext", "ptr", -4)
OnMessage(0x02E0, _WmDpiChanged)

global g_cliMode := A_Args.Length > 0

OnError(LogError)
OnExit(Cleanup)
if !g_cliMode {
    DetectHiddenWindows true
    for hwnd in WinGetList(A_ScriptFullPath " ahk_class AutoHotkey")
        if (hwnd != A_ScriptHwnd)
            PostMessage(0x111, 65307, 0, , hwnd)   ; ask the old instance to exit
    DetectHiddenWindows false
}
LoadConfig()
if g_cliMode
    CliMain()   ; plays or exports, then exits
macros := ListMacros()
if macros.Length {
    g_currentFile := macros[1].p
    LoadMacroFile(g_currentFile)
}
InitTray()

; External control: PostMessage the registered window message
; "ENCORE_CMD" to the script's hidden window — wParam 1 = toggle
; recording, 2 = play, 3 = abort playback, 4 = reload the configuration,
; 5 = open the management window.
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
        case 5: SetTimer(OpenUi, -1)
    }
}

; ── Command-line mode ───────────────────────────────────────────────────
CliMain() {
    global g_events, g_currentFile
    A_IconHidden := true
    if (A_Args[1] = "--export") {
        if (A_Args.Length < 3)
            ExitApp 1
        file := CliResolve(A_Args[2])
        if (file = "")
            ExitApp 1
        LoadMacroFile(file)
        g_currentFile := file
        dest := A_Args[3]
        if !RegExMatch(dest, "i)\.ahk$")
            dest .= ".ahk"
        ExitApp(ExportTo(dest) ? 0 : 1)
    }
    file := CliResolve(A_Args[1])
    if (file = "") {
        Notify("Encore: macro not found: " A_Args[1], 2500)
        Sleep 2500
        ExitApp 1
    }
    LoadMacroFile(file)
    g_currentFile := file
    if !g_events.Length
        ExitApp 1
    Play()
    ExitApp 0
}

; A path as given, or a name (with or without .macro) in macros\.
CliResolve(arg) {
    if FileExist(arg)
        return arg
    if FileExist(g_macroDir "\" arg)
        return g_macroDir "\" arg
    if FileExist(g_macroDir "\" arg ".macro")
        return g_macroDir "\" arg ".macro"
    return ""
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

_RecEscStop(*) {
    global g_recording
    if g_recording
        StopRecording()
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
    ; Esc stops the recording too (pass-through, so the app still gets the
    ; keypress). The Esc-down lands in the recording but its up never does -
    ; recording stops first - so CleanUnmatched drops it from the result.
    Hotkey("~*Escape", _RecEscStop, "On")
    g_recording := true
    global g_fgX, g_fgY
    try WinGetPos(&g_fgX, &g_fgY, , , WinGetID("A"))
    if g_windowAnchors {
        ; anchor to the window that is active as the macro begins, then to
        ; every switch — playback re-activates that program at each anchor
        g_lastActive := 0
        g_geoHwnd := 0, g_geoSig := "", g_geoDirty := false, g_geoStable := 0
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
    for hk in ["~*WheelUp", "~*WheelDown", "~*WheelLeft", "~*WheelRight", "~*Escape"]
        try Hotkey(hk, "Off")
    if g_ih {
        try g_ih.Stop()
        g_ih := 0
    }
    g_recording := false
    FlushGeo()
    CleanUnmatched()
    if g_windowAnchors {
        StripAltTabs()
        StripTaskbarSwitchClicks()
    }
    FuseDoubleClicks()
    if g_events.Length {
        SaveMacro()
        Notify("■ Recorded " g_events.Length " events", 2000)
    } else {
        Notify("■ Nothing recorded", 2000)
    }
    InitTray()
    PushMacro()
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
        g_events.Push({t: A_TickCount, kind: "m", msg: 0x200, x: mx, y: my, data: 0
            , wx: mx - g_fgX, wy: my - g_fgY})
    }
    for b, def in BTN {
        now := false
        try now := GetKeyState(b)
        if (now != g_btnState[b]) {
            g_btnState[b] := now
            ; class of the window under the cursor: lets post-processing
            ; recognize taskbar clicks used for window switching
            cls := ""
            if now {
                try {
                    MouseGetPos(, , &under)
                    cls := WinGetClass(under)
                }
            }
            g_events.Push({t: A_TickCount, kind: "m", msg: def[now ? 1 : 2]
                , x: mx, y: my, data: def[3], cls: cls
                , wx: mx - g_fgX, wy: my - g_fgY})
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
        , data: (delta & 0xFFFF) << 16, wx: mx - g_fgX, wy: my - g_fgY})
}

; Records a "switch to program X" anchor whenever the foreground window
; changes during recording. Tabs are stripped from titles (TSV storage).
RecordActiveWindow() {
    global g_events, g_lastActive
    ; shell surfaces that become foreground transiently (the Alt-Tab
    ; switcher, Task View, the taskbar, Start/search) must never become
    ; anchors — re-activating them during playback would be nonsense
    static SKIP := Map("MultitaskingViewFrame", 1, "XamlExplorerHostIslandWindow", 1
        , "TaskSwitcherWnd", 1, "TaskSwitcherOverlayWnd", 1, "ForegroundStaging", 1
        , "Shell_TrayWnd", 1, "Shell_SecondaryTrayWnd", 1, "Windows.UI.Core.CoreWindow", 1)
    global g_geoHwnd, g_geoSig, g_geoDirty, g_geoStable
    if !g_recording
        return
    hwnd := 0
    try hwnd := WinGetID("A")
    if !hwnd
        return
    cls := ""
    try cls := WinGetClass(hwnd)
    if SKIP.Has(cls)
        return
    ; track the foreground window's position — mouse events store their
    ; offset from it, enabling window-relative playback (coords=window)
    global g_fgX, g_fgY
    try WinGetPos(&g_fgX, &g_fgY, , , hwnd)
    if (hwnd != g_lastActive) {
        FlushGeo()   ; pending geometry change of the previous window
        g_lastActive := hwnd
        exe := "", title := "", path := ""
        try exe := WinGetProcessName(hwnd)
        try title := StrReplace(WinGetTitle(hwnd), "`t", " ")
        try path := WinGetProcessPath(hwnd)
        if (exe != "" || title != "")
            g_events.Push({t: A_TickCount, kind: "w", exe: exe, title: title, path: path})
        g_geoHwnd := hwnd
        g_geoSig := GeoSig(hwnd)
        g_geoDirty := false
        g_geoStable := 0
        return
    }
    ; same window still in front: watch its geometry — a moved/resized/
    ; maximized/minimized window becomes a corrective "g" anchor once the
    ; change has settled (two stable samples)
    sig := GeoSig(hwnd)
    if (sig != g_geoSig) {
        g_geoSig := sig
        g_geoDirty := true
        g_geoStable := 0
    } else if g_geoDirty {
        g_geoStable += 1
        if (g_geoStable >= 2)
            FlushGeo()
    }
}

GeoSig(hwnd) {
    x := 0, y := 0, w := 0, h := 0, s := 0
    try WinGetPos(&x, &y, &w, &h, hwnd)
    try s := WinGetMinMax(hwnd)
    return x "|" y "|" w "|" h "|" s
}

FlushGeo() {
    global g_events, g_geoHwnd, g_geoSig, g_geoDirty
    if (g_geoDirty && g_geoHwnd) {
        parts := StrSplit(g_geoSig, "|")
        exe := "", title := ""
        try exe := WinGetProcessName(g_geoHwnd)
        try title := StrReplace(WinGetTitle(g_geoHwnd), "`t", " ")
        if ((exe != "" || title != "") && parts.Length = 5)
            g_events.Push({t: A_TickCount, kind: "g", exe: exe, title: title
                , x: Integer(parts[1]), y: Integer(parts[2]), w: Integer(parts[3])
                , h: Integer(parts[4]), state: Integer(parts[5])})
    }
    g_geoDirty := false
}

; Alt+Tab app switching is replaced by the window anchor: replaying the
; keystrokes would open the switcher and hope the window order matches —
; the anchor jumps straight to the right window instead. A sequence is
; stripped only when it is unmistakably switcher-use: Alt down … Alt up
; containing at least one Tab and nothing but Tab/Shift/arrows/Esc and
; plain mouse moves. Anything else while Alt is held (Alt+F4, clicks in
; the switcher, …) leaves the sequence untouched. Anchors recorded inside
; the range are preserved.
StripAltTabs() {
    global g_events
    IsAlt := (vk) => (vk = 0x12 || vk = 0xA4 || vk = 0xA5)
    IsSwitcherKey := (vk) => (vk = 0x09 || vk = 0x10 || vk = 0xA0 || vk = 0xA1
        || (vk >= 0x25 && vk <= 0x28) || vk = 0x1B || IsAlt(vk))
    out := []
    i := 1
    n := g_events.Length
    while (i <= n) {
        e := g_events[i]
        if (e.kind = "k" && !e.up && IsAlt(e.vk)) {
            j := i + 1
            sawTab := false
            pure := true
            while (j <= n) {
                x := g_events[j]
                if (x.kind = "k") {
                    if (x.vk = e.vk && x.up)
                        break
                    if (x.vk = 0x09)
                        sawTab := true
                    else if !IsSwitcherKey(x.vk)
                        pure := false
                } else if (x.kind = "m" && x.msg != 0x200) {
                    pure := false
                }
                j += 1
            }
            if (j <= n && sawTab && pure) {
                k := i
                while (k <= j) {
                    if (g_events[k].kind = "w")
                        out.Push(g_events[k])
                    k += 1
                }
                i := j + 1
                continue
            }
        }
        out.Push(e)
        i += 1
    }
    g_events := out
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

; A taskbar click that switched window is dropped: the click position is
; fragile (button order changes as windows come and go) and the window
; anchor recorded right after it makes the switch directly. The click's
; own window class was captured at record time; only clicks followed by an
; anchor within 2 s are treated as switches — tray-icon clicks and other
; taskbar interactions are left untouched.
StripTaskbarSwitchClicks() {
    global g_events
    static TASKBAR := Map("Shell_TrayWnd", 1, "Shell_SecondaryTrayWnd", 1
        , "MSTaskListWClass", 1, "MSTaskSwWClass", 1)
    static UPOF := Map(0x201, 0x202, 0x204, 0x205, 0x207, 0x208)
    out := []
    i := 1
    n := g_events.Length
    while (i <= n) {
        e := g_events[i]
        if (e.kind = "m" && UPOF.Has(e.msg) && e.HasOwnProp("cls") && TASKBAR.Has(e.cls)) {
            j := i + 1
            while (j <= n) {
                x := g_events[j]
                if (x.kind = "m" && x.msg = UPOF[e.msg])
                    break
                j += 1
            }
            hasAnchor := false
            k := j + 1
            while (k <= n && g_events[k].t - e.t <= 2000) {
                if (g_events[k].kind = "w") {
                    hasAnchor := true
                    break
                }
                k += 1
            }
            if (j <= n && hasAnchor) {
                k := i + 1
                while (k <= j - 1) {
                    out.Push(g_events[k])
                    k += 1
                }
                i := j + 1
                continue
            }
        }
        out.Push(e)
        i += 1
    }
    g_events := out
}

; Two clicks of the same button within the system double-click time and
; radius are fused into one atomic double-click event — replayed as a real
; double-click regardless of playback mode (a large fixed delay would
; otherwise split it into two single clicks).
FuseDoubleClicks() {
    global g_events
    static DOWN2DBL := Map(0x201, 0x203, 0x204, 0x206, 0x207, 0x209)
    static UPOF := Map(0x201, 0x202, 0x204, 0x205, 0x207, 0x208)
    dblTime := DllCall("GetDoubleClickTime", "uint")
    dx := DllCall("GetSystemMetrics", "int", 36)   ; SM_CXDOUBLECLK
    dy := DllCall("GetSystemMetrics", "int", 37)   ; SM_CYDOUBLECLK
    out := []
    i := 1
    n := g_events.Length
    while (i <= n) {
        e := g_events[i]
        endIdx := (e.kind = "m" && DOWN2DBL.Has(e.msg))
            ? FindDbl(i, e, dblTime, dx, dy, UPOF) : 0
        if endIdx {
            out.Push({t: e.t, kind: "m", msg: DOWN2DBL[e.msg], x: e.x, y: e.y, data: 0})
            i := endIdx + 1
            continue
        }
        out.Push(e)
        i += 1
    }
    g_events := out
}

; From the down at index i: expect up, down (in time + radius), up of the
; same button, allowing only plain mouse moves in between. Returns the
; index of the second up, or 0.
FindDbl(i, d1, dblTime, dx, dy, UPOF) {
    global g_events
    n := g_events.Length
    upMsg := UPOF[d1.msg]
    stage := 1
    j := i + 1
    while (j <= n) {
        x := g_events[j]
        if (x.kind = "m" && x.msg = 0x200) {
            j += 1
            continue
        }
        if (x.kind != "m")
            return 0
        if (stage = 1) {
            if (x.msg != upMsg)
                return 0
            stage := 2
        } else if (stage = 2) {
            if (x.msg != d1.msg || x.t - d1.t > dblTime
                || Abs(x.x - d1.x) > dx || Abs(x.y - d1.y) > dy)
                return 0
            stage := 3
        } else {
            return (x.msg = upMsg) ? j : 0
        }
        j += 1
    }
    return 0
}

; ── Data-driven playback ────────────────────────────────────────────────
; A {value} step + a data list = one repetition per row: the step types
; the current row (tab-separated columns; col picks one). The list lives
; in "<macro name>.data" beside the macro file.
DataFileFor(macroPath) {
    return (macroPath != "" && SubStr(macroPath, -6) = ".macro")
        ? SubStr(macroPath, 1, -6) ".data" : ""
}

MacroHasValueStep() {
    global g_events
    for e in g_events
        if (e.kind = "v")
            return true
    return false
}

; Which value a {value} step types for this row. ok=false means the row simply does
; not have that column, and the caller must STOP rather than type something else:
; the old code fell back to the whole raw row, so a two-column list with one broken
; row typed the ID into the field meant for the result — silently, into whatever
; record was open. col is clamped because a hand-edited macro file can hold 0, and a
; wholly blank row reports no column at all (StrSplit("") is an empty array) — which
; is right, and moot anyway since LoadDataRows drops blank lines.
DataColumn(row, col) {
    col := (col >= 1) ? col : 1
    parts := StrSplit(row, "`t")
    if (col > parts.Length)
        return {ok: false, value: "", col: col}
    return {ok: true, value: parts[col], col: col}
}

LoadDataRows() {
    global g_currentFile
    rows := []
    df := DataFileFor(g_currentFile)
    if (df = "" || !FileExist(df))
        return rows
    try {
        loop parse FileRead(df, "UTF-8"), "`n", "`r"
            if (Trim(A_LoopField) != "")
                rows.Push(A_LoopField)
    }
    return rows
}

; ── Playback ────────────────────────────────────────────────────────────
EffInt(key, glob) {
    global g_curProps
    if (g_curProps.Get(key, "") != "") {
        try return Integer(g_curProps[key])
    }
    return glob
}

EffNum(key, glob) {
    global g_curProps
    if (g_curProps.Get(key, "") != "") {
        try return Number(g_curProps[key])
    }
    return glob
}

Play(*) {
    global g_playing, g_stopPlay, g_playRef, g_playRefT, g_playCoords, g_playRow
    if g_recording {
        StopRecording()   ; the play key doubles as stop while recording
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
    ; Annonsera uppspelningen för andra skript: Keyboard assistants vakthund
    ; släpper annars "fastnade" modifierare - och en uppspelad Ctrl+C håller
    ; Ctrl syntetiskt nere i mänsklig takt, längre än dess 300 ms-gräns, så
    ; Ctrl rycktes bort och bara "c" kom fram. Mutexen försvinner automatiskt
    ; med processen om uppspelningen kraschar.
    global g_playMutex := DllCall("CreateMutexW", "ptr", 0, "int", 0, "str", "Local\EncorePlayback", "ptr")
    InitTray()
    ; wait until the play hotkey's own modifiers are physically released —
    ; a still-held Win/Ctrl would combine with the replayed keys
    for m in ["LWin", "RWin", "LShift", "RShift", "LCtrl", "RCtrl", "LAlt", "RAlt"]
        KeyWait m, "T2"
    ; optional countdown so the user can settle focus before replay starts
    if (g_countdownMs > 0) {
        waitedC := 0
        while (waitedC < g_countdownMs) {
            ToolTip("▶ Starting in " Round((g_countdownMs - waitedC) / 1000.0, 1) " s — Esc aborts"
                , A_ScreenWidth // 2 - 110, 40, 2)
            Sleep 100
            waitedC += 100
            if (g_stopPlay || GetKeyState("Escape", "P"))
                break
        }
        ToolTip(, , , 2)
        if (g_stopPlay || GetKeyState("Escape", "P")) {
            g_playing := false
            InitTray()
            Notify("■ Playback aborted", 1500)
            return
        }
    }
    ; effective playback values: per-recording overrides beat the globals
    reps := EffInt("repeat", g_repeat)
    repPause := EffInt("pause", g_repeatPauseMs)
    fixedDelay := g_fixedDelayMs
    speed := EffNum("speed", g_speed)
    mode := (g_curProps.Get("mode", "") != "") ? g_curProps["mode"] : g_mode
    if (speed <= 0)
        speed := 1.0
    if (reps < 0)
        reps := 1
    ; data-driven: with a {value} step, one repetition per data row
    dataRows := []
    if MacroHasValueStep() {
        dataRows := LoadDataRows()
        if !dataRows.Length {
            Notify("Encore: the macro has a {value} step but the data list is empty")
            g_playing := false
            InitTray()
            return
        }
        reps := dataRows.Length
    }
    suffix := dataRows.Length ? " × " dataRows.Length " data rows"
        : reps = 0 ? " (until aborted)" : reps > 1 ? " ×" reps : ""
    Notify("▶ Playing " g_events.Length " events" suffix "…", 1500)
    SendLevel 1   ; replayed input is visible to other AHK scripts, like real typing
    list := (mode = "fixed") ? FixedModeList() : g_events
    downKeys := Map()      ; vk → sc for keys currently sent down
    downBtns := Map()      ; button name → true
    g_playRef := 0, g_playRefT := 0
    g_playCoords := g_curProps.Get("coords", "")
    osdName := g_currentFile != ""
        ? SubStr(SubStr(g_currentFile, InStr(g_currentFile, "\", , -1) + 1), 1, -6) : ""
    evIdx := 0
    ; the try guarantees the cleanup below always runs — an error midway
    ; must never leave g_playing stuck (every later Play would silently
    ; be treated as an abort request)
    err := 0
    stopped := false
    try {
        rep := 0
        loop {
            rep += 1
            if dataRows.Length
                g_playRow := dataRows[rep]
            prevT := list.Length ? list[1].t : 0
            loopStack := []   ; ⟳-block: {startIdx, kvar}
            li := 0
            while (li < list.Length) {
                li += 1
                e := list[li]
                if (stopped := (g_stopPlay || GetKeyState("Escape", "P")))
                    break
                evIdx += 1
                if (g_playOsd && Mod(evIdx, 20) = 1)
                    ToolTip("▶ " osdName " — " evIdx "/" (list.Length * (reps ? reps : 1))
                        (reps != 1 ? " · rep " rep (reps ? "/" reps : "") : "")
                        " — Esc aborts", A_ScreenWidth // 2 - 140, 40, 2)
                if (mode = "fixed") {
                    Sleep fixedDelay
                } else {
                    wait := Round((e.t - prevT) / speed)
                    if (wait > 0)
                        Sleep Min(wait, g_maxWaitMs)
                    prevT := e.t
                }
                if (e.kind = "k") {
                    key := Format("vk{:X}sc{:03X}", e.vk, e.sc)
                    Send "{" key (e.up ? " up" : " down") "}"
                    if e.up {
                        if downKeys.Has(e.vk)   ; Map.Delete throws on a missing key
                            downKeys.Delete(e.vk)
                    } else {
                        downKeys[e.vk] := e.sc
                    }
                } else if (e.kind = "w") {
                    ReplayWindowSwitch(e)
                } else if (e.kind = "g") {
                    ReplayGeometry(e)
                } else if (e.kind = "t") {
                    SendText e.text
                } else if (e.kind = "s") {
                    try Send e.keys   ; user-written AHK syntax — a bad step is skipped
                } else if (e.kind = "d") {
                    waited2 := 0
                    while (waited2 < e.ms) {   ; explicit pause, abortable in slices
                        Sleep Min(50, e.ms - waited2)
                        waited2 += 50
                        if (g_stopPlay || GetKeyState("Escape", "P"))
                            break
                    }
                } else if (e.kind = "ww") {
                    ReplayWaitWindow(e)
                } else if (e.kind = "v") {
                    dv := DataColumn(g_playRow, e.col)
                    if !dv.ok {
                        Notify("Encore: row " rep " has no column " dv.col " — stopped", 4000)
                        g_stopPlay := true
                        stopped := true
                        break
                    }
                    SendText(dv.value)
                } else if (e.kind = "ls") {
                    loopStack.Push({startIdx: li, kvar: 0})
                } else if (e.kind = "le") {
                    ; hör till närmaste ls; en ensam le ignoreras
                    if loopStack.Length {
                        top := loopStack[loopStack.Length]
                        if (top.kvar = 0)
                            top.kvar := e.count
                        if (top.kvar > 1) {
                            top.kvar -= 1
                            li := top.startIdx
                            ; pacing: nästa varv tidsätts relativt ls-eventet,
                            ; annars blir alla väntetider i blocket negativa
                            prevT := list[top.startIdx].t
                        } else
                            loopStack.Pop()
                    }
                } else {
                    ReplayMouse(e, downBtns)
                }
            }
            if (stopped || (reps != 0 && rep >= reps))
                break
            ; pause between repetitions, abortable in short slices
            waited := 0
            while (waited < repPause) {
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
    ToolTip(, , , 2)
    if g_playMutex {
        DllCall("CloseHandle", "ptr", g_playMutex)
        g_playMutex := 0
    }
    g_playing := false
    InitTray()
    if err {
        LogError(err, "")
        Notify("Encore: playback error — see error.log")
    } else {
        Notify(aborted ? "■ Playback aborted" : "■ Playback finished", 1500)
    }
}

; Playback position of a mouse event: screen coordinates by default, or —
; when the recording's coords=window — the recorded offset applied to the
; current position of the last anchored window (cached for 500 ms).
PlayXY(e, &x, &y) {
    global g_playRef, g_playRefX, g_playRefY, g_playRefT
    x := e.x, y := e.y
    if (g_playCoords != "window" || !e.HasOwnProp("wx") || !g_playRef)
        return
    if (A_TickCount - g_playRefT > 500) {
        rx := "", ry := ""
        try WinGetPos(&rx, &ry, , , g_playRef)
        if (rx = "")
            return
        g_playRefX := rx, g_playRefY := ry, g_playRefT := A_TickCount
    }
    x := g_playRefX + e.wx
    y := g_playRefY + e.wy
}

ReplayMouse(e, downBtns) {
    static DOWN := Map(0x201, "Left", 0x204, "Right", 0x207, "Middle")
    static UP   := Map(0x202, "Left", 0x205, "Right", 0x208, "Middle")
    static DBL  := Map(0x203, "Left", 0x206, "Right", 0x209, "Middle")
    PlayXY(e, &px, &py)
    if (e.msg = 0x200) {                       ; move
        MouseMove(px, py, 0)
    } else if DBL.Has(e.msg) {                 ; fused double-click
        MouseMove(px, py, 0)
        Click DBL[e.msg] " 2"
    } else if DOWN.Has(e.msg) {
        MouseMove(px, py, 0)
        Click DOWN[e.msg] " Down"
        downBtns[DOWN[e.msg]] := true
    } else if UP.Has(e.msg) {
        MouseMove(px, py, 0)
        Click UP[e.msg] " Up"
        if downBtns.Has(UP[e.msg])
            downBtns.Delete(UP[e.msg])
    } else if (e.msg = 0x20B || e.msg = 0x20C) {   ; X buttons
        btn := ((e.data >> 16) & 0xFFFF) = 2 ? "X2" : "X1"
        MouseMove(px, py, 0)
        Click btn (e.msg = 0x20B ? " Down" : " Up")
        if (e.msg = 0x20B)
            downBtns[btn] := true
        else if downBtns.Has(btn)
            downBtns.Delete(btn)
    } else if (e.msg = 0x20A || e.msg = 0x20E) {   ; wheel / horizontal wheel
        delta := (e.data >> 16) & 0xFFFF
        if (delta > 0x7FFF)
            delta -= 0x10000
        notches := Abs(delta) // 120
        if (notches < 1)
            notches := 1
        MouseMove(px, py, 0)
        if (e.msg = 0x20A)
            Click (delta > 0 ? "WheelUp " : "WheelDown ") notches
        else
            Click (delta > 0 ? "WheelRight " : "WheelLeft ") notches
    }
}

; Wait until a window matching title-part/exe exists (or is active), up to
; e.ms — then it becomes the reference window for window-relative coords.
ReplayWaitWindow(e) {
    global g_playRef, g_playRefT
    crit := LTrim(e.title (e.exe != "" ? " ahk_exe " e.exe : ""))
    if (crit = "")
        return
    deadline := A_TickCount + e.ms
    hwnd := 0
    loop {
        try hwnd := e.active ? WinActive(crit) : WinExist(crit)
        if (hwnd || A_TickCount >= deadline)
            break
        Sleep 100
        if (g_stopPlay || GetKeyState("Escape", "P"))
            return
    }
    if hwnd {
        g_playRef := hwnd
        g_playRefT := 0
    }
}

; Anchored-window matching: title substring + process name, falling back
; to the process alone, then to the title alone.
FindTargetWindow(e) {
    hwnd := 0
    try {
        if (e.title != "" && e.exe != "" && WinExist(e.title " ahk_exe " e.exe))
            hwnd := WinExist()
        else if (e.exe != "" && WinExist("ahk_exe " e.exe))
            hwnd := WinExist()
        else if (e.title != "" && WinExist(e.title))
            hwnd := WinExist()
    }
    return hwnd
}

; "Switch to program X": activate the anchored window and wait until it is
; actually active. If the program is not running at all, start it from the
; recorded process path and wait for its window. Already active or not
; startable: no-op, the rest of the macro plays on.
ReplayWindowSwitch(e) {
    global g_playRef, g_playRefT
    hwnd := FindTargetWindow(e)
    if (!hwnd && e.HasOwnProp("path") && e.path != "" && FileExist(e.path)) {
        try {
            Run(e.path)
            if (e.exe != "" && WinWait("ahk_exe " e.exe, , 10))
                hwnd := WinExist()
        }
    }
    if !hwnd
        return
    g_playRef := hwnd   ; reference for window-relative coordinates
    g_playRefT := 0
    if WinActive(hwnd)
        return
    try {
        WinActivate(hwnd)
        WinWaitActive(hwnd, , 2)
    }
}

; Corrective geometry anchor: snap the window to its recorded position,
; size and min/max state — replayed drags and title-bar-button clicks are
; imprecise, this makes the end state exact.
ReplayGeometry(e) {
    hwnd := FindTargetWindow(e)
    if !hwnd
        return
    try {
        if (e.state = -1) {
            WinMinimize(hwnd)
        } else if (e.state = 1) {
            WinMaximize(hwnd)
        } else {
            if (WinGetMinMax(hwnd) != 0)
                WinRestore(hwnd)
            WinMove(e.x, e.y, e.w, e.h, hwnd)
        }
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
    global g_currentFile, g_curProps
    g_curProps := Map()   ; a fresh recording has no playback overrides
    try DirCreate(g_macroDir)
    path := g_macroDir "\" FormatTime(, "yyyy-MM-dd HH.mm.ss") ".macro"
    WriteMacroFile(path)
    g_currentFile := path
}

; A "p" header line carries per-recording playback overrides
; (repeat, pause ms, speed, mode) — empty field = use the global setting.
WriteMacroFile(path) {
    global g_events, g_curProps
    out := ""
    hasProps := false
    for , v in g_curProps
        if (v != "")
            hasProps := true
    if hasProps
        out .= "p`t" g_curProps.Get("repeat", "") "`t" g_curProps.Get("pause", "")
            . "`t" g_curProps.Get("speed", "") "`t" g_curProps.Get("mode", "")
            . "`t" CleanField(g_curProps.Get("hotkey", "")) "`t" g_curProps.Get("coords", "") "`n"
    for e in g_events {
        if (e.kind = "k")
            out .= "k`t" e.t "`t" e.vk "`t" e.sc "`t" (e.up ? 1 : 0) "`n"
        else if (e.kind = "w")
            out .= "w`t" e.t "`t" e.exe "`t" e.title "`t" (e.HasOwnProp("path") ? e.path : "") "`n"
        else if (e.kind = "g")
            out .= "g`t" e.t "`t" e.exe "`t" e.title "`t" e.x "`t" e.y "`t" e.w "`t" e.h "`t" e.state "`n"
        else if (e.kind = "t")
            out .= "t`t" e.t "`t" CleanField(e.text) "`n"
        else if (e.kind = "s")
            out .= "s`t" e.t "`t" CleanField(e.keys) "`n"
        else if (e.kind = "d")
            out .= "d`t" e.t "`t" e.ms "`n"
        else if (e.kind = "ww")
            out .= "ww`t" e.t "`t" e.exe "`t" e.title "`t" e.ms "`t" e.active "`n"
        else if (e.kind = "v")
            out .= "v`t" e.t "`t" e.col "`n"
        else if (e.kind = "ls")
            out .= "ls`t" e.t "`n"
        else if (e.kind = "le")
            out .= "le`t" e.t "`t" e.count "`n"
        else
            out .= "m`t" e.t "`t" e.msg "`t" e.x "`t" e.y "`t" e.data
                . (e.HasOwnProp("wx") ? "`t" e.wx "`t" e.wy : "") "`n"
    }
    try FileDelete(path)
    try FileAppend(out, path, "UTF-8")
}

; TSV storage: tabs and line breaks cannot appear inside a field.
CleanField(s) {
    return StrReplace(StrReplace(StrReplace(s, "`t", " "), "`r", ""), "`n", " ")
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
    PushMacro()
}

LoadMacroFile(path) {
    global g_events, g_curProps
    g_curProps := Map()
    if !FileExist(path)
        return
    try {
        loop parse FileRead(path, "UTF-8"), "`n", "`r" {
            f := StrSplit(A_LoopField, "`t")
            if (f.Length >= 5 && f[1] = "p") {
                for i, k in ["repeat", "pause", "speed", "mode", "hotkey", "coords"]
                    if (f.Length >= i + 1 && f[i + 1] != "")
                        g_curProps[k] := f[i + 1]
            } else if (f.Length >= 5 && f[1] = "k")
                g_events.Push({t: Integer(f[2]), kind: "k", vk: Integer(f[3])
                    , sc: Integer(f[4]), up: f[5] = "1"})
            else if (f.Length >= 8 && f[1] = "m")
                g_events.Push({t: Integer(f[2]), kind: "m", msg: Integer(f[3])
                    , x: Integer(f[4]), y: Integer(f[5]), data: Integer(f[6])
                    , wx: Integer(f[7]), wy: Integer(f[8])})
            else if (f.Length >= 6 && f[1] = "m")
                g_events.Push({t: Integer(f[2]), kind: "m", msg: Integer(f[3])
                    , x: Integer(f[4]), y: Integer(f[5]), data: Integer(f[6])})
            else if (f.Length >= 4 && f[1] = "w")
                g_events.Push({t: Integer(f[2]), kind: "w", exe: f[3], title: f[4]
                    , path: f.Length >= 5 ? f[5] : ""})
            else if (f.Length >= 9 && f[1] = "g")
                g_events.Push({t: Integer(f[2]), kind: "g", exe: f[3], title: f[4]
                    , x: Integer(f[5]), y: Integer(f[6]), w: Integer(f[7])
                    , h: Integer(f[8]), state: Integer(f[9])})
            else if (f.Length >= 3 && f[1] = "t")
                g_events.Push({t: Integer(f[2]), kind: "t", text: f[3]})
            else if (f.Length >= 3 && f[1] = "s")
                g_events.Push({t: Integer(f[2]), kind: "s", keys: f[3]})
            else if (f.Length >= 3 && f[1] = "d")
                g_events.Push({t: Integer(f[2]), kind: "d", ms: Integer(f[3])})
            else if (f.Length >= 6 && f[1] = "ww")
                g_events.Push({t: Integer(f[2]), kind: "ww", exe: f[3], title: f[4]
                    , ms: Integer(f[5]), active: f[6] = "1" ? 1 : 0})
            else if (f.Length >= 3 && f[1] = "v")
                g_events.Push({t: Integer(f[2]), kind: "v", col: Integer(f[3])})
            else if (f.Length >= 2 && f[1] = "ls")
                g_events.Push({t: Integer(f[2]), kind: "ls"})
            else if (f.Length >= 3 && f[1] = "le")
                g_events.Push({t: Integer(f[2]), kind: "le", count: Integer(f[3])})
        }
    }
}

; ── Config ──────────────────────────────────────────────────────────────
LoadConfig(reread := false) {
    global g_recordKey, g_playKey, g_mode, g_speed, g_fixedDelayMs
    global g_maxWaitMs, g_pollMs, g_maxEvents, g_windowAnchors, g_macroDir
    global g_countdownMs, g_playOsd
    if !FileExist(g_configFile)
        WriteDefaultConfig()
    dir := Trim(IniRead(g_configFile, "Settings", "MacroFolder", ""))
    if (dir != "") {
        if !RegExMatch(dir, "^([A-Za-z]:\\|\\\\)")   ; relative → beside the script
            dir := A_ScriptDir "\" dir
        g_macroDir := RTrim(dir, "\")
    } else {
        g_macroDir := A_ScriptDir "\macros"
    }
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
    try g_countdownMs := Integer(IniRead(g_configFile, "Settings", "CountdownMs", "1000"))
    catch
        g_countdownMs := 1000
    if (g_countdownMs < 0)
        g_countdownMs := 0
    g_playOsd := IniRead(g_configFile, "Settings", "PlaybackOsd", "1") != "0"
    ApplyHotkey(&g_recordKey, Trim(IniRead(g_configFile, "Settings", "RecordHotkey", "+F12")), ToggleRecord)
    ApplyHotkey(&g_playKey,   Trim(IniRead(g_configFile, "Settings", "PlayHotkey",   "F12")), Play)
    if reread
        InitTray()
}

ApplyHotkey(&stored, newKey, fn) {
    if g_cliMode {   ; a CLI run must not fight the tray instance's hotkeys
        stored := ""
        return
    }
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
;   Esc - aborts; pressing it during recording stops the recording.
; Mode: original (recorded timing) or fixed (fixed pause between events).
; Speed: playback speed factor in original mode - 2 = twice as fast.
; FixedDelayMs: the pause between events in fixed mode.
; MaxWaitMs: longest single pause replayed in original mode.
; MousePollMs: mouse sampling interval while recording (position/buttons).
; MaxEvents: safety cap on the number of recorded events.
; MacroFolder: where recordings are stored. Empty = the "macros" folder
;   beside the script; a relative path is resolved against the script
;   folder. Existing recordings are NOT moved when this changes.
; Repeat: how many times a playback runs (0 = until aborted).
; RepeatPauseMs: pause between the repetitions.
; CountdownMs: pause before playback starts, with a countdown overlay
;   (0 = start immediately).
; PlaybackOsd=1: progress overlay during playback (step count, repetition).
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
MacroFolder=
WindowAnchors=1
Repeat=1
RepeatPauseMs=1000
CountdownMs=1000
PlaybackOsd=1
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
    recsMenu.Add("Name recording…", NameRecording)
    recsMenu.Add("Save copy as…", SaveCopyAs)
    recsMenu.Add("Export as standalone script…", ExportStandalone)
    recsMenu.Add("Load macro file…", LoadMacroDialog)
    recsMenu.Add("Change macro folder…", ChangeMacroFolder)
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
    A_TrayMenu.Add("Open Encore", OpenUi)
    A_TrayMenu.Add()
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
    A_TrayMenu.Default := "Open Encore"   ; double-clicking the tray icon opens the window
    cur := g_currentFile != "" ? SubStr(g_currentFile, InStr(g_currentFile, "\", , -1) + 1) : ""
    A_IconTip := "Encore — " (g_recording ? "recording…"
        : g_playing ? "playing…"
        : cur != "" ? cur " (" g_events.Length " events)" : "no recordings")
    SyncMacroHotkeys()
    PushState()
}

OpenMacroDir(*) {
    try DirCreate(g_macroDir)
    try Run(g_macroDir)
}

; Rename the selected recording — the file name IS the name in the menu.
NameRecording(*) {
    global g_currentFile
    if (g_currentFile = "" || !FileExist(g_currentFile)) {
        Notify("Encore: no recording selected")
        return
    }
    cur := SubStr(g_currentFile, InStr(g_currentFile, "\", , -1) + 1)
    cur := SubStr(cur, 1, -6)
    ib := InputBox("Name for the recording:", "Encore", "w400 h130", cur)
    if (ib.Result != "OK" || Trim(ib.Value) = "")
        return
    name := RegExReplace(Trim(ib.Value), '[\\/:*?"<>|]', "_")
    newPath := g_macroDir "\" name ".macro"
    if (newPath = g_currentFile)
        return
    if FileExist(newPath) {
        Notify("Encore: a recording with that name already exists")
        return
    }
    try {
        FileMove(g_currentFile, newPath)
        if FileExist(DataFileFor(g_currentFile))
            FileMove(DataFileFor(g_currentFile), DataFileFor(newPath))
        g_currentFile := newPath
        ; The schedule follows the name here too — renaming from the tray used to
        ; leave the task behind on the old name, which is the very orphan the
        ; schedule list was added to clean up after.
        SetTimer(MoveTask.Bind(cur, name), -1)
    } catch {
        Notify("Encore: could not rename the recording")
    }
    InitTray()
}

SaveCopyAs(*) {
    global g_currentFile
    if (g_currentFile = "" || !FileExist(g_currentFile)) {
        Notify("Encore: no recording selected")
        return
    }
    dest := ""
    try dest := FileSelect("S", g_currentFile, "Save a copy of the recording", "Macro (*.macro)")
    if (dest = "")
        return
    if !RegExMatch(dest, "i)\.macro$")
        dest .= ".macro"
    try FileCopy(g_currentFile, dest, true)
    InitTray()
}

LoadMacroDialog(*) {
    global g_events, g_currentFile
    if (g_recording || g_playing)
        return
    try DirCreate(g_macroDir)
    f := ""
    try f := FileSelect(3, g_macroDir, "Load a macro", "Macro (*.macro)")
    if (f = "")
        return
    g_events := []
    LoadMacroFile(f)
    g_currentFile := f
    InitTray()
    PushMacro()
    Notify("Loaded " g_events.Length " events")
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

; ── Management window (WebView2, same architecture as Expanto) ──────────
; Created lazily on first open; closing hides it so reopening is instant.
OpenUi(*) {
    global g_uiWin, g_uiCtrl, g_uiCore
    if !g_uiWin {
        DllCall("shell32\SetCurrentProcessExplicitAppUserModelID", "str", "Encore.Application.2")
        g_uiWin := Gui("+Resize +MinSize640x420", "Encore")
        g_uiWin.OnEvent("Close", (*) => (SaveUiGeometry(), g_uiWin.Hide()))
        g_uiWin.OnEvent("Size", UiResize)
        g_uiWin.Show(ReadUiGeometry())
        FitUiToScreen()
        DllCall("dwmapi\DwmSetWindowAttribute", "ptr", g_uiWin.hwnd, "uint", 20, "int*", 1, "uint", 4)
        ; WM_SETICON täcker titelraden, men med ett explicit AppUserModelID
        ; faller aktivitetsfältets GRUPPIKON tillbaka på fönsterklassens ikon
        ; — AutoHotkeys gröna H — så klassikonen byts också (GCLP_HICON/-SM).
        try {
            ico16 := LoadPicture(A_ScriptDir "\app.ico", "Icon1 w16 h16", &_it1)
            ico32 := LoadPicture(A_ScriptDir "\app.ico", "Icon1 w32 h32", &_it2)
            SendMessage(0x80, 0, ico16, , g_uiWin.hwnd)
            SendMessage(0x80, 1, ico32, , g_uiWin.hwnd)
            DllCall("SetClassLongPtr", "ptr", g_uiWin.hwnd, "int", -14, "ptr", ico32)   ; GCLP_HICON
            DllCall("SetClassLongPtr", "ptr", g_uiWin.hwnd, "int", -34, "ptr", ico16)   ; GCLP_HICONSM
        }
        try {
            g_uiCtrl := WebView2.create(g_uiWin.hwnd, , 0, "", "", 0
                , A_ScriptDir "\lib\WebView2Loader.dll")
            g_uiCtrl.Fill()
            g_uiCore := g_uiCtrl.CoreWebView2
            g_uiCore.add_WebMessageReceived(UiMessage)
            g_uiCore.Navigate("file:///" StrReplace(A_ScriptDir "\ui\index.html", "\", "/"))
        } catch as err {
            g_uiWin.Destroy()
            g_uiWin := 0, g_uiCtrl := 0, g_uiCore := 0
            LogError(err, "")
            Notify("Encore: could not start the UI (WebView2 runtime missing?)")
            return
        }
    } else {
        g_uiWin.Show()
        FitUiToScreen()
    }
}

; Window geometry is remembered between sessions, but always clamped to
; the work area of the monitor it lands on — a window wider than the
; screen puts its toolbar buttons out of reach (and a stale saved size
; from another monitor setup would do the same).
ReadUiGeometry() {
    w := 980, h := 640
    try {
        w := Integer(IniRead(g_configFile, "Window", "W", "980"))
        h := Integer(IniRead(g_configFile, "Window", "H", "640"))
    }
    x := IniRead(g_configFile, "Window", "X", "")
    y := IniRead(g_configFile, "Window", "Y", "")
    opt := "w" Max(640, w) " h" Max(420, h)
    if (x != "" && y != "")
        opt := "x" x " y" y " " opt
    return opt
}

SaveUiGeometry() {
    global g_uiWin, g_configFile
    if !g_uiWin
        return
    try {
        if (WinGetMinMax(g_uiWin.hwnd) != 0)   ; don't store a maximized/minimized rect
            return
        ; Position from the window rect, size from the CLIENT rect: Gui.Show("w… h…")
        ; sizes the client area, so storing the outer size grew the window by the
        ; title bar and borders on every single session.
        WinGetPos(&x, &y, , , g_uiWin.hwnd)
        WinGetClientPos( , , &w, &h, g_uiWin.hwnd)
        IniWrite(x, g_configFile, "Window", "X")
        IniWrite(y, g_configFile, "Window", "Y")
        IniWrite(w, g_configFile, "Window", "W")
        IniWrite(h, g_configFile, "Window", "H")
    }
}

FitUiToScreen() {
    global g_uiWin
    if !g_uiWin
        return
    try {
        if (WinGetMinMax(g_uiWin.hwnd) != 0)
            return
        WinGetPos(&x, &y, &w, &h, g_uiWin.hwnd)
        MonitorGetWorkArea(MonitorFromWindow(g_uiWin.hwnd), &l, &t, &r, &b)
        w := Min(w, r - l), h := Min(h, b - t)
        x := Min(Max(x, l), r - w), y := Min(Max(y, t), b - h)
        WinMove(x, y, w, h, g_uiWin.hwnd)
    }
}

MonitorFromWindow(hwnd) {
    h := DllCall("MonitorFromWindow", "ptr", hwnd, "uint", 2, "ptr")   ; NEAREST
    info := Buffer(40, 0)
    NumPut("UInt", 40, info, 0)
    if !DllCall("GetMonitorInfoW", "ptr", h, "ptr", info)
        return 0   ; MonitorGetWorkArea(0) = primary
    loop MonitorGetCount() {
        MonitorGet(A_Index, &ml, &mt, &mr, &mb)
        if (ml = NumGet(info, 4, "Int") && mt = NumGet(info, 8, "Int"))
            return A_Index
    }
    return 0
}

UiResize(guiObj, minMax, w, h) {
    global g_uiCtrl
    if (minMax != -1 && IsObject(g_uiCtrl))
        try g_uiCtrl.Fill()
}

UiSend(script) {
    global g_uiReady, g_uiCore
    if (!g_uiReady || !IsObject(g_uiCore))
        return
    try g_uiCore.ExecuteScriptAsync(script)
    catch
        g_uiReady := false
}

UiMessage(sender, args) {
    global g_uiReady, g_stopPlay
    try msg := JSON.Load(args.WebMessageAsJson)
    catch
        return
    if (!(msg is Map) || !msg.Has("action"))
        return
    switch msg["action"] {
        case "ready":
            g_uiReady := true
            PushState()
            PushMacro()
        case "record": SetTimer(ToggleRecord, -1)
        case "play": SetTimer(Play, -1)
        case "stop":
            if g_playing
                g_stopPlay := true
        case "select":
            SelectMacro(g_macroDir "\" msg["name"] ".macro")
        case "rename": UiRename(msg["name"], msg["newName"])
        case "delete": UiDelete(msg["name"])
        case "deleteMany": UiDeleteMany(msg["names"])
        case "copyStepsTo": UiCopyStepsTo(msg)
        case "copyText":
            A_Clipboard := msg.Get("text", "")
            Notify("Copied to the clipboard", 1200)
        case "openReadme": Run("https://github.com/ibst1/encore#command-line-and-standalone-use")
        case "deleteEvents": UiDeleteEvents(msg["ranges"])
        case "setStep": UiSetStep(msg)
        case "insertStep": UiInsertStep(msg)
        case "setDelay": UiSetDelay(msg)
        case "saveData": UiSaveData(msg)
        case "moveEvents": UiMoveEvents(msg)
        case "trim": UiTrim()
        case "repeatSteps": UiRepeatSteps(msg)
        case "setRepeatCount": UiSetRepeatCount(msg)
        case "queryTask": SetTimer(UiQueryTask, -1)         ; schtasks calls block briefly
        case "removeTaskNamed": SetTimer(UiRemoveTaskNamed.Bind(msg.Get("name", "")), -1)
        case "scheduleTask": SetTimer(() => UiScheduleTask(msg), -1)
        case "removeTask": SetTimer(UiRemoveTask, -1)
        case "saveMacroSettings": UiSaveMacroProps(msg)
        case "saveSettings": UiSaveSettings(msg)
        case "exportAhk": SetTimer((*) => ExportStandalone(), -1)   ; detached: opens a file dialog
        case "browseMacroFolder": SetTimer(UiBrowseMacroFolder, -1)
        case "openFolder": OpenMacroDir()
    }
}

PushState() {
    global g_currentFile, g_curProps
    if !g_uiReady
        return
    list := []
    for m in ListMacros() {
        info := MacroInfo(m.p)
        list.Push(Map("name", m.name, "events", info.n, "durMs", info.dur))
    }
    props := Map()
    for k, v in g_curProps
        if (v != "")
            props[k] := v
    cur := g_currentFile != ""
        ? SubStr(SubStr(g_currentFile, InStr(g_currentFile, "\", , -1) + 1), 1, -6) : ""
    dataText := ""
    df := DataFileFor(g_currentFile)
    ; Read the list WHOLE. It used to come across capped at 65536 characters, and
    ; since the panel writes back whatever it is showing, the first save after
    ; opening a long list silently threw the tail away.
    if (df != "" && FileExist(df))
        try dataText := FileRead(df, "UTF-8")
    st := Map("recordings", list, "current", cur, "dataText", dataText
        , "recording", g_recording ? 1 : 0, "playing", g_playing ? 1 : 0
        , "macroProps", props, "cliBase", CliBase()
        , "settings", Map("recordKey", g_recordKey, "playKey", g_playKey
            , "mode", g_mode, "speed", g_speed, "fixedDelayMs", g_fixedDelayMs
            , "repeat", g_repeat, "repeatPauseMs", g_repeatPauseMs
            , "anchors", g_windowAnchors ? 1 : 0, "macroFolder", g_macroDir
            , "countdownMs", g_countdownMs, "playbackOsd", g_playOsd ? 1 : 0))
    UiSend("window.receiveState(" JSON.Dump(st) ")")
}

PushMacro() {
    global g_events
    if !g_uiReady
        return
    cap := Min(g_events.Length, 5000)
    arr := []
    loop cap {
        e := g_events[A_Index]
        if (e.kind = "k")
            arr.Push(Map("kind", "k", "t", e.t, "vk", e.vk, "sc", e.sc, "up", e.up ? 1 : 0))
        else if (e.kind = "w")
            arr.Push(Map("kind", "w", "t", e.t, "exe", e.exe, "title", e.title))
        else if (e.kind = "g")
            arr.Push(Map("kind", "g", "t", e.t, "exe", e.exe, "title", e.title
                , "x", e.x, "y", e.y, "w", e.w, "h", e.h, "state", e.state))
        else if (e.kind = "t")
            arr.Push(Map("kind", "t", "t", e.t, "text", e.text))
        else if (e.kind = "s")
            arr.Push(Map("kind", "s", "t", e.t, "keys", e.keys))
        else if (e.kind = "d")
            arr.Push(Map("kind", "d", "t", e.t, "ms", e.ms))
        else if (e.kind = "ww")
            arr.Push(Map("kind", "ww", "t", e.t, "exe", e.exe, "title", e.title
                , "ms", e.ms, "active", e.active))
        else if (e.kind = "v")
            arr.Push(Map("kind", "v", "t", e.t, "col", e.col))
        else if (e.kind = "ls")
            arr.Push(Map("kind", "ls", "t", e.t))
        else if (e.kind = "le")
            arr.Push(Map("kind", "le", "t", e.t, "count", e.count))
        else
            arr.Push(Map("kind", "m", "t", e.t, "msg", e.msg, "x", e.x, "y", e.y, "data", e.data))
    }
    payload := Map("events", arr, "truncated", g_events.Length > cap ? 1 : 0)
    UiSend("window.receiveMacro(" JSON.Dump(payload) ")")
}

; Browse… in the settings dialog: pick a folder, send it back into the
; open dialog's field (applied when the user presses Save).
UiBrowseMacroFolder() {
    global g_macroDir
    dir := ""
    try dir := DirSelect("*" g_macroDir, 3, "Choose the folder where recordings are stored")
    if (dir != "")
        UiSend("window.setMacroFolder(" JSON.Dump(dir) ")")
}

; ── Per-macro hotkeys ───────────────────────────────────────────────────
; Each recording can carry its own global hotkey (field 5 of the p line):
; pressing it plays THAT macro. The registry is rebuilt from the files on
; every state change (InitTray), so renames/deletes/edits stay in sync.
ReadMacroHotkey(path) {
    line := ""
    try line := FileRead(path, "UTF-8 m256")
    if !line
        return ""
    line := StrSplit(line, "`n")[1]
    f := StrSplit(RTrim(line, "`r"), "`t")
    return (f.Length >= 6 && f[1] = "p") ? Trim(f[6]) : ""
}

SyncMacroHotkeys() {
    global g_macroHotkeys
    if g_cliMode
        return
    wanted := Map()
    for m in ListMacros() {
        hk := ReadMacroHotkey(m.p)
        if (hk = "" || wanted.Has(hk))
            continue
        if (hk = g_recordKey || hk = g_playKey) {
            Notify("Encore: macro hotkey " hk " collides with the main hotkeys")
            continue
        }
        wanted[hk] := m.p
    }
    for hk, path in g_macroHotkeys.Clone() {
        if (!wanted.Has(hk) || wanted[hk] != path) {
            try Hotkey(hk, "Off")
            g_macroHotkeys.Delete(hk)
        }
    }
    for hk, path in wanted {
        if !g_macroHotkeys.Has(hk) {
            try {
                Hotkey(hk, PlayMacroFile.Bind(path), "On")
                g_macroHotkeys[hk] := path
            } catch {
                Notify("Encore: invalid macro hotkey: " hk)
            }
        }
    }
}

PlayMacroFile(path, *) {
    if (g_recording || g_playing || !FileExist(path))
        return
    SelectMacro(path)
    SetTimer(Play, -1)
}

; Light parse for the sidebar: event count and duration of a macro file.
MacroInfo(path) {
    n := 0, tFirst := 0, tLast := 0
    try {
        loop parse FileRead(path, "UTF-8"), "`n", "`r" {
            f := StrSplit(A_LoopField, "`t")
            if (f.Length < 2 || f[1] = "p")
                continue
            n += 1
            t := 0
            try t := Integer(f[2])
            if !tFirst
                tFirst := t
            tLast := t
        }
    }
    return {n: n, dur: tLast > tFirst ? tLast - tFirst : 0}
}

UiRename(old, newName) {
    global g_currentFile
    src := g_macroDir "\" old ".macro"
    name := RegExReplace(Trim(newName), '[\\/:*?"<>|]', "_")
    dst := g_macroDir "\" name ".macro"
    if (name = "" || !FileExist(src) || FileExist(dst))
        return
    moved := false
    try {
        FileMove(src, dst)
        moved := true
        if (g_currentFile = src)
            g_currentFile := dst
        if FileExist(DataFileFor(src))   ; the data list follows its macro
            FileMove(DataFileFor(src), DataFileFor(dst))
    }
    ; …and so does its schedule, or the task would keep firing on a name that no
    ; longer exists, with no way to see it from inside the app. Only when the file
    ; really moved: FileMove throws while OneDrive or an editor holds the file, and
    ; repointing the schedule then would take it away from the macro that still has
    ; the old name and hand it to one that does not exist.
    if moved
        SetTimer(MoveTask.Bind(old, name), -1)
    InitTray()
}

UiDelete(name) {
    global g_currentFile, g_events, g_curProps
    if (g_recording || g_playing)
        return
    p := g_macroDir "\" name ".macro"
    try FileDelete(p)
    try FileDelete(DataFileFor(p))
    ; A deleted macro must not leave a task behind that fires on nothing.
    SetTimer(() => CaptureCmd('schtasks /Delete /F /TN "' TaskName(name) '"'), -1)
    if (g_currentFile = p) {
        g_currentFile := ""
        g_events := []
        g_curProps := Map()
        macros := ListMacros()
        if macros.Length {
            g_currentFile := macros[1].p
            LoadMacroFile(g_currentFile)
        }
        PushMacro()
    }
    InitTray()
}

; Delete several recordings in one sweep — the current macro is re-resolved
; and the UI refreshed once at the end instead of per file.
UiDeleteMany(names) {
    global g_recording, g_playing, g_macroDir, g_currentFile, g_events, g_curProps
    if (g_recording || g_playing)
        return
    lostCurrent := false
    for name in names {
        p := g_macroDir "\" name ".macro"
        try FileDelete(p)
        try FileDelete(DataFileFor(p))
        ; A deleted macro must not leave a task behind that fires on nothing.
        ; Bind() snapshots the command string — a fat-arrow closure here would
        ; capture the loop variable and every timer would fire with the last name.
        SetTimer(CaptureCmd.Bind('schtasks /Delete /F /TN "' TaskName(name) '"'), -1)
        if (g_currentFile = p)
            lostCurrent := true
    }
    if lostCurrent {
        g_currentFile := ""
        g_events := []
        g_curProps := Map()
        macros := ListMacros()
        if macros.Length {
            g_currentFile := macros[1].p
            LoadMacroFile(g_currentFile)
        }
        PushMacro()
    }
    InitTray()
}

; Delete the raw events behind the display steps the user selected —
; ranges are 1-based inclusive [from, to] pairs into the event array.
UiDeleteEvents(ranges) {
    global g_events, g_currentFile
    if (g_currentFile = "" || g_recording || g_playing || !(ranges is Array))
        return
    keep := []
    for idx, e in g_events {
        drop := false
        for r in ranges {
            if (idx >= r[1] && idx <= r[2]) {
                drop := true
                break
            }
        }
        if !drop
            keep.Push(e)
    }
    g_events := keep
    WriteMacroFile(g_currentFile)
    InitTray()
    PushMacro()
}

; Append the events in `ranges` (from the current macro) to another macro's
; file — drag & drop in the UI. move=1 also removes them from the source.
; The block keeps its internal spacing and lands 500 ms after the target's
; last event, so the target's own timing is untouched.
UiCopyStepsTo(msg) {
    global g_events, g_curProps, g_currentFile, g_macroDir, g_recording, g_playing
    if (g_currentFile = "" || g_recording || g_playing)
        return
    target := msg.Get("target", "")
    ranges := msg.Get("ranges", "")
    doMove := msg.Get("move", 0) ? true : false
    tp := g_macroDir "\" target ".macro"
    if (target = "" || !(ranges is Array) || !ranges.Length
        || !FileExist(tp) || tp = g_currentFile)
        return
    picked := []
    for idx, e in g_events {
        for r in ranges {
            if (idx >= r[1] && idx <= r[2]) {
                picked.Push(e)
                break
            }
        }
    }
    if !picked.Length
        return
    ; borrow the ordinary loader for the target, then restore the globals
    srcEvents := g_events, srcProps := g_curProps, srcFile := g_currentFile
    g_events := []
    LoadMacroFile(tp)
    tgtEvents := g_events, tgtProps := g_curProps
    base := tgtEvents.Length ? tgtEvents[tgtEvents.Length].t + 500 : 0
    first := picked[1].t
    hasMouse := false
    for e in picked {
        c := e.Clone()
        c.t := base + (e.t - first)
        tgtEvents.Push(c)
        if (c.kind = "m")
            hasMouse := true
    }
    ; mouse steps recorded in one coordinate mode land differently in the other
    coordWarn := hasMouse
        && srcProps.Get("coords", "") != tgtProps.Get("coords", "")
    g_events := tgtEvents, g_curProps := tgtProps
    WriteMacroFile(tp)
    g_events := srcEvents, g_curProps := srcProps, g_currentFile := srcFile
    if doMove
        UiDeleteEvents(ranges)   ; rewrites the source file and refreshes the UI
    else {
        InitTray()
        PushMacro()
    }
    n := picked.Length
    Notify((doMove ? "Moved " : "Copied ") n " event" (n > 1 ? "s" : "")
        . " to `"" target "`""
        . (coordWarn ? "`nNote: the two macros use different coordinate modes - check the mouse positions."
                     : ""), coordWarn ? 4000 : 2000)
}

; Wrap the event range in repeat markers: ls before, le(count) after. The
; markers take their neighbours' timestamps so the timeline is untouched.
UiRepeatSteps(msg) {
    global g_events, g_currentFile, g_recording, g_playing
    if (g_currentFile = "" || g_recording || g_playing)
        return
    from := 0, to := 0, count := 0
    try {
        from := Integer(msg.Get("from", 0)), to := Integer(msg.Get("to", 0))
        count := Integer(msg.Get("count", 0))
    }
    if (from < 1 || to > g_events.Length || from > to || count < 2)
        return
    g_events.InsertAt(to + 1, {t: g_events[to].t, kind: "le", count: count})
    g_events.InsertAt(from, {t: g_events[from].t, kind: "ls"})
    WriteMacroFile(g_currentFile)
    InitTray()
    PushMacro()
}

UiSetRepeatCount(msg) {
    global g_events, g_currentFile, g_recording, g_playing
    if (g_currentFile = "" || g_recording || g_playing)
        return
    at := 0, count := -1
    try {
        at := Integer(msg.Get("at", 0)), count := Integer(msg.Get("count", -1))
    }
    if (at < 1 || at > g_events.Length || g_events[at].kind != "le" || count < 0)
        return
    if (count = 0) {
        ; 0 = ta bort klammern: hitta matchande ls bakåt med nästlingsräknare
        depth := 1, lsAt := 0, idx := at - 1
        while (idx >= 1) {
            if (g_events[idx].kind = "le")
                depth += 1
            else if (g_events[idx].kind = "ls") {
                depth -= 1
                if (depth = 0) {
                    lsAt := idx
                    break
                }
            }
            idx -= 1
        }
        g_events.RemoveAt(at)          ; högsta index först
        if lsAt
            g_events.RemoveAt(lsAt)
    } else {
        g_events[at].count := count
    }
    WriteMacroFile(g_currentFile)
    InitTray()
    PushMacro()
}

_WmDpiChanged(wParam, lParam, msg, hwnd) {
    global g_uiCtrl
    x := NumGet(lParam, 0, "int"), y := NumGet(lParam, 4, "int")
    r := NumGet(lParam, 8, "int"), b := NumGet(lParam, 12, "int")
    DllCall("SetWindowPos", "ptr", hwnd, "ptr", 0, "int", x, "int", y
        , "int", r - x, "int", b - y, "uint", 0x0214)   ; NOZORDER|NOACTIVATE|FRAMECHANGED
    try SetTimer(() => (g_uiCtrl ? g_uiCtrl.Fill() : 0), -80)   ; hangslen: fyll om WebView2-ytan
    return 0
}

; The exact command-line prefix that plays a macro from outside the UI —
; compiled: the exe alone; script install: interpreter + script path.
; Store-edition AutoHotkey runs inside an app container whose interpreter
; path ("C:\Program Files\AutoHotkey\...") only exists INSIDE the
; container — other processes (cmd, Task Scheduler) cannot see it. The
; execution alias in LOCALAPPDATA is the globally visible launcher, so
; prefer it whenever it exists.
CliBase() {
    if A_IsCompiled
        return '"' A_ScriptFullPath '"'
    ahk := A_AhkPath
    alias := EnvGet("LOCALAPPDATA") "\Microsoft\WindowsApps\AutoHotkeyV2.exe"
    if FileExist(alias)
        ahk := alias
    return '"' ahk '" "' A_ScriptFullPath '"'
}

; Build a single event from a step spec sent by the UI. type: "text",
; "pause", "send" or "switch". Returns 0 on an invalid spec.
BuildStepEvent(msg, t) {
    type := msg.Get("type", "")
    if (type = "text" && Trim(msg.Get("text", "")) != "")
        return {t: t, kind: "t", text: msg["text"]}
    if (type = "send" && Trim(msg.Get("keys", "")) != "")
        return {t: t, kind: "s", keys: Trim(msg["keys"])}
    if (type = "pause") {
        ms := 0
        try ms := Integer(msg.Get("ms", ""))
        if (ms > 0)
            return {t: t, kind: "d", ms: ms}
    }
    if (type = "switch" && (Trim(msg.Get("exe", "")) != "" || Trim(msg.Get("title", "")) != ""))
        return {t: t, kind: "w", exe: Trim(msg.Get("exe", ""))
            , title: Trim(msg.Get("title", "")), path: ""}
    if (type = "value") {
        col := 1
        try col := Integer(msg.Get("col", "1"))
        if (col < 1)
            col := 1
        return {t: t, kind: "v", col: col}
    }
    if (type = "waitwin" && (Trim(msg.Get("exe", "")) != "" || Trim(msg.Get("title", "")) != "")) {
        tmo := 10000
        try tmo := Integer(msg.Get("timeout", "10000"))
        if (tmo < 100)
            tmo := 10000
        return {t: t, kind: "ww", exe: Trim(msg.Get("exe", ""))
            , title: Trim(msg.Get("title", "")), ms: tmo
            , active: msg.Get("active", "") = "1" ? 1 : 0}
    }
    return 0
}

; Replace the events behind one display step ([from..to], 1-based) with a
; single new event — how "edit step" turns a raw typing run into a text
; event, or changes a pause/send/switch step.
UiSetStep(msg) {
    global g_events, g_currentFile
    if (g_currentFile = "" || g_recording || g_playing)
        return
    from := 0, to := 0
    try from := Integer(msg.Get("from", 0)), to := Integer(msg.Get("to", 0))
    if (from < 1 || to > g_events.Length || from > to)
        return
    ev := BuildStepEvent(msg, g_events[from].t)
    if !ev
        return
    keep := []
    for idx, e in g_events {
        if (idx = from)
            keep.Push(ev)
        if (idx < from || idx > to)
            keep.Push(e)
    }
    g_events := keep
    WriteMacroFile(g_currentFile)
    InitTray()
    PushMacro()
}

; Insert a new event before position `at` (1-based; > length = append).
UiInsertStep(msg) {
    global g_events, g_currentFile
    if (g_currentFile = "" || g_recording || g_playing)
        return
    at := g_events.Length + 1
    try at := Integer(msg.Get("at", at))
    if (at < 1)
        at := 1
    if (at > g_events.Length + 1)
        at := g_events.Length + 1
    ; timestamp of the neighbour = no extra wait in original-timing mode
    t := g_events.Length ? g_events[Min(at, g_events.Length)].t : 0
    ev := BuildStepEvent(msg, t)
    if !ev
        return
    keep := []
    for idx, e in g_events {
        if (idx = at)
            keep.Push(ev)
        keep.Push(e)
    }
    if (at = g_events.Length + 1)
        keep.Push(ev)
    g_events := keep
    WriteMacroFile(g_currentFile)
    InitTray()
    PushMacro()
}

; Change the pause before the step whose first event is `at` (1-based):
; every timestamp from that event on is shifted by the difference, so the
; step's internal timing is preserved. (Replay of a single pause is still
; capped by MaxWaitMs in original mode.)
UiSetDelay(msg) {
    global g_events, g_currentFile
    if (g_currentFile = "" || g_recording || g_playing)
        return
    at := 0, ms := -1
    try {
        at := Integer(msg.Get("at", 0))
        ms := Integer(msg.Get("ms", -1))
    }
    if (at < 2 || at > g_events.Length || ms < 0)
        return
    delta := ms - (g_events[at].t - g_events[at - 1].t)
    if (delta = 0)
        return
    idx := at
    while (idx <= g_events.Length) {
        g_events[idx].t := g_events[idx].t + delta
        idx += 1
    }
    WriteMacroFile(g_currentFile)
    InitTray()
    PushMacro()
}

; Save the data list for the selected recording (empty text removes it).
UiSaveData(msg) {
    global g_currentFile
    if (g_currentFile = "")
        return
    df := DataFileFor(g_currentFile)
    if (df = "")
        return
    text := msg.Get("text", "")
    try FileDelete(df)
    if (Trim(text, " `t`r`n") != "")
        try FileAppend(text, df, "UTF-8")
    InitTray()
}

; ── Step reordering and trimming ────────────────────────────────────────
; Move events [from..to] before destFrom (dir=up) or after destTo
; (dir=down). Each event keeps its lead-in gap through the move, and the
; timeline is rebuilt cumulatively — so the pause before a step travels
; with it and timestamps stay monotonic.
MoveEventBlock(arr, from, to, insertAt) {
    gaps := []
    prev := 0
    for i, e in arr {
        gaps.Push(i = 1 ? 0 : e.t - prev)
        prev := e.t
    }
    block := [], blockG := [], rest := [], restG := []
    for i, e in arr {
        if (i >= from && i <= to) {
            block.Push(e), blockG.Push(gaps[i])
        } else {
            rest.Push(e), restG.Push(gaps[i])
        }
    }
    out := [], outG := []
    for i, e in rest {
        if (i = insertAt) {
            for j, b in block {
                out.Push(b), outG.Push(blockG[j])
            }
        }
        out.Push(e), outG.Push(restG[i])
    }
    if (insertAt = rest.Length + 1) {
        for j, b in block {
            out.Push(b), outG.Push(blockG[j])
        }
    }
    t := 0
    for i, e in out {
        t += outG[i]
        e.t := t
    }
    return out
}

UiMoveEvents(msg) {
    global g_events, g_currentFile
    if (g_currentFile = "" || g_recording || g_playing)
        return
    from := 0, to := 0, destFrom := 0, destTo := 0
    try {
        from := Integer(msg.Get("from", 0)), to := Integer(msg.Get("to", 0))
        destFrom := Integer(msg.Get("destFrom", 0)), destTo := Integer(msg.Get("destTo", 0))
    }
    if (from < 1 || to > g_events.Length || from > to)
        return
    if (msg.Get("dir", "") = "up" && destFrom >= 1 && destFrom < from)
        insertAt := destFrom
    else if (msg.Get("dir", "") = "down" && destTo > to && destTo <= g_events.Length)
        insertAt := destTo + 1 - (to - from + 1)
    else
        return
    g_events := MoveEventBlock(g_events, from, to, insertAt)
    WriteMacroFile(g_currentFile)
    InitTray()
    PushMacro()
}

; Remove the dead mouse movements before the first real action and after
; the last one (the path toward the stop button). Anchors and geometry
; events are never actions but are kept wherever they are.
TrimEvents(arr) {
    isMove := (e) => (e.kind = "m" && e.msg = 0x200)
    first := 0, last := 0
    for i, e in arr {
        if (!isMove(e) && e.kind != "w" && e.kind != "g") {
            if !first
                first := i
            last := i
        }
    }
    if !first   ; a moves-only macro (a recorded mouse path) is left intact
        return {events: arr, removed: 0}
    out := [], removed := 0
    for i, e in arr {
        if (isMove(e) && (i < first || i > last))
            removed += 1
        else
            out.Push(e)
    }
    return {events: out, removed: removed}
}

UiTrim(*) {
    global g_events, g_currentFile
    if (g_currentFile = "" || g_recording || g_playing)
        return
    r := TrimEvents(g_events)
    if !r.removed {
        Notify("Encore: nothing to trim")
        return
    }
    g_events := r.events
    WriteMacroFile(g_currentFile)
    InitTray()
    PushMacro()
    Notify("Trimmed " r.removed " events", 2000)
}

; ── Task Scheduler integration ──────────────────────────────────────────
; Creates user-level scheduled tasks that run the CLI play mode:
;   "<interpreter>" "<Encore.ahk>" "<macro name>"
; Grouped under an "Encore" folder in the Task Scheduler.
TaskName(name) {
    return "Encore\" name
}

RunnerCmd(name) {
    ahk := EnvGet("LOCALAPPDATA") "\Microsoft\WindowsApps\AutoHotkeyV2.exe"
    if !FileExist(ahk)   ; the alias is short (schtasks /TR max 261 chars)
        ahk := A_AhkPath
    return '\"' ahk '\" \"' A_ScriptFullPath '\" \"' name '\"'
}

; Run a console command and hand back its output. The code page is FORCED to UTF-8
; rather than guessed: a redirected console writes in the OEM page (850 here) while
; FileRead without an encoding decodes with the ANSI one (1252), so a macro named
; "Sköldkörtelprov" came back mangled — and that string is not merely displayed, it
; is what the schedule list matches against the macro files and sends back to
; schtasks /Delete. Mangled meant a real schedule shown as an orphan whose ✕ then
; failed. "chcp 65001>nul &" costs nothing and removes the guesswork.
CaptureCmd(cmd) {
    tmp := A_Temp "\encore_schtask.txt"
    try FileDelete(tmp)
    code := 1
    try code := RunWait(A_ComSpec ' /c chcp 65001>nul & ' cmd ' > "' tmp '" 2>&1', , "Hide")
    out := ""
    try out := FileRead(tmp, "UTF-8")
    return {code: code, out: Trim(out, " `t`r`n")}
}

CurrentMacroName() {
    global g_currentFile
    return g_currentFile != ""
        ? SubStr(SubStr(g_currentFile, InStr(g_currentFile, "\", , -1) + 1), 1, -6) : ""
}

; Everything Encore has ever scheduled, whether or not the macro behind it still
; exists. Renaming or deleting a macro used to leave its task behind, firing on a
; macro that was gone — invisible from the app, because the dialog only ever knew
; about the selected one. The list is how you find and clear those.
ListTasks() {
    global g_macroDir
    out := []
    r := CaptureCmd('schtasks /Query /FO CSV /NH')
    if (r.code != 0)
        return out
    pre := TaskName("")            ; "Encore\"
    for line in StrSplit(r.out, "`n", "`r") {
        if !RegExMatch(line, '^"\\\Q' pre '\E([^"]+)","([^"]*)","([^"]*)"$', &m)
            continue
        out.Push(Map("name", m[1], "next", m[2], "status", m[3]
                   , "orphan", FileExist(g_macroDir "\" m[1] ".macro") ? 0 : 1))
    }
    return out
}

UiQueryTask() {
    global g_macroDir
    name := CurrentMacroName()
    info := "", exists := 0
    if (name != "") {
        r := CaptureCmd('schtasks /Query /TN "' TaskName(name) '" /FO LIST')
        exists := r.code = 0 ? 1 : 0
        info   := SubStr(r.out, 1, 500)
    }
    UiSend("window.receiveTask(" JSON.Dump(Map("exists", exists, "info", info
        , "all", ListTasks())) ")")
}

; Remove any Encore schedule by name — the dialog's list uses this, so a task
; whose macro is long gone can still be cleared.
UiRemoveTaskNamed(name) {
    name := Trim(name)
    if (name = "" || InStr(name, '"'))   ; the name goes on a command line
        return
    r := CaptureCmd('schtasks /Delete /F /TN "' TaskName(name) '"')
    Notify(r.code = 0 ? "Schedule removed: " name : "Encore: could not remove that schedule", 2000)
    UiQueryTask()
}

; Carry a schedule over to a renamed macro. schtasks cannot rename, so the task is
; exported, its macro argument repointed and re-created under the new name — and
; the old one is only deleted once the new one exists.
MoveTask(oldName, newName) {
    tmp := A_Temp "\encore_task.xml"
    try FileDelete(tmp)
    code := 1
    try code := RunWait(A_ComSpec ' /c chcp 65001>nul & schtasks /Query /TN "' TaskName(oldName) '" /XML ONE > "' tmp '" 2>&1', , "Hide")
    if (code != 0) {
        try FileDelete(tmp)
        return false               ; nothing scheduled for this macro
    }
    xml := ""
    ; cmd redirects the console output as 8-bit text even though the XML declares
    ; UTF-16, so read it as UTF-8 and write it back as what it claims to be.
    try xml := FileRead(tmp, "UTF-8")
    try FileDelete(tmp)
    if (xml = "" || !InStr(xml, '"' oldName '"'))
        return false
    xml := StrReplace(xml, '"' oldName '"', '"' newName '"')
    try FileAppend(xml, tmp, "UTF-16")
    c := CaptureCmd('schtasks /Create /F /TN "' TaskName(newName) '" /XML "' tmp '"')
    try FileDelete(tmp)
    if (c.code != 0)
        return false               ; keep the old task rather than lose the schedule
    CaptureCmd('schtasks /Delete /F /TN "' TaskName(oldName) '"')
    return true
}

UiScheduleTask(msg) {
    name := CurrentMacroName()
    if (name = "")
        return
    freq := msg.Get("freq", "DAILY")
    if (freq != "DAILY" && freq != "WEEKLY" && freq != "ONCE")
        freq := "DAILY"
    time := Trim(msg.Get("time", ""))
    if !RegExMatch(time, "^\d{2}:\d{2}$")
        time := "08:00"
    sc := ' /SC ' freq ' /ST ' time
    if (freq = "WEEKLY") {
        day := msg.Get("day", "MON")
        if !RegExMatch(day, "^(MON|TUE|WED|THU|FRI|SAT|SUN)$")
            day := "MON"
        sc .= ' /D ' day
    }
    if (freq = "ONCE") {
        date := Trim(msg.Get("date", ""))
        ; Digits and separators only. Frequency, time and weekday above are all
        ; whitelisted; the date is a free-text field in the UI, so without this it
        ; would be the one way to push extra arguments into the schtasks command
        ; line. Reject rather than silently schedule for the wrong day.
        if (date != "" && !RegExMatch(date, "^\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}$")) {
            Notify("Encore: date must look like yyyy-mm-dd", 2500)
            return
        }
        if (date != "")
            sc .= ' /SD ' date
    }
    r := CaptureCmd('schtasks /Create /F /TN "' TaskName(name) '" /TR "' RunnerCmd(name) '"' sc)
    Notify(r.code = 0 ? "Scheduled: " name : "Encore: scheduling failed — " SubStr(r.out, 1, 120), 2500)
    UiQueryTask()
}

UiRemoveTask() {
    name := CurrentMacroName()
    if (name = "")
        return
    r := CaptureCmd('schtasks /Delete /F /TN "' TaskName(name) '"')
    Notify(r.code = 0 ? "Schedule removed" : "Encore: no schedule to remove", 2000)
    UiQueryTask()
}

UiSaveMacroProps(msg) {
    global g_curProps, g_currentFile
    if (g_currentFile = "")
        return
    g_curProps := Map()
    for k in ["repeat", "pause", "speed", "mode", "hotkey", "coords"]
        if (msg.Has(k) && Trim(msg[k]) != "")
            g_curProps[k] := Trim(msg[k])
    WriteMacroFile(g_currentFile)
    InitTray()   ; also re-syncs the per-macro hotkeys
}

UiSaveSettings(msg) {
    global g_configFile, g_macroDir
    static PAIRS := Map("recordKey", "RecordHotkey", "playKey", "PlayHotkey"
        , "mode", "Mode", "speed", "Speed", "fixedDelayMs", "FixedDelayMs"
        , "repeat", "Repeat", "repeatPauseMs", "RepeatPauseMs", "anchors", "WindowAnchors"
        , "macroFolder", "MacroFolder", "countdownMs", "CountdownMs", "playbackOsd", "PlaybackOsd")
    prevDir := g_macroDir
    for k, ini in PAIRS
        if msg.Has(k)
            try IniWrite(msg[k], g_configFile, "Settings", ini)
    LoadConfig(true)
    if (g_macroDir != prevDir)
        SelectNewestMacro()
}

; After a folder change: point the selection at the newest recording in
; the new folder (or clear it when the folder is empty).
SelectNewestMacro() {
    global g_currentFile, g_events, g_curProps
    macros := ListMacros()
    if macros.Length {
        SelectMacro(macros[1].p)
        return
    }
    g_currentFile := ""
    g_events := []
    g_curProps := Map()
    InitTray()
    PushMacro()
}

; Tray path for changing the folder — the UI has Browse… in Settings.
ChangeMacroFolder(*) {
    global g_configFile, g_macroDir
    dir := ""
    try dir := DirSelect("*" g_macroDir, 3, "Choose the folder where recordings are stored")
    if (dir = "")
        return
    try IniWrite(dir, g_configFile, "Settings", "MacroFolder")
    LoadConfig(true)
    SelectNewestMacro()
}

; Notices go to the top center of the screen, away from the mouse — a
; tooltip at the pointer swallows the click the user aims right after it.
; ── Standalone export ───────────────────────────────────────────────────
; Generates a self-contained .ahk: the events as data plus a minimal
; player. Repeat/pause/speed/mode are baked in at export time (the
; recording's own overrides, falling back to the globals).
ExportStandalone(*) {
    global g_currentFile, g_events
    if (g_currentFile = "" || !g_events.Length) {
        Notify("Encore: no recording selected")
        return
    }
    base := SubStr(g_currentFile, InStr(g_currentFile, "\", , -1) + 1)
    base := SubStr(base, 1, -6)
    dest := ""
    try dest := FileSelect("S", g_macroDir "\" base ".ahk"
        , "Export as a standalone script", "AutoHotkey (*.ahk)")
    if (dest = "")
        return
    if !RegExMatch(dest, "i)\.ahk$")
        dest .= ".ahk"
    if ExportTo(dest)
        Notify("Exported: " dest, 2000)
    else
        Notify("Encore: could not export")
}

ExportTo(dest) {
    try {
        try FileDelete(dest)
        FileAppend(BuildStandalone(), dest, "UTF-8")
        return true
    } catch {
        return false
    }
}

; Escape a value for a double-quoted string in generated v2 source.
_QEsc(s) {
    s := StrReplace(s, Chr(96), Chr(96) Chr(96))
    s := StrReplace(s, '"', Chr(96) '"')
    s := StrReplace(s, "`r", "")
    s := StrReplace(s, "`n", Chr(96) "n")
    return s
}

BuildStandalone() {
    global g_events
    name := SubStr(g_currentFile, InStr(g_currentFile, "\", , -1) + 1)
    t0 := g_events[1].t
    ev := ""
    for e in g_events {
        rt := e.t - t0
        if (e.kind = "k")
            ev .= '    {k:"k", t:' rt ', vk:' e.vk ', sc:' e.sc ', up:' (e.up ? 1 : 0) '},`n'
        else if (e.kind = "m")
            ev .= '    {k:"m", t:' rt ', msg:' e.msg ', x:' e.x ', y:' e.y ', data:' e.data '},`n'
        else if (e.kind = "w")
            ev .= '    {k:"w", t:' rt ', exe:"' _QEsc(e.exe) '", title:"' _QEsc(e.title)
                . '", path:"' _QEsc(e.HasOwnProp("path") ? e.path : "") '"},`n'
        else if (e.kind = "g")
            ev .= '    {k:"g", t:' rt ', exe:"' _QEsc(e.exe) '", title:"' _QEsc(e.title)
                . '", x:' e.x ', y:' e.y ', w:' e.w ', h:' e.h ', state:' e.state '},`n'
        else if (e.kind = "t")
            ev .= '    {k:"t", t:' rt ', text:"' _QEsc(e.text) '"},`n'
        else if (e.kind = "s")
            ev .= '    {k:"s", t:' rt ', keys:"' _QEsc(e.keys) '"},`n'
        else if (e.kind = "d")
            ev .= '    {k:"d", t:' rt ', ms:' e.ms '},`n'
        else if (e.kind = "ww")
            ev .= '    {k:"ww", t:' rt ', exe:"' _QEsc(e.exe) '", title:"' _QEsc(e.title)
                . '", ms:' e.ms ', active:' e.active '},`n'
        else if (e.kind = "v")
            ev .= '    {k:"v", t:' rt ', col:' e.col '},`n'
    }
    rowsSrc := ""
    ; Only bake in the list when the macro actually consumes it: the exported script
    ; does "if rows.Length -> reps := rows.Length", so a stale .data file left beside
    ; a macro with no {value} step would silently override the repeat count.
    if MacroHasValueStep()
        for row in LoadDataRows()
            rowsSrc .= '    "' _QEsc(row) '",`n'
    tpl := "
(LTrim0
; %NAME% - exported from Encore %DATE%. Run to play back; Esc aborts.
#Requires AutoHotkey v2.0
#SingleInstance Off
CoordMode "Mouse", "Screen"
SendLevel 1

reps := %REPS%          ; 0 = until aborted
repPause := %RPAUSE%
speed := %SPEED%
mode := "%MODE%"
fixedDelay := %FIXED%
maxWait := %MAXWAIT%

ev := [
%EVENTS%]

rows := [
%ROWS%]
if rows.Length
    reps := rows.Length

if (mode = "fixed") {
    kept := []
    pending := 0
    for e in ev {
        if (e.k = "m" && e.msg = 0x200) {
            pending := e
        } else {
            if pending {
                kept.Push(pending)
                pending := 0
            }
            kept.Push(e)
        }
    }
    ev := kept
}

down := Map()
rep := 0
loop {
    rep += 1
    row := rows.Length ? rows[rep] : ""
    prevT := ev.Length ? ev[1].t : 0
    stop := false
    for e in ev {
        if GetKeyState("Escape", "P") {
            stop := true
            break
        }
        if (mode = "fixed") {
            Sleep fixedDelay
        } else {
            w := Round((e.t - prevT) / speed)
            if (w > 0)
                Sleep Min(w, maxWait)
            prevT := e.t
        }
        Replay(e, down, row)
    }
    if (stop || (reps != 0 && rep >= reps))
        break
    Sleep repPause
}
for vk, sc in down
    try Send "{" Format("vk{:X}sc{:03X}", vk, sc) " up}"
ExitApp

Replay(e, held, row) {
    static BD := Map(0x201, "Left", 0x204, "Right", 0x207, "Middle")
    static BU := Map(0x202, "Left", 0x205, "Right", 0x208, "Middle")
    static BDBL := Map(0x203, "Left", 0x206, "Right", 0x209, "Middle")
    switch e.k {
        case "v":
            parts := StrSplit(row, Chr(9))
            SendText(parts.Length >= e.col ? parts[e.col] : row)
        case "k":
            key := Format("vk{:X}sc{:03X}", e.vk, e.sc)
            Send "{" key (e.up ? " up" : " down") "}"
            if e.up {
                if held.Has(e.vk)
                    held.Delete(e.vk)
            } else {
                held[e.vk] := e.sc
            }
        case "t":
            SendText e.text
        case "s":
            try Send e.keys
        case "d":
            Sleep e.ms
        case "ww":
            crit := LTrim(e.title (e.exe != "" ? " ahk_exe " e.exe : ""))
            if (crit != "") {
                try (e.active ? WinWaitActive(crit, , e.ms / 1000.0) : WinWait(crit, , e.ms / 1000.0))
            }
        case "w":
            hwnd := 0
            try {
                if (e.title != "" && e.exe != "" && WinExist(e.title " ahk_exe " e.exe))
                    hwnd := WinExist()
                else if (e.exe != "" && WinExist("ahk_exe " e.exe))
                    hwnd := WinExist()
                else if (e.title != "" && WinExist(e.title))
                    hwnd := WinExist()
            }
            if (!hwnd && e.path != "" && FileExist(e.path)) {
                try {
                    Run(e.path)
                    if (e.exe != "" && WinWait("ahk_exe " e.exe, , 10))
                        hwnd := WinExist()
                }
            }
            if (hwnd && !WinActive(hwnd)) {
                try {
                    WinActivate(hwnd)
                    WinWaitActive(hwnd, , 2)
                }
            }
        case "g":
            hwnd := 0
            try {
                if (e.title != "" && e.exe != "" && WinExist(e.title " ahk_exe " e.exe))
                    hwnd := WinExist()
                else if (e.exe != "" && WinExist("ahk_exe " e.exe))
                    hwnd := WinExist()
            }
            if !hwnd
                return
            try {
                if (e.state = -1) {
                    WinMinimize(hwnd)
                } else if (e.state = 1) {
                    WinMaximize(hwnd)
                } else {
                    if (WinGetMinMax(hwnd) != 0)
                        WinRestore(hwnd)
                    WinMove(e.x, e.y, e.w, e.h, hwnd)
                }
            }
        case "m":
            if (e.msg = 0x200) {
                MouseMove(e.x, e.y, 0)
            } else if BDBL.Has(e.msg) {
                MouseMove(e.x, e.y, 0)
                Click BDBL[e.msg] " 2"
            } else if BD.Has(e.msg) {
                MouseMove(e.x, e.y, 0)
                Click BD[e.msg] " Down"
            } else if BU.Has(e.msg) {
                MouseMove(e.x, e.y, 0)
                Click BU[e.msg] " Up"
            } else if (e.msg = 0x20A || e.msg = 0x20E) {
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
}
)"
    tpl := StrReplace(tpl, "%NAME%", name)
    tpl := StrReplace(tpl, "%DATE%", FormatTime(, "yyyy-MM-dd"))
    tpl := StrReplace(tpl, "%REPS%", EffInt("repeat", g_repeat))
    tpl := StrReplace(tpl, "%RPAUSE%", EffInt("pause", g_repeatPauseMs))
    tpl := StrReplace(tpl, "%SPEED%", EffNum("speed", g_speed))
    tpl := StrReplace(tpl, "%MODE%", g_curProps.Get("mode", "") != "" ? g_curProps["mode"] : g_mode)
    tpl := StrReplace(tpl, "%FIXED%", g_fixedDelayMs)
    tpl := StrReplace(tpl, "%MAXWAIT%", g_maxWaitMs)
    tpl := StrReplace(tpl, "%EVENTS%", ev)
    tpl := StrReplace(tpl, "%ROWS%", rowsSrc)
    return tpl
}

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
