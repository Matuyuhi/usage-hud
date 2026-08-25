import Foundation

/// 上位プロセス 1 件。CPU% はアクティビティモニタと同じくコア数で割らないので、
/// 複数コアを使い切るプロセスは 100% を超える
nonisolated struct ProcessUsage: Identifiable, Sendable {
    let pid: Int32
    let name: String
    let cpuPercent: Double
    let memBytes: UInt64

    var id: Int32 { pid }
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
        // プロセス起動は main を塞ぐので off-main で回す
        return await runOffMain { scan(wanted) }
    }

    private static func scan(_ wanted: Set<DisplayItem>) -> ProcessSample? {
        let needsCPU = wanted.contains(.cpu)
        let needsMemory = wanted.contains(.memory)
        // -w を 2 回渡して端末幅での切り詰めを止める(実行ファイルのパスが途中で切れると名前が化ける)。
        // 列は "=" 付きで見出しを消す。カンマ区切りだと空見出しの解釈が ps の実装依存になるので -o を並べる
        var arguments = ["-A", "-w", "-w", "-o", "pid="]
        if needsCPU { arguments += ["-o", "pcpu="] }
        if needsMemory { arguments += ["-o", "rss="] }
        arguments += ["-o", "comm="]

        guard let session = try? ProcessSession(command: "ps", arguments: arguments, timeout: 5)
        else { return nil }
        defer { session.terminate() }
        session.readUntilEOF()

        let usages = session.lines().compactMap { parse($0, cpu: needsCPU, memory: needsMemory) }
        guard !usages.isEmpty else { return nil }
        return ProcessSample(
            topCPU: needsCPU
                ? Array(usages.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit)) : [],
            topMemory: needsMemory
                ? Array(usages.sorted { $0.memBytes > $1.memBytes }.prefix(limit)) : [])
    }

    /// "  123   4.5  98304 /Applications/Foo.app/Contents/MacOS/Foo" の 1 行。
    /// 中間の 2 列は要求したときだけ出るので、有効な指標に合わせて読み進める。
    /// 実行ファイルのパスには空白が入るので、残り全部を名前に使う
    private static func parse(_ line: String, cpu: Bool, memory: Bool) -> ProcessUsage? {
        var rest = Substring(line)
        func nextField() -> Substring? {
            rest = rest.drop { $0 == " " }
            let field = rest.prefix { $0 != " " }
            guard !field.isEmpty else { return nil }
            rest = rest.dropFirst(field.count)
            return field
        }

        guard let pid = nextField().flatMap({ Int32($0) }) else { return nil }
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

        return ProcessUsage(
            pid: pid,
            name: URL(fileURLWithPath: String(path)).lastPathComponent,
            cpuPercent: cpuPercent,
            memBytes: memBytes)
    }
}
