import AppKit

/// A connected display. `uuid` is stable across reconnects, unlike the CGDirectDisplayID.
struct ScreenInfo: Equatable {
    let displayID: CGDirectDisplayID
    let uuid: String
    let name: String
    /// Cocoa coordinates (bottom-left origin).
    let frame: CGRect

    init?(_ screen: NSScreen) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = CGDirectDisplayID(number.uint32Value)
        displayID = id
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            uuid = CFUUIDCreateString(nil, cfUUID) as String
        } else {
            uuid = "display-\(id)"
        }
        name = screen.localizedName
        frame = screen.frame
    }

    static func all() -> [ScreenInfo] {
        NSScreen.screens.compactMap(ScreenInfo.init).sorted { $0.frame.minX < $1.frame.minX }
    }

    /// The screen whose frame contains `point` (Cocoa coordinates), else the one with the most overlap with `rect`.
    static func screen(containing rect: CGRect, in screens: [ScreenInfo]) -> ScreenInfo? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let hit = screens.first(where: { $0.frame.contains(center) }) { return hit }
        return screens.max { a, b in
            a.frame.intersection(rect).area < b.frame.intersection(rect).area
        }.flatMap { $0.frame.intersection(rect).area > 0 ? $0 : nil }
    }
}

extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

enum CoordinateSpace {
    /// Height of the primary display, which is the pivot between Cocoa (bottom-left) and Quartz/AX (top-left) coordinates.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height ?? NSScreen.main?.frame.height ?? 0
    }

    /// Converts a top-left-origin rect (AX, CGWindowList) to Cocoa coordinates.
    static func cocoaRect(fromQuartz rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
