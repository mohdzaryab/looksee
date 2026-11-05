import AppKit

/// Walks the user through each screen: an overlay says "look here", we sample the head pose for a second, next screen.
final class Calibrator {
    private var overlays: [NSWindow] = []
    private var samples: [HeadPose] = []
    private var collecting = false
    private var screens: [ScreenInfo] = []
    private var index = 0
    struct Entry { let mean: [Double]; let noise: [Double]; let samples: Int }
    private var result: [String: Entry] = [:]
    private var completion: (([String: Entry]?) -> Void)?
    private var label: NSTextField?
    private var countdown: NSTextField?
    private var timer: Timer?
    private var escMonitor: Any?

    var isRunning: Bool { completion != nil }

    func start(screens: [ScreenInfo], completion: @escaping ([String: Entry]?) -> Void) {
        guard !isRunning else { return }
        self.screens = screens
        self.completion = completion
        index = 0
        result = [:]
        showOverlays()
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.finish(nil) }
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        step()
    }

    /// Called by the tracker for every frame while calibration is running.
    func feed(_ pose: HeadPose?) {
        guard collecting, let pose else { return }
        samples.append(pose)
    }

    private func showOverlays() {
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = NSColor.black.withAlphaComponent(0.55)
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.contentView = NSView(frame: screen.frame)
            window.orderFrontRegardless()
            overlays.append(window)
        }
    }

    private func step() {
        guard index < screens.count else { return finish(result) }
        let target = screens[index]
        // Dim every overlay except the target, which gets the instructions.
        for (i, window) in overlays.enumerated() {
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }
            let isTarget = ScreenInfo(NSScreen.screens[i])?.uuid == target.uuid
            window.backgroundColor = isTarget ? NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.3, alpha: 0.85) : NSColor.black.withAlphaComponent(0.7)
            guard isTarget, let view = window.contentView else { continue }

            let title = Self.makeLabel("Look at this screen", size: 64, weight: .bold)
            let sub = Self.makeLabel("\(target.name)  ·  screen \(index + 1) of \(screens.count)  ·  Esc to cancel", size: 22, weight: .regular)
            let count = Self.makeLabel("3", size: 120, weight: .heavy)
            let stack = NSStackView(views: [title, sub, count])
            stack.orientation = .vertical
            stack.spacing = 24
            stack.alignment = .centerX
            stack.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            label = sub
            countdown = count
        }

        var remaining = 3
        var holdTicks = 0
        samples = []
        collecting = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            remaining -= 1
            if remaining > 0 {
                countdown?.stringValue = "\(remaining)"
            } else if remaining == 0 {
                countdown?.stringValue = "hold still…"
                collecting = true
                remaining = -1
            } else if holdTicks < 1 {
                holdTicks += 1 // two seconds of samples
            } else {
                t.invalidate()
                collecting = false
                let rows = samples.map(\.features)
                if samples.count >= 6 {
                    result[target.uuid] = Entry(mean: Statistics.mean(rows), noise: Statistics.standardDeviation(rows), samples: samples.count)
                    index += 1
                    step()
                } else {
                    countdown?.stringValue = "no face seen, retrying"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.step() }
                }
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func finish(_ outcome: [String: Entry]?) {
        timer?.invalidate()
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        let done = completion
        completion = nil
        done?(outcome)
    }

    private static func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = .white
        field.alignment = .center
        return field
    }
}
