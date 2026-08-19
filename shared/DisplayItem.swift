import Foundation

/// パネルとウィジェットに出せる項目。無効にした項目は「表示しない」だけでなく取得自体を行わないため、
/// 使わないサービスの CLI 起動・HTTP 呼び出しや、使わない指標のサンプリングは発生しない
nonisolated enum DisplayItem: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case copilot
    case cpu
    case memory
    case battery
    case disk
    case network

    var id: String { rawValue }

    nonisolated enum Category: Sendable {
        /// 外部 API / CLI を叩く。無効化の効果が最も大きい
        case service
        /// ローカルのカーネル統計。パネル表示中のみ一定間隔でサンプリングする
        case system
    }

    var category: Category {
        switch self {
        case .claude, .codex, .copilot: .service
        case .cpu, .memory, .battery, .disk, .network: .system
        }
    }

    /// 既定は従来どおりの表示(3 サービス + CPU/メモリ)にバッテリーを足したもの。
    /// ディスクとネットワークは常時サンプリングの負荷を避けて opt-in にする
    static let defaultEnabled: Set<DisplayItem> = [.claude, .codex, .copilot, .cpu, .memory, .battery]

    static var services: [DisplayItem] { allCases.filter { $0.category == .service } }
    static var systemMetrics: [DisplayItem] { allCases.filter { $0.category == .system } }

    /// JSON / UserDefaults には rawValue の配列で入れる。知らない項目(新しいバージョンが書いた値)は
    /// 読み飛ばすだけにして、snapshot 全体のデコード失敗にはしない
    static func decode(_ ids: [String]?) -> Set<DisplayItem> {
        guard let ids else { return defaultEnabled }
        return Set(ids.compactMap(DisplayItem.init(rawValue:)))
    }

    /// 並びは allCases の宣言順に正規化して、保存のたびに順序が揺れないようにする
    static func encode(_ items: Set<DisplayItem>) -> [String] {
        allCases.filter { items.contains($0) }.map(\.rawValue)
    }
}
