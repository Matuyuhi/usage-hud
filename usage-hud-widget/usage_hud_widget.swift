import WidgetKit
import SwiftUI

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: SharedStore.load())
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: Date(), snapshot: SharedStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        // データ更新は本体アプリが担い、保存のたびに reloadAllTimelines される。
        // ここでの 15 分は本体が落ちている時のフォールバック再読込
        let entry = UsageEntry(date: Date(), snapshot: SharedStore.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: UsageEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let snapshot = entry.snapshot {
                ServiceLine(name: "Claude", usage: snapshot.claude, compact: family == .systemSmall)
                ServiceLine(name: "Codex", usage: snapshot.codex, compact: family == .systemSmall)
                ServiceLine(name: "Copilot", usage: snapshot.copilot, compact: family == .systemSmall)
                Spacer(minLength: 0)
                HStack {
                    Text("更新 \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    Spacer()
                    if family != .systemSmall, let system = snapshot.system {
                        Text(String(format: "CPU %.0f%% · MEM %.0f/%.0fGB",
                                    system.cpuPercent, system.memUsedGB, system.memTotalGB))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            } else {
                Text("usage-hud を起動するとここに表示されます")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct ServiceLine: View {
    let name: String
    let usage: ServiceUsage?
    let compact: Bool

    // 最も逼迫しているゲージを代表として出す
    private var worst: Gauge? {
        usage?.gauges.max { $0.usedPercent < $1.usedPercent }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.caption2.weight(.semibold))
                .frame(width: compact ? 44 : 52, alignment: .leading)
            if let worst {
                UsageBar(fraction: worst.usedPercent / 100, height: DesignTokens.widgetBarHeight)
                Text(String(format: "%.0f%%", worst.remainingPercent))
                    .font(.caption2.monospacedDigit())
                    .frame(width: 34, alignment: .trailing)
            } else if usage?.error != nil {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Spacer()
            } else {
                Text("-")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

struct usage_hud_widget: Widget {
    let kind: String = "usage_hud_widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Usage HUD")
        .description("Copilot / Claude Code / Codex の残り使用量")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
