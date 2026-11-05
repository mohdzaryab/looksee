import AppKit

/// A window the user had focused, enough to find it again later.
struct RememberedWindow {
    let pid: pid_t
    let element: AXUIElement
    let title: String
    let appName: String
    let screenID: String
    /// Set when Accessibility can't see the window (it lives in another Space): `element` is then the app itself,
    /// and activating the app makes macOS switch that display to the window's Space.
    var activateOnly = false
    var quartzBounds: CGRect? = nil
}

/// Watches which window has keyboard focus and remembers the last one per screen.
final class FocusTracker {
    private(set) var lastWindow: [String: RememberedWindow] = [:]
    private(set) var current: RememberedWindow?
    var screens: [ScreenInfo] = ScreenInfo.all()
    var onChange: ((RememberedWindow?) -> Void)?

    private var timer: Timer?
    private var observers: [Any] = []

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = 0.1
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.poll() })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screens = ScreenInfo.all() })
        poll()
    }

    func forget(screenID: String) { lastWindow[screenID] = nil }

    /// Reads the frontmost app's focused window and files it under the screen it sits on.
    func poll() {
        guard Accessibility.isTrusted,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let axApp = AXUIElement.application(pid: app.processIdentifier)
        guard let window = axApp.element(kAXFocusedWindowAttribute) ?? axApp.element(kAXMainWindowAttribute),
              let frame = window.quartzFrame, frame.width > 1,
              let screen = ScreenInfo.screen(containing: CoordinateSpace.cocoaRect(fromQuartz: frame), in: screens)
        else { return }

        let remembered = RememberedWindow(
            pid: app.processIdentifier, element: window,
            title: window.title ?? "", appName: app.localizedName ?? "App", screenID: screen.uuid
        )
        let changed = current.map { $0.pid != remembered.pid || $0.screenID != remembered.screenID || !CFEqual($0.element, remembered.element) } ?? true
        lastWindow[screen.uuid] = remembered
        current = remembered
        if changed { onChange?(remembered) }
    }
}
