import Foundation

// 取得処理はバックグラウンドで走るため、データ型と保存先は MainActor から切り離す
nonisolated struct UsageSnapshot: Codable {
    var claude: ServiceUsage?
    var codex: ServiceUsage?
    var copilot: ServiceUsage?
    var system: SystemSample?
    var fetchedAt: Date
    /// 本体が表示すると決めた項目。ウィジェットは UserDefaults を共有できないので、
    /// 選択内容もこのファイル経由で渡す
    var enabledItems: [String]? = nil

    var enabled: Set<DisplayItem> { DisplayItem.decode(enabledItems) }
}

nonisolated struct ServiceUsage: Codable {
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

nonisolated struct DetailItem: Codable, Identifiable {
    var id: String { label }
    var label: String
    var value: String
}

nonisolated struct Gauge: Codable, Identifiable {
    var id: String { label }
    var label: String
    var usedPercent: Double
    var resetsAt: Date?

    var remainingPercent: Double { max(0, 100 - usedPercent) }
}

// 各指標は「無効なので取っていない」を nil で表す。既存の JSON もそのまま読める
nonisolated struct SystemSample: Codable {
    var cpuPercent: Double?
    var memUsedBytes: UInt64?
    var memTotalBytes: UInt64?
    var sampledAt: Date
    var memActiveBytes: UInt64? = nil
    var memWiredBytes: UInt64? = nil
    var memCompressedBytes: UInt64? = nil
    var battery: BatterySample? = nil
    var disk: DiskSample? = nil
    var network: NetworkSample? = nil

    var memUsedGB: Double { Double(memUsedBytes ?? 0) / 1_073_741_824 }
    var memTotalGB: Double { Double(memTotalBytes ?? 0) / 1_073_741_824 }

    var memFraction: Double? {
        guard let used = memUsedBytes, let total = memTotalBytes, total > 0 else { return nil }
        return Double(used) / Double(total)
    }
}

nonisolated struct BatterySample: Codable {
    var percent: Double
    var isCharging: Bool
    /// 電源に繋がっているか。満充電で充電が止まっている間も true
    var isPluggedIn: Bool
    /// 残り時間 / 満充電までの時間。macOS が算出中の間は nil
    var minutesToEmpty: Int? = nil
    var minutesToFull: Int? = nil
    /// "Good" / "Fair" / "Poor" など。取れないモデルもあるので optional
    var health: String? = nil

    var fraction: Double { min(max(percent / 100, 0), 1) }
}

nonisolated struct DiskSample: Codable {
    var usedBytes: UInt64
    var totalBytes: UInt64
    var freeBytes: UInt64
    var volumeName: String? = nil

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }
}

nonisolated struct NetworkSample: Codable {
    var inBytesPerSecond: Double
    var outBytesPerSecond: Double
    var totalInBytes: UInt64
    var totalOutBytes: UInt64
}

nonisolated enum SharedStore {
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
