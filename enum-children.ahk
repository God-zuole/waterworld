#Requires AutoHotkey v2.0
; 枚举目标窗口的子窗口层级（类名 + 句柄），诊断消息点击该发给谁
#SingleInstance Force
SetTitleMatchMode 2

out := ""
try {
    目标 := "小游戏 ahk_exe douyin.exe"
    hwnd := WinExist(目标)
    if !hwnd
        throw Error("未找到目标窗口")

    out .= "顶层: hwnd=" hwnd "  class=" WinGetClass("ahk_id " hwnd) "  标题=" WinGetTitle("ahk_id " hwnd) "`n"

    枚举(parent, 深度) {
        global out
        child := 0
        loop {
            child := DllCall("FindWindowExW", "Ptr", parent, "Ptr", child, "Ptr", 0, "Ptr", 0, "Ptr")
            if !child
                break
            cls := Buffer(512)
            DllCall("GetClassNameW", "Ptr", child, "Ptr", cls, "Int", 256)
            classname := StrGet(cls, "UTF-16")
            rect := Buffer(16)
            DllCall("GetClientRect", "Ptr", child, "Ptr", rect)
            w := NumGet(rect, 8, "Int"), h := NumGet(rect, 12, "Int")
            缩进 := ""
            loop 深度+1
                缩进 .= "  "
            out .= 缩进 "hwnd=" child "  class=" classname "  客户区 " w "x" h "`n"
            if (深度 < 3)
                枚举(child, 深度+1)
        }
    }

    枚举(hwnd, 0)
} catch as e {
    out .= "错误: " e.Message "`n"
}
FileAppend out, "*"
ExitApp()
