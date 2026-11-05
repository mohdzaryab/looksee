import AppKit

/// Brings a window to the front and gives it keyboard focus.
enum WindowSwitcher {
    enum Outcome { case raised(String), alreadyThere, nothingToRaise, failed(String) }

    /// Where to put the pointer after raising a window.
    enum PointerTarget {
        case stay
        /// A remembered spot on the screen, in Cocoa coordinates.
        case restore(CGPoint)
        /// Just inside the top of the raised window.
        case window
    }

    /// Focus the remembered window on `screen`, or the topmost window there when nothing is remembered.
    static func focus(screen: ScreenInfo, remembered: RememberedWindow?, fallback: Bool, pointer: PointerTarget) -> Outcome {
        if let remembered, isAlive(remembered, on: screen) {
            return raise(remembered.element, pid: remembered.pid, label: "\(remembered.appName) — \(remembered.title)", screen: screen, pointer: pointer, activateOnly: remembered.activateOnly ? (remembered.quartzBounds ?? .zero) : nil)
        }
        guard fallback else { return .nothingToRaise }
        var lastFailure: Outcome = .nothingToRaise
        let candidates = candidateWindows(on: screen)
        if candidates.isEmpty { log.notice("Fallback on \(screen.name, privacy: .public) found no raisable window") }
        for candidate in candidates {
            let outcome = raise(candidate.element, pid: candidate.pid, label: "\(candidate.appName) — \(candidate.title)\(candidate.activateOnly ? " (other Space)" : "")", screen: screen, pointer: pointer, activateOnly: candidate.activateOnly ? candidate.quartzBounds : nil)
            if case .raised = outcome { return outcome }
            lastFailure = outcome
        }
        return lastFailure
    }

    /// Still open, not minimised, and still on that screen (the user may have dragged it elsewhere).
    private static func isAlive(_ window: RememberedWindow, on screen: ScreenInfo) -> Bool {
        guard NSRunningApplication(processIdentifier: window.pid) != nil, !window.activateOnly,
              let frame = window.element.quartzFrame, !window.element.isMinimized else { return false }
        return ScreenInfo.screen(containing: CoordinateSpace.cocoaRect(fromQuartz: frame), in: ScreenInfo.all())?.uuid == screen.uuid
    }

    private static func raise(_ element: AXUIElement, pid: pid_t, label: String, screen: ScreenInfo, pointer: PointerTarget, activateOnly: CGRect? = nil) -> Outcome {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return .failed("app quit") }
        app.activate()
        var raised = true
        var frame: CGRect? = activateOnly
        if activateOnly == nil {
            raised = element.perform(kAXRaiseAction)
            element.set(kAXMainAttribute, to: kCFBooleanTrue)
            element.set(kAXFocusedAttribute, to: kCFBooleanTrue)
            frame = element.quartzFrame
        }
        switch pointer {
        case .stay: break
        case .restore(let cocoaPoint) where screen.frame.contains(cocoaPoint):
            CGWarpMouseCursorPosition(CGPoint(x: cocoaPoint.x, y: CoordinateSpace.primaryHeight - cocoaPoint.y))
        case .restore, .window:
            if let frame {
                CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: min(frame.minY + 40, frame.midY)))
            }
        }
        return raised ? .raised(label) : .failed("could not raise \(label)")
    }

    /// Windows on `screen` in front-to-back order: first those visible in the display's current Space, then
    /// those in its other Spaces (raising one of them makes macOS switch that display to its Space).
    /// Helper windows with no title and little size are skipped. Needs Accessibility to resolve AX elements.
    static func candidateWindows(on screen: ScreenInfo, limit: Int = 5) -> [RememberedWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let screens = ScreenInfo.all()
        var seen = Set<Int>()
        var axWindowsByPID: [pid_t: [AXUIElement]] = [:]
        var result: [RememberedWindow] = []

        for options in [CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements]), CGWindowListOption([.excludeDesktopElements])] {
            guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { continue }
            for info in list { // front-to-back
                guard let number = info[kCGWindowNumber as String] as? Int, !seen.contains(number) else { continue }
                seen.insert(number)
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                      let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.width > 50, bounds.height > 50,
                      (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                      ScreenInfo.screen(containing: CoordinateSpace.cocoaRect(fromQuartz: bounds), in: screens)?.uuid == screen.uuid,
                      let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular
                else { continue }

                if axWindowsByPID[pid] == nil { axWindowsByPID[pid] = AXUIElement.application(pid: pid).elements(kAXWindowsAttribute) }
                let axWindows = axWindowsByPID[pid]!
                let cgTitle = info[kCGWindowName as String] as? String ?? ""
                let match = axWindows.first { w in
                    guard let f = w.quartzFrame else { return false }
                    return abs(f.minX - bounds.minX) < 4 && abs(f.minY - bounds.minY) < 4 && abs(f.width - bounds.width) < 4
                } ?? axWindows.first { w in
                    // Looser: same screen and roughly the same size (Electron apps can report frames a few points off).
                    guard let f = w.quartzFrame, ScreenInfo.screen(containing: CoordinateSpace.cocoaRect(fromQuartz: f), in: screens)?.uuid == screen.uuid else { return false }
                    return abs(f.width - bounds.width) < 40 && abs(f.height - bounds.height) < 80 && (cgTitle.isEmpty || w.title == cgTitle)
                }
                let onScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
                guard let match else {
                    // Accessibility only exposes windows in the display's current Space. A sizeable window the
                    // window server knows about but AX can't see is in another Space: activating its app makes
                    // macOS switch there. Small untitled ones are helper windows; skip them.
                    if !onScreen, bounds.area >= screen.frame.area * 0.25 {
                        result.append(RememberedWindow(pid: pid, element: AXUIElement.application(pid: pid), title: cgTitle, appName: app.localizedName ?? "App", screenID: screen.uuid, activateOnly: true, quartzBounds: bounds))
                        if result.count >= limit { return result }
                    }
                    continue
                }
                guard !match.isMinimized else { continue }
                let title = match.title ?? cgTitle
                // Untitled and small: almost always an invisible helper window (Electron, Finder, etc.).
                if title.isEmpty, bounds.area < screen.frame.area * 0.25 { continue }
                result.append(RememberedWindow(pid: pid, element: match, title: title, appName: app.localizedName ?? "App", screenID: screen.uuid))
                if result.count >= limit { return result }
            }
        }
        return result
    }
}
