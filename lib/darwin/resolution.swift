// Selects modes with consistent apparent UI density across different display sizes.
// A 27-inch 2560x1440 panel and a 49-inch 5120x1440 panel are both about 109 PPI;
// Retina displays retain at least their native 2x mode to avoid oversized interface elements.

import CoreGraphics
import Foundation

private let targetPPI = hypot(2560.0, 1440.0) / 27.0
private let nativeModeFlag: UInt32 = 0x02000000

private struct DisplayMode {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let isNative: Bool

    init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, isNative: Bool = false) {
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isNative = isNative
    }

    init(_ mode: CGDisplayMode) {
        self.init(
            width: mode.width,
            height: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            isNative: mode.ioFlags & nativeModeFlag != 0
        )
    }

    var scaling: String {
        pixelWidth == width * 2 && pixelHeight == height * 2 ? "on" : "off"
    }
}

private func effectivePPI(_ mode: DisplayMode, widthMM: Double, heightMM: Double) -> String {
    let diagonalInches = hypot(widthMM, heightMM) / 25.4
    let ppi = hypot(Double(mode.width), Double(mode.height)) / diagonalInches
    return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), ppi)
}

private func closestMode(widthMM: Double, heightMM: Double, modes: [DisplayMode]) -> DisplayMode? {
    guard widthMM > 0, heightMM > 0 else { return nil }

    let nativeRetinaMode = modes.first { $0.isNative && $0.scaling == "on" }
    let candidates = modes.filter { mode in
        guard let nativeRetinaMode else { return true }
        return mode.width >= nativeRetinaMode.width && mode.height >= nativeRetinaMode.height
    }

    return candidates.min { left, right in
        let leftError = max(
            abs(Double(left.width) / (widthMM / 25.4) - targetPPI),
            abs(Double(left.height) / (heightMM / 25.4) - targetPPI)
        )
        let rightError = max(
            abs(Double(right.width) / (widthMM / 25.4) - targetPPI),
            abs(Double(right.height) / (heightMM / 25.4) - targetPPI)
        )
        if leftError == rightError {
            return left.pixelWidth * left.pixelHeight > right.pixelWidth * right.pixelHeight
        }
        return leftError < rightError
    }
}

private func runSelfTest() {
    let ultrawide = closestMode(
        widthMM: 1197,
        heightMM: 337,
        modes: [
            DisplayMode(width: 3840, height: 1080, pixelWidth: 3840, pixelHeight: 1080),
            DisplayMode(width: 5120, height: 1440, pixelWidth: 5120, pixelHeight: 1440),
        ]
    )
    precondition(ultrawide?.width == 5120 && ultrawide?.height == 1440)
    precondition(ultrawide.map { effectivePPI($0, widthMM: 1197, heightMM: 337) } == "108.6")

    let retina27 = closestMode(
        widthMM: 598,
        heightMM: 336,
        modes: [
            DisplayMode(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160),
            DisplayMode(width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880),
            DisplayMode(width: 3200, height: 1800, pixelWidth: 5120, pixelHeight: 2880),
        ]
    )
    precondition(retina27?.width == 2560 && retina27?.height == 1440)
    precondition(retina27?.scaling == "on")
    precondition(retina27.map { effectivePPI($0, widthMM: 598, heightMM: 336) } == "108.8")

    let retinaMacBook = closestMode(
        widthMM: 344,
        heightMM: 223,
        modes: [
            DisplayMode(width: 1496, height: 967, pixelWidth: 2992, pixelHeight: 1934),
            DisplayMode(
                width: 1728,
                height: 1117,
                pixelWidth: 3456,
                pixelHeight: 2234,
                isNative: true
            ),
        ]
    )
    precondition(retinaMacBook?.width == 1728 && retinaMacBook?.height == 1117)
    print("Display resolution selection checks passed.")
}

if CommandLine.arguments.dropFirst().first == "--self-test" {
    runSelfTest()
    exit(0)
}

var displayCount: UInt32 = 0
guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success else {
    fputs("Unable to enumerate online displays.\n", stderr)
    exit(1)
}

var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
guard CGGetOnlineDisplayList(displayCount, &displays, &displayCount) == .success else {
    fputs("Unable to read online displays.\n", stderr)
    exit(1)
}
let modeOptions = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary

for display in displays where CGDisplayIsActive(display) != 0 {
    if CGDisplayMirrorsDisplay(display) != kCGNullDirectDisplay {
        continue
    }

    let rotation = Int(CGDisplayRotation(display))
    let panelSize = CGDisplayScreenSize(display)
    let widthMM = rotation == 90 || rotation == 270 ? panelSize.height : panelSize.width
    let heightMM = rotation == 90 || rotation == 270 ? panelSize.width : panelSize.height
    let modes = ((CGDisplayCopyAllDisplayModes(display, modeOptions) as? [CGDisplayMode]) ?? []).map {
        DisplayMode($0)
    }

    guard let mode = closestMode(widthMM: widthMM, heightMM: heightMM, modes: modes) else {
        fputs("Skipping display \(display): physical dimensions or display modes are unavailable.\n", stderr)
        continue
    }

    let mirrorIDs = displays.filter { CGDisplayMirrorsDisplay($0) == display }
    let identifiers = ([display] + mirrorIDs).map(String.init).joined(separator: "+")
    let origin = CGDisplayBounds(display).origin
    let displayArgument =
        "id:\(identifiers) res:\(mode.width)x\(mode.height) scaling:\(mode.scaling) "
            + "origin:(\(Int(origin.x)),\(Int(origin.y))) degree:\(rotation)"
    let displayKind = CGDisplayIsBuiltin(display) != 0 ? "Built-in" : "External"
    var currentDetails = ["unknown", "unknown", "unknown", "unknown"]
    if let currentCGMode = CGDisplayCopyDisplayMode(display) {
        let currentMode = DisplayMode(currentCGMode)
        currentDetails = [
            "\(currentMode.width)x\(currentMode.height)",
            "\(currentMode.pixelWidth)x\(currentMode.pixelHeight)",
            currentMode.scaling,
            effectivePPI(currentMode, widthMM: widthMM, heightMM: heightMM),
        ]
    }
    let fields = [
        displayArgument,
        "\(displayKind) display \(display)",
        "\(Int(widthMM.rounded()))x\(Int(heightMM.rounded())) mm",
    ] + currentDetails + [
        "\(mode.width)x\(mode.height)",
        "\(mode.pixelWidth)x\(mode.pixelHeight)",
        mode.scaling,
        effectivePPI(mode, widthMM: widthMM, heightMM: heightMM),
    ]
    print(fields.joined(separator: "\t"))
}
