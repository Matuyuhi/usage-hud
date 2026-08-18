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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var panel: NSPanel?
    private var hotKey: HotKey?
    private var clickOutsideMonitor: Any?
    private var resizeCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
        // ゲージ数の変化で必要サイズが変わるため、snapshot 更新のたびに合わせ直す
        resizeCancellable = store.$snapshot.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitPanelToContent() }
        }
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

    private func fitPanelToContent() {
        guard let panel, panel.isVisible, let content = panel.contentView else { return }
        panel.setContentSize(content.fittingSize)
        position(panel)
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setContentSize(panel.contentView?.fittingSize ?? .zero)
        position(panel)
        panel.orderFrontRegardless()
        store.panelVisibilityChanged(visible: true)
        // パネル外のクリックで閉じる(自アプリ外のイベントのみ飛んでくる)
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hidePanel()
        }
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        store.panelVisibilityChanged(visible: false)
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: PanelView(store: store) { [weak self] in
            self?.fitPanelToContent()
        })
        let panel = NSPanel(
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
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - 12,
            y: visible.maxY - size.height - 12))
    }
}
