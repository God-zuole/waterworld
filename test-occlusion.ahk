#Requires AutoHotkey v2.0
#SingleInstance Force
; 遮挡对照实验：
;   阶段1 窗口可见时抓两帧（间隔3秒）—— 看画面有没有自然变化
;   阶段2 用不透明黑窗完全盖住，再抓两帧（间隔3秒）—— 看遮挡下画面还更不更新
; 结论输出到 stdout

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

; 后台抓帧：PrintWindow 整窗 -> 返回一组采样点的颜色数组
抓帧(hwnd, cw, ch) {
    r := Buffer(16)
    DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", r)
    ww := NumGet(r, 8, "Int") - NumGet(r, 0, "Int")
    wh := NumGet(r, 12, "Int") - NumGet(r, 4, "Int")
    hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
    mdc := DllCall("CreateCompatibleDC", "Ptr", hdc, "Ptr")
    bmp := DllCall("CreateCompatibleBitmap", "Ptr", hdc, "Int", ww, "Int", wh)
    old := DllCall("SelectObject", "Ptr", mdc, "Ptr", bmp, "Ptr")
    ok := DllCall("PrintWindow", "Ptr", hwnd, "Ptr", mdc, "UInt", 2, "Int")
    颜色 := []
    if ok {
        ; 8x8 网格采样
        loop 8 {
            iy := A_Index
            loop 8 {
                ix := A_Index
                px := Round(cw * ix / 9), py := Round(ch * iy / 9)
                cr := DllCall("GetPixel", "Ptr", mdc, "Int", px, "Int", py, "UInt")
                颜色.Push((cr = 0xFFFFFFFF) ? -1 : cr)
            }
        }
    }
    DllCall("SelectObject", "Ptr", mdc, "Ptr", old)
    DllCall("DeleteObject", "Ptr", bmp)
    DllCall("DeleteDC", "Ptr", mdc)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
    return ok ? 颜色 : []
}

差异(a, b) {
    n := (a.Length < b.Length) ? a.Length : b.Length
    d := 0
    loop n
        if (a[A_Index] != b[A_Index])
            d += 1
    return d . "/" . n
}

取客户区(hwnd, &cx, &cy, &cw, &ch)
out := ""

; ── 阶段1：可见状态 ──
f1 := 抓帧(hwnd, cw, ch)
Sleep 3000
f2 := 抓帧(hwnd, cw, ch)
out .= "可见帧1 vs 可见帧2（隔3秒）差异点数: " . 差异(f1, f2) . "`n"

; ── 阶段2：盖住 ──
cover := Gui("+AlwaysOnTop -Caption +ToolWindow", "")
cover.BackColor := "202020"
cover.Show("x" cx . " y" cy . " w" cw . " h" ch . " NA")
Sleep 500

f3 := 抓帧(hwnd, cw, ch)
Sleep 3000
f4 := 抓帧(hwnd, cw, ch)
out .= "遮挡帧1 vs 遮挡帧2（隔3秒）差异点数: " . 差异(f3, f4) . "`n"
out .= "可见帧2 vs 遮挡帧1 差异点数: " . 差异(f2, f3) . "`n"

; 采样点样例（方便肉眼对比）
out .= "遮挡帧1 中心采样: 0x" . Format("{:06X}", f3[28] & 0xFFFFFF) . "   遮挡帧2 中心采样: 0x" . Format("{:06X}", f4[28] & 0xFFFFFF) . "`n"

cover.Destroy()
FileAppend out, "*"
ExitApp()
