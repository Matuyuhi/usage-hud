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

/// CPU / メモリの上位プロセス。ps を 1 回起動して全プロセスを取り、両方の並びをここで作る。
///
/// libproc(proc_listallpids / proc_pidinfo)は SDK の module map に libproc.h が無く
/// Swift から直接は呼べないうえ、他ユーザ(root デーモン)のプロセスが EPERM で引けない。
/// 一方 ps は全プロセスを返し、%CPU も OS 側の減衰平均をそのまま使える
nonisolated enum ProcessSampler {
    /// 一覧に出す件数
    static let limit = 5
    /// 走査の最小間隔。2 秒のシステム指標タイマーから呼ばれるので、ここで間引く
    static let interval: TimeInterval = 5

    static func sample() async -> ProcessSample? {
        // プロセス起動は main を塞ぐので off-main で回す
        await runOffMain { scan() }
    }

    private static func scan() -> ProcessSample? {
        // -w を 2 回渡して端末幅での切り詰めを止める(実行ファイルのパスが途中で切れると名前が化ける)。
        // 列は "=" 付きで見出しを消す。カンマ区切りだと空見出しの解釈が ps の実装依存になるので -o を並べる
        guard let session = try? ProcessSession(
            command: "ps",
            arguments: ["-A", "-w", "-w", "-o", "pid=", "-o", "pcpu=", "-o", "rss=", "-o", "comm="],
            timeout: 5)
        else { return nil }
        defer { session.terminate() }
        session.readUntilEOF()

        let usages = session.lines().compactMap { parse($0) }
        guard !usages.isEmpty else { return nil }
        return ProcessSample(
            topCPU: Array(usages.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit)),
            topMemory: Array(usages.sorted { $0.memBytes > $1.memBytes }.prefix(limit)))
    }

    /// "  123   4.5  98304 /Applications/Foo.app/Contents/MacOS/Foo" の 1 行。
    /// 実行ファイルのパスには空白が入るので、前から 3 列だけ切り出して残り全部を名前に使う
    private static func parse(_ line: String) -> ProcessUsage? {
        var rest = Substring(line)
        func nextField() -> Substring? {
            rest = rest.drop { $0 == " " }
            let field = rest.prefix { $0 != " " }
            guard !field.isEmpty else { return nil }
            rest = rest.dropFirst(field.count)
            return field
        }

        guard let pid = nextField().flatMap({ Int32($0) }),
              let cpuField = nextField(),
              // ps の RSS は KiB
              let residentKB = nextField().flatMap({ UInt64($0) })
        else { return nil }
        let path = rest.drop { $0 == " " }
        guard !path.isEmpty else { return nil }

        // 小数点がロケールで "," になっても読めるようにする
        let cpuPercent = Double(cpuField.replacingOccurrences(of: ",", with: ".")) ?? 0
        return ProcessUsage(
            pid: pid,
            name: URL(fileURLWithPath: String(path)).lastPathComponent,
            cpuPercent: cpuPercent,
            memBytes: residentKB * 1024)
    }
}
