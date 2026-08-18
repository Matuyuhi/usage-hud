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

struct UsageBar: View {
    let fraction: Double
    var height: CGFloat = DesignTokens.barHeight

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(DesignTokens.usageColor(fraction: fraction))
                    .frame(width: max(height / 2, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}
