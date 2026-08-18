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
                // サービス名と残量の列幅は実際の文言から揃える(言語で語長が変わるため固定値で持たない)
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                    serviceLine(name: "Claude", usage: snapshot.claude)
                    serviceLine(name: "Codex", usage: snapshot.codex)
                    serviceLine(name: "Copilot", usage: snapshot.copilot)
                }
                Spacer(minLength: 0)
                HStack {
                    Text("Updated \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    Spacer()
                    if family != .systemSmall, let system = snapshot.system {
                        Text(systemText(system))
                    }
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

    private func systemText(_ system: SystemSample) -> String {
        "CPU \(percentText(system.cpuPercent)) · MEM "
            + String(format: "%.0f/%.0fGB", system.memUsedGB, system.memTotalGB)
    }
}

struct usage_hud_widget: Widget {
    let kind: String = "usage_hud_widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Usage HUD")
        .description("Remaining usage for Copilot / Claude Code / Codex")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
