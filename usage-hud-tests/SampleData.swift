import Foundation
@testable import usage_hud

/// スナップショットに使う固定データ。日時は固定し、テストは TZ=UTC で走らせる(scheme の Test 設定)
enum SampleData {
    /// 2026-01-02 03:04:00 UTC
    static let fetchedAt = Date(timeIntervalSince1970: 1_767_323_040)

    static let claude = ServiceUsage(
        gauges: [
            Gauge(label: "Session", usedPercent: 35, resetsAt: fetchedAt.addingTimeInterval(3 * 3600)),
            Gauge(label: "Weekly", usedPercent: 62, resetsAt: fetchedAt.addingTimeInterval(4 * 86400)),
        ],
        detail: "Max 5x",
        error: nil,
        updatedAt: fetchedAt,
        details: [
            DetailItem(label: "Plan", value: "Max 5x"),
            DetailItem(label: "Weekly (Opus)", value: "18%"),
            DetailItem(label: "Extra usage", value: "$12.40 / $50.00"),
        ])

    static let codex = ServiceUsage(
        gauges: [
            Gauge(label: "5h", usedPercent: 48, resetsAt: fetchedAt.addingTimeInterval(95 * 60)),
            Gauge(label: "Weekly", usedPercent: 12, resetsAt: fetchedAt.addingTimeInterval(5 * 86400)),
        ],
        detail: "Plus",
        error: nil,
        updatedAt: fetchedAt,
        details: [DetailItem(label: "Plan", value: "Plus")])

    static let copilot = ServiceUsage(
        gauges: [Gauge(label: "Premium", usedPercent: 81, resetsAt: fetchedAt.addingTimeInterval(20 * 86400))],
        detail: "1,215 / 1,500",
        error: nil,
        updatedAt: fetchedAt,
        details: [
            DetailItem(label: "Premium requests", value: "1,215 / 1,500"),
            DetailItem(label: "Overage", value: "Off"),
        ])

    /// 取得に失敗したが前回値が残っている(ゲージとエラーを併記する)ケース
    static var staleCopilot: ServiceUsage {
        var usage = copilot
        usage.error = "gh: token expired"
        return usage
    }

    static let system = SystemSample(
        cpuPercent: 47.5,
        memUsedBytes: 19_542_000_000,
        memTotalBytes: 34_359_738_368,
        sampledAt: fetchedAt,
        memActiveBytes: 9_100_000_000,
        memWiredBytes: 4_300_000_000,
        memCompressedBytes: 6_142_000_000,
        battery: BatterySample(percent: 76, isCharging: false, isPluggedIn: false, minutesToEmpty: 214, health: "Good"),
        disk: DiskSample(usedBytes: 310_000_000_000, totalBytes: 494_384_795_648, freeBytes: 184_384_795_648, volumeName: "Macintosh HD"),
        network: NetworkSample(inBytesPerSecond: 1_250_000, outBytesPerSecond: 88_000, totalInBytes: 42_000_000_000, totalOutBytes: 3_100_000_000))

    /// 内蔵バッテリーの無い Mac(バッテリー行の代わりに注記が出る)
    static var desktopSystem: SystemSample {
        var sample = system
        sample.battery = nil
        return sample
    }

    static let processes = ProcessSample(
        topCPU: [
            ProcessUsage(id: "/Applications/Xcode.app", name: "Xcode", cpuPercent: 142.3, memBytes: 6_400_000_000, processCount: 7),
            ProcessUsage(id: "/Applications/Google Chrome.app", name: "Google Chrome", cpuPercent: 38.1, memBytes: 4_100_000_000, processCount: 24),
            ProcessUsage(id: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", name: "WindowServer", cpuPercent: 12.4, memBytes: 900_000_000, processCount: 1),
            ProcessUsage(id: "/Applications/usage-hud.app", name: "usage-hud", cpuPercent: 1.2, memBytes: 60_000_000, processCount: 2),
            ProcessUsage(id: "kernel_task", name: "kernel_task", cpuPercent: 0.9, memBytes: 2_000_000_000, processCount: 1),
        ],
        topMemory: [
            ProcessUsage(id: "/Applications/Xcode.app", name: "Xcode", cpuPercent: 142.3, memBytes: 6_400_000_000, processCount: 7),
            ProcessUsage(id: "/Applications/Google Chrome.app", name: "Google Chrome", cpuPercent: 38.1, memBytes: 4_100_000_000, processCount: 24),
            ProcessUsage(id: "kernel_task", name: "kernel_task", cpuPercent: 0.9, memBytes: 2_000_000_000, processCount: 1),
            ProcessUsage(id: "/Applications/Slack.app", name: "Slack", cpuPercent: 0.4, memBytes: 1_300_000_000, processCount: 5),
            ProcessUsage(id: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", name: "WindowServer", cpuPercent: 12.4, memBytes: 900_000_000, processCount: 1),
        ])

    static func snapshot(
        claude: ServiceUsage? = SampleData.claude, codex: ServiceUsage? = SampleData.codex,
        copilot: ServiceUsage? = SampleData.copilot, system: SystemSample? = SampleData.system,
        enabled: Set<DisplayItem> = DisplayItem.defaultEnabled
    ) -> UsageSnapshot {
        UsageSnapshot(
            claude: enabled.contains(.claude) ? claude : nil,
            codex: enabled.contains(.codex) ? codex : nil,
            copilot: enabled.contains(.copilot) ? copilot : nil,
            system: system,
            fetchedAt: fetchedAt,
            enabledItems: DisplayItem.encode(enabled))
    }
}
