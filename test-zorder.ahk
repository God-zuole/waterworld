#Requires AutoHotkey v2.0
#SingleInstance Force
SetTitleMatchMode 2
CoordMode "Pixel", "Screen"

out := ""
目标 := "小游戏 ahk_exe douyin.exe"
hwnd := WinExist(目标)
if !hwnd {
    FileAppend "未找到目标窗口`n", "*"
    ExitApp()
}

取客户区(hwnd, &cx, &cy, &cw, &ch) {
    pt := Buffer(8)
    NumPut("Int", 0, "Int", 0, pt)
    DllCall("ClientToScreen", "Ptr", hwnd, "Ptr", pt)
    rect := Buffer(16)
    DllCall("GetClientRect", "Ptr", hwnd, "Ptr", rect)
    cx := NumGet(pt, 0, "Int"), cy := NumGet(pt, 4, "Int")
    cw := NumGet(rect, 8, "Int"), ch := NumGet(rect, 12, "Int")
}
取客户区(hwnd, &cx, &cy, &cw, &ch)

mx := cx + cw // 2, my := cy + ch // 2
pt := Buffer(8)
NumPut("Int", mx, "Int", my, pt)
top := DllCall("WindowFromPoint", "Int64", (my << 32) | (mx & 0xFFFFFFFF), "Ptr")
root := DllCall("GetAncestor", "Ptr", top, "UInt", 2, "Ptr")

cls := Buffer(512)
DllCall("GetClassNameW", "Ptr", root, "Ptr", cls, "Int", 256)
t := WinGetTitle("ahk_id " . root)
out .= "游戏窗口: hwnd=" hwnd "  屏幕位置(" cx "," cy ") " cw "x" ch "`n"
out .= "中心点(" mx "," my ") 最顶层窗口: hwnd=" root "  class=" StrGet(cls, "UTF-16") "  标题=[" t "]`n"
out .= "顶层窗口就是游戏自己: " ((root = hwnd) ? "是（没被挡）" : "否（被挡了）") "`n"
out .= "游戏窗口 可见=" DllCall("IsWindowVisible", "Ptr", hwnd, "Int") "  最小化=" DllCall("IsIconic", "Ptr", hwnd, "Int") "`n"

; 列出窗口矩形范围内的所有顶层窗口（按Z序），看谁压在谁上面
out .= "`n屏幕上(" cx "," cy "," cw "," ch ")区域的顶层窗口 Z 序:`n"
for id in WinGetList() {
    try {
        WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " . id)
        if (ww < 50 || wh < 50)
            continue
        ; 与游戏窗口矩形有交集才算
        if (wx < cx + cw && wx + ww > cx && wy < cy + ch && wy + wh > cy) {
            c2 := Buffer(512)
            DllCall("GetClassNameW", "Ptr", id, "Ptr", c2, "Int", 256)
            out .= "  hwnd=" id "  class=" StrGet(c2, "UTF-16") "  标题=[" WinGetTitle("ahk_id " . id) "]  位置(" wx "," wy ") " ww "x" wh "`n"
        }
    }
}

FileAppend out, "*"
ExitApp()
