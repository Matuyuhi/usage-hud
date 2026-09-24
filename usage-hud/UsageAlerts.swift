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

    private(set) var isEnabled = UserDefaults.standard.bool(forKey: UsageAlerts.enabledKey)
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
        var granted = false
        if isOn {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .denied {
                // 一度拒否すると requestAuthorization はダイアログを出さずに false を返すだけなので、設定を開く
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            } else {
                granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
        }
        isEnabled = granted
        UserDefaults.standard.set(granted, forKey: Self.enabledKey)
        return granted
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
                let key = "\(service.rawValue)|\(gauge.label)"
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
        // 同じゲージの通知は差し替える(80% の通知の後に 95% が来たら 1 件にまとめる)
        let request = UNNotificationRequest(
            identifier: "usage-alert.\(service.rawValue).\(gauge.label)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
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
    /// 閾値付近の揺れで「通知済み」を取り消して二重に知らせないための余裕
    static let hysteresis: Double = 5

    /// "claude|5h" → 通知済みの閾値
    private(set) var notified: [String: Double]

    init(notified: [String: Double] = [:]) {
        self.notified = notified
    }

    /// 今回の使用率を記録し、新しく知らせるべき閾値を返す(無ければ nil)
    mutating func update(key: String, usedPercent: Double) -> Double? {
        let reached = Self.thresholds.last { $0 <= usedPercent }
        if let previous = notified[key], usedPercent < previous - Self.hysteresis {
            // 大きく下がった = 新しい窓に入った。今の使用率で届いている段階まで巻き戻す
            notified[key] = reached
        }
        guard let reached, reached > notified[key] ?? 0 else { return nil }
        notified[key] = reached
        return reached
    }
}
