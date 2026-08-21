import SwiftUI
import Combine
import Carbon.HIToolbox

@main
struct UsageHudApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// borderless の NSWindow は key になれないため、中の SwiftUI Menu が開いた直後に tracking を失う
/// (設定・表示項目のメニューが点滅して選べない)。nonactivatingPanel と併せることで、
/// アプリ自体はアクティブにせず——クリックされたときだけ key を取って——操作を受け取れる
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // 常駐 HUD なのでメインウィンドウにはならない
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let screenMargin: CGFloat = 12

    private let store = UsageStore()
    private var panel: NSPanel?
    private var hotKey: HotKey?
    private var clickOutsideMonitor: Any?
    private var resizeCancellables: Set<AnyCancellable> = []
    /// tracking 中の NSMenu。サブメニューにも別々に通知が来るので、空になるまでが「メニューが開いている間」
    private var trackingMenus: Set<ObjectIdentifier> = []
    private var needsFitAfterMenu = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
        // 行数の変化で必要サイズが変わるため、snapshot とシステム指標の更新のたびに合わせ直す。
        // system は初回サンプルで行が増えるので、snapshot が変わらない経路でも見る必要がある
        store.$snapshot.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitPanelToContent() }
        }
        .store(in: &resizeCancellables)
        store.$system.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitPanelToContent() }
        }
        .store(in: &resizeCancellables)
        observeMenuTracking()
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_U), modifiers: [.control, .option]) { [weak self] in
            self?.togglePanel()
        }
        showPanel()
    }

    private func togglePanel() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - メニュー表示中はパネルを固める

    /// 開いた NSMenu は開いた時点のパネルに紐づくので、下でパネルがリサイズ・移動・再描画されると
    /// メニューが閉じたり点滅したりして操作できない。tracking 中は更新を止め、閉じてからまとめて反映する
    private func observeMenuTracking() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuDidEndTracking(_:)),
            name: NSMenu.didEndTrackingNotification, object: nil)
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        trackingMenus.insert(ObjectIdentifier(menu))
        store.setUpdatesPaused(true)
    }

    @objc private func menuDidEndTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        trackingMenus.remove(ObjectIdentifier(menu))
        guard trackingMenus.isEmpty else { return }
        resumeUpdates()
    }

    private func resumeUpdates() {
        trackingMenus.removeAll()
        store.setUpdatesPaused(false)
        guard needsFitAfterMenu else { return }
        needsFitAfterMenu = false
        fitPanelToContent()
    }

    // MARK: - パネル

    private func fitPanelToContent() {
        guard let panel, panel.isVisible, let content = panel.contentView else { return }
        guard trackingMenus.isEmpty else {
            needsFitAfterMenu = true
            return
        }
        // 2 秒ごとのシステム指標の更新では行数は変わらない。
        // 毎回 position し直すと、ユーザーがドラッグで動かしたパネルを右上へ引き戻してしまう
        let fitting = content.fittingSize
        guard fitting != content.frame.size else { return }
        // 行が増減しても左上は動かさない(表示項目を切り替えただけでパネルが飛ばないように)
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setContentSize(fitting)
        panel.setFrameTopLeftPoint(topLeft)
        clampToScreen(panel)
    }

    /// 伸びた結果はみ出したときだけ、可視領域の内側へ寄せる
    private func clampToScreen(_ panel: NSPanel) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = panel.frame
        let origin = NSPoint(
            x: max(visible.minX + Self.screenMargin,
                   min(frame.minX, visible.maxX - frame.width - Self.screenMargin)),
            y: max(visible.minY + Self.screenMargin,
                   min(frame.minY, visible.maxY - frame.height - Self.screenMargin)))
        guard origin != frame.origin else { return }
        panel.setFrameOrigin(origin)
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setContentSize(panel.contentView?.fittingSize ?? .zero)
        position(panel)
        // key は取らない(⌃⌥U で覗いただけで、編集中のウィンドウからフォーカスを奪わない)。
        // クリックされた時点で FloatingPanel が key になり、そこからメニューが正しく tracking できる
        panel.orderFrontRegardless()
        store.panelVisibilityChanged(visible: true)
        // パネル外のクリックで閉じる(自アプリ外のイベントのみ飛んでくる)
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, self.trackingMenus.isEmpty else { return }
            // メニュー tracking 中のクリックはメニューのものなので、パネルを閉じない
            self.hidePanel()
        }
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        store.panelVisibilityChanged(visible: false)
        // 閉じている間に tracking 終了の通知を取り逃しても、更新が止まったままにならないように戻す
        resumeUpdates()
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: PanelView(store: store) { [weak self] in
            self?.fitPanelToContent()
        })
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        // NSPanel の既定はアプリが非アクティブになると自動で引っ込む。
        // メニューを開くとアプリのアクティブ状態が動くため、既定のままだと
        // パネルごと消えて(=謎の表示/非表示)メニューも一緒に飛ぶ
        panel.hidesOnDeactivate = false
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - Self.screenMargin,
            y: visible.maxY - size.height - Self.screenMargin))
    }
}
