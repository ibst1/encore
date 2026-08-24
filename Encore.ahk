; Encore — v1.2.0 (2026-08-24)
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
#SingleInstance Force
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
    for hk in ["~*WheelUp", "~*WheelDown", "~*WheelLeft", "~*WheelRight"]
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
        g_events.Push({t: A_TickCount, kind: "m", msg: 0x200, x: mx, y: my, data: 0})
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
                , x: mx, y: my, data: def[3], cls: cls})
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
    global g_playing, g_stopPlay
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
    InitTray()
    ; wait until the play hotkey's own modifiers are physically released —
    ; a still-held Win/Ctrl would combine with the replayed keys
    for m in ["LWin", "RWin", "LShift", "RShift", "LCtrl", "RCtrl", "LAlt", "RAlt"]
        KeyWait m, "T2"
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
    Notify("▶ Playing " g_events.Length " events"
        (reps = 0 ? " (until aborted)" : reps > 1 ? " ×" reps : "") "…", 1500)
    SendLevel 1   ; replayed input is visible to other AHK scripts, like real typing
    list := (mode = "fixed") ? FixedModeList() : g_events
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
                    if e.up
                        downKeys.Delete(e.vk)
                    else
                        downKeys[e.vk] := e.sc
                } else if (e.kind = "w") {
                    ReplayWindowSwitch(e)
                } else if (e.kind = "g") {
                    ReplayGeometry(e)
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
    static DBL  := Map(0x203, "Left", 0x206, "Right", 0x209, "Middle")
    if (e.msg = 0x200) {                       ; move
        MouseMove(e.x, e.y, 0)
    } else if DBL.Has(e.msg) {                 ; fused double-click
        MouseMove(e.x, e.y, 0)
        Click DBL[e.msg] " 2"
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
    hwnd := FindTargetWindow(e)
    if (!hwnd && e.HasOwnProp("path") && e.path != "" && FileExist(e.path)) {
        try {
            Run(e.path)
            if (e.exe != "" && WinWait("ahk_exe " e.exe, , 10))
                hwnd := WinExist()
        }
    }
    if (!hwnd || WinActive(hwnd))
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
            . "`t" g_curProps.Get("speed", "") "`t" g_curProps.Get("mode", "") "`n"
    for e in g_events {
        if (e.kind = "k")
            out .= "k`t" e.t "`t" e.vk "`t" e.sc "`t" (e.up ? 1 : 0) "`n"
        else if (e.kind = "w")
            out .= "w`t" e.t "`t" e.exe "`t" e.title "`t" (e.HasOwnProp("path") ? e.path : "") "`n"
        else if (e.kind = "g")
            out .= "g`t" e.t "`t" e.exe "`t" e.title "`t" e.x "`t" e.y "`t" e.w "`t" e.h "`t" e.state "`n"
        else
            out .= "m`t" e.t "`t" e.msg "`t" e.x "`t" e.y "`t" e.data "`n"
    }
    try FileDelete(path)
    try FileAppend(out, path, "UTF-8")
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
                for i, k in ["repeat", "pause", "speed", "mode"]
                    if (f[i + 1] != "")
                        g_curProps[k] := f[i + 1]
            } else if (f.Length >= 5 && f[1] = "k")
                g_events.Push({t: Integer(f[2]), kind: "k", vk: Integer(f[3])
                    , sc: Integer(f[4]), up: f[5] = "1"})
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
;   Esc - aborts; pressing it during recording stops the recording.
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
    recsMenu.Add("Name recording…", NameRecording)
    recsMenu.Add("Save copy as…", SaveCopyAs)
    recsMenu.Add("Load macro file…", LoadMacroDialog)
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
        g_currentFile := newPath
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
        DllCall("shell32\SetCurrentProcessExplicitAppUserModelID", "str", "Encore.Application.1")
        g_uiWin := Gui("+Resize +MinSize640x420", "Encore")
        g_uiWin.OnEvent("Close", (*) => g_uiWin.Hide())
        g_uiWin.OnEvent("Size", UiResize)
        g_uiWin.Show("w980 h640")
        DllCall("dwmapi\DwmSetWindowAttribute", "ptr", g_uiWin.hwnd, "uint", 20, "int*", 1, "uint", 4)
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
    }
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
        case "deleteEvents": UiDeleteEvents(msg["ranges"])
        case "saveMacroSettings": UiSaveMacroProps(msg)
        case "saveSettings": UiSaveSettings(msg)
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
    st := Map("recordings", list, "current", cur
        , "recording", g_recording ? 1 : 0, "playing", g_playing ? 1 : 0
        , "macroProps", props
        , "settings", Map("recordKey", g_recordKey, "playKey", g_playKey
            , "mode", g_mode, "speed", g_speed, "fixedDelayMs", g_fixedDelayMs
            , "repeat", g_repeat, "repeatPauseMs", g_repeatPauseMs
            , "anchors", g_windowAnchors ? 1 : 0))
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
        else
            arr.Push(Map("kind", "m", "t", e.t, "msg", e.msg, "x", e.x, "y", e.y, "data", e.data))
    }
    payload := Map("events", arr, "truncated", g_events.Length > cap ? 1 : 0)
    UiSend("window.receiveMacro(" JSON.Dump(payload) ")")
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
    try {
        FileMove(src, dst)
        if (g_currentFile = src)
            g_currentFile := dst
    }
    InitTray()
}

UiDelete(name) {
    global g_currentFile, g_events, g_curProps
    if (g_recording || g_playing)
        return
    p := g_macroDir "\" name ".macro"
    try FileDelete(p)
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

UiSaveMacroProps(msg) {
    global g_curProps, g_currentFile
    if (g_currentFile = "")
        return
    g_curProps := Map()
    for k in ["repeat", "pause", "speed", "mode"]
        if (msg.Has(k) && Trim(msg[k]) != "")
            g_curProps[k] := Trim(msg[k])
    WriteMacroFile(g_currentFile)
    InitTray()
}

UiSaveSettings(msg) {
    global g_configFile
    static PAIRS := Map("recordKey", "RecordHotkey", "playKey", "PlayHotkey"
        , "mode", "Mode", "speed", "Speed", "fixedDelayMs", "FixedDelayMs"
        , "repeat", "Repeat", "repeatPauseMs", "RepeatPauseMs", "anchors", "WindowAnchors")
    for k, ini in PAIRS
        if msg.Has(k)
            try IniWrite(msg[k], g_configFile, "Settings", ini)
    LoadConfig(true)
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
