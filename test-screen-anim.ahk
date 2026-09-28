#Requires AutoHotkey v2.0
#SingleInstance Force
; 判断游戏画面当前是否在动：直接从屏幕取窗口区域的像素，隔5秒对比两次

CoordMode "Pixel", "Screen"
目标 := "小游戏 ahk_exe douyin.exe"
hwnd := WinExist(目标)
if !hwnd {
    FileAppend "未找到目标窗口`n", "*"
    ExitApp()
}
if DllCall("IsIconic", "Ptr", hwnd, "Int") {
    FileAppend "窗口最小化，请先还原`n", "*"
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

屏幕采样(&out, cx, cy, cw, ch) {
    out .= ""
    arr := []
    loop 6 {
        iy := A_Index
        loop 6 {
            px := cx + Round(cw * A_Index / 7), py := cy + Round(ch * iy / 7)
            arr.Push(DllCall("GetPixel", "Ptr", DllCall("GetDC", "Ptr", 0, "Ptr"), "Int", px, "Int", py, "UInt"))
        }
    }
    return arr
}

; 上面的写法每次 GetDC 泄漏了，改成先取一次 DC
取客户区(hwnd, &cx, &cy, &cw, &ch)
hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
采样() {
    global hdc, cx, cy, cw, ch
    arr := []
    loop 6 {
        iy := A_Index
        loop 6 {
            px := cx + Round(cw * A_Index / 7), py := cy + Round(ch * iy / 7)
            arr.Push(DllCall("GetPixel", "Ptr", hdc, "Int", px, "Int", py, "UInt"))
        }
    }
    return arr
}

a1 := 采样()
Sleep 5000
a2 := 采样()
d := 0
loop 36
    d += (a1[A_Index] != a2[A_Index]) ? 1 : 0
DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)

out := "屏幕直采 5 秒差异点数: " d "/36`n"
out .= "前: " Format("0x{:06X}", a1[18] & 0xFFFFFF) "  后: " Format("0x{:06X}", a2[18] & 0xFFFFFF) "`n"
FileAppend out, "*"
ExitApp()
