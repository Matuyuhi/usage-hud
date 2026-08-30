import Foundation

/// 上位プロセス 1 件。同じアプリに属するヘルパーはまとめて 1 行にするので、
/// 値は processCount 個ぶんの合計になることがある。
/// CPU% はアクティビティモニタと同じくコア数で割らないので、
/// 複数コアを使い切るプロセスは 100% を超える
nonisolated struct ProcessUsage: Identifiable, Sendable {
    /// アプリならバンドルのパス、そうでなければ実行ファイルのパス
    let id: String
    let name: String
    let cpuPercent: Double
    let memBytes: UInt64
    /// まとめたプロセス数(1 なら単独プロセス)
    let processCount: Int
}

nonisolated struct ProcessSample: Sendable {
    let topCPU: [ProcessUsage]
    let topMemory: [ProcessUsage]
}

/// CPU / メモリの上位プロセス。ps を 1 回起動して全プロセスを取り、有効な指標の並びだけ作る。
///
/// libproc(proc_listallpids / proc_pidinfo)は SDK の module map に libproc.h が無く
/// Swift から直接は呼べないうえ、他ユーザ(root デーモン)のプロセスが EPERM で引けない。
/// 一方 ps は全プロセスを返し、%CPU も OS 側の減衰平均をそのまま使える
nonisolated enum ProcessSampler {
    /// 一覧に出す件数
    static let limit = 5
    /// 走査の最小間隔。2 秒のシステム指標タイマーから呼ばれるので、ここで間引く
    static let interval: TimeInterval = 5

    /// metrics は表示中の CPU / メモリ。無効な指標は ps の列にも入れず、並べ替えもしない
    static func sample(metrics: Set<DisplayItem>) async -> ProcessSample? {
        let wanted = metrics.intersection([.cpu, .memory])
        guard !wanted.isEmpty else { return nil }
        // プロセス起動と Info.plist の読み出しは main を塞ぐので off-main で回す
        return await runOffMain { scan(wanted) }
    }

    private static func scan(_ wanted: Set<DisplayItem>) -> ProcessSample? {
        let needsCPU = wanted.contains(.cpu)
        let needsMemory = wanted.contains(.memory)
        // -w を 2 回渡して端末幅での切り詰めを止める(実行ファイルのパスが途中で切れると名前が化ける)。
        // 列は "=" 付きで見出しを消す。カンマ区切りだと空見出しの解釈が ps の実装依存になるので -o を並べる。
        // pid は表示にも集計にも使わないので要求しない
        var arguments = ["-A", "-w", "-w"]
        if needsCPU { arguments += ["-o", "pcpu="] }
        if needsMemory { arguments += ["-o", "rss="] }
        arguments += ["-o", "comm="]

        guard let session = try? ProcessSession(command: "ps", arguments: arguments, timeout: 5, prependCustomPaths: false)
        else { return nil }
        defer { session.terminate() }
        session.readUntilEOF()

        // 同じアプリのヘルパー(Electron 系は Renderer / GPU などに分かれる)は 1 行にまとめる。
        // 別々に出すと上位 5 件が同じアプリで埋まるうえ、アプリ全体の使用量が読めない
        var groups: [String: ProcessUsage] = [:]
        for line in session.lines() {
            guard let entry = parse(line, cpu: needsCPU, memory: needsMemory) else { continue }
            let app = AppNames.resolve(executablePath: entry.path)
            if let merged = groups[app.key] {
                groups[app.key] = ProcessUsage(
                    id: app.key,
                    name: merged.name,
                    cpuPercent: merged.cpuPercent + entry.cpuPercent,
                    memBytes: merged.memBytes + entry.memBytes,
                    processCount: merged.processCount + 1)
            } else {
                groups[app.key] = ProcessUsage(
                    id: app.key,
                    name: app.name,
                    cpuPercent: entry.cpuPercent,
                    memBytes: entry.memBytes,
                    processCount: 1)
            }
        }
        guard !groups.isEmpty else { return nil }

        let usages = Array(groups.values)
        return ProcessSample(
            topCPU: needsCPU
                ? Array(usages.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit)) : [],
            topMemory: needsMemory
                ? Array(usages.sorted { $0.memBytes > $1.memBytes }.prefix(limit)) : [])
    }

    /// ps の 1 行ぶん。名前はここでは決めず、実行ファイルのパスのまま返す
    private struct Entry {
        let path: String
        let cpuPercent: Double
        let memBytes: UInt64
    }

    /// "  4.5  98304 /Applications/Foo.app/Contents/MacOS/Foo" の 1 行。
    /// 先頭の 2 列は要求したときだけ出るので、有効な指標に合わせて読み進める。
    /// 実行ファイルのパスには空白が入るので、残り全部をパスに使う
    private static func parse(_ line: String, cpu: Bool, memory: Bool) -> Entry? {
        var rest = Substring(line)
        func nextField() -> Substring? {
            rest = rest.drop { $0 == " " }
            let field = rest.prefix { $0 != " " }
            guard !field.isEmpty else { return nil }
            rest = rest.dropFirst(field.count)
            return field
        }

        var cpuPercent: Double = 0
        if cpu {
            guard let field = nextField() else { return nil }
            // 小数点がロケールで "," になっても読めるようにする
            cpuPercent = Double(field.replacingOccurrences(of: ",", with: ".")) ?? 0
        }
        var memBytes: UInt64 = 0
        if memory {
            // ps の RSS は KiB
            guard let residentKB = nextField().flatMap({ UInt64($0) }) else { return nil }
            memBytes = residentKB * 1024
        }
        let path = rest.drop { $0 == " " }
        guard !path.isEmpty else { return nil }

        return Entry(path: String(path), cpuPercent: cpuPercent, memBytes: memBytes)
    }
}

/// 実行ファイルのパスからアプリの表示名を引く。
///
/// ps が返すのは実行ファイルなので、そのままだと Android Studio が "studio"、
/// Electron 系のヘルパーが "Slack Helper (Renderer)" のように出る。
/// パスに含まれる**一番外側の** .app まで遡ってバンドルの表示名を使うと、
/// ヘルパー(Foo.app/Contents/Frameworks/Foo Helper.app/…)や
/// XPC サービス(Foo.app/Contents/XPCServices/Bar.xpc/…)も親アプリの名前になる。
/// .app の外にいる WindowServer などのシステムプロセスは、アクティビティモニタと同じく実行ファイル名のまま
nonisolated enum AppNames {
    struct Resolved {
        /// 同じアプリのプロセスをまとめるためのキー
        let key: String
        let name: String
    }

    private static let cache = BundleNameCache()

    static func resolve(executablePath path: String) -> Resolved {
        guard let bundlePath = outermostAppBundle(in: path) else {
            return Resolved(key: path, name: (path as NSString).lastPathComponent)
        }
        return Resolved(key: bundlePath, name: cache.name(ofBundle: bundlePath))
    }

    /// "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"
    /// → "/Applications/Slack.app"
    private static func outermostAppBundle(in path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let end = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return components[...end].joined(separator: "/")
    }
}

/// バンドルの表示名は毎回 Info.plist を読むと 5 秒ごとのディスク I/O になるので覚えておく。
/// off-main の走査から呼ばれるだけだが、将来どこから呼ばれても壊れないようロックで守る。
/// 本体は既定 MainActor 隔離なので nonisolated を明示する(付け忘れると呼び出し側でコンパイルが落ちる)
private nonisolated final class BundleNameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String] = [:]

    func name(ofBundle bundlePath: String) -> String {
        lock.lock()
        let cached = names[bundlePath]
        lock.unlock()
        if let cached { return cached }

        let resolved = Self.read(bundlePath)
        lock.lock()
        names[bundlePath] = resolved
        lock.unlock()
        return resolved
    }

    /// 表示名は CFBundleDisplayName → CFBundleName の順。どちらも無ければバンドル名から .app を落とす。
    /// localizedInfoDictionary を先に見るのは、日本語名を持つアプリ(システム設定など)に合わせるため
    private static func read(_ bundlePath: String) -> String {
        let fallback = ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        guard let bundle = Bundle(path: bundlePath) else { return fallback }
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            let value: Any? = bundle.localizedInfoDictionary?[key] ?? bundle.infoDictionary?[key]
            if let name = value.flatMap({ $0 as? String }), !name.isEmpty { return name }
        }
        return fallback
    }
}
