import SwiftUI
import WidgetKit

/// ウィジェットの描画本体。shared に置くのは、本体側のスナップショットテストから描くため
/// (extension はテストのホストになれない)。TimelineProvider と Widget 本体は extension 側にある
struct UsageWidgetView: View {
    var snapshot: UsageSnapshot?
    var family: WidgetFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let snapshot {
                // 本体で表示対象から外した項目はウィジェットにも出さない
                let enabled = snapshot.enabled
                let services = DisplayItem.services.filter { enabled.contains($0) }
                let metrics = snapshot.system.map { systemParts($0, enabled: enabled) } ?? []
                // サービス名と残量の列幅は実際の文言から揃える(言語で語長が変わるため固定値で持たない)
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(services) { service in
                        serviceLine(name: shortName(service), usage: usage(for: service, in: snapshot))
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 2) {
                    // 小サイズは横幅が足りないので普段は指標を省くが、
                    // サービスを 1 つも表示しない設定では指標だけが中身なので縦に並べて出す
                    if family == .systemSmall {
                        if services.isEmpty {
                            ForEach(metrics, id: \.self) { metric in
                                Text(metric)
                            }
                        }
                    } else if !metrics.isEmpty {
                        Text(metrics.joined(separator: " · "))
                            .lineLimit(1)
                    }
                    Text("Updated \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            } else {
                Text("Launch usage-hud to see your usage here")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func shortName(_ service: DisplayItem) -> String {
        switch service {
        case .claude: "Claude"
        case .codex: "Codex"
        case .copilot: "Copilot"
        default: service.rawValue
        }
    }

    private func usage(for service: DisplayItem, in snapshot: UsageSnapshot) -> ServiceUsage? {
        switch service {
        case .claude: snapshot.claude
        case .codex: snapshot.codex
        case .copilot: snapshot.copilot
        default: nil
        }
    }

    // GridRow は Grid の直接の子である必要があるため、行はメソッドで組む(View に包まない)
    private func serviceLine(name: String, usage: ServiceUsage?) -> some View {
        // 最も逼迫しているゲージを代表として出す
        let worst = usage?.gauges.max { $0.usedPercent < $1.usedPercent }
        return GridRow {
            Text(name)
                .font(.caption2.weight(.semibold))
            if let worst {
                UsageBar(fraction: worst.usedPercent / 100, height: DesignTokens.widgetBarHeight)
                Text(percentText(worst.remainingPercent))
                    .font(.caption2.monospacedDigit())
                    .gridColumnAlignment(.trailing)
            } else if usage?.error != nil {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            } else {
                Text("-")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
        }
    }

    /// 表示している指標だけを並べる。狭いのでラベルは短縮形にする
    private func systemParts(_ system: SystemSample, enabled: Set<DisplayItem>) -> [String] {
        var parts: [String] = []
        if enabled.contains(.cpu), let cpu = system.cpuPercent {
            parts.append("CPU \(percentText(cpu))")
        }
        if enabled.contains(.memory), system.memTotalBytes != nil {
            parts.append(String(format: "MEM %.0f/%.0fGB", system.memUsedGB, system.memTotalGB))
        }
        if enabled.contains(.battery), let battery = system.battery {
            parts.append("BAT \(percentText(battery.percent))" + (battery.isPluggedIn ? "⚡" : ""))
        }
        if enabled.contains(.disk), let disk = system.disk {
            parts.append("SSD \(percentText(disk.fraction * 100))")
        }
        if enabled.contains(.network), let network = system.network {
            parts.append("↓" + rateText(network.inBytesPerSecond))
        }
        return parts
    }
}
