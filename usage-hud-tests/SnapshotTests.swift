import SwiftUI
import WidgetKit
import XCTest
@testable import usage_hud

// パネルとウィジェットの見た目の回帰テスト。参照画像は usage-hud-tests/__Snapshots__ にあり、
// 見た目を意図して変えたときは scripts/snapshot-test.sh --record(または Record snapshots ワークフロー)で撮り直す

@MainActor
final class PanelSnapshotTests: XCTestCase {
    private func panel(
        _ store: UsageStore, expanded: Set<String> = []
    ) -> some View {
        PanelView(store: store, expanded: expanded, flatBackground: true) {}
    }

    func testDefault() {
        let store = UsageStore(
            preview: SampleData.snapshot(), system: SampleData.system, enabled: DisplayItem.defaultEnabled)
        assertSnapshot("panel-default") { panel(store) }
    }

    func testDefaultDark() {
        let store = UsageStore(
            preview: SampleData.snapshot(), system: SampleData.system, enabled: DisplayItem.defaultEnabled)
        assertSnapshot("panel-default", appearance: .dark) { panel(store) }
    }

    /// 全項目を有効にして、サービスと System の詳細(内訳・上位プロセス)を開いた状態
    func testExpanded() {
        let all = Set(DisplayItem.allCases)
        let store = UsageStore(
            preview: SampleData.snapshot(enabled: all), system: SampleData.system,
            processes: SampleData.processes, enabled: all)
        assertSnapshot("panel-expanded") {
            panel(store, expanded: [DisplayItem.claude.rawValue, PanelView.systemKey])
        }
    }

    /// 起動直後。共有 JSON もまだ無い
    func testLoading() {
        let store = UsageStore(preview: nil, system: nil, enabled: DisplayItem.defaultEnabled)
        assertSnapshot("panel-loading") { panel(store) }
    }

    /// 取得失敗(前回値なし・前回値あり)と、内蔵バッテリーの無い Mac
    func testErrors() {
        let store = UsageStore(
            preview: SampleData.snapshot(
                claude: .failed("Claude Code credentials not found in Keychain"),
                codex: .failed("codex: command not found"),
                copilot: SampleData.staleCopilot,
                system: SampleData.desktopSystem),
            system: SampleData.desktopSystem,
            enabled: DisplayItem.defaultEnabled)
        assertSnapshot("panel-errors") { panel(store) }
    }

    /// サービスを全部外して指標だけにした場合(区切り線もサービス見出しも出ない)
    func testMetricsOnly() {
        let enabled: Set<DisplayItem> = [.cpu, .memory, .disk, .network]
        let store = UsageStore(
            preview: SampleData.snapshot(enabled: enabled), system: SampleData.system, enabled: enabled)
        assertSnapshot("panel-metrics-only") { panel(store) }
    }
}

@MainActor
final class WidgetSnapshotTests: XCTestCase {
    // macOS の通知センターでのおおよそのサイズ。WidgetKit が付ける余白のぶんを padding で足す
    private static let small = CGSize(width: 160, height: 160)
    private static let medium = CGSize(width: 340, height: 160)

    private func widget(_ snapshot: UsageSnapshot?, family: WidgetFamily) -> some View {
        UsageWidgetView(snapshot: snapshot, family: family)
            .padding(16)
            .frame(width: family == .systemSmall ? Self.small.width : Self.medium.width,
                   height: Self.small.height)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    func testSmall() {
        assertSnapshot("widget-small", size: Self.small) {
            widget(SampleData.snapshot(), family: .systemSmall)
        }
    }

    func testMedium() {
        assertSnapshot("widget-medium", size: Self.medium) {
            widget(SampleData.snapshot(), family: .systemMedium)
        }
    }

    /// 本体が一度も保存していない(共有 JSON が無い)
    func testEmpty() {
        assertSnapshot("widget-empty", size: Self.medium) {
            widget(nil, family: .systemMedium)
        }
    }

    /// 取得失敗のサービスは警告アイコンになる
    func testErrors() {
        assertSnapshot("widget-errors", size: Self.medium) {
            widget(SampleData.snapshot(claude: .failed("no credentials"), codex: nil), family: .systemMedium)
        }
    }

    /// サービスを 1 つも出さない設定の小サイズは、指標を縦に並べる
    func testSmallMetricsOnly() {
        let enabled: Set<DisplayItem> = [.cpu, .memory, .battery]
        assertSnapshot("widget-small-metrics-only", size: Self.small) {
            widget(SampleData.snapshot(enabled: enabled), family: .systemSmall)
        }
    }
}
