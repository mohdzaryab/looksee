import AppKit

/// Tracks keyboard and mouse activity so glances don't steal focus mid-typing or mid-drag.
final class ActivityMonitor {
    private(set) var lastKeyAt: TimeInterval = 0
    private(set) var lastClickAt: TimeInterval = 0
    private(set) var mouseButtonDown = false
    private(set) var lastPointerMoveAt: TimeInterval = 0
    /// Where the pointer last was on each screen (Cocoa coordinates), keyed by display UUID.
    private(set) var lastPointerPosition: [String: CGPoint] = [:]
    private var lastPositionSample: TimeInterval = 0
    private var monitors: [Any] = []

    func start() {
        let events: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged, .mouseMoved]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(m)
        }
    }

    private func handle(_ event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        switch event.type {
        case .keyDown:
            // Bare modifier chords (⌘⇥ etc.) aren't "typing".
            if !(event.characters ?? "").isEmpty { lastKeyAt = now }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            mouseButtonDown = true
            lastClickAt = now
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            mouseButtonDown = false
        case .mouseMoved, .leftMouseDragged:
            lastPointerMoveAt = now
            // Sample position at most ~20 times a second; the events arrive far faster than that.
            if now - lastPositionSample > 0.05 {
                lastPositionSample = now
                let location = NSEvent.mouseLocation
                if let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }), let info = ScreenInfo(screen) {
                    lastPointerPosition[info.uuid] = location
                }
            }
        default: break
        }
    }

    func pointerMovedRecently(within window: TimeInterval = 0.5) -> Bool {
        ProcessInfo.processInfo.systemUptime - lastPointerMoveAt < window
    }

    func isTyping(within hold: TimeInterval) -> Bool {
        ProcessInfo.processInfo.systemUptime - lastKeyAt < hold
    }

    func clickedRecently(within window: TimeInterval = 0.5) -> Bool {
        ProcessInfo.processInfo.systemUptime - lastClickAt < window
    }
}
