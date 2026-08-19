import Foundation
import SwiftUI

/// 表示項目の選択は本体の UserDefaults に持つ。
/// ウィジェットとは App Group を共有できないので、選択内容は共有 JSON 経由で渡している
enum DisplayPreferences {
    private static let defaultsKey = "EnabledDisplayItems"

    static func load() -> Set<DisplayItem> {
        DisplayItem.decode(UserDefaults.standard.stringArray(forKey: defaultsKey))
    }

    static func save(_ items: Set<DisplayItem>) {
        UserDefaults.standard.set(DisplayItem.encode(items), forKey: defaultsKey)
    }
}

extension DisplayItem {
    /// サービス名は製品名なので翻訳しない。指標名だけローカライズする
    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .copilot: "Copilot"
        case .cpu: "CPU"
        case .memory: String(localized: "Memory")
        case .battery: String(localized: "Battery")
        case .disk: String(localized: "Disk")
        case .network: String(localized: "Network")
        }
    }
}
