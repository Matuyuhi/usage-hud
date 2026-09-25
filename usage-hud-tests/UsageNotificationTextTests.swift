import XCTest
@testable import usage_hud

// 通知の文面の組み立て。見た目はスナップショット(NotificationSnapshotTests)で見るので、
// ここでは言語に依らない並びと載せる枠の選び方だけを確かめる
@MainActor
final class UsageNotificationTextTests: XCTestCase {
    /// 5h 枠は載せず、残りの少ない枠から並べる(Copilot 19% → Claude 38% → Codex 88%)
    func testSummaryOrdersByRemaining() throws {
        let text = try XCTUnwrap(UsageNotificationText.summary(SampleData.snapshot(), now: SampleData.fetchedAt))
        let lines = text.body.components(separatedBy: "\n")
        XCTAssertEqual(lines.map { String($0.prefix(1)) }, ["🔴", "🟡", "🟢"])
        XCTAssertTrue(lines[0].contains("Copilot"))
        XCTAssertTrue(lines[1].contains("Claude Code"))
        XCTAssertTrue(lines[2].contains("Codex"))
    }

    /// 取得に失敗したサービスは載せず、載せる枠が無ければ出さない
    func testSummarySkipsFailedServices() {
        var copilot = SampleData.copilot
        copilot.error = "gh: token expired"
        let snapshot = SampleData.snapshot(claude: nil, codex: nil, copilot: copilot)
        XCTAssertNil(UsageNotificationText.summary(snapshot, now: SampleData.fetchedAt))
    }

    func testUntilText() {
        let now = SampleData.fetchedAt
        XCTAssertEqual(UsageNotificationText.untilText(now.addingTimeInterval(95 * 60), now: now), "1h 35m")
        XCTAssertEqual(UsageNotificationText.untilText(now.addingTimeInterval(4 * 86400 + 3 * 3600), now: now), "4d 3h")
        // 取得からリセットをまたいだら 0 に丸める
        XCTAssertEqual(UsageNotificationText.untilText(now.addingTimeInterval(-60), now: now), "0m")
    }
}
