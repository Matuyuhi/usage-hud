import XCTest
@testable import usage_hud

// 使用量の通知で「いつ知らせるか」の判定。通知センターには触れない純粋なロジックなので、
// スナップショットではなく値で確かめる
final class UsageAlertLevelsTests: XCTestCase {
    private let key = "claude|5h"

    func testNotifiesOncePerThreshold() {
        var levels = UsageAlertLevels()
        XCTAssertNil(levels.update(key: key, usedPercent: 50))
        XCTAssertEqual(levels.update(key: key, usedPercent: 81), 80)
        // 同じ段階の中で増えても二度は知らせない
        XCTAssertNil(levels.update(key: key, usedPercent: 90))
        XCTAssertEqual(levels.update(key: key, usedPercent: 96), 95)
        XCTAssertNil(levels.update(key: key, usedPercent: 100))
    }

    /// 取得の間隔が空いて一気に超えたら、超えた中で一番高い段階だけを 1 度知らせる
    func testJumpNotifiesHighestOnly() {
        var levels = UsageAlertLevels()
        XCTAssertEqual(levels.update(key: key, usedPercent: 97), 95)
        XCTAssertNil(levels.update(key: key, usedPercent: 98))
    }

    /// 閾値付近の小さな揺れでは通知済みを取り消さない
    func testSmallDropDoesNotRearm() {
        var levels = UsageAlertLevels()
        XCTAssertEqual(levels.update(key: key, usedPercent: 81), 80)
        XCTAssertNil(levels.update(key: key, usedPercent: 78))
        XCTAssertNil(levels.update(key: key, usedPercent: 82))
    }

    /// ちょうど 5 ポイント下がったら新しい窓とみなす(4.x ポイントなら揺れとして扱う)
    func testHysteresisBoundary() {
        var levels = UsageAlertLevels()
        XCTAssertEqual(levels.update(key: key, usedPercent: 80), 80)
        XCTAssertNil(levels.update(key: key, usedPercent: 75.5))
        XCTAssertEqual(levels.notified[key], 80)
        XCTAssertNil(levels.update(key: key, usedPercent: 75))
        XCTAssertNil(levels.notified[key])
        XCTAssertEqual(levels.update(key: key, usedPercent: 80), 80)
    }

    /// 使用率が大きく下がったら新しい窓とみなし、次に超えたときにまた知らせる
    func testResetRearms() {
        var levels = UsageAlertLevels()
        XCTAssertEqual(levels.update(key: key, usedPercent: 96), 95)
        XCTAssertNil(levels.update(key: key, usedPercent: 3))
        XCTAssertTrue(levels.notified.isEmpty)
        XCTAssertEqual(levels.update(key: key, usedPercent: 85), 80)
    }

    /// 95% の後に 80% 台へ下がった場合は 80% までを通知済みとして残し、95% だけを知らせ直す
    func testPartialDropKeepsLowerLevel() {
        var levels = UsageAlertLevels()
        XCTAssertEqual(levels.update(key: key, usedPercent: 96), 95)
        XCTAssertNil(levels.update(key: key, usedPercent: 85))
        XCTAssertEqual(levels.notified[key], 80)
        XCTAssertEqual(levels.update(key: key, usedPercent: 95), 95)
    }

    /// ゲージごとに独立して判定する
    func testKeysAreIndependent() {
        var levels = UsageAlertLevels()
        XCTAssertEqual(levels.update(key: key, usedPercent: 90), 80)
        XCTAssertEqual(levels.update(key: "claude|Week", usedPercent: 90), 80)
        XCTAssertNil(levels.update(key: "copilot|Premium", usedPercent: 10))
    }
}
