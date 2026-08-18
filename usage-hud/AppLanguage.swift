import SwiftUI

/// パネルの表示言語。macOS の「アプリケーションごとの言語」と同じ UserDefaults キーを使うため、
/// システム設定側で変更した場合もこの選択と食い違わない
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case japanese

    var id: String { rawValue }

    /// AppleLanguages に書く言語コード。system は指定自体を消して OS の判断に委ねる
    fileprivate var code: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .japanese: "ja"
        }
    }

    /// 言語名は各言語での表記をそのまま出すため、system 以外は翻訳しない
    var label: LocalizedStringKey {
        switch self {
        case .system: "Follow system"
        case .english: "English"
        case .japanese: "日本語"
        }
    }
}

enum LanguageSetting {
    private static let defaultsKey = "AppleLanguages"

    static var current: AppLanguage {
        guard let code = UserDefaults.standard.stringArray(forKey: defaultsKey)?.first else {
            return .system
        }
        // システム設定側から指定された場合は "en-US" のような地域付きの値が入る
        return AppLanguage.allCases.first { $0.code.map(code.hasPrefix) == true } ?? .system
    }

    /// 表示言語は起動時に解決されるため、選択を書き込んだうえで起動し直す
    static func apply(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        if let code = language.code {
            defaults.set([code], forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
        // 起動し直した側が新しい値を読めるよう、再起動の前に書き込みを確定させる
        defaults.synchronize()
        restart()
    }

    private static func restart() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: configuration
        ) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
