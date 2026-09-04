import AppKit
import Foundation
import SwiftUI
import XCTest

// SwiftUI ビューを PNG に描いて、リポジトリに入れた参照画像と比べる。
//
// ImageRenderer ではなく NSHostingView + cacheDisplay を使うのは、Menu のような AppKit 由来の
// 部品も一緒に描けるため。素材(ultraThinMaterial)だけはウィンドウの裏側が無いと描けないので、
// テスト対象のビュー側で不透明背景に差し替えている。
//
// 環境変数(xcodebuild からは TEST_RUNNER_ を前置して渡す):
//   SNAPSHOT_RECORD=1        参照画像を書き直す(比較しない)
//   SNAPSHOT_RECORD=missing  参照画像が無いケースだけ書き、あるケースは比較する
//   SNAPSHOT_OUTPUT_DIR    描画結果の出力先。actual/ に毎回、diff/ と expected/ は不一致のときだけ書く

/// ランナーのディスプレイが 1x でも同じピクセル数になるよう、倍率を 2x に固定する
private final class SnapshotWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 2 }
}

enum SnapshotAppearance: String {
    case light
    case dark

    fileprivate var nsAppearance: NSAppearance? {
        NSAppearance(named: self == .dark ? .darkAqua : .aqua)
    }
}

/// 比較しやすいよう RGBA 8bit / sRGB に揃えた画素列
struct SnapshotPixels {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        rgba = data
    }

    fileprivate init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    func pngData() -> Data {
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    }
}

enum SnapshotComparison {
    /// 1 チャンネルあたりこの差までは同じ画素とみなす(アンチエイリアスの揺れを吸収する)
    static let channelTolerance = 8
    /// 違う画素がこの割合を超えたら不一致
    static let maxDifferentFraction = 0.001

    struct Result {
        let differentPixels: Int
        let totalPixels: Int
        let diff: SnapshotPixels?

        var isMatch: Bool {
            Double(differentPixels) / Double(max(totalPixels, 1)) <= SnapshotComparison.maxDifferentFraction
        }
    }

    /// サイズが違えば即不一致。同じなら画素ごとに比べ、違う画素を赤く塗った diff 画像を返す
    static func compare(actual: SnapshotPixels, expected: SnapshotPixels) -> Result {
        guard actual.width == expected.width, actual.height == expected.height else {
            return Result(differentPixels: actual.width * actual.height, totalPixels: actual.width * actual.height, diff: nil)
        }
        var diff = [UInt8](repeating: 0, count: actual.rgba.count)
        var different = 0
        for pixel in stride(from: 0, to: actual.rgba.count, by: 4) {
            var delta = 0
            for channel in 0..<4 {
                delta = max(delta, abs(Int(actual.rgba[pixel + channel]) - Int(expected.rgba[pixel + channel])))
            }
            if delta > channelTolerance {
                different += 1
                diff[pixel] = 255
                diff[pixel + 1] = 0
                diff[pixel + 2] = 0
                diff[pixel + 3] = 255
            } else {
                // 一致した画素は薄く残して、どこが違うかを見当付けやすくする
                for channel in 0..<3 {
                    diff[pixel + channel] = UInt8(Int(expected.rgba[pixel + channel]) / 4 + 191)
                }
                diff[pixel + 3] = 255
            }
        }
        return Result(
            differentPixels: different, totalPixels: actual.width * actual.height,
            diff: SnapshotPixels(width: actual.width, height: actual.height, rgba: diff))
    }
}

@MainActor
enum SnapshotRenderer {
    static let scale: CGFloat = 2

    /// ビューをウィンドウに載せてレイアウトし、2x のビットマップに描く。ウィンドウは画面には出さない
    static func render<Content: View>(
        _ content: Content, appearance: SnapshotAppearance, size: CGSize? = nil
    ) -> SnapshotPixels {
        let hosting = NSHostingView(rootView: content)
        let size = size ?? hosting.fittingSize
        let window = SnapshotWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance.nsAppearance
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        // SwiftUI の初回レイアウトと画像・フォントの解決に 1 周回す
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        hosting.layoutSubtreeIfNeeded()

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded(.up)),
            pixelsHigh: Int((size.height * scale).rounded(.up)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return SnapshotPixels(rep.cgImage!)
    }
}

extension XCTestCase {
    private enum RecordMode {
        case off
        case all
        case missing
    }

    private static var recordMode: RecordMode {
        switch ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] ?? "" {
        case "1", "true", "YES", "all": .all
        case "missing": .missing
        default: .off
        }
    }

    private static var referenceDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("__Snapshots__")
    }

    private static var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["SNAPSHOT_OUTPUT_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usage-hud-snapshots")
    }

    /// ビューを描いて `__Snapshots__/<name>.<locale>.<appearance>.png` と比べる。
    /// 表示言語は起動時に決まるので、ロケールはファイル名に含めて言語ごとに別の参照画像を持つ
    @MainActor
    func assertSnapshot<Content: View>(
        _ name: String, appearance: SnapshotAppearance = .light, size: CGSize? = nil,
        file: StaticString = #filePath, line: UInt = #line,
        @ViewBuilder content: () -> Content
    ) {
        let fileName = "\(name).\(Locale.current.identifier).\(appearance.rawValue).png"
        let actual = SnapshotRenderer.render(content(), appearance: appearance, size: size)
        let referenceURL = Self.referenceDirectory.appendingPathComponent(fileName)

        write(actual, to: Self.outputDirectory.appendingPathComponent("actual").appendingPathComponent(fileName))

        let hasReference = FileManager.default.fileExists(atPath: referenceURL.path)
        if Self.recordMode == .all || (Self.recordMode == .missing && !hasReference) {
            write(actual, to: referenceURL)
            print("snapshot recorded: \(referenceURL.path)")
            return
        }
        guard let data = try? Data(contentsOf: referenceURL),
              let image = NSBitmapImageRep(data: data)?.cgImage else {
            XCTFail(
                "no reference image at \(referenceURL.path). "
                + "Run 'scripts/snapshot-test.sh --record' or the 'Record snapshots' workflow to create it",
                file: file, line: line)
            return
        }
        let expected = SnapshotPixels(image)
        let result = SnapshotComparison.compare(actual: actual, expected: expected)
        guard !result.isMatch else { return }

        let expectedURL = Self.outputDirectory.appendingPathComponent("expected").appendingPathComponent(fileName)
        write(expected, to: expectedURL)
        if let diff = result.diff {
            write(diff, to: Self.outputDirectory.appendingPathComponent("diff").appendingPathComponent(fileName))
        }
        let sizeNote = actual.width == expected.width && actual.height == expected.height
            ? "" : " (size \(actual.width)x\(actual.height) vs \(expected.width)x\(expected.height))"
        XCTFail(
            "snapshot '\(fileName)' differs from the reference: \(result.differentPixels) of "
            + "\(result.totalPixels) pixels\(sizeNote). See \(Self.outputDirectory.path)/{actual,expected,diff}/",
            file: file, line: line)
    }

    private func write(_ pixels: SnapshotPixels, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? pixels.pngData().write(to: url, options: .atomic)
    }
}
