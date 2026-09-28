#Requires AutoHotkey v2.0
#SingleInstance Force
SetTitleMatchMode 2
; 挂边有效性验证：
;   1. 记录窗口原位
;   2. 挂边（挪到右缘露6px + 置顶，此时 WorkBuddy 全屏盖着其他区域）
;   3. 抓帧A -> 消息点击规则1的点击点 -> 等1.5秒 -> 抓帧B
;   4. 若 B != A，说明遮挡+挂边状态下画面仍在实时更新
;   5. 还原窗口原位
; 全程消息点击，不动真实鼠标

CoordMode "Pixel", "Screen"
配置文件 := A_ScriptDir "\color-click.ini"

读配置() {
    m := Map()
    if !FileExist(配置文件)
        return m
    try {
        txt := FileRead(配置文件, "UTF-8")
    } catch {
        return m
    }
    for line in StrSplit(txt, "`n", "`r") {
        line := Trim(line)
        if (line = "")
            continue
        h := SubStr(line, 1, 1)
        if (h = ";" || h = "#")
            continue
        p := InStr(line, "=")
        if !p
            continue
        m[Trim(SubStr(line, 1, p - 1))] := Trim(SubStr(line, p + 1))
    }
    return m
}

m := 读配置()
hwnd := WinExist(m["目标窗口"])
if !hwnd {
    FileAppend "未找到目标窗口`n", "*"
    ExitApp()
}
if DllCall("IsIconic", "Ptr", hwnd, "Int")
    WinRestore("ahk_id " . hwnd)

取客户区(hwnd, &cx, &cy, &cw, &ch) {
    pt := Buffer(8)
    NumPut("Int", 0, "Int", 0, pt)
    DllCall("ClientToScreen", "Ptr", hwnd, "Ptr", pt)
    rect := Buffer(16)
    DllCall("GetClientRect", "Ptr", hwnd, "Ptr", rect)
    cx := NumGet(pt, 0, "Int"), cy := NumGet(pt, 4, "Int")
    cw := NumGet(rect, 8, "Int"), ch := NumGet(rect, 12, "Int")
}

抓帧(hwnd, cw, ch) {
    r := Buffer(16)
    DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", r)
    ww := NumGet(r, 8, "Int") - NumGet(r, 0, "Int")
    wh := NumGet(r, 12, "Int") - NumGet(r, 4, "Int")
    hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
    mdc := DllCall("CreateCompatibleDC", "Ptr", hdc, "Ptr")
    bmp := DllCall("CreateCompatibleBitmap", "Ptr", hdc, "Int", ww, "Int", wh)
    old := DllCall("SelectObject", "Ptr", mdc, "Ptr", bmp, "Ptr")
    DllCall("PrintWindow", "Ptr", hwnd, "Ptr", mdc, "UInt", 2, "Int")
    arr := []
    loop 8 {
        iy := A_Index
        loop 8
            arr.Push(DllCall("GetPixel", "Ptr", mdc, "Int", Round(cw * A_Index / 9), "Int", Round(ch * iy / 9), "UInt"))
    }
    DllCall("SelectObject", "Ptr", mdc, "Ptr", old)
    DllCall("DeleteObject", "Ptr", bmp)
    DllCall("DeleteDC", "Ptr", mdc)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
    return arr
}

差异(a, b) {
    d := 0
    loop a.Length
        d += (a[A_Index] != b[A_Index]) ? 1 : 0
    return d . "/" . a.Length
}

; 找 Chrome_RenderWidgetHostHWND
找RWH(hwnd) {
    child := 0
    loop {
        child := DllCall("FindWindowExW", "Ptr", hwnd, "Ptr", child, "Ptr", 0, "Ptr", 0, "Ptr")
        if !child
            return 0
        cls := Buffer(512)
        DllCall("GetClassNameW", "Ptr", child, "Ptr", cls, "Int", 256)
        if (StrGet(cls, "UTF-16") = "Chrome_RenderWidgetHostHWND")
            return child
    }
}

out := ""
try {
    取客户区(hwnd, &cx, &cy, &cw, &ch)

    ; 1) 记录原位并挂边
    WinGetPos(&ox, &oy, &ow, &oh, "ahk_id " . hwnd)
    DllCall("MoveWindow", "Ptr", hwnd, "Int", A_ScreenWidth - 6, "Int", oy, "Int", ow, "Int", oh, "Int", 1)
    WinSetAlwaysOnTop(true, "ahk_id " . hwnd)
    Sleep 800

    fA := 抓帧(hwnd, cw, ch)
    Sleep 1000
    fA2 := 抓帧(hwnd, cw, ch)
    out .= "挂边且被遮挡时，静置1秒差异: " . 差异(fA, fA2) . "`n"

    ; 2) 消息点击规则1点击点 (52.65%, 82.31%)
    rwh := 找RWH(hwnd)
    lpX := Round(cw * 52.65 / 100)
    lpY := Round(ch * 82.31 / 100)
    lp := ((lpY & 0xFFFF) << 16) | (lpX & 0xFFFF)
    if rwh {
        PostMessage(0x0200, 0,      lp, , "ahk_id " . rwh)
        Sleep 10
        PostMessage(0x0201, 0x0001, lp, , "ahk_id " . rwh)
        Sleep 10
        PostMessage(0x0202, 0,      lp, , "ahk_id " . rwh)
        out .= "已向渲染子窗口发消息点击 (" lpX "," lpY ")`n"
    } else {
        out .= "未找到渲染子窗口，点击跳过`n"
    }
    Sleep 1500

    fB := 抓帧(hwnd, cw, ch)
    out .= "点击后1.5秒差异(对比点击前): " . 差异(fA, fB) . "`n"
} catch as e {
    out .= "错误: " e.Message " @ line " e.Line "`n"
} finally {
    ; 3) 还原
    try {
        DllCall("MoveWindow", "Ptr", hwnd, "Int", ox, "Int", oy, "Int", ow, "Int", oh, "Int", 1)
        WinSetAlwaysOnTop(false, "ahk_id " . hwnd)
        out .= "窗口已还原原位`n"
    }
}
FileAppend out, "*"
ExitApp()
