import Combine
import Foundation
import WidgetKit

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var system: SystemSample?
    /// CPU / メモリの上位プロセス。System の詳細を開いている間だけ入る
    @Published private(set) var processes: ProcessSample?
    @Published private(set) var isRefreshing = false
    /// 表示する項目。無効な項目は取得も行わない
    @Published private(set) var enabled: Set<DisplayItem> = DisplayPreferences.load()

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
    /// メニュー表示中の一時停止。再描画が開いた NSMenu を組み直してしまうため、開いている間は更新しない
    private var updatesPaused = false
    /// メニュー表示中に取得が終わった場合の反映待ち(開いている間は @Published を触らない)
    private var deferredResult: (snapshot: UsageSnapshot, sample: SystemSample?)?
    /// 取得中かどうかの実体。表示用の isRefreshing は一時停止中は据え置くので分けて持つ
    private var isFetching = false
    private var cooldownUntil: [String: Date] = [:]
    /// 取得中に項目が有効化された場合の再取得予約
    private var pendingRefresh = false
    /// System の詳細(上位プロセス)を開いているか。ps を起動するので開いている間だけ取る
    private var systemDetailExpanded = false
    private var isSamplingProcesses = false
    private var lastProcessSampleAt: Date?
    /// 今の一覧を取ったときの指標。選択が変わったら間引きを飛ばして取り直す
    private var lastProcessMetrics: Set<DisplayItem>?

    private var enabledServices: Set<DisplayItem> { enabled.filter { $0.category == .service } }
    private var enabledSystemMetrics: Set<DisplayItem> { enabled.filter { $0.category == .system } }
    /// 上位プロセスに使う指標。無効な指標は ps の列にも入れないので、どちらも無効なら取る意味が無い
    private var processMetrics: Set<DisplayItem> { enabled.intersection([.cpu, .memory]) }
    private var needsProcesses: Bool { !processMetrics.isEmpty }

    func start() {
        snapshot = SharedStore.load()
        refresh()
        rescheduleQuotaTimer()
    }

    func panelVisibilityChanged(visible: Bool) {
        panelVisible = visible
        rescheduleQuotaTimer()
        rescheduleSystemTimer()
        if visible {
            refresh()
        }
    }

    func isEnabled(_ item: DisplayItem) -> Bool { enabled.contains(item) }

    /// System セクションの詳細を開いた / 閉じた。
    /// 上位プロセスは全プロセスを列挙する ps を回すため、開いている間だけ取る
    func setSystemDetailExpanded(_ expanded: Bool) {
        guard systemDetailExpanded != expanded else { return }
        systemDetailExpanded = expanded
        // メニュー表示中は @Published を触らない(閉じたときに rescheduleSystemTimer から取り直す)
        guard !updatesPaused else { return }
        sampleProcesses(force: expanded)
    }

    /// 設定メニューを開いている間は定期更新を止める。
    /// 2 秒ごとのシステム指標でビューが作り直されると、開いているメニューが点滅して操作できない
    func setUpdatesPaused(_ paused: Bool) {
        guard updatesPaused != paused else { return }
        updatesPaused = paused
        guard !paused else {
            // 止めるだけ。ここでサンプリングし直すと、開いた直後のメニューを潰してしまう
            systemTimer?.invalidate()
            systemTimer = nil
            quotaTimer?.invalidate()
            quotaTimer = nil
            return
        }
        if let deferredResult {
            self.deferredResult = nil
            system = deferredResult.sample
            publish(snapshot: withCurrentSelection(deferredResult.snapshot))
        }
        syncRefreshingIndicator()
        rescheduleSystemTimer()
        rescheduleQuotaTimer()
    }

    /// 表示項目の変更。無効化した項目は共有ファイルからも消し、有効化した項目はその場で取りに行く
    func setEnabled(_ item: DisplayItem, _ isOn: Bool) {
        guard enabled.contains(item) != isOn else { return }
        if isOn {
            enabled.insert(item)
        } else {
            enabled.remove(item)
        }
        DisplayPreferences.save(enabled)
        rescheduleQuotaTimer()
        rescheduleSystemTimer()
        if item.category == .system {
            // 有効化した指標は rescheduleSystemTimer 側で即時サンプリング済み
            publish(snapshot: snapshot.map { withCurrentSelection($0) })
        } else if isOn {
            refresh(force: true)
        } else {
            publish(snapshot: snapshot.map { withCurrentSelection($0) })
        }
    }

    func refresh(force: Bool = false) {
        guard !isFetching else {
            // 取得中に有効化されたサービスは、今の取得では拾えないので終わり次第もう一度回す
            pendingRefresh = pendingRefresh || force
            return
        }
        // パネルの開閉連打で endpoint を叩きすぎない(Claude 側で 429 になった実績あり)
        if !force, let last = snapshot?.fetchedAt,
           Date().timeIntervalSince(last) < Self.minRefreshInterval {
            return
        }
        isFetching = true
        syncRefreshingIndicator()
        Task {
            // 無効なサービスは fetch 自体を呼ばない(CLI の起動も HTTP 呼び出しも発生しない)
            async let claude = fetchService(.claude, current: snapshot?.claude, using: ClaudeFetcher.fetch)
            async let codex = fetchService(.codex, current: snapshot?.codex, using: CodexFetcher.fetch)
            async let copilot = fetchService(.copilot, current: snapshot?.copilot, using: CopilotFetcher.fetch)
            let services = (claude: await claude, codex: await codex, copilot: await copilot)
            let sample = sampleForSnapshot()
            let fresh = UsageSnapshot(
                claude: services.claude,
                codex: services.codex,
                copilot: services.copilot,
                system: sample,
                fetchedAt: Date())
            isFetching = false
            syncRefreshingIndicator()
            applyOrDefer(fresh, sample: sample)
            if pendingRefresh {
                pendingRefresh = false
                refresh(force: true)
            }
        }
    }

    /// 表示しないサービスは叩かず、値も残さない。
    /// 429 を返したサービスはクールダウンが明けるまで一切叩かず前回値を返す
    private func fetchService(
        _ item: DisplayItem, current: ServiceUsage?, using fetch: () async -> ServiceUsage
    ) async -> ServiceUsage? {
        guard enabled.contains(item) else { return nil }
        if let until = cooldownUntil[item.rawValue], Date() < until {
            return current
        }
        let fresh = await fetch()
        if fresh.rateLimited == true {
            cooldownUntil[item.rawValue] = Date().addingTimeInterval(Self.rateLimitCooldown)
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

    /// メニュー表示中に取得が終わったら、閉じるまで反映を待つ。
    /// 開いている NSMenu は下のビューが作り直されると閉じてしまう
    private func applyOrDefer(_ fresh: UsageSnapshot, sample: SystemSample?) {
        guard !updatesPaused else {
            deferredResult = (snapshot: fresh, sample: sample)
            return
        }
        system = sample
        // 取得中に無効化されたサービスがあり得るので、公開前に今の選択で絞り直す
        publish(snapshot: withCurrentSelection(fresh))
    }

    /// 取得中インジケータ。一時停止中は再描画を避けるため、再開時にまとめて合わせる
    private func syncRefreshingIndicator() {
        guard !updatesPaused, isRefreshing != isFetching else { return }
        isRefreshing = isFetching
    }

    private func publish(snapshot newSnapshot: UsageSnapshot?) {
        guard let newSnapshot else { return }
        snapshot = newSnapshot
        SharedStore.save(newSnapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 無効にした項目を落として現在の選択に合わせる(ウィジェットに古い値を残さないため)
    private func withCurrentSelection(_ old: UsageSnapshot) -> UsageSnapshot {
        var updated = old
        updated.claude = enabled.contains(.claude) ? old.claude : nil
        updated.codex = enabled.contains(.codex) ? old.codex : nil
        updated.copilot = enabled.contains(.copilot) ? old.copilot : nil
        updated.system = system
        updated.enabledItems = DisplayItem.encode(enabled)
        return updated
    }

    private func sampleSystem() {
        system = sampler.sample(enabled: enabledSystemMetrics)
        sampleProcesses()
    }

    /// 上位プロセスの取得。ps の起動は 2 秒より粗い間隔に間引き、開いた直後だけ force で即取る
    private func sampleProcesses(force: Bool = false) {
        guard systemDetailExpanded, needsProcesses else {
            lastProcessSampleAt = nil
            lastProcessMetrics = nil
            if processes != nil { processes = nil }
            return
        }
        let metrics = processMetrics
        if !force, lastProcessMetrics == metrics, let last = lastProcessSampleAt,
           Date().timeIntervalSince(last) < ProcessSampler.interval {
            return
        }
        guard !isSamplingProcesses else { return }
        isSamplingProcesses = true
        lastProcessSampleAt = Date()
        lastProcessMetrics = metrics
        Task {
            let sample = await ProcessSampler.sample(metrics: metrics)
            isSamplingProcesses = false
            // 取得中に詳細が閉じられた / メニューが開いた場合は反映しない
            guard systemDetailExpanded, needsProcesses, !updatesPaused else { return }
            processes = sample
        }
    }

    private func sampleForSnapshot() -> SystemSample? {
        guard !enabledSystemMetrics.isEmpty else { return nil }
        // 直前のサンプルがまだ新しければ使い回す。続けて引くと CPU の差分の窓が潰れて 0% になる
        if let recent = system,
           Date().timeIntervalSince(recent.sampledAt) < Self.systemInterval * 2 {
            return recent
        }
        return sampler.sample(enabled: enabledSystemMetrics)
    }

    /// システム指標はパネル表示中だけ 2 秒ごとに取る。全部無効ならタイマー自体を持たない
    private func rescheduleSystemTimer() {
        systemTimer?.invalidate()
        systemTimer = nil
        guard !enabledSystemMetrics.isEmpty else {
            // 全部無効になったら共有ファイルにも残さない
            system = nil
            sampleProcesses()
            return
        }
        // 一時停止中はサンプリングもしない(@Published system の更新でメニューが閉じてしまう)。
        // 再開時にここへ戻ってきて 1 回取る
        guard panelVisible, !updatesPaused else { return }
        sampleSystem()
        let timer = Timer(timeInterval: Self.systemInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleSystem() }
        }
        RunLoop.main.add(timer, forMode: .common)
        systemTimer = timer
    }

    private func rescheduleQuotaTimer() {
        quotaTimer?.invalidate()
        quotaTimer = nil
        // サービスを 1 つも表示しないなら定期取得する対象が無い
        guard !enabledServices.isEmpty, !updatesPaused else { return }
        if panelVisible {
            scheduleQuotaTimer(interval: Self.visibleInterval)
        } else {
            // 非表示中の更新は widget の鮮度維持のためだけなので、widget 未設置なら止める。
            // 後から widget を追加した場合は、次にパネルを開閉した時点で再判定される
            WidgetCenter.shared.getCurrentConfigurations { [weak self] result in
                guard case .success(let configurations) = result, !configurations.isEmpty else { return }
                Task { @MainActor in
                    guard let self, !self.panelVisible, self.quotaTimer == nil,
                          !self.enabledServices.isEmpty else { return }
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
