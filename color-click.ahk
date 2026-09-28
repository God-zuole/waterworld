#Requires AutoHotkey v2.0
#SingleInstance Force

; ══════════════════════════════════════════════════════════════
;  颜色触发点击器（窗口相对坐标 + 后台运行版）  color-click.ahk
;
;  逻辑：逐条检查「监视点」，颜色匹配就点对应的「点击点」
;        多条规则各自独立判断、独立冷却、独立计数
; ──────────────────────────────────────────────────────────────
;  两种取色方式（配置：取色方式）
;    后台 = 用 PrintWindow 把窗口画面抓进内存再取色
;           · 窗口被别的程序盖住、不是活动窗口 —— 都照常工作
;           · 唯一要求：窗口别最小化（最小化后画面抓不到）
;           · 不抢焦点、不动鼠标，你可以随便干别的
;    屏幕 = 老方式，从屏幕上直接取色
;           · 窗口必须露在最前面，被挡住就取到遮挡物的颜色
;           · 可用「要求窗口激活=1」让它只在窗口在最前时才工作
;
;  两种点击方式（配置：点击方式）
;    消息 = 往窗口发鼠标消息，不抢焦点、不动真实光标
;           · 实测 CEF/Chromium 内核响应正常，遮挡时也生效
;    前台 = 把窗口拉到前台，用真实鼠标点击，点完可还原原窗口
;           · 万一个别程序不认消息点击，用这个兜底
; ──────────────────────────────────────────────────────────────
;  热键
;    F1           开始 / 停止（每次开始都会重读配置，状态干净）
;    F2           退出
;    Ctrl+Alt+L   显示 / 隐藏监控日志窗口（点窗口的 X 也是隐藏）
;    Ctrl+Alt+0   重新载入配置
;
;  监控日志窗口
;    可拖动、可缩放、始终置顶；位置记在 ini 里，下次启动还在原地。
;    隐藏后脚本照常工作，只是不再占屏幕。
; ──────────────────────────────────────────────────────────────
;  坐标体系：窗口客户区百分比（0-100）
;    监视点/点击点存的是「相对窗口客户区宽/高的百分比」，
;    每轮运行时实时探测目标窗口的尺寸，换算成窗口内坐标，
;    再取色/点击。窗口随便拖动、缩放、换机器都不用重新标定。
;
;  标定工具：pick-relative.ahk
;
;  注意：不用 AHK 内置 IniRead/IniWrite —— 它们底层是 Windows 的
;        INI 接口，只认 ANSI / UTF-16，遇到「UTF-8 + 中文键名」会
;        读不到。这里自己按行解析，编码全程 UTF-8。
; ══════════════════════════════════════════════════════════════

SetTitleMatchMode 2

CoordMode "Mouse",   "Screen"
CoordMode "Pixel",   "Screen"
CoordMode "ToolTip", "Screen"

配置文件 := A_ScriptDir "\color-click.ini"

通用 := {
    取色方式: "后台",
    点击方式: "消息",
    点击后还原: true,
    最小化自动还原: true,
    检查间隔: 1000,
    点击后等待: 800,
    最大点击数: 0,
    颜色容差: 12,
    触发模式: "edge",
    要求窗口激活: false,
    目标窗口: "ahk_exe douyin.exe"
}

规则集       := []
运行中       := false
点击总数     := 0
当前规则     := 1
上次提示时刻 := 0
本轮颜色     := []
本轮备注     := ""
本轮客户区   := {x:0, y:0, w:0, h:0}

; 监控日志窗口
日志Gui      := ""
日志Text     := ""
日志可见     := true
日志位置X    := 20
日志位置Y    := 20
日志行数     := 0
最近触发     := ""

; ══════════════════════════════════════════════════════════════
;  颜色 / 几何工具
; ══════════════════════════════════════════════════════════════
颜色匹配(c1, c2, tol) {
    if (c1 < 0 || c2 < 0)
        return false
    r1 := (c1 >> 16) & 0xFF
    g1 := (c1 >> 8)  & 0xFF
    b1 := c1 & 0xFF
    r2 := (c2 >> 16) & 0xFF
    g2 := (c2 >> 8)  & 0xFF
    b2 := c2 & 0xFF
    return Abs(r1 - r2) <= tol && Abs(g1 - g2) <= tol && Abs(b1 - b2) <= tol
}

颜色文本(c) {
    return (c < 0) ? "——" : Format("0x{:06X}", c & 0xFFFFFF)
}

; 取窗口客户区在屏幕上的原点和大小
取客户区(hwnd, &cx, &cy, &cw, &ch) {
    pt := Buffer(8)
    NumPut("Int", 0, "Int", 0, pt)
    DllCall("ClientToScreen", "Ptr", hwnd, "Ptr", pt)
    cx := NumGet(pt, 0, "Int")
    cy := NumGet(pt, 4, "Int")
    rect := Buffer(16)
    DllCall("GetClientRect", "Ptr", hwnd, "Ptr", rect)
    cw := NumGet(rect, 8, "Int")
    ch := NumGet(rect, 12, "Int")
}

; 一次性拿到窗口和客户区的所有几何信息
取几何(hwnd, &wx, &wy, &ww, &wh, &offx, &offy, &cw, &ch) {
    r := Buffer(16)
    DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", r)
    wx := NumGet(r, 0, "Int")
    wy := NumGet(r, 4, "Int")
    ww := NumGet(r, 8, "Int")  - wx
    wh := NumGet(r, 12, "Int") - wy
    取客户区(hwnd, &cx, &cy, &cw, &ch)
    offx := cx - wx
    offy := cy - wy
}

; ══════════════════════════════════════════════════════════════
;  后台取色：PrintWindow 把窗口画进内存位图，再逐点 GetPixel
;  点集格式：数组，每项 {x, y}，坐标是「窗口内坐标（含边框）」
;  返回：与点集等长的颜色数组（RGB 0xRRGGBB）；取不到的填 -1
; ══════════════════════════════════════════════════════════════
后台取色(hwnd, 点集) {
    结果 := []
    n := 点集.Length
    if (n = 0)
        return 结果

    r := Buffer(16)
    DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", r)
    ww := NumGet(r, 8, "Int")  - NumGet(r, 0, "Int")
    wh := NumGet(r, 12, "Int") - NumGet(r, 4, "Int")
    if (ww < 1 || wh < 1) {
        loop n
            结果.Push(-1)
        return 结果
    }

    hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
    mdc := DllCall("gdi32\CreateCompatibleDC", "Ptr", hdc, "Ptr")
    bmp := DllCall("gdi32\CreateCompatibleBitmap", "Ptr", hdc, "Int", ww, "Int", wh)
    old := DllCall("gdi32\SelectObject", "Ptr", mdc, "Ptr", bmp, "Ptr")

    ; 2 = PW_RENDERFULLCONTENT，CEF/Chromium 必须用这个标志才有画面
    ok := DllCall("user32\PrintWindow", "Ptr", hwnd, "Ptr", mdc, "UInt", 2, "Int")

    if ok {
        for p in 点集 {
            cr := DllCall("gdi32\GetPixel", "Ptr", mdc, "Int", p.x, "Int", p.y, "UInt")
            if (cr = 0xFFFFFFFF) {          ; CLR_INVALID
                结果.Push(-1)
            } else {
                ; COLORREF 是 0x00BBGGRR，转成统一的 0xRRGGBB
                结果.Push(((cr & 0xFF) << 16) | (((cr >> 8) & 0xFF) << 8) | ((cr >> 16) & 0xFF))
            }
        }
    } else {
        loop n
            结果.Push(-1)
    }

    DllCall("gdi32\SelectObject", "Ptr", mdc, "Ptr", old)
    DllCall("gdi32\DeleteObject", "Ptr", bmp)
    DllCall("gdi32\DeleteDC", "Ptr", mdc)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
    return 结果
}

; ══════════════════════════════════════════════════════════════
;  找出真正接收鼠标消息的窗口
;  Chromium/CEF 内核（抖音小游戏就是）的鼠标输入实际由子窗口
;  Chrome_RenderWidgetHostHWND 处理，发给顶层窗口是没反应的。
;  找不到该子窗口时，沿子窗口层级下钻找包含该点的最深窗口兜底。
;  入参 cx,cy 是顶层客户区坐标；出参 tx,ty 是目标窗口客户区坐标
; ══════════════════════════════════════════════════════════════
找消息目标(hwnd, cx, cy, &thwnd, &tx, &ty) {
    ; 顶层客户区坐标 -> 屏幕坐标
    pt := Buffer(8)
    NumPut("Int", cx, "Int", cy, pt)
    DllCall("ClientToScreen", "Ptr", hwnd, "Ptr", pt)
    sx := NumGet(pt, 0, "Int")
    sy := NumGet(pt, 4, "Int")

    thwnd := hwnd

    ; 1) Chromium 系：直接找 Chrome_RenderWidgetHostHWND
    rwh := 0
    child := 0
    loop {
        child := DllCall("FindWindowExW", "Ptr", hwnd, "Ptr", child, "Ptr", 0, "Ptr", 0, "Ptr")
        if !child
            break
        cls := Buffer(512)
        DllCall("GetClassNameW", "Ptr", child, "Ptr", cls, "Int", 256)
        if (StrGet(cls, "UTF-16") = "Chrome_RenderWidgetHostHWND") {
            rwh := child
            break
        }
    }
    if rwh {
        thwnd := rwh
    } else {
        ; 2) 兜底：逐层下钻，找包含该点的最深子窗口
        cur := hwnd
        loop 6 {
            ptc := Buffer(8)
            NumPut("Int", sx, "Int", sy, ptc)
            DllCall("ScreenToClient", "Ptr", cur, "Ptr", ptc)
            lx := NumGet(ptc, 0, "Int")
            ly := NumGet(ptc, 4, "Int")
            ; POINT 按值传参：低 32 位 x、高 32 位 y
            deeper := DllCall("ChildWindowFromPoint", "Ptr", cur, "Int64", (ly << 32) | (lx & 0xFFFFFFFF), "Ptr")
            if !deeper || (deeper = cur)
                break
            cur := deeper
        }
        if (cur != hwnd)
            thwnd := cur
    }

    ; 屏幕坐标 -> 目标窗口客户区坐标
    pt2 := Buffer(8)
    NumPut("Int", sx, "Int", sy, pt2)
    DllCall("ScreenToClient", "Ptr", thwnd, "Ptr", pt2)
    tx := NumGet(pt2, 0, "Int")
    ty := NumGet(pt2, 4, "Int")
}

; ══════════════════════════════════════════════════════════════
;  点击：cx, cy 是「窗口内坐标」，sx, sy 是对应的屏幕坐标
; ══════════════════════════════════════════════════════════════
点击(hwnd, cx, cy, sx, sy) {
    global 通用

    if (通用.点击方式 = "消息") {
        找消息目标(hwnd, cx, cy, &thwnd, &tx, &ty)
        lp := ((ty & 0xFFFF) << 16) | (tx & 0xFFFF)
        PostMessage(0x0200, 0,      lp, , "ahk_id " . thwnd)   ; WM_MOUSEMOVE
        Sleep 10
        PostMessage(0x0201, 0x0001, lp, , "ahk_id " . thwnd)   ; WM_LBUTTONDOWN
        Sleep 10
        PostMessage(0x0202, 0,      lp, , "ahk_id " . thwnd)   ; WM_LBUTTONUP
        return "消息"
    }

    ; 前台模式：拉窗口到最前，用真实鼠标点，点完把原窗口还回去
    原前台 := 0
    try 原前台 := WinExist("A")
    WinActivate("ahk_id " . hwnd)
    if !WinWaitActive("ahk_id " . hwnd, , 1.2)
        return "失败"
    Sleep 60
    Click(sx, sy)
    Sleep 60
    if (通用.点击后还原 && 原前台 && 原前台 != hwnd)
        WinActivate("ahk_id " . 原前台)
    return "前台"
}

; ══════════════════════════════════════════════════════════════
;  配置解析（自己实现，不用 IniRead）
; ══════════════════════════════════════════════════════════════
读配置() {
    global 配置文件
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
        head := SubStr(line, 1, 1)
        if (head = ";" || head = "#")
            continue
        p := InStr(line, "=")
        if !p
            continue
        m[Trim(SubStr(line, 1, p - 1))] := Trim(SubStr(line, p + 1))
    }
    return m
}

取整(m, k, d) {
    return m.Has(k) ? Integer(m[k]) : d
}

取浮(m, k, d) {
    return m.Has(k) ? Round(Number(m[k]), 2) : d
}

取串(m, k, d) {
    return m.Has(k) ? m[k] : d
}

加载配置(静默 := false) {
    global 通用, 规则集, 配置文件, 日志位置X, 日志位置Y

    m := 读配置()
    if (m.Count = 0) {
        if !静默
            MsgBox("配置文件不存在或为空：`n" . 配置文件, "缺少配置", "Icon!")
        return false
    }

    通用.取色方式     := 取串(m, "取色方式",   "后台")
    通用.点击方式     := 取串(m, "点击方式",   "消息")
    通用.点击后还原   := (取整(m, "点击后还原", 1) = 1)
    通用.最小化自动还原 := (取整(m, "最小化自动还原", 1) = 1)
    通用.检查间隔     := 取整(m, "检查间隔",   1000)
    通用.点击后等待   := 取整(m, "点击后等待", 800)
    通用.最大点击数   := 取整(m, "最大点击数", 0)
    通用.颜色容差     := 取整(m, "颜色容差",   12)
    通用.触发模式     := 取串(m, "触发模式",   "edge")
    通用.要求窗口激活 := (取整(m, "要求窗口激活", 0) = 1)
    通用.目标窗口     := 取串(m, "目标窗口",   "ahk_exe douyin.exe")

    ; 监控日志窗口的上次位置
    日志位置X := 取整(m, "日志位置X", 20)
    日志位置Y := 取整(m, "日志位置Y", 20)

    规则集 := []
    loop 取整(m, "规则数", 0) {
        i := A_Index
        规则集.Push({
            监视点RX: 取浮(m, "规则" . i . "监视点RX", -1),
            监视点RY: 取浮(m, "规则" . i . "监视点RY", -1),
            目标颜色: 取整(m, "规则" . i . "目标颜色", -1),
            点击点RX: 取浮(m, "规则" . i . "点击点RX", -1),
            点击点RY: 取浮(m, "规则" . i . "点击点RY", -1),
            启用: (取整(m, "规则" . i . "启用", 1) = 1),
            上次匹配: false,
            上次点击时刻: 0,
            点击数: 0
        })
    }
    return 规则集.Length > 0
}

保存配置() {
    global 通用, 规则集, 配置文件
    L := []
    L.Push("; color-click.ahk 配置文件")
    L.Push("; 颜色写 0xRRGGBB（和取色结果一致），-1 = 未标定")
    L.Push("; 坐标写「窗口客户区百分比」数值（0-100），")
    L.Push(";   例：RX=50 表示客户区宽度的一半；RY=90 表示靠下的位置")
    L.Push("; 用 pick-relative.ahk 标定，脚本运行时按当前窗口大小实时换算")
    L.Push("; 改完在脚本里按 Ctrl+Alt+0 重新载入，或按 F1 重开")
    L.Push("")
    L.Push("; ─── 运行方式 ───")
    L.Push("; 取色方式：后台 = 抓窗口画面（窗口被盖住也能用，别最小化）")
    L.Push(";           屏幕 = 从屏幕取色（窗口必须在最前）")
    L.Push("取色方式=" . 通用.取色方式)
    L.Push("; 点击方式：消息 = 发鼠标消息，不抢焦点")
    L.Push(";           前台 = 拉窗口到前台真实点击，点完还原原窗口")
    L.Push("点击方式=" . 通用.点击方式)
    L.Push("; 仅「前台」模式有效：点完是否把原来那个窗口还原到前台")
    L.Push("点击后还原=" . (通用.点击后还原 ? 1 : 0))
    L.Push("; 后台模式专用：窗口被最小化时自动还原（最小化状态抓不到画面，")
    L.Push(";   还原后被别的窗口盖住没关系）。0 = 最小化就暂停并提示")
    L.Push("最小化自动还原=" . (通用.最小化自动还原 ? 1 : 0))
    L.Push("")
    L.Push("; ─── 通用 ───")
    L.Push("检查间隔=" . 通用.检查间隔)
    L.Push("点击后等待=" . 通用.点击后等待)
    L.Push("最大点击数=" . 通用.最大点击数)
    L.Push("颜色容差=" . 通用.颜色容差)
    L.Push("触发模式=" . 通用.触发模式)
    L.Push("; 仅「屏幕」取色方式有效：1 = 窗口不在最前就暂停")
    L.Push("要求窗口激活=" . (通用.要求窗口激活 ? 1 : 0))
    L.Push("目标窗口=" . 通用.目标窗口)
    L.Push("规则数=" . 规则集.Length)
    for i, r in 规则集 {
        L.Push("")
        L.Push("; ─── 规则 " . i . " ───")
        L.Push("规则" . i . "监视点RX=" . Format("{:.2f}", r.监视点RX))
        L.Push("规则" . i . "监视点RY=" . Format("{:.2f}", r.监视点RY))
        L.Push("规则" . i . "目标颜色=" . ((r.目标颜色 < 0) ? "-1" : Format("0x{:06X}", r.目标颜色)))
        L.Push("规则" . i . "点击点RX=" . Format("{:.2f}", r.点击点RX))
        L.Push("规则" . i . "点击点RY=" . Format("{:.2f}", r.点击点RY))
        L.Push("规则" . i . "启用=" . (r.启用 ? 1 : 0))
    }
    txt := ""
    for l in L
        txt .= l . "`r`n"
    try {
        f := FileOpen(配置文件, "w", "UTF-8")
        f.Write(txt)
        f.Close()
    }
}

; ══════════════════════════════════════════════════════════════
;  采集一轮颜色（主循环和 /probe 共用）
; ══════════════════════════════════════════════════════════════
采集颜色(hwnd) {
    global 通用, 规则集

    取几何(hwnd, &wx, &wy, &ww, &wh, &offx, &offy, &cw, &ch)
    颜色 := []
    颜色.Length := 规则集.Length

    if (通用.取色方式 = "后台") {
        点集 := []
        for r in 规则集
            点集.Push({
                x: offx + Round(((r.监视点RX < 0) ? 0 : r.监视点RX) / 100 * cw),
                y: offy + Round(((r.监视点RY < 0) ? 0 : r.监视点RY) / 100 * ch)
            })
        颜色 := 后台取色(hwnd, 点集)
    } else {
        for i, r in 规则集 {
            if (r.监视点RX < 0 || r.监视点RY < 0) {
                颜色[i] := -1
                continue
            }
            颜色[i] := PixelGetColor(wx + offx + Round(r.监视点RX / 100 * cw),
                                     wy + offy + Round(r.监视点RY / 100 * ch), "RGB")
        }
    }
    return 颜色
}

; ══════════════════════════════════════════════════════════════
;  核心循环：定时器驱动，永远快速返回，不做长 Sleep
; ══════════════════════════════════════════════════════════════
循环回调() {
    global 通用, 规则集, 运行中, 点击总数, 上次提示时刻, 本轮颜色, 本轮客户区, 本轮备注, 最近触发

    if !运行中
        return

    hwnd := WinExist(通用.目标窗口)
    if !hwnd {
        if (A_TickCount - 上次提示时刻 > 400) {
            刷新提示("（未找到目标窗口）")
            上次提示时刻 := A_TickCount
        }
        return
    }

    ; 最小化时 PrintWindow 抓不到画面：
    ;   自动还原 = 把窗口还原（还原后放底层被盖住没关系），继续本轮
    ;   不自动还原 = 提示用户手动还原
    if (通用.取色方式 = "后台" && DllCall("IsIconic", "Ptr", hwnd, "Int")) {
        if 通用.最小化自动还原 {
            WinRestore("ahk_id " . hwnd)
            Sleep 300
            if DllCall("IsIconic", "Ptr", hwnd, "Int")
                return
        } else {
            if (A_TickCount - 上次提示时刻 > 400) {
                刷新提示("（窗口被最小化了，后台取色失效 —— 点任务栏还原它就行，之后被别的窗口盖住都没关系）")
                上次提示时刻 := A_TickCount
            }
            return
        }
    }

    if (通用.取色方式 = "屏幕" && 通用.要求窗口激活 && !WinActive("ahk_id " . hwnd)) {
        if (A_TickCount - 上次提示时刻 > 400) {
            刷新提示("（目标窗口未激活，暂停中）")
            上次提示时刻 := A_TickCount
        }
        return
    }

    取几何(hwnd, &wx, &wy, &ww, &wh, &offx, &offy, &cw, &ch)
    if (cw < 10 || ch < 10)
        return
    本轮客户区 := {x: wx + offx, y: wy + offy, w: cw, h: ch}

    本轮颜色 := 采集颜色(hwnd)
    本轮备注 := ""

    还有活 := false
    for i, r in 规则集 {
        if !r.启用
            continue

        还有活 := true
        if (r.监视点RX < 0 || r.监视点RY < 0 || r.目标颜色 < 0)
            continue

        c := (i <= 本轮颜色.Length) ? 本轮颜色[i] : -1
        匹配 := 颜色匹配(c, r.目标颜色, 通用.颜色容差)
        触发 := (通用.触发模式 = "edge") ? (匹配 && !r.上次匹配) : 匹配
        r.上次匹配 := 匹配

        if !触发
            continue
        if (A_TickCount - r.上次点击时刻 < 通用.点击后等待)
            continue
        if (通用.最大点击数 > 0 && r.点击数 >= 通用.最大点击数) {
            r.启用 := false
            continue
        }
        if (r.点击点RX < 0 || r.点击点RY < 0)
            continue

        cx := offx + Round(r.点击点RX / 100 * cw)
        cy := offy + Round(r.点击点RY / 100 * ch)
        方式 := 点击(hwnd, cx, cy, wx + cx, wy + cy)
        r.点击数 += 1
        r.上次点击时刻 := A_TickCount
        if (方式 != "失败")
            点击总数 += 1
        本轮备注 := "规则" . i . " 触发（" . 方式 . "）"
        最近触发 := FormatTime(, "HH:mm:ss") . " 规则" . i . "（" . 方式 . "）"
    }

    if !还有活 {
        停止运行()
        return
    }

    if (A_TickCount - 上次提示时刻 > 400) {
        刷新提示()
        上次提示时刻 := A_TickCount
    }
}

; ══════════════════════════════════════════════════════════════
;  监控日志窗口（Gui）
;    · 可拖动、可缩放、始终置顶；位置存进 ini，下次启动还在原地
;    · Ctrl+Alt+L 显示 / 隐藏；点标题栏 X 也是隐藏
;    · 隐藏后脚本照常运行，只是不再占屏幕
; ══════════════════════════════════════════════════════════════
建日志窗口() {
    global 日志Gui, 日志Text, 日志位置X, 日志位置Y, 日志行数, 规则集

    g := Gui("+AlwaysOnTop +ToolWindow +Border +Resize", "color-click 监控")
    g.BackColor := "1F1F1F"
    g.SetFont("s9 cE8E8E8", "Microsoft YaHei UI")
    日志Text := g.Add("Text", "x10 y6 w430 h170", "启动中…")
    g.OnEvent("Size", 日志窗口缩放)
    g.OnEvent("Close", (*) => 隐藏日志())
    g.OnEvent("Escape", (*) => 隐藏日志())

    ; 位置越界（换过显示器 / 拖到屏幕外）就回到左上角
    if (日志位置X < -800 || 日志位置Y < -800 || 日志位置X > A_ScreenWidth - 120 || 日志位置Y > A_ScreenHeight - 80)
        日志位置X := 20, 日志位置Y := 20

    ; 高度按「规则条数 + 2 行（状态行、参数行）」来定
    日志行数 := 规则集.Length + 2
    g.Show("x" . 日志位置X . " y" . 日志位置Y . " w450 h" . 计算日志高度(日志行数) . " NA")
    日志Gui := g
}

; 一行文字实测约 22px
计算日志高度(行数) {
    高 := 行数 * 22 + 24
    if (高 < 130)
        高 := 130
    if (高 > A_ScreenHeight * 0.8)
        高 := Round(A_ScreenHeight * 0.8)
    return 高
}

; 规则条数变了才调高度 —— 不会跟你的手动缩放打架
日志调高度() {
    global 日志Gui, 日志行数, 规则集
    行数 := 规则集.Length + 2
    if (行数 = 日志行数)
        return
    日志行数 := 行数
    if 日志Gui
        try 日志Gui.Move(, , , 计算日志高度(行数))
}

日志窗口缩放(g, mm, w, h) {
    global 日志Text
    if (w > 60 && h > 60)
        日志Text.Move(, , w - 20, h - 14)
}

显示日志() {
    global 日志Gui, 日志可见
    if !日志Gui
        建日志窗口()
    else
        try 日志Gui.Show("NA")
    日志可见 := true
    刷新提示()
}

隐藏日志() {
    global 日志Gui, 日志可见, 日志位置X, 日志位置Y
    if 日志Gui {
        try {
            日志Gui.GetPos(&x, &y)
            if (x > -800 && y > -800)
                日志位置X := x, 日志位置Y := y
            日志Gui.Hide()
        }
    }
    日志可见 := false
    保存日志位置()
    短暂提示("监控日志已隐藏 —— 按 Ctrl+Alt+L 重新显示")
}

切换日志() {
    global 日志可见
    if 日志可见
        隐藏日志()
    else
        显示日志()
}

; 日志隐藏时的轻量反馈（日志开着就不用这个）
短暂提示(txt, ms := 3500) {
    ToolTip(txt, 20, 20)
    SetTimer(清除提示, -ms)
}

清除提示() {
    ToolTip()
}

; 把窗口位置写回 ini —— 只动「日志位置X/Y」两行，其余原样保留
保存日志位置() {
    global 配置文件, 日志位置X, 日志位置Y

    if !FileExist(配置文件)
        return
    try {
        txt := FileRead(配置文件, "UTF-8")
    } catch {
        return
    }

    出 := []
    有X := false, 有Y := false
    for l in StrSplit(txt, "`n", "`r") {
        k := Trim(l)
        if (SubStr(k, 1, 6) = "日志位置X=") {
            出.Push("日志位置X=" . 日志位置X)
            有X := true
        } else if (SubStr(k, 1, 6) = "日志位置Y=") {
            出.Push("日志位置Y=" . 日志位置Y)
            有Y := true
        } else {
            出.Push(l)
        }
    }
    if !有X
        出.Push("日志位置X=" . 日志位置X)
    if !有Y
        出.Push("日志位置Y=" . 日志位置Y)

    t := ""
    for l in 出
        t .= l . "`r`n"
    try {
        f := FileOpen(配置文件, "w", "UTF-8")
        f.Write(t)
        f.Close()
    }
}

刷新提示(备注 := "") {
    global 通用, 规则集, 运行中, 点击总数, 本轮颜色, 当前规则, 本轮客户区, 本轮备注
    global 日志可见, 日志Gui, 日志Text, 最近触发

    if !日志可见
        return
    if !日志Gui
        建日志窗口()
    日志调高度()

    ; ── 停止状态 ──
    if !运行中 {
        日志Text.Text := "【已停止】    F1 开始 / 停止      F2 退出`n"
            . "取色 " . 通用.取色方式 . "   |   点击 " . 通用.点击方式
            . "   |   共 " . 规则集.Length . " 条规则`n"
            . "Ctrl+Alt+L 显示/隐藏本窗口     Ctrl+Alt+0 重新载入配置`n"
            . "标定用 pick-relative.ahk"
        return
    }

    ; ── 运行状态 ──
    t := "【运行中】   累计点击 " . 点击总数 . " 次"
    if (备注 != "")
        t .= "   " . 备注
    else if (最近触发 != "")
        t .= "   最近 " . 最近触发
    t .= "`n"

    for i, r in 规则集 {
        if !r.启用 {
            t .= "规则" . i . "  —— 已停用`n"
            continue
        }
        if (r.监视点RX < 0 || r.目标颜色 < 0) {
            t .= "规则" . i . "  —— 未标定（用 pick-relative.ahk 标记）`n"
            continue
        }
        c := (i <= 本轮颜色.Length) ? 本轮颜色[i] : -1
        hit := 颜色匹配(c, r.目标颜色, 通用.颜色容差) ? "● 匹配" : "○"
        t .= "规则" . i . " " . (i = 当前规则 ? "▶" : " ") .
            " 盯(" . Format("{:.1f}", r.监视点RX) . "," . Format("{:.1f}", r.监视点RY) . "%)" .
            " 取到 " . 颜色文本(c) . "   目标 " . 颜色文本(r.目标颜色) . "  " . hit . "`n"
    }
    t .= "取色 " . 通用.取色方式 . " | 点击 " . 通用.点击方式 .
        " | 容差 " . 通用.颜色容差 . " | 间隔 " . 通用.检查间隔 . "ms | 触发 " . 通用.触发模式 .
        " | 客户区 " . 本轮客户区.w . "x" . 本轮客户区.h
    日志Text.Text := t
}

; ══════════════════════════════════════════════════════════════
;  开始 / 停止
; ══════════════════════════════════════════════════════════════
开始运行() {
    global 通用, 规则集, 运行中, 点击总数, 上次提示时刻, 当前规则, 本轮颜色, 本轮备注, 本轮客户区

    if !加载配置()
        return

    if (规则集.Length = 0) {
        MsgBox("配置里没有规则。", "无可执行规则", "Icon!")
        return
    }
    已标定 := 0
    for r in 规则集
        if (r.监视点RX >= 0 && r.点击点RX >= 0 && r.目标颜色 >= 0)
            已标定 += 1
    if (已标定 = 0) {
        MsgBox("所有规则都还没标定坐标。`n请先运行 pick-relative.ahk 在小游戏上标记点位。", "需要先标定", "Icon!")
        return
    }

    hwnd := WinExist(通用.目标窗口)
    if !hwnd {
        MsgBox("没找到目标窗口：`n" . 通用.目标窗口 . "`n`n先把小游戏打开。", "找不到窗口", "Icon!")
        return
    }
    if (通用.取色方式 = "后台" && DllCall("IsIconic", "Ptr", hwnd, "Int")) {
        if 通用.最小化自动还原 {
            WinRestore("ahk_id " . hwnd)
            Sleep 300
        } else {
            MsgBox("小游戏窗口目前是最小化的，后台取色抓不到画面。`n`n请点一下任务栏把它还原（之后被别的窗口盖住都没关系）。",
                   "请先还原窗口", "Icon!")
            return
        }
    }

    if (当前规则 > 规则集.Length)
        当前规则 := 1

    点击总数 := 0
    上次提示时刻 := 0
    本轮颜色 := []
    本轮备注 := ""
    本轮客户区 := {x:0, y:0, w:0, h:0}
    for r in 规则集 {
        r.上次匹配 := false
        r.上次点击时刻 := 0
        r.点击数 := 0
    }
    运行中 := true
    SetTimer(循环回调, 通用.检查间隔)
    循环回调()
}

停止运行() {
    global 运行中
    运行中 := false
    SetTimer(循环回调, 0)
    刷新提示()
}

; ══════════════════════════════════════════════════════════════
;  热键
; ══════════════════════════════════════════════════════════════
F1:: {
    global 运行中, 日志可见, 通用
    if 运行中 {
        停止运行()
        if !日志可见
            短暂提示("■ 已停止 —— Ctrl+Alt+L 可显示详细状态")
    } else {
        开始运行()
        if (运行中 && !日志可见)
            短暂提示("▶ 已开始，每 " . 通用.检查间隔 . "ms 检查一次 —— Ctrl+Alt+L 显示详细状态")
    }
}

F2:: {
    global 日志Gui
    SetTimer(循环回调, 0)
    ToolTip()
    if 日志Gui
        try 日志Gui.Destroy()
    ExitApp()
}

; 显示 / 隐藏监控日志窗口
^!l:: 切换日志()

^!0:: {
    global 日志可见
    加载配置()
    if 日志可见
        刷新提示("已重新载入配置")
    else
        短暂提示("已重新载入配置 —— Ctrl+Alt+L 显示日志")
}

; ══════════════════════════════════════════════════════════════
; 调试用命令行开关
;   color-click.ahk /dump          打印解析出的配置后退出
;   color-click.ahk /probe         后台抓一帧，打印各监视点当前颜色后退出
;   color-click.ahk /testclick N   对规则 N 的点击点发一次消息点击（验证用）
; ══════════════════════════════════════════════════════════════
if (A_Args.Length > 1 && A_Args[1] = "/testclick") {
    s := ""
    if 加载配置(true) {
        n := Integer(A_Args[2])
        hwnd := WinExist(通用.目标窗口)
        if !hwnd {
            s := "目标窗口未找到`r`n"
        } else if (n < 1 || n > 规则集.Length) {
            s := "规则编号超出范围（1-" . 规则集.Length . "）`r`n"
        } else {
            r := 规则集[n]
            if DllCall("IsIconic", "Ptr", hwnd, "Int") {
                if 通用.最小化自动还原 {
                    WinRestore("ahk_id " . hwnd)
                    Sleep 300
                } else {
                    FileAppend "窗口处于最小化，无法测试（最小化自动还原=0）`r`n", "*"
                    ExitApp()
                }
            }
            取几何(hwnd, &wx, &wy, &ww, &wh, &offx, &offy, &cw, &ch)
            cx := offx + Round(r.点击点RX / 100 * cw)
            cy := offy + Round(r.点击点RY / 100 * ch)
            找消息目标(hwnd, cx, cy, &thwnd, &tx, &ty)
            s .= "点击点(顶层客户区 " . cx . "," . cy . ")  ->  消息目标 hwnd=" . thwnd .
                  "  class=" . WinGetClass("ahk_id " . thwnd) .
                  "  目标客户区坐标(" . tx . "," . ty . ")`r`n"
            点击(hwnd, cx, cy, wx + cx, wy + cy)
            s .= "已发送一次消息点击，观察游戏窗口有没有反应`r`n"
        }
    } else {
        s := "配置加载失败`r`n"
    }
    FileAppend s, "*"
    ExitApp()
}

if (A_Args.Length > 0 && (A_Args[1] = "/dump" || A_Args[1] = "/probe")) {
    s := ""
    if 加载配置(true) {
        hwnd := WinExist(通用.目标窗口)
        if hwnd {
            取几何(hwnd, &wx, &wy, &ww, &wh, &offx, &offy, &cw, &ch)
            s .= "目标窗口: hwnd=" . hwnd . "  窗口(" . wx . "," . wy . ") " . ww . "x" . wh .
                  "  客户区 " . cw . "x" . ch . "  客户区偏移(" . offx . "," . offy . ")`r`n"
            s .= "  最小化=" . (DllCall("IsIconic", "Ptr", hwnd, "Int") ? "是（后台取色会失效）" : "否") .
                  "  可见=" . (DllCall("IsWindowVisible", "Ptr", hwnd, "Int") ? "是" : "否") . "`r`n"
        } else {
            s .= "目标窗口未找到`r`n"
        }
        s .= "取色方式=" . 通用.取色方式 . "  点击方式=" . 通用.点击方式 .
              "  还原=" . 通用.点击后还原 . "  间隔=" . 通用.检查间隔 . "ms  冷却=" . 通用.点击后等待 .
              "ms  容差=" . 通用.颜色容差 . "  触发=" . 通用.触发模式 .
              "  需激活=" . 通用.要求窗口激活 . "  规则数=" . 规则集.Length . "`r`n"
        s .= "日志窗口位置=" . 日志位置X . "," . 日志位置Y . "  显示中=" . 日志可见 . "`r`n"

        if (A_Args[1] = "/probe" && hwnd) {
            颜色 := 采集颜色(hwnd)
            s .= "`r`n── 后台实测各监视点 ──`r`n"
            for i, r in 规则集 {
                c := (i <= 颜色.Length) ? 颜色[i] : -1
                命中 := 颜色匹配(c, r.目标颜色, 通用.颜色容差) ? "  ● 命中目标色" : ""
                s .= "规则" . i . " 盯(" . Format("{:.2f}", r.监视点RX) . "," . Format("{:.2f}", r.监视点RY) .
                     "%)  取到 " . 颜色文本(c) . "   目标 " . 颜色文本(r.目标颜色) . 命中 . "`r`n"
            }
        } else {
            for i, r in 规则集 {
                s .= "规则" . i . ": 盯(" . Format("{:.2f}", r.监视点RX) . "," . Format("{:.2f}", r.监视点RY) . "%)" .
                     "  色=" . 颜色文本(r.目标颜色) .
                     "  点(" . Format("{:.2f}", r.点击点RX) . "," . Format("{:.2f}", r.点击点RY) . "%)" .
                     "  启用=" . r.启用 . "`r`n"
            }
        }
    } else {
        s := "配置加载失败`r`n"
    }
    FileAppend s, "*"
    ExitApp()
}

if !加载配置()
    ExitApp()
显示日志()
