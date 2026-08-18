import Foundation

// MARK: - Claude Code

enum ClaudeFetcher {
    static func fetch() async -> ServiceUsage {
        do {
            // Keychain 許可ダイアログ表示中に main thread を塞がないよう off-main で読む
            let token = try await runOffMain { try accessToken() }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                if code == 401 {
                    // token refresh は Claude Code 本体に任せる(refresh token rotation を壊さないため)
                    throw FetchError.message("認証切れ。Claude Code を開くと更新されます")
                }
                if code == 429 {
                    throw FetchError.rateLimited
                }
                throw FetchError.message("HTTP \(code)")
            }
            return try parse(data)
        } catch let error as FetchError {
            return error.asServiceUsage
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // SecItemCopyMatching ではなく security コマンド経由で読む。
    // アプリ自身の署名 identity に Keychain ACL が紐づかないため、
    // ad-hoc 署名でもリビルドごとの許可ダイアログが出ない
    private nonisolated static func accessToken() throws -> String {
        let session = try ProcessSession(
            command: "security",
            arguments: ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
            timeout: 10)
        defer { session.terminate() }
        session.readUntilEOF()
        let raw = session.lines().joined()
        guard !raw.isEmpty else {
            throw FetchError.message("Keychain に認証なし (claude でログインしてください)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else {
            throw FetchError.message("credential の形式が不明")
        }
        return token
    }

    private static func parse(_ data: Data) throws -> ServiceUsage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = json["limits"] as? [[String: Any]]
        else { throw FetchError.message("レスポンスの形式が不明") }

        var gauges: [Gauge] = []
        for limit in limits {
            guard let kind = limit["kind"] as? String,
                  let percent = limit["percent"] as? Double else { continue }
            let resets = (limit["resets_at"] as? String).flatMap(parseISODate)
            let label: String
            switch kind {
            case "session": label = "5時間"
            case "weekly_all": label = "週"
            case "weekly_scoped":
                let model = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                label = "週 (\(model ?? "モデル別"))"
            default: continue
            }
            gauges.append(Gauge(label: label, usedPercent: percent, resetsAt: resets))
        }
        var details: [DetailItem] = gauges.compactMap { gauge in
            gauge.resetsAt.map { DetailItem(label: "\(gauge.label) リセット", value: formatDetailDate($0)) }
        }
        if let extra = json["extra_usage"] as? [String: Any] {
            if (extra["is_enabled"] as? Bool) == true {
                let used = (extra["used_credits"] as? Double).map { String(format: " (使用 %.0f)", $0) } ?? ""
                details.append(DetailItem(label: "追加クレジット", value: "有効" + used))
            } else {
                details.append(DetailItem(label: "追加クレジット", value: "無効"))
            }
        }
        return ServiceUsage(gauges: gauges, detail: nil, error: nil, updatedAt: Date(), details: details)
    }
}

// MARK: - Codex

enum CodexFetcher {
    static func fetch() async -> ServiceUsage {
        await runOffMain {
            do {
                return try fetchSync()
            } catch let error as FetchError {
                return .failed(error.text)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    private nonisolated static func fetchSync() throws -> ServiceUsage {
        let session = try ProcessSession(command: "codex", arguments: ["app-server"], timeout: 15)
        defer { session.terminate() }
        // initialize の応答を待ってから次を送る。まとめて書き込むと app-server が 2 通目を無視する
        session.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"usage-hud","title":"usage-hud","version":"1.0"}}}"#)
        try session.waitForLine(containing: "\"id\":1")
        session.send(#"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}"#)
        try session.waitForLine(containing: "\"id\":2")
        let output = session.lines()
        guard let line = output.first(where: { $0.contains("\"id\":2") }),
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let rateLimits = result["rateLimits"] as? [String: Any]
        else { throw FetchError.message("rateLimits を取得できず (codex login を確認)") }

        var gauges: [Gauge] = []
        var details: [DetailItem] = []
        if let individual = rateLimits["individualLimit"] as? [String: Any],
           let remaining = individual["remainingPercent"] as? Double {
            let resets = (individual["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
            gauges.append(Gauge(label: "月", usedPercent: 100 - remaining, resetsAt: resets))
            if let limit = looseDouble(individual["limit"]), let used = looseDouble(individual["used"]) {
                details.append(DetailItem(
                    label: "月間クレジット", value: "\(groupedNumber(used)) / \(groupedNumber(limit))"))
            }
            if let resets {
                details.append(DetailItem(label: "リセット", value: formatDetailDate(resets)))
            }
        }
        if let credits = rateLimits["credits"] as? [String: Any],
           let balance = looseDouble(credits["balance"]) {
            details.append(DetailItem(label: "クレジット残高", value: groupedNumber(balance)))
        }
        // プランによっては 5h/週のウィンドウ形式で返る
        for key in ["primary", "secondary"] {
            guard let window = rateLimits[key] as? [String: Any],
                  let used = window["used_percent"] as? Double else { continue }
            let minutes = window["window_minutes"] as? Double ?? 0
            let label = minutes >= 10000 ? "週" : "5時間"
            let resets = (window["resets_in_seconds"] as? Double).map { Date().addingTimeInterval($0) }
            gauges.append(Gauge(label: label, usedPercent: used, resetsAt: resets))
        }
        let plan = rateLimits["planType"] as? String
        return ServiceUsage(gauges: gauges, detail: plan, error: nil, updatedAt: Date(), details: details)
    }
}

// MARK: - Copilot

enum CopilotFetcher {
    static func fetch() async -> ServiceUsage {
        do {
            let token = try await runOffMain { try ghToken() }
            var request = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
            request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                if code == 429 {
                    throw FetchError.rateLimited
                }
                throw FetchError.message("HTTP \(code) (gh auth status を確認)")
            }
            return try parse(data)
        } catch let error as FetchError {
            return error.asServiceUsage
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private nonisolated static func ghToken() throws -> String {
        let session = try ProcessSession(command: "gh", arguments: ["auth", "token"], timeout: 10)
        defer { session.terminate() }
        session.readUntilEOF()
        guard let token = session.lines().first(where: { !$0.isEmpty }) else {
            throw FetchError.message("gh 未ログイン (gh auth login を実行)")
        }
        return token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parse(_ data: Data) throws -> ServiceUsage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshots = json["quota_snapshots"] as? [String: Any]
        else { throw FetchError.message("quota_snapshots が無い") }

        let reset = (json["quota_reset_date"] as? String).flatMap { string -> Date? in
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.date(from: string)
        }
        var gauges: [Gauge] = []
        var details: [DetailItem] = []
        if let premium = snapshots["premium_interactions"] as? [String: Any],
           (premium["unlimited"] as? Bool) != true,
           let remaining = premium["percent_remaining"] as? Double {
            gauges.append(Gauge(label: "Premium", usedPercent: 100 - remaining, resetsAt: reset))
            if let left = premium["remaining"] as? Double, let total = premium["entitlement"] as? Double {
                details.append(DetailItem(
                    label: "Premium 残り", value: "\(groupedNumber(left)) / \(groupedNumber(total))"))
            }
            if let overage = premium["overage_permitted"] as? Bool {
                details.append(DetailItem(label: "超過利用", value: overage ? "許可" : "不可"))
            }
        }
        for (key, label) in [("chat", "チャット"), ("completions", "コード補完")] {
            if let snapshot = snapshots[key] as? [String: Any],
               (snapshot["unlimited"] as? Bool) == true {
                details.append(DetailItem(label: label, value: "無制限"))
            }
        }
        if let reset {
            details.append(DetailItem(label: "リセット", value: formatDetailDate(reset)))
        }
        return ServiceUsage(gauges: gauges, detail: json["copilot_plan"] as? String,
                            error: nil, updatedAt: Date(), details: details)
    }
}

// MARK: - Helpers

nonisolated enum FetchError: Error {
    case message(String)
    case rateLimited

    var text: String {
        switch self {
        case .message(let text): return text
        case .rateLimited: return "レート制限中 (自動で回復します)"
        }
    }

    var asServiceUsage: ServiceUsage {
        var failed = ServiceUsage.failed(text)
        if case .rateLimited = self { failed.rateLimited = true }
        return failed
    }
}

/// 微秒精度の fractional seconds を含む ISO8601 に対応(ISO8601DateFormatter は 3 桁までしか受けない)
nonisolated func parseISODate(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: string) { return date }
    // fractional seconds を除去して再試行
    if let dotIndex = string.firstIndex(of: ".") {
        let tail = string[dotIndex...]
        if let end = tail.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            return formatter.date(from: String(string[..<dotIndex]) + String(string[end...]))
        }
    }
    return nil
}

nonisolated func formatDetailDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "M/d HH:mm"
    return formatter.string(from: date)
}

nonisolated func groupedNumber(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
}

/// codex の rateLimits は数値が文字列で返る("550" 等)ため両対応で取り出す
nonisolated func looseDouble(_ any: Any?) -> Double? {
    if let value = any as? Double { return value }
    if let string = any as? String { return Double(string) }
    return nil
}

private func runOffMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: work())
        }
    }
}

private func runOffMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result(catching: work))
        }
    }
}

/// Homebrew 等の CLI を PATH 解決込みで起動し、行単位の対話(送信→応答待ち)を行うセッション。
/// GUI アプリの PATH に CLI の場所が含まれないことがあるため、既知の bin ディレクトリを前置する
private nonisolated final class ProcessSession {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private var buffer = Data()
    private let deadline: Date
    private let command: String

    init(command: String, arguments: [String], timeout: TimeInterval) throws {
        self.command = command
        self.deadline = Date().addingTimeInterval(timeout)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        var environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + path
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardInput = stdinPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        // availableData がブロックしたままでも timeout で pipe が閉じるように保険をかける
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
            if let process, process.isRunning { process.terminate() }
        }
    }

    func send(_ line: String) {
        stdinPipe.fileHandleForWriting.write(Data((line + "\n").utf8))
    }

    /// needle を含む行(改行まで到達済み)が現れるまで stdout を読む
    func waitForLine(containing needle: String) throws {
        let handle = stdoutPipe.fileHandleForReading
        while Date() < deadline {
            let text = String(decoding: buffer, as: UTF8.self)
            if let range = text.range(of: needle), text[range.upperBound...].contains("\n") {
                return
            }
            let chunk = handle.availableData
            if chunk.isEmpty { break }  // EOF
            buffer.append(chunk)
        }
        throw FetchError.message("\(command) が応答しません (ログイン状態を確認)")
    }

    func readUntilEOF() {
        stdinPipe.fileHandleForWriting.closeFile()
        let handle = stdoutPipe.fileHandleForReading
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
    }

    func lines() -> [String] {
        String(decoding: buffer, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
