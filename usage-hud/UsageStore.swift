import Combine
import Foundation
import WidgetKit

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var system: SystemSample?
    @Published private(set) var isRefreshing = false

    // 内部 API 2 つ(Claude / Copilot)に配慮して控えめな間隔にする(Claude で 429 実績あり)
    private static let visibleInterval: TimeInterval = 120
    private static let hiddenInterval: TimeInterval = 1800
    private static let systemInterval: TimeInterval = 2
    private static let minRefreshInterval: TimeInterval = 60
    private static let rateLimitCooldown: TimeInterval = 900

    private let sampler = SystemSampler()
    private var quotaTimer: Timer?
    private var systemTimer: Timer?
    private var panelVisible = false
    private var cooldownUntil: [String: Date] = [:]

    func start() {
        snapshot = SharedStore.load()
        refresh()
        rescheduleQuotaTimer()
    }

    func panelVisibilityChanged(visible: Bool) {
        panelVisible = visible
        rescheduleQuotaTimer()
        systemTimer?.invalidate()
        systemTimer = nil
        if visible {
            sampleSystem()
            let timer = Timer(timeInterval: Self.systemInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sampleSystem() }
            }
            RunLoop.main.add(timer, forMode: .common)
            systemTimer = timer
            refresh()
        }
    }

    func refresh(force: Bool = false) {
        guard !isRefreshing else { return }
        // パネルの開閉連打で endpoint を叩きすぎない(Claude 側で 429 になった実績あり)
        if !force, let last = snapshot?.fetchedAt,
           Date().timeIntervalSince(last) < Self.minRefreshInterval {
            return
        }
        isRefreshing = true
        Task {
            async let claude = fetchService("claude", current: snapshot?.claude, using: ClaudeFetcher.fetch)
            async let codex = fetchService("codex", current: snapshot?.codex, using: CodexFetcher.fetch)
            async let copilot = fetchService("copilot", current: snapshot?.copilot, using: CopilotFetcher.fetch)
            let newSnapshot = UsageSnapshot(
                claude: await claude,
                codex: await codex,
                copilot: await copilot,
                system: sampler.sample(),
                fetchedAt: Date())
            snapshot = newSnapshot
            SharedStore.save(newSnapshot)
            WidgetCenter.shared.reloadAllTimelines()
            isRefreshing = false
        }
    }

    /// 429 を返したサービスはクールダウンが明けるまで一切叩かず前回値を返す
    private func fetchService(
        _ key: String, current: ServiceUsage?, using fetch: () async -> ServiceUsage
    ) async -> ServiceUsage? {
        if let until = cooldownUntil[key], Date() < until {
            return current
        }
        let fresh = await fetch()
        if fresh.rateLimited == true {
            cooldownUntil[key] = Date().addingTimeInterval(Self.rateLimitCooldown)
        }
        return merging(new: fresh, over: current)
    }

    /// 取得失敗時は前回の取得値を残し、エラーメッセージだけ差し替える
    private func merging(new: ServiceUsage?, over old: ServiceUsage?) -> ServiceUsage? {
        guard let new else { return old }
        guard new.error != nil, let old, old.error == nil, !old.gauges.isEmpty else { return new }
        var kept = old
        kept.error = new.error
        return kept
    }

    private func sampleSystem() {
        system = sampler.sample()
    }

    private func rescheduleQuotaTimer() {
        quotaTimer?.invalidate()
        quotaTimer = nil
        if panelVisible {
            scheduleQuotaTimer(interval: Self.visibleInterval)
        } else {
            // 非表示中の更新は widget の鮮度維持のためだけなので、widget 未設置なら止める。
            // 後から widget を追加した場合は、次にパネルを開閉した時点で再判定される
            WidgetCenter.shared.getCurrentConfigurations { [weak self] result in
                guard case .success(let configurations) = result, !configurations.isEmpty else { return }
                Task { @MainActor in
                    guard let self, !self.panelVisible, self.quotaTimer == nil else { return }
                    self.scheduleQuotaTimer(interval: Self.hiddenInterval)
                }
            }
        }
    }

    private func scheduleQuotaTimer(interval: TimeInterval) {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        quotaTimer = timer
    }
}
