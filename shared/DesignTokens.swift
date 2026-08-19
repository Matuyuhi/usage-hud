import SwiftUI

enum DesignTokens {
    static let panelWidth: CGFloat = 300
    static let panelCornerRadius: CGFloat = 14
    static let barHeight: CGFloat = 6
    static let widgetBarHeight: CGFloat = 5
    /// desktop の最小ヒットターゲット(WCAG 2.2 の 24×24px 基準)
    static let minHitTarget: CGFloat = 24

    static let usageWarnFraction = 0.5
    static let usageDangerFraction = 0.8

    static func usageColor(fraction: Double) -> Color {
        switch fraction {
        case ..<usageWarnFraction: .green
        case ..<usageDangerFraction: .yellow
        default: .red
        }
    }
}

/// パーセントの記号位置・数字表記は言語で異なるため、記号を自前で付けずに FormatStyle へ委ねる
func percentText(_ percent: Double) -> String {
    (percent / 100).formatted(.percent.precision(.fractionLength(0)))
}

/// 単位付きのバイト表記。桁区切りや小数点記号は FormatStyle 側でローカライズされる
func byteText(_ bytes: UInt64) -> String {
    Int64(clamping: bytes).formatted(.byteCount(style: .file))
}

/// 通信速度。B と kB を行き来してラベル幅が暴れないよう、単位は kB 以上に固定する
func rateText(_ bytesPerSecond: Double) -> String {
    let bytes = Int64(max(bytesPerSecond, 0))
    return bytes.formatted(.byteCount(style: .file, allowedUnits: [.kb, .mb, .gb])) + "/s"
}

/// 分を「3h 12m」形式にする。時間が 0 の場合は分だけ出す
func durationText(_ minutes: Int) -> String {
    let hours = minutes / 60
    let rest = minutes % 60
    return hours > 0 ? "\(hours)h \(rest)m" : "\(rest)m"
}

struct UsageBar: View {
    let fraction: Double
    var height: CGFloat = DesignTokens.barHeight
    /// 色の判定に使う値。バッテリーのように「多いほど良い」指標では、
    /// バーの長さ(残量)とは別に不足量を渡して配色を揃える
    var severity: Double? = nil

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(DesignTokens.usageColor(fraction: severity ?? fraction))
                    .frame(width: max(height / 2, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}
