#Requires AutoHotkey v2.0
; Minimal JSON for AHK v2 — enough for the Anthropic Messages API.
;   JSON.Dump(value) : Map -> object, Array -> array, String/Number -> literal.
;                      Non-ASCII is emitted as \uXXXX so the body survives WinHttp.
;   JSON.Load(text)  : object -> Map, array -> Array, true/false -> 1/0, null -> "".
; Not a full validator; assumes well-formed input (API responses are).

class JSON {
    static _s := "", _i := 1, _n := 0
    ; AHK has no native bool — use these sentinels where JSON needs true/false
    static _true  := { __jb: "true" }
    static _false := { __jb: "false" }

    static Dump(val) {
        t := Type(val)
        if (t = "Object" && val.HasOwnProp("__jb"))
            return val.__jb
        if (t = "Map") {
            s := "{", first := true
            for k, v in val {
                s .= (first ? "" : ",") . JSON._EncStr(k . "") . ":" . JSON.Dump(v)
                first := false
            }
            return s . "}"
        }
        if (t = "Array") {
            s := "[", first := true
            for v in val {
                s .= (first ? "" : ",") . JSON.Dump(v)
                first := false
            }
            return s . "]"
        }
        if (t = "String")
            return JSON._EncStr(val)
        if (t = "Integer" || t = "Float")
            return val . ""
        return "null"
    }

    static _EncStr(s) {
        out := '"'
        Loop Parse, s {
            c := A_LoopField, o := Ord(c)
            if (c = '"')
                out .= '\"'
            else if (c = "\")
                out .= "\\"
            else if (o = 8)
                out .= "\b"
            else if (o = 9)
                out .= "\t"
            else if (o = 10)
                out .= "\n"
            else if (o = 12)
                out .= "\f"
            else if (o = 13)
                out .= "\r"
            else if (o < 32 || o > 126)
                out .= Format("\u{:04x}", o)
            else
                out .= c
        }
        return out . '"'
    }

    static Load(text) {
        JSON._s := text, JSON._i := 1, JSON._n := StrLen(text)
        return JSON._Val()
    }

    static _Val() {
        JSON._Ws()
        c := SubStr(JSON._s, JSON._i, 1)
        if (c = "{")
            return JSON._Obj()
        if (c = "[")
            return JSON._Arr()
        if (c = '"')
            return JSON._Str()
        if (c = "t") {
            JSON._i += 4
            return true
        }
        if (c = "f") {
            JSON._i += 5
            return false
        }
        if (c = "n") {
            JSON._i += 4
            return ""
        }
        return JSON._Num()
    }

    static _Ws() {
        while (JSON._i <= JSON._n) {
            c := SubStr(JSON._s, JSON._i, 1)
            if (c = " " || c = "`t" || c = "`n" || c = "`r")
                JSON._i++
            else
                break
        }
    }

    static _Obj() {
        m := Map()
        JSON._i++                       ; skip {
        JSON._Ws()
        if (SubStr(JSON._s, JSON._i, 1) = "}") {
            JSON._i++
            return m
        }
        loop {
            JSON._Ws()
            key := JSON._Str()
            JSON._Ws()
            JSON._i++                   ; skip :
            m[key] := JSON._Val()
            JSON._Ws()
            c := SubStr(JSON._s, JSON._i, 1)
            JSON._i++                   ; skip , or }
            if (c = "}")
                break
        }
        return m
    }

    static _Arr() {
        a := []
        JSON._i++                       ; skip [
        JSON._Ws()
        if (SubStr(JSON._s, JSON._i, 1) = "]") {
            JSON._i++
            return a
        }
        loop {
            a.Push(JSON._Val())
            JSON._Ws()
            c := SubStr(JSON._s, JSON._i, 1)
            JSON._i++                   ; skip , or ]
            if (c = "]")
                break
        }
        return a
    }

    static _Str() {
        JSON._i++                       ; skip opening "
        out := ""
        while (JSON._i <= JSON._n) {
            c := SubStr(JSON._s, JSON._i, 1)
            JSON._i++
            if (c = '"')
                break
            if (c = "\") {
                e := SubStr(JSON._s, JSON._i, 1)
                JSON._i++
                switch e {
                    case '"': out .= '"'
                    case "\": out .= "\"
                    case "/": out .= "/"
                    case "b": out .= Chr(8)
                    case "t": out .= Chr(9)
                    case "n": out .= "`n"
                    case "f": out .= Chr(12)
                    case "r": out .= "`r"
                    case "u":
                        hex := SubStr(JSON._s, JSON._i, 4)
                        JSON._i += 4
                        out .= Chr(Integer("0x" . hex))
                    default: out .= e
                }
            } else {
                out .= c
            }
        }
        return out
    }

    static _Num() {
        start := JSON._i
        while (JSON._i <= JSON._n) {
            c := SubStr(JSON._s, JSON._i, 1)
            if (InStr("0123456789+-.eE", c))
                JSON._i++
            else
                break
        }
        numStr := SubStr(JSON._s, start, JSON._i - start)
        if (numStr = "" || !IsNumber(numStr))        ; malformed/empty token → 0 (don't crash)
            return 0
        if (InStr(numStr, ".") || InStr(numStr, "e") || InStr(numStr, "E"))
            return numStr + 0.0
        return Integer(numStr)
    }
}
