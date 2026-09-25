import XCTest
@testable import usage_hud

// まとめ通知を「いつ出すか」の判定。タイムゾーンで結果が変わらないよう、暦は UTC に固定して確かめる
final class DailySummaryScheduleTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    /// 初めて有効にしたときは、時刻の前後に関わらずその場で 1 度出す
    func testDueWhenNeverSent() {
        XCTAssertTrue(DailySummarySchedule.isDue(now: date(25, 7), lastSent: nil, calendar: calendar))
        XCTAssertEqual(DailySummarySchedule.nextFire(now: date(25, 7), lastSent: nil, calendar: calendar), date(24, 9))
    }

    /// 時刻前は前日の回を出していれば出さず、次は今日の時刻
    func testNotDueBeforeTodaysSlot() {
        let lastSent = date(24, 9, 5)
        XCTAssertFalse(DailySummarySchedule.isDue(now: date(25, 8, 59), lastSent: lastSent, calendar: calendar))
        XCTAssertEqual(
            DailySummarySchedule.nextFire(now: date(25, 8, 59), lastSent: lastSent, calendar: calendar), date(25, 9))
    }

    /// 時刻を過ぎたら今日の回を出す(スリープで遅れても、その日のうちなら 1 度出る)
    func testDueAfterTodaysSlot() {
        let lastSent = date(24, 9, 5)
        XCTAssertTrue(DailySummarySchedule.isDue(now: date(25, 9), lastSent: lastSent, calendar: calendar))
        XCTAssertTrue(DailySummarySchedule.isDue(now: date(25, 23), lastSent: lastSent, calendar: calendar))
    }

    /// 今日の回を出したら、次は明日の時刻
    func testNotDueTwiceADay() {
        let lastSent = date(25, 9, 1)
        XCTAssertFalse(DailySummarySchedule.isDue(now: date(25, 18), lastSent: lastSent, calendar: calendar))
        XCTAssertEqual(
            DailySummarySchedule.nextFire(now: date(25, 18), lastSent: lastSent, calendar: calendar), date(26, 9))
    }

    /// 前日の時刻より前に出したきり(何日も起動していなかった等)なら、時刻前でも前日の回として出す
    func testDueWhenMissedYesterday() {
        let lastSent = date(22, 10)
        XCTAssertTrue(DailySummarySchedule.isDue(now: date(25, 7), lastSent: lastSent, calendar: calendar))
    }
}
