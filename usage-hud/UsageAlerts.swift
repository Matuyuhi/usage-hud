import AppKit
import Foundation
import UserNotifications

/// 使用量が閾値を超えたら通知センターに出す(既定は OFF、歯車メニューから有効にする)。
///
/// パネルを閉じている間に 5h 枠を使い切って気付かない、を防ぐのが目的。
/// 判定は取得結果を見るだけで、自分では取得しない(閉じている間の定期取得は `UsageStore` が張る)
final class UsageAlerts: NSObject, UNUserNotificationCenterDelegate {
    private static let enabledKey = "UsageAlertsEnabled"
    private static let levelsKey = "UsageAlertLevels"
    private static let summaryEnabledKey = "UsageSummaryEnabled"
    private static let summaryLastSentKey = "UsageSummaryLastSent"

    private(set) var isEnabled = UserDefaults.standard.bool(forKey: UsageAlerts.enabledKey)
    /// 1 日 1 回、週 / 月の枠の残りとリセット日時をまとめて知らせる(閾値の通知とは別に切り替える)
    private(set) var isSummaryEnabled = UserDefaults.standard.bool(forKey: UsageAlerts.summaryEnabledKey)
    /// 最後にまとめ通知を出した日時。同じ日に二度出さないために持つ
    private(set) var summaryLastSent = UserDefaults.standard.object(forKey: UsageAlerts.summaryLastSentKey) as? Date
    private var levels = UsageAlertLevels(
        notified: UserDefaults.standard.dictionary(forKey: UsageAlerts.levelsKey) as? [String: Double] ?? [:])
    private var onOpen: (() -> Void)?

    /// 通知のクリックでパネルを開けるよう、デリゲートを張る。
    /// XCTest のホストでは呼ばない(init は UserDefaults を読むだけで通知センターには触れない)
    func activate(onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
        UNUserNotificationCenter.current().delegate = self
    }

    /// 有効にするときだけ許可を求める。拒否済みなら通知の設定画面を開き、無効のまま返す
    func setEnabled(_ isOn: Bool) async -> Bool {
        let granted = isOn ? await requestAuthorization() : false
        isEnabled = granted
        UserDefaults.standard.set(granted, forKey: Self.enabledKey)
        return granted
    }

    /// まとめ通知の切り替え。許可の扱いは `setEnabled` と同じ
    func setSummaryEnabled(_ isOn: Bool) async -> Bool {
        let granted = isOn ? await requestAuthorization() : false
        isSummaryEnabled = granted
        UserDefaults.standard.set(granted, forKey: Self.summaryEnabledKey)
        return granted
    }

    private func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .denied {
            // 一度拒否すると requestAuthorization はダイアログを出さずに false を返すだけなので、設定を開く
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
            return false
        }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// 有効にした後でシステム設定から通知の許可を取り消されていたら、無効に戻す。
    /// 残したままだと通知は届かないのに、非表示中の 10 分ごとの取得だけが続く
    func reconcileWithAuthorization() async {
        guard isEnabled || isSummaryEnabled else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard status != .authorized && status != .provisional else { return }
        isEnabled = false
        isSummaryEnabled = false
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        UserDefaults.standard.set(false, forKey: Self.summaryEnabledKey)
    }

    /// 取得結果を見て、新しく閾値を超えたゲージを通知する。無効な間は通知済みの記録も進めない
    /// (有効にした時点で既に超えているゲージは、その時点で 1 度だけ知らせる)
    func evaluate(_ snapshot: UsageSnapshot) {
        guard isEnabled else { return }
        let services: [(DisplayItem, ServiceUsage?)] = [
            (.claude, snapshot.claude), (.codex, snapshot.codex), (.copilot, snapshot.copilot),
        ]
        var changed = false
        for (service, usage) in services {
            for gauge in usage?.gauges ?? [] {
                // 翻訳される label ではなく key で覚える(言語を切り替えると同じ枠で再通知してしまう)
                let key = "\(service.rawValue)|\(gauge.key ?? gauge.label)"
                let before = levels.notified
                if levels.update(key: key, usedPercent: gauge.usedPercent) != nil {
                    post(service: service, gauge: gauge)
                }
                changed = changed || levels.notified != before
            }
        }
        if changed {
            UserDefaults.standard.set(levels.notified, forKey: Self.levelsKey)
        }
    }

    private func post(service: DisplayItem, gauge: Gauge) {
        let content = UNMutableNotificationContent()
        content.title = "\(service.title) · \(gauge.label)"
        var lines = [String(
            format: String(localized: "%1$@ used · %2$@ left"),
            percentText(gauge.usedPercent), percentText(gauge.remainingPercent))]
        if let resets = gauge.resetsAt {
            lines.append(String(format: String(localized: "Resets %@"), formatDetailDate(resets)))
        }
        content.body = lines.joined(separator: "\n")
        content.sound = .default
        // 同じゲージの通知は差し替える(80% の通知の後に 95% が来たら 1 件にまとめる)。
        // 同じ identifier で add しても差し替わるのは配信前の要求だけなので、配信済みのものは先に消す
        let identifier = "usage-alert.\(service.rawValue).\(gauge.key ?? gauge.label)"
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    /// まとめ通知を出すべき回で、まだ出していないか
    var isSummaryDue: Bool {
        isSummaryEnabled && DailySummarySchedule.isDue(now: Date(), lastSent: summaryLastSent)
    }

    /// まとめ通知の時刻を過ぎていて今日まだ出していなければ、週 / 月の枠の残りとリセット日時を 1 件にまとめて出す。
    /// 出したら true(呼び出し側は次の日の時刻にタイマーを張り直す)。
    /// 載せる枠が 1 つも無い(取得に失敗した等)ときは出したことにせず、次の取得で出し直す
    func postSummaryIfDue(_ snapshot: UsageSnapshot, now: Date = Date()) -> Bool {
        guard isSummaryEnabled, DailySummarySchedule.isDue(now: now, lastSent: summaryLastSent) else { return false }
        let services: [(DisplayItem, ServiceUsage?)] = [
            (.claude, snapshot.claude), (.codex, snapshot.codex), (.copilot, snapshot.copilot),
        ]
        var lines: [String] = []
        // 取得に失敗したサービスは前回値が残っているだけなので載せない(古い値で「今日の分」を済ませない)
        for (service, usage) in services where usage?.error == nil {
            // 5h 枠は数時間で戻るので、朝に知らせても意味が無い
            for gauge in usage?.gauges ?? [] where gauge.isShortWindow != true {
                var line = String(
                    format: String(localized: "%1$@ · %2$@: %3$@ left"),
                    service.title, gauge.label, percentText(gauge.remainingPercent))
                if let resets = gauge.resetsAt {
                    line += " · " + String(format: String(localized: "until %@"), formatDetailDate(resets))
                }
                lines.append(line)
            }
        }
        guard !lines.isEmpty else { return false }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Daily usage summary")
        content.body = lines.joined(separator: "\n")
        // 前日のまとめは差し替える(通知センターに毎日溜めない)
        let identifier = "usage-summary"
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil), withCompletionHandler: nil)
        summaryLastSent = now
        UserDefaults.standard.set(now, forKey: Self.summaryLastSentKey)
        return true
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// パネルをクリックしてアプリが前面にいる間もバナーを出す(既定では前面のアプリには出ない)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        onOpen?()
    }
}

/// どのゲージをどの閾値まで通知したか。通知センターに触れない純粋な判定なのでテストから直接使う。
///
/// 窓(5h / 週など)の切り替わりはリセット日時ではなく、使用率が下がったことで判定する。
/// Codex の 5h 窓はリセットまでの秒数で返るので、リセット日時が取得のたびに少しずつずれるため
nonisolated struct UsageAlertLevels: Equatable {
    /// 使用率(%)。上から順に超えたかを見て、一度に知らせるのは超えた中で一番高いものだけ
    static let thresholds: [Double] = [80, 95]
    /// 閾値付近の揺れで「通知済み」を取り消して二重に知らせないための余裕。この幅以上下がったら新しい窓とみなす
    static let hysteresis: Double = 5

    /// "claude|5h" → 通知済みの閾値
    private(set) var notified: [String: Double]

    init(notified: [String: Double] = [:]) {
        self.notified = notified
    }

    /// 今回の使用率を記録し、新しく知らせるべき閾値を返す(無ければ nil)
    mutating func update(key: String, usedPercent: Double) -> Double? {
        let reached = Self.thresholds.last { $0 <= usedPercent }
        if let previous = notified[key], usedPercent <= previous - Self.hysteresis {
            // 大きく下がった = 新しい窓に入った。今の使用率で届いている段階まで巻き戻す
            notified[key] = reached
        }
        guard let reached, reached > notified[key] ?? 0 else { return nil }
        notified[key] = reached
        return reached
    }
}

/// まとめ通知をいつ出すか。通知センターに触れない純粋な計算なのでテストから直接使う。
///
/// 決まった時刻に `UNCalendarNotificationTrigger` で予約しないのは、中身(残り %)を出す直前の取得結果で作りたいため。
/// 時刻を過ぎてから最初の取得で出すので、スリープで時刻をまたいだ場合も起きた後に 1 度出る
nonisolated enum DailySummarySchedule {
    /// 出す時刻(ローカル時刻の時)。1 日の使い方を決める朝に見られるようにする
    static let hour = 9

    /// 今日の時刻。時刻前なら前日の時刻(= 今出すべき回)を返す
    static func currentSlot(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        return today <= now ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
    }

    /// 次に出す時刻。今の回をまだ出していなければその回(過去の日時)を返す。タイマーに渡せば即座に発火する
    static func nextFire(now: Date, lastSent: Date?, calendar: Calendar = .current) -> Date {
        let slot = currentSlot(now: now, calendar: calendar)
        if isDue(now: now, lastSent: lastSent, calendar: calendar) { return slot }
        return calendar.date(byAdding: .day, value: 1, to: slot) ?? slot
    }

    /// 最後に出したのが今の回より前なら、今出すべき。
    /// 初めて有効にしたとき(lastSent が nil)は時刻を過ぎていればその場で 1 度出す(動いていることが分かる)
    static func isDue(now: Date, lastSent: Date?, calendar: Calendar = .current) -> Bool {
        guard let lastSent else { return true }
        return lastSent < currentSlot(now: now, calendar: calendar)
    }
}
