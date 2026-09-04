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

/// WidgetKit 上ではサイズを環境から受け取る。環境の widgetFamily は書き込めないため、
/// 描画本体(shared/UsageWidgetView)は family を引数で受け、本体のスナップショットテストから直接指定できるようにしている
struct UsageWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: UsageEntry

    var body: some View {
        UsageWidgetView(snapshot: entry.snapshot, family: family)
    }
}

struct usage_hud_widget: Widget {
    let kind: String = "usage_hud_widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            UsageWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Usage HUD")
        .description("Remaining usage for Copilot / Claude Code / Codex")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
