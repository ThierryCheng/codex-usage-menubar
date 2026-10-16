import Foundation

struct QuotaWindow: Codable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Double?

    var remaining: Int? {
        guard let usedPercent, usedPercent.isFinite else { return nil }
        return Int(floor(max(0, min(100, 100 - usedPercent))))
    }

    var label: String {
        guard let minutes = windowDurationMins else { return "额度" }
        if minutes == 10080 { return "周额度" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) 天额度" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时额度" }
        return "\(minutes) 分钟额度"
    }
}

struct QuotaBucket: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: QuotaWindow?
    let secondary: QuotaWindow?
    let planType: String?

    var windows: [QuotaWindow] { [primary, secondary].compactMap { $0 } }
}

struct QuotaResponse: Decodable {
    let rateLimits: QuotaBucket?
    let rateLimitsByLimitId: [String: QuotaBucket]?

    var buckets: [(String, QuotaBucket)] {
        if let map = rateLimitsByLimitId, !map.isEmpty {
            return map.sorted { lhs, rhs in
                if lhs.key == "codex" { return rhs.key != "codex" }
                if rhs.key == "codex" { return false }
                return lhs.key < rhs.key
            }
        }
        return rateLimits.map { [($0.limitId ?? "codex", $0)] } ?? []
    }

    var title: String {
        guard let bucket = buckets.first?.1 else { return "—" }
        let windows = bucket.windows.filter { $0.remaining != nil }
        guard !windows.isEmpty else { return "—" }
        if windows.count == 1 { return "\(windows[0].remaining!)%" }
        return windows.map { window in
            let label = window.windowDurationMins == 10080 ? "周" : window.label.replacingOccurrences(of: "额度", with: "")
            return "\(label) \(window.remaining!)%"
        }.joined(separator: " · ")
    }
}

enum QuotaError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

enum QuotaClient {
    static func read() throws -> QuotaResponse {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let applications = ["/Applications/ChatGPT.app", "/Applications/Codex.app",
                            home.appendingPathComponent("Applications/ChatGPT.app").path,
                            home.appendingPathComponent("Applications/Codex.app").path]
        let bundledPaths = ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"]
        let candidates = applications.flatMap { app in bundledPaths.map { "\(app)/\($0)" } } + [
            home.appendingPathComponent(".npm-global/bin/codex").path,
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw QuotaError.message("未找到 Codex，请先安装并登录 Codex。")
        }
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = home
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(home.path)/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeout)
        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
        }
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": [
            "name": "codex_usage_menubar", "title": "Codex Usage Menu Bar", "version": "1.0.0"
        ]]])
        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw QuotaError.message("读取中断或超时；请确认网络及 Codex 登录状态。") }
            buffer.append(chunk)
            guard buffer.count < 2_000_000 else { throw QuotaError.message("Codex 返回的数据异常。") }
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.subdata(in: 0..<newline)
                buffer.removeSubrange(0...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = message["id"] as? Int else { continue }
                if message["error"] != nil {
                    throw QuotaError.message("额度接口读取失败；请在 Codex 中确认登录状态后重试。")
                }
                if id == 1 {
                    try send(["method": "initialized", "params": [:]])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if id == 2, let result = message["result"] {
                    return try JSONDecoder().decode(QuotaResponse.self, from: JSONSerialization.data(withJSONObject: result))
                }
            }
        }
    }
}
