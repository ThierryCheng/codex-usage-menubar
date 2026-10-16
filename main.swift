import AppKit
import ServiceManagement

let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Codex Usage", isDirectory: true)

private final class MenuBarContentView: NSView {
    var remaining: Int?
    var percentText = "…"
    var needsAttention = false
    private let nameFont = NSFont.menuBarFont(ofSize: 0)
    private let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private let barWidth: CGFloat = 56

    var label: String { needsAttention ? "Codex !" : "Codex" }
    var preferredWidth: CGFloat { ceil((label as NSString).size(withAttributes: [.font: nameFont]).width) + 8 + barWidth + 12 }
    override var allowsVibrancy: Bool { true }

    // The system status button retains menu handling and its native highlight.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let highlighted = (superview as? NSStatusBarButton)?.isHighlighted == true
        let foreground = highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
        let nameAttributes: [NSAttributedString.Key: Any] = [.font: nameFont, .foregroundColor: foreground]
        let nameSize = (label as NSString).size(withAttributes: nameAttributes)
        (label as NSString).draw(at: NSPoint(x: 6, y: (bounds.height - nameSize.height) / 2), withAttributes: nameAttributes)

        let trackRect = NSRect(x: 6 + ceil(nameSize.width) + 8, y: (bounds.height - 18) / 2, width: barWidth, height: 18)
        let track = NSBezierPath(roundedRect: trackRect, xRadius: 9, yRadius: 9)
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        NSColor.black.withAlphaComponent(dark ? 0.24 : 0.06).setFill()
        track.fill()
        if let remaining, remaining > 0 {
            let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY,
                                  width: trackRect.width * Double(remaining) / 100, height: trackRect.height)
            let fillColor = dark ? NSColor.white : NSColor.black
            fillColor.withAlphaComponent(highContrast ? 0.30 : (dark ? 0.18 : 0.13)).setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: 9, yRadius: 9).fill()
        }
        if highContrast {
            foreground.withAlphaComponent(0.5).setStroke()
            track.lineWidth = 1
            track.stroke()
        }
        let percentAttributes: [NSAttributedString.Key: Any] = [.font: percentFont, .foregroundColor: foreground]
        let percentSize = (percentText as NSString).size(withAttributes: percentAttributes)
        (percentText as NSString).draw(at: NSPoint(x: trackRect.midX - percentSize.width / 2,
                                                  y: trackRect.midY - percentSize.height / 2), withAttributes: percentAttributes)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let statusContent = MenuBarContentView(frame: .zero)
    private var timer: Timer?
    private var quota: QuotaResponse?
    private var updatedAt: Date?
    private var error: String?
    private var refreshing = false
    private var loginError: String?
    private var autoStart: Bool { SMAppService.mainApp.status == .enabled }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = ""
            statusContent.frame = button.bounds
            statusContent.autoresizingMask = [.width, .height]
            button.addSubview(statusContent)
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        if !UserDefaults.standard.bool(forKey: "autoStartDisabled"),
           SMAppService.mainApp.status != .enabled, SMAppService.mainApp.status != .requiresApproval {
            do { try SMAppService.mainApp.register() }
            catch { loginError = "登录自动启动未启用，可点击下方选项重试。" }
        }
        render()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
    }

    private var stale: Bool { updatedAt.map { Date().timeIntervalSince($0) > 180 } ?? false }

    private func dateText(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private func row(_ title: String, action: Selector? = nil) {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: "")
        row.target = self
        item.menu?.addItem(row)
    }

    private func render() {
        var title = quota?.title ?? (refreshing ? "…" : "—")
        if quota != nil && (error != nil || stale) { title += " !" }
        let remaining = quota?.buckets.first?.1.windows.compactMap { $0.remaining }.first
        let progressText = remaining.map { "\($0)%" } ?? (refreshing ? "…" : "—")
        let needsAttention = quota != nil && (error != nil || stale)
        statusContent.remaining = remaining
        statusContent.percentText = progressText
        statusContent.needsAttention = needsAttention
        item.length = statusContent.preferredWidth
        statusContent.needsDisplay = true
        item.button?.setAccessibilityLabel("Codex 剩余额度：\(title)")
        item.button?.toolTip = error ?? "Codex 剩余使用量，每 60 秒刷新。点击查看各窗口及重置时间。"
        item.menu?.removeAllItems()
        let plan = quota?.buckets.first?.1.planType.map { " · \($0.capitalized)" } ?? ""
        row("Codex 额度\(plan)")
        item.menu?.addItem(.separator())
        if let quota {
            for (id, bucket) in quota.buckets {
                if quota.buckets.count > 1 { row(bucket.limitName ?? id) }
                for window in bucket.windows {
                    let remaining = window.remaining.map { "\($0)%" } ?? "未知"
                    row("\(window.label)：剩余 \(remaining)")
                    if let used = window.usedPercent { row(String(format: "    已使用 %.1f%%", used)) }
                    if let reset = window.resetsAt {
                        row("    重置：\(dateText(Date(timeIntervalSince1970: reset), format: "M月d日 E HH:mm"))")
                    }
                }
                if bucket.windows.isEmpty { row("当前未返回额度窗口") }
            }
        } else { row("等待读取额度…") }
        item.menu?.addItem(.separator())
        if let updatedAt { row("上次成功更新：\(dateText(updatedAt, format: "M/d HH:mm:ss"))") }
        if let error { row(error) }
        else if stale { row("数据已过期，正在等待刷新") }
        row(refreshing ? "正在刷新…" : "立即刷新", action: refreshing ? nil : #selector(refresh))
        row("每 60 秒自动刷新")
        item.menu?.addItem(.separator())
        row("打开 Codex", action: #selector(openCodex))
        if let loginError { row(loginError) }
        let loginTitle = SMAppService.mainApp.status == .requiresApproval ? "允许登录自动启动…" : (autoStart ? "✓ 登录后自动启动" : "登录后自动启动")
        row(loginTitle, action: #selector(toggleAutoStart))
        row("退出", action: #selector(quit))
        writeStatus("Codex [\(progressText)]\(needsAttention ? " !" : "")")
    }

    private func writeStatus(_ title: String) {
        // Only display data is saved; authentication is handled by Codex itself.
        var status: [String: Any] = ["title": title, "refreshing": refreshing, "autoRefreshSeconds": 60,
            "autoStart": autoStart, "stale": stale, "observedAt": ISO8601DateFormatter().string(from: Date())]
        status["menuBarItemVisible"] = item.isVisible
        status["menuBarWindowVisible"] = item.button?.window?.isVisible ?? false
        status["iconStyle"] = "capsule-progress"
        status["label"] = statusContent.label
        status["progressPosition"] = "right"
        status["iconVisible"] = statusContent.superview === item.button && !statusContent.isHidden
        status["appearance"] = statusContent.effectiveAppearance.name.rawValue
        status["contentWidth"] = statusContent.bounds.width
        status["percentText"] = statusContent.percentText
        if let remaining = quota?.buckets.first?.1.windows.compactMap({ $0.remaining }).first {
            status["iconRemainingPercent"] = remaining
        }
        status["loginItemStatus"] = SMAppService.mainApp.status.rawValue
        if let loginError { status["loginError"] = loginError }
        if let updatedAt { status["updatedAt"] = ISO8601DateFormatter().string(from: updatedAt) }
        if let error { status["error"] = error }
        if let quota {
            status["windows"] = quota.buckets.flatMap { id, bucket in bucket.windows.map { window -> [String: Any] in
                var value: [String: Any] = ["bucket": id, "label": window.label]
                if let remaining = window.remaining { value["remainingPercent"] = remaining }
                if let used = window.usedPercent { value["usedPercent"] = used }
                if let reset = window.resetsAt { value["resetsAt"] = reset }
                return value
            }}
        }
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: supportDirectory.appendingPathComponent("status.json"), options: .atomic)
        }
    }

    @objc private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        render()
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try QuotaClient.read() }
            DispatchQueue.main.async {
                self.refreshing = false
                switch result {
                case .success(let quota):
                    self.quota = quota
                    self.updatedAt = Date()
                    self.error = quota.buckets.contains(where: { !$0.1.windows.isEmpty }) ? nil : "当前账号未返回额度数据。"
                case .failure(let error): self.error = error.localizedDescription
                }
                self.render()
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) { render() }
    @objc private func woke() { refresh() }
    @objc private func openCodex() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let urls = [URL(fileURLWithPath: "/Applications/ChatGPT.app"), URL(fileURLWithPath: "/Applications/Codex.app"),
                    home.appendingPathComponent("Applications/ChatGPT.app"), home.appendingPathComponent("Applications/Codex.app")]
        if let url = urls.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    @objc private func toggleAutoStart() {
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        do {
            if autoStart {
                try SMAppService.mainApp.unregister()
                UserDefaults.standard.set(true, forKey: "autoStartDisabled")
            } else {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(false, forKey: "autoStartDisabled")
            }
            loginError = nil
        } catch { loginError = "自动启动设置未保存，请重试。" }
        render()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--check") {
    do {
        let quota = try QuotaClient.read()
        print(quota.title)
        for (_, bucket) in quota.buckets {
            for window in bucket.windows {
                let remaining = window.remaining.map { String($0) } ?? "unknown"
                let reset = window.resetsAt.map { String($0) } ?? "unknown"
                print("\(window.label): remaining=\(remaining)%, resetsAt=\(reset)")
            }
        }
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else {
    let application = NSApplication.shared
    let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.codex-usage")
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !otherInstances.isEmpty { exit(0) }
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
