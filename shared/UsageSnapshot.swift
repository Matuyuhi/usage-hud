import Foundation

struct UsageSnapshot: Codable {
    var claude: ServiceUsage?
    var codex: ServiceUsage?
    var copilot: ServiceUsage?
    var system: SystemSample?
    var fetchedAt: Date
}

struct ServiceUsage: Codable {
    var gauges: [Gauge]
    var detail: String?
    var error: String?
    var updatedAt: Date
    var details: [DetailItem]? = nil
    var rateLimited: Bool? = nil

    static func failed(_ message: String) -> ServiceUsage {
        ServiceUsage(gauges: [], detail: nil, error: message, updatedAt: Date())
    }
}

struct DetailItem: Codable, Identifiable {
    var id: String { label }
    var label: String
    var value: String
}

struct Gauge: Codable, Identifiable {
    var id: String { label }
    var label: String
    var usedPercent: Double
    var resetsAt: Date?

    var remainingPercent: Double { max(0, 100 - usedPercent) }
}

struct SystemSample: Codable {
    var cpuPercent: Double
    var memUsedBytes: UInt64
    var memTotalBytes: UInt64
    var sampledAt: Date
    var memActiveBytes: UInt64? = nil
    var memWiredBytes: UInt64? = nil
    var memCompressedBytes: UInt64? = nil

    var memUsedGB: Double { Double(memUsedBytes) / 1_073_741_824 }
    var memTotalGB: Double { Double(memTotalBytes) / 1_073_741_824 }
}

enum SharedStore {
    // App Group ではなく実ホーム直下の Application Support を使う。
    // App Group は ID にチーム ID prefix が必須で、署名チームを持たない ad-hoc ビルドと両立しないため。
    // sandbox 内の widget は NSHomeDirectory がコンテナを指すので getpwuid で実ホームを引き、
    // temporary-exception entitlement で読み取りを許可している
    static var fileURL: URL? {
        realHomeDirectory?.appendingPathComponent("Library/Application Support/usage-hud/usage.json")
    }

    private static var realHomeDirectory: URL? {
        guard let passwd = getpwuid(getuid()), let dir = passwd.pointee.pw_dir else {
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.deletingLastPathComponent().deletingLastPathComponent()
        }
        return URL(fileURLWithPath: String(cString: dir))
    }

    static func save(_ snapshot: UsageSnapshot) {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> UsageSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UsageSnapshot.self, from: data)
    }
}
