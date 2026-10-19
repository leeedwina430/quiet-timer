// QuietTimer · 静音倒计时
// 单文件 AppKit 应用：
//   - 屏幕角落置顶悬浮的倒计时胶囊（可拖动、半透明、全屏 App 之上也能看到）
//   - 时间到：屏幕中央弹出大窗口提醒（全程静音），并持续显示"已超时"
//   - 全局快捷键 ⌃⌥T 一键隐藏 / 显示胶囊，也可以"隐藏一会，之后自动出现"
import Cocoa
import Carbon
import ServiceManagement

// MARK: - 纯函数：时间格式化 / 解析

/// 69 -> "01:09"，3725 -> "1:02:05"
func formatTime(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
    return String(format: "%02d:%02d", m, sec)
}

/// 1800 -> "30 分钟"，5400 -> "1 小时 30 分钟"
func durationLabel(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    var parts: [String] = []
    if h > 0 { parts.append("\(h) 小时") }
    if m > 0 { parts.append("\(m) 分钟") }
    if sec > 0 { parts.append("\(sec) 秒") }
    return parts.isEmpty ? "0 秒" : parts.joined(separator: " ")
}

func parseNumber(_ s: String) -> Double? {
    if s.isEmpty { return nil }
    for ch in s {
        if !"0123456789.".contains(ch) { return nil }
    }
    return Double(s)
}

/// 解析用户输入的时长（单位：秒）。
/// 支持：25（默认分钟） / 45m / 1.5h / 1h30m / 90s / 1小时30分 / 25:00（分:秒） / 1:30:00（时:分:秒）
func parseDuration(_ raw: String) -> TimeInterval? {
    var t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    t = t.replacingOccurrences(of: " ", with: "")
    t = t.replacingOccurrences(of: "\u{3000}", with: "")
    t = t.replacingOccurrences(of: "：", with: ":")
    if t.isEmpty { return nil }

    var total = 0.0

    if t.contains(":") {
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        var nums: [Double] = []
        for p in parts {
            guard let v = parseNumber(String(p)) else { return nil }
            nums.append(v)
        }
        if nums.count == 2 {
            total = nums[0] * 60 + nums[1]
        } else if nums.count == 3 {
            total = nums[0] * 3600 + nums[1] * 60 + nums[2]
        } else {
            return nil
        }
    } else {
        var segments: [(num: String, unit: String)] = []
        var num = ""
        var unit = ""
        for ch in t {
            if "0123456789.".contains(ch) {
                if !unit.isEmpty {
                    segments.append((num: num, unit: unit))
                    num = ""
                    unit = ""
                }
                num.append(ch)
            } else {
                unit.append(ch)
            }
        }
        segments.append((num: num, unit: unit))

        for seg in segments {
            guard let n = parseNumber(seg.num) else { return nil }
            var mult = 60.0
            switch seg.unit {
            case "", "m", "min", "mins", "minute", "minutes", "分", "分钟":
                mult = 60
            case "h", "hr", "hrs", "hour", "hours", "小时", "时":
                mult = 3600
            case "s", "sec", "secs", "second", "seconds", "秒", "秒钟":
                mult = 1
            default:
                return nil
            }
            total += n * mult
        }
    }

    if !total.isFinite || total < 1 || total > 99 * 3600 { return nil }
    return total
}

// MARK: - 悬浮窗口 / 胶囊视图

/// 不抢键盘焦点的浮动面板：点它不会打断你正在其他软件里的输入
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { return false }
    override var canBecomeMain: Bool { return false }
}

/// 第一次点击就能响应（即使本 App 不在前台）
final class ClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }
}

final class PillView: NSView {
    var text: String = "" { didSet { needsDisplay = true } }
    var accent: NSColor = NSColor.systemGray { didSet { needsDisplay = true } }
    var background: NSColor = NSColor(calibratedWhite: 0.1, alpha: 0.85) { didSet { needsDisplay = true } }
    var textColor: NSColor = NSColor.white { didSet { needsDisplay = true } }
    /// 剩余比例 0...1；小于 0 表示不画进度条
    var progress: CGFloat = -1 { didSet { needsDisplay = true } }
    var fontSize: CGFloat = 19 { didSet { needsDisplay = true } }

    var onClick: ((NSEvent) -> Void)?
    var onDragEnd: (() -> Void)?

    private var dragOffset = NSPoint.zero
    private var startMouse = NSPoint.zero
    private var didDrag = false

    var font: NSFont { return NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold) }
    var pillHeight: CGFloat { return (fontSize * 2.0).rounded() }
    var dotSize: CGFloat { return (fontSize * 0.42).rounded() }
    var hPad: CGFloat { return (fontSize * 0.8).rounded() }
    var gap: CGFloat { return (fontSize * 0.5).rounded() }

    func desiredWidth() -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let w = (text as NSString).size(withAttributes: attrs).width
        return ceil(w) + hPad * 2 + dotSize + gap
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        background.setFill()
        path.fill()

        if progress >= 0 {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let barH: CGFloat = max(3, (fontSize * 0.16).rounded())
            NSColor(white: 1, alpha: 0.14).setFill()
            NSBezierPath.fill(NSRect(x: 0, y: 0, width: r.width, height: barH))
            accent.setFill()
            let p = min(1, max(0, progress))
            NSBezierPath.fill(NSRect(x: 0, y: 0, width: r.width * p, height: barH))
            NSGraphicsContext.restoreGraphicsState()
        }

        let dot = dotSize
        let lift: CGFloat = progress >= 0 ? 1.5 : 0
        let dotRect = NSRect(x: hPad, y: (r.height - dot) / 2 + lift, width: dot, height: dot)
        accent.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        str.draw(at: NSPoint(x: hPad + dot + gap, y: (r.height - size.height) / 2 + lift))
    }

    // 鼠标：拖动 = 移动胶囊；单击 / 右键 = 打开菜单
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        dragOffset = event.locationInWindow
        startMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let w = window else { return }
        let loc = NSEvent.mouseLocation
        // 移动不足 4 像素视为"点击"，避免手抖把点击当成拖动
        if !didDrag && hypot(loc.x - startMouse.x, loc.y - startMouse.y) < 4 { return }
        didDrag = true
        w.setFrameOrigin(NSPoint(x: loc.x - dragOffset.x, y: loc.y - dragOffset.y))
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            onDragEnd?()
        } else {
            onClick?(event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onClick?(event)
    }
}

// MARK: - 全局快捷键（Carbon，不需要任何系统权限）

let hotKeyNotification = Notification.Name("QuietTimerToggleHotKey")

// MARK: - 主控制器

final class Controller: NSObject {
    enum State { case idle, running, paused, finished }

    static let sizeOptions: [(String, CGFloat)] = [("小", 15), ("中", 19), ("大", 26)]
    static let opacityOptions: [Int] = [100, 85, 70, 55, 40]

    // UI
    var panel: FloatingPanel!
    var pill: PillView!
    var statusItem: NSStatusItem!
    var alertPanel: FloatingPanel?
    var overtimeLabel: NSTextField?

    // 计时
    var state: State = .idle {
        didSet { updateActivity() }
    }
    var total: TimeInterval = 0
    var endDate = Date()
    var pausedRemaining: TimeInterval = 0

    // 其他
    var pillHidden = false
    var tickTimer: Timer?
    var hideTimer: Timer?
    var hotKeyRef: EventHotKeyRef?
    var activity: NSObjectProtocol?
    var lastSig = ""

    // 到点弹窗里的"目标是否完成"勾选
    enum Outcome { case pending, done, notDone }
    var currentOutcome: Outcome = .pending
    var doneBox: NSButton?
    var notDoneBox: NSButton?
    var outcomeHint: NSTextField?
    var alertButtons: [NSButton] = []

    private let defaults = UserDefaults.standard

    // MARK: 偏好设置

    var lastDuration: TimeInterval {
        get {
            let v = defaults.double(forKey: "lastDuration")
            return v >= 1 ? v : 1800
        }
        set { defaults.set(newValue, forKey: "lastDuration") }
    }

    var sizeIndex: Int {
        get {
            let v = defaults.object(forKey: "sizeIndex") as? Int ?? 1
            return min(max(v, 0), Controller.sizeOptions.count - 1)
        }
        set { defaults.set(newValue, forKey: "sizeIndex") }
    }

    var opacityPercent: Int {
        get {
            let v = defaults.object(forKey: "opacityPercent") as? Int ?? 85
            return Controller.opacityOptions.contains(v) ? v : 85
        }
        set { defaults.set(newValue, forKey: "opacityPercent") }
    }

    // 今日统计：total = 今天已结束的倒计时个数；done = 其中勾选"完成目标"的个数
    var statsTotal: Int {
        get { return defaults.integer(forKey: "statsTotal") }
        set { defaults.set(max(0, newValue), forKey: "statsTotal") }
    }

    var statsDone: Int {
        get { return defaults.integer(forKey: "statsDone") }
        set { defaults.set(max(0, newValue), forKey: "statsDone") }
    }

    var statsSince: Date {
        get {
            if let d = defaults.object(forKey: "statsSince") as? Date { return d }
            let d = Date()
            defaults.set(d, forKey: "statsSince")
            return d
        }
        set { defaults.set(newValue, forKey: "statsSince") }
    }

    // MARK: 启动

    func installEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(NSMenuItem.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    func launch() {
        installEditMenu()
        setupPill()
        setupStatusItem()
        registerHotKey()

        NotificationCenter.default.addObserver(self, selector: #selector(hotKeyPressed(_:)),
                                               name: hotKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t

        refresh()
    }

    func updateActivity() {
        if state == .running || state == .finished {
            if activity == nil {
                // 防止 macOS 的 App Nap 把计时器拖慢（允许电脑正常休眠）
                activity = ProcessInfo.processInfo.beginActivity(
                    options: .userInitiatedAllowingIdleSystemSleep, reason: "Countdown running")
            }
        } else if let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    // MARK: 悬浮胶囊

    func setupPill() {
        pill = PillView(frame: NSRect(x: 0, y: 0, width: 120, height: 38))
        pill.fontSize = Controller.sizeOptions[sizeIndex].1
        pill.text = "点击设置"

        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: pill.desiredWidth(), height: pill.pillHeight),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.contentView = pill
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = NSColor.clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.alphaValue = CGFloat(opacityPercent) / 100.0

        pill.onClick = { [weak self] event in self?.showPillMenu(event) }
        pill.onDragEnd = { [weak self] in self?.savePosition() }

        placeInitially()
        panel.orderFrontRegardless()
    }

    func placeInitially() {
        let size = panel.frame.size
        if let cx = defaults.object(forKey: "pillCenterX") as? Double,
           let cy = defaults.object(forKey: "pillCenterY") as? Double {
            let c = NSPoint(x: cx, y: cy)
            if NSScreen.screens.contains(where: { $0.frame.contains(c) }) {
                panel.setFrameOrigin(NSPoint(x: c.x - size.width / 2, y: c.y - size.height / 2))
                return
            }
        }
        resetPosition()
    }

    @objc func resetPosition() {
        let size = panel.frame.size
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 24, y: vf.maxY - size.height - 14))
        savePosition()
    }

    func savePosition() {
        let f = panel.frame
        defaults.set(Double(f.midX), forKey: "pillCenterX")
        defaults.set(Double(f.midY), forKey: "pillCenterY")
    }

    @objc func screensChanged(_ n: Notification) {
        let c = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        if !NSScreen.screens.contains(where: { $0.frame.contains(c) }) {
            resetPosition()
        }
    }

    func resizePill() {
        let w = pill.desiredWidth()
        let h = pill.pillHeight
        let f = panel.frame
        if abs(f.width - w) < 0.5 && abs(f.height - h) < 0.5 { return }
        let newFrame = NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h)
        panel.setFrame(newFrame, display: true)
        panel.invalidateShadow()
    }

    func setPillHidden(_ hidden: Bool) {
        hideTimer?.invalidate()
        hideTimer = nil
        pillHidden = hidden
        if hidden {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc func hotKeyPressed(_ n: Notification) {
        setPillHidden(!pillHidden)
    }

    @objc func doToggle() {
        setPillHidden(!pillHidden)
    }

    @objc func doHideFor(_ sender: NSMenuItem) {
        setPillHidden(true)
        let t = Timer(timeInterval: Double(sender.tag) * 60, repeats: false) { [weak self] _ in
            self?.setPillHidden(false)
        }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    // MARK: 计时逻辑

    func start(_ seconds: TimeInterval, remember: Bool = true) {
        closeAlert()
        if remember && statsTotal == 0 { statsSince = Date() }   // 新一天的第一个倒计时开始的时间
        total = seconds
        endDate = Date().addingTimeInterval(seconds)
        state = .running
        if remember { lastDuration = seconds }
        if pillHidden { setPillHidden(false) }
        lastSig = ""
        refresh()
    }

    func tick() {
        if state == .running && endDate.timeIntervalSinceNow <= 0 {
            state = .finished
            statsTotal += 1              // 每结束一个倒计时，就计入"今日总数"
            currentOutcome = .pending
            showAlert()
        }
        refresh()
    }

    @objc func doPause() {
        guard state == .running else { return }
        pausedRemaining = max(0, endDate.timeIntervalSinceNow)
        state = .paused
        lastSig = ""
        refresh()
    }

    @objc func doResume() {
        guard state == .paused else { return }
        endDate = Date().addingTimeInterval(pausedRemaining)
        state = .running
        lastSig = ""
        refresh()
    }

    @objc func doStop() {
        closeAlert()
        state = .idle
        lastSig = ""
        refresh()
    }

    @objc func doRestart() {
        start(lastDuration)
    }

    @objc func doAdd5() {
        if state == .running {
            endDate = endDate.addingTimeInterval(300)
            total += 300
        } else if state == .paused {
            pausedRemaining += 300
            total += 300
        }
        lastSig = ""
        refresh()
    }

    @objc func doPreset(_ sender: NSMenuItem) {
        if let n = sender.representedObject as? NSNumber {
            start(n.doubleValue)
        }
    }

    // MARK: 刷新胶囊显示

    func refresh() {
        let now = Date()
        var text = ""
        var style = 0
        var progress: CGFloat = -1

        switch state {
        case .idle:
            text = "点击设置"
            style = 0
        case .running, .paused:
            let rem = (state == .running) ? max(0, endDate.timeIntervalSince(now)) : pausedRemaining
            text = formatTime(Int(ceil(rem)))
            progress = CGFloat(rem / max(total, 1))
            if state == .paused {
                style = 4
            } else if rem <= min(60, total * 0.5) {
                style = 3
            } else if rem <= max(90, min(900, total * 0.2)) {
                style = 2
            } else {
                style = 1
            }
        case .finished:
            let over = max(0, now.timeIntervalSince(endDate))
            text = "+" + formatTime(Int(over))
            style = (Int(now.timeIntervalSince1970 * 2) % 2 == 0) ? 5 : 6
            overtimeLabel?.stringValue = "已超时 " + formatTime(Int(over))
        }

        let sig = "\(text)|\(style)|\(Int(progress * 400))"
        if sig == lastSig { return }
        lastSig = sig

        switch style {
        case 0:
            pill.accent = NSColor.systemGray
            pill.background = NSColor(calibratedWhite: 0.1, alpha: 0.85)
            pill.textColor = NSColor(white: 1, alpha: 0.85)
        case 1:
            pill.accent = NSColor.systemGreen
            pill.background = NSColor(calibratedWhite: 0.1, alpha: 0.85)
            pill.textColor = NSColor.white
        case 2:
            pill.accent = NSColor.systemOrange
            pill.background = NSColor(calibratedRed: 0.26, green: 0.16, blue: 0.02, alpha: 0.9)
            pill.textColor = NSColor.white
        case 3:
            pill.accent = NSColor.systemRed
            pill.background = NSColor(calibratedRed: 0.45, green: 0.04, blue: 0.06, alpha: 0.93)
            pill.textColor = NSColor.white
        case 4:
            pill.accent = NSColor.systemYellow
            pill.background = NSColor(calibratedWhite: 0.1, alpha: 0.85)
            pill.textColor = NSColor(white: 1, alpha: 0.6)
        case 5:
            pill.accent = NSColor.white
            pill.background = NSColor(calibratedRed: 0.88, green: 0.10, blue: 0.12, alpha: 0.96)
            pill.textColor = NSColor.white
        default:
            pill.accent = NSColor.white
            pill.background = NSColor(calibratedRed: 0.48, green: 0.04, blue: 0.06, alpha: 0.96)
            pill.textColor = NSColor.white
        }
        pill.progress = progress
        pill.text = text
        resizePill()
    }

    // MARK: 到点弹窗（静音）

    func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) { return s }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    func makeLabel(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                      : NSFont.systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.alignment = .center
        return f
    }

    func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let b = ClickButton(frame: NSRect(x: 0, y: 0, width: 100, height: 32))
        b.setButtonType(.momentaryPushIn)
        b.title = title
        b.target = self
        b.action = action
        b.bezelStyle = .rounded
        b.controlSize = .large
        return b
    }

    func makeCheckbox(_ title: String, _ action: Selector) -> NSButton {
        let b = ClickButton(frame: NSRect(x: 0, y: 0, width: 140, height: 24))
        b.setButtonType(.switch)
        b.title = title
        b.font = NSFont.systemFont(ofSize: 17, weight: .medium)
        b.target = self
        b.action = action
        b.state = .off
        return b
    }

    func showAlert() {
        closeAlert()

        var views: [NSView] = []

        if let img = NSImage(systemSymbolName: "alarm.fill", accessibilityDescription: nil) {
            let iv = NSImageView(image: img)
            iv.contentTintColor = NSColor.systemOrange
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 46).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 46).isActive = true
            views.append(iv)
        }

        let title = makeLabel("时间到了", size: 38, weight: .bold, color: NSColor.white)
        let sub = makeLabel("「\(durationLabel(total))」倒计时已结束", size: 15, weight: .regular,
                            color: NSColor(white: 1, alpha: 0.75))
        let over = makeLabel("已超时 00:00", size: 20, weight: .semibold, color: NSColor.systemRed, mono: true)
        overtimeLabel = over

        let ask = makeLabel("这次的目标完成了吗？", size: 16, weight: .medium, color: NSColor(white: 1, alpha: 0.9))
        let cDone = makeCheckbox("完成目标", #selector(outcomeDone))
        let cNot = makeCheckbox("未完成目标", #selector(outcomeNotDone))
        let boxes = NSStackView(views: [cDone, cNot])
        boxes.orientation = .horizontal
        boxes.spacing = 30
        let hint = makeLabel("勾选一项后，才能「关闭」或「重新计时」", size: 12, weight: .regular, color: NSColor(white: 1, alpha: 0.55))
        doneBox = cDone
        notDoneBox = cNot
        outcomeHint = hint

        let bClose = makeButton("关闭", #selector(alertClose))
        let bSnooze = makeButton("再来 5 分钟", #selector(alertSnooze))
        let bRestart = makeButton("重新计时 " + durationLabel(lastDuration), #selector(alertRestart))
        let buttons = NSStackView(views: [bClose, bSnooze, bRestart])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        alertButtons = [bClose, bRestart]
        for b in alertButtons { b.isEnabled = false }   // 勾选之后才能"关闭"/"重新计时"；"再来 5 分钟"不需要勾选

        views.append(contentsOf: [title, sub, over, ask, boxes, hint, buttons])
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(18, after: over)
        stack.setCustomSpacing(18, after: hint)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.layoutSubtreeIfNeeded()
        let fit = stack.fittingSize
        let w = max(420, fit.width + 72)
        let h = fit.height + 60

        let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .screenSaver
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isOpaque = false
        p.backgroundColor = NSColor.clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        let radius: CGFloat = 22
        let mask = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        effect.maskImage = mask
        effect.wantsLayer = true
        effect.layer?.cornerRadius = radius
        effect.layer?.masksToBounds = true
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor)
        ])
        p.contentView = effect

        let sf = activeScreen().visibleFrame
        p.setFrameOrigin(NSPoint(x: sf.midX - w / 2, y: sf.midY - h / 2 + sf.height * 0.08))
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 1
        }, completionHandler: nil)
        alertPanel = p
        lastSig = ""
    }

    func closeAlert() {
        guard let p = alertPanel else { return }
        p.ignoresMouseEvents = true
        alertPanel = nil
        overtimeLabel = nil
        doneBox = nil
        notDoneBox = nil
        outcomeHint = nil
        alertButtons = []
        currentOutcome = .pending
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    @objc func outcomeDone() { setOutcome(.done) }
    @objc func outcomeNotDone() { setOutcome(.notDone) }

    /// 记录这次倒计时的结果。可以在点按钮之前反复改选，统计会同步修正。
    func setOutcome(_ o: Outcome) {
        guard alertPanel != nil, state == .finished, o != .pending else { return }
        if currentOutcome == .done && o != .done {
            statsDone -= 1
        } else if currentOutcome != .done && o == .done {
            if statsDone < statsTotal { statsDone += 1 }
        }
        currentOutcome = o
        doneBox?.state = (o == .done) ? .on : .off
        notDoneBox?.state = (o == .notDone) ? .on : .off
        outcomeHint?.stringValue = (o == .done) ? "已记录：完成目标" : "已记录：未完成目标"
        for b in alertButtons { b.isEnabled = true }
    }

    @objc func alertClose() { doStop() }
    @objc func alertSnooze() {
        // "再来 5 分钟"是同一个目标的延长：撤销这次结束的计数，等延长的那段结束时再统一计一次
        if state == .finished {
            statsTotal -= 1
            if currentOutcome == .done { statsDone -= 1 }
        }
        start(300, remember: false)
    }
    @objc func alertRestart() { start(lastDuration) }

    // MARK: 菜单

    func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    func statusLine() -> String {
        switch state {
        case .idle:
            return "未在计时"
        case .running:
            let rem = max(0, endDate.timeIntervalSinceNow)
            return "剩余 \(formatTime(Int(ceil(rem))))  ·  共 \(durationLabel(total))"
        case .paused:
            return "已暂停  ·  剩余 \(formatTime(Int(ceil(pausedRemaining))))"
        case .finished:
            let over = max(0, Date().timeIntervalSince(endDate))
            return "时间到了  ·  已超时 \(formatTime(Int(over)))"
        }
    }

    func statsLine() -> String {
        let total = statsTotal
        if total == 0 { return "今日：还没有结束的倒计时" }
        let done = min(statsDone, total)
        let pct = Int((Double(done) / Double(total) * 100).rounded())
        return "今日：完成 \(done) / \(total)（\(pct)%）"
    }

    func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let stats = NSMenuItem(title: statsLine(), action: nil, keyEquivalent: "")
        stats.isEnabled = false
        menu.addItem(stats)
        menu.addItem(item("Call it a day（收工并清零）…", #selector(doCallItADay)))
        menu.addItem(NSMenuItem.separator())

        switch state {
        case .running:
            menu.addItem(item("暂停", #selector(doPause)))
            menu.addItem(item("加 5 分钟", #selector(doAdd5)))
            menu.addItem(item("重新开始（\(durationLabel(lastDuration))）", #selector(doRestart)))
            menu.addItem(item("停止并清除", #selector(doStop)))
        case .paused:
            menu.addItem(item("继续", #selector(doResume)))
            menu.addItem(item("加 5 分钟", #selector(doAdd5)))
            menu.addItem(item("重新开始（\(durationLabel(lastDuration))）", #selector(doRestart)))
            menu.addItem(item("停止并清除", #selector(doStop)))
        case .finished:
            let closeItem = item("关闭提醒（需先在弹窗里勾选）", #selector(alertClose))
            let restartItem = item("重新计时（\(durationLabel(lastDuration))）", #selector(alertRestart))
            closeItem.isEnabled = (currentOutcome != .pending)
            restartItem.isEnabled = (currentOutcome != .pending)
            menu.addItem(closeItem)
            menu.addItem(item("再来 5 分钟", #selector(alertSnooze)))
            menu.addItem(restartItem)
        case .idle:
            menu.addItem(item("重复上次（\(durationLabel(lastDuration))）", #selector(doRestart)))
        }
        menu.addItem(NSMenuItem.separator())

        let hdr = NSMenuItem(title: "开始新的倒计时", action: nil, keyEquivalent: "")
        hdr.isEnabled = false
        menu.addItem(hdr)
        let presets: [(String, TimeInterval)] = [
            ("10 分钟", 600), ("15 分钟", 900), ("25 分钟", 1500), ("30 分钟", 1800),
            ("45 分钟", 2700), ("1 小时", 3600), ("1.5 小时", 5400), ("2 小时", 7200)
        ]
        for (title, secs) in presets {
            let it = item(title, #selector(doPreset(_:)))
            it.representedObject = NSNumber(value: secs)
            menu.addItem(it)
        }
        menu.addItem(item("自定义…", #selector(doCustom)))
        menu.addItem(NSMenuItem.separator())

        let toggle = item(pillHidden ? "显示倒计时" : "隐藏倒计时", #selector(doToggle))
        toggle.keyEquivalent = "t"
        toggle.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(toggle)

        let hideSub = NSMenu()
        hideSub.autoenablesItems = false
        for m in [5, 10, 15, 30, 60] {
            let it = item("\(m) 分钟", #selector(doHideFor(_:)))
            it.tag = m
            hideSub.addItem(it)
        }
        let hideParent = NSMenuItem(title: "隐藏一会，之后自动出现", action: nil, keyEquivalent: "")
        hideParent.submenu = hideSub
        menu.addItem(hideParent)
        menu.addItem(NSMenuItem.separator())

        let sizeSub = NSMenu()
        sizeSub.autoenablesItems = false
        for (i, opt) in Controller.sizeOptions.enumerated() {
            let it = item(opt.0, #selector(doSetSize(_:)))
            it.tag = i
            it.state = (i == sizeIndex) ? .on : .off
            sizeSub.addItem(it)
        }
        let sizeParent = NSMenuItem(title: "胶囊大小", action: nil, keyEquivalent: "")
        sizeParent.submenu = sizeSub
        menu.addItem(sizeParent)

        let opSub = NSMenu()
        opSub.autoenablesItems = false
        for pct in Controller.opacityOptions {
            let it = item("\(pct)%", #selector(doSetOpacity(_:)))
            it.tag = pct
            it.state = (pct == opacityPercent) ? .on : .off
            opSub.addItem(it)
        }
        let opParent = NSMenuItem(title: "胶囊透明度", action: nil, keyEquivalent: "")
        opParent.submenu = opSub
        menu.addItem(opParent)

        menu.addItem(item("把胶囊移回右上角", #selector(resetPosition)))

        if #available(macOS 13.0, *) {
            let login = item("开机自动启动", #selector(doToggleLogin))
            login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
            menu.addItem(login)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("退出", #selector(doQuit)))
    }

    func showPillMenu(_ event: NSEvent) {
        let m = NSMenu()
        populate(m)
        NSMenu.popUpContextMenu(m, with: event, for: pill)
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            if let img = NSImage(systemSymbolName: "timer", accessibilityDescription: "倒计时") {
                img.isTemplate = true
                b.image = img
            } else {
                b.title = "计时"
            }
            b.target = self
            b.action = #selector(statusClicked(_:))
        }
    }

    @objc func statusClicked(_ sender: Any?) {
        let m = NSMenu()
        populate(m)
        statusItem.menu = m
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: 菜单动作

    @objc func doSetSize(_ sender: NSMenuItem) {
        sizeIndex = sender.tag
        pill.fontSize = Controller.sizeOptions[sizeIndex].1
        lastSig = ""
        refresh()
        resizePill()
    }

    @objc func doSetOpacity(_ sender: NSMenuItem) {
        opacityPercent = sender.tag
        panel.alphaValue = CGFloat(opacityPercent) / 100.0
    }

    @objc func doCallItADay() {
        let total = statsTotal
        let done = min(statsDone, total)
        let notDone = total - done
        let pct = total > 0 ? Int((Double(done) / Double(total) * 100).rounded()) : 0

        let fmt = DateFormatter()
        fmt.dateFormat = "M月d日 HH:mm"
        var info = ""
        if total == 0 {
            info = "今天还没有结束过的倒计时。"
        } else {
            info = "完成目标：\(done) / \(total) 次倒计时\n未完成：\(notDone) 次\n完成率：\(pct)%"
        }
        info += "\n\n统计起点：" + fmt.string(from: statsSince)
        info += "\n点「收工并清零」后计数归零，重新开始新的一天。"

        var shouldReset = false
        runActivated {
            let a = NSAlert()
            a.alertStyle = .informational
            a.messageText = "Call it a day · 今天辛苦了"
            a.informativeText = info
            a.addButton(withTitle: "收工并清零")
            a.addButton(withTitle: "先不收工")
            shouldReset = (a.runModal() == .alertFirstButtonReturn)
        }
        if shouldReset {
            statsTotal = 0
            statsDone = 0
            statsSince = Date()
        }
    }

    @objc func doQuit() {
        NSApp.terminate(nil)
    }

    @objc func doToggleLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                showSimpleAlert("无法设置开机启动",
                                "\(error.localizedDescription)\n\n你也可以手动添加：系统设置 → 通用 → 登录项与扩展 → 点 + 选择本 App。")
            }
        }
    }

    /// 弹出系统对话框前需要激活本 App；用完把焦点还给原来的软件
    func runActivated(_ body: () -> Void) {
        let prev = NSWorkspace.shared.frontmostApplication
        let shown = alertPanel
        shown?.level = .floating          // 让系统对话框显示在"时间到了"卡片上面
        NSApp.activate(ignoringOtherApps: true)
        body()
        shown?.level = .screenSaver
        if let p = prev, p.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            p.activate(options: [])
        }
    }

    func showSimpleAlert(_ title: String, _ text: String) {
        runActivated {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = text
            a.addButton(withTitle: "好")
            a.runModal()
        }
    }

    func promptDuration() -> TimeInterval? {
        var errorText = ""
        while true {
            let alert = NSAlert()
            alert.messageText = "自定义倒计时"
            let hint = "输入时长，例如：25（默认按分钟）、45m、1.5h、1h30m、90s、25:00（分:秒）"
            alert.informativeText = errorText.isEmpty ? hint : errorText + "\n\n" + hint
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.placeholderString = "例如 50m"
            alert.accessoryView = field
            alert.addButton(withTitle: "开始")
            alert.addButton(withTitle: "取消")
            alert.window.initialFirstResponder = field
            let resp = alert.runModal()
            if resp != .alertFirstButtonReturn { return nil }
            if let secs = parseDuration(field.stringValue) { return secs }
            errorText = "没看懂「\(field.stringValue)」，请再试一次。"
        }
    }

    @objc func doCustom() {
        var result: TimeInterval? = nil
        runActivated {
            result = promptDuration()
        }
        if let r = result { start(r) }
    }

    // MARK: 全局快捷键 ⌃⌥T

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, _, _) -> OSStatus in
            NotificationCenter.default.post(name: Notification.Name("QuietTimerToggleHotKey"), object: nil)
            return OSStatus(0)
        }, 1, &spec, nil, nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x51545452), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey), hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

// MARK: - 入口

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 不出现在 Dock
let controller = Controller()
controller.launch()
app.run()
