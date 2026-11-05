import AppKit
import Carbon.HIToolbox
import ServiceManagement
import os

let log = Logger(subsystem: "com.zaryab.looksee", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let tracker = GazeTracker()
    private let focus = FocusTracker()
    private let activity = ActivityMonitor()
    private let calibrator = Calibrator()
    private var classifier: GazeClassifier?
    private var hotKey: HotKey?

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var menuRefreshTimer: Timer?

    private var paused = false
    private var faceSeen = false
    private var cameraError: String?
    private var lookingAt: String?
    private var lastEvent = "Waiting for the first glance." {
        didSet { if lastEvent != oldValue { log.notice("\(self.lastEvent, privacy: .public)") } }
    }
    private var screens: [ScreenInfo] = ScreenInfo.all()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = menu
        menu.delegate = self
        updateIcon()

        rebuildClassifier()
        focus.start()
        focus.onChange = { [weak self] window in
            // The user picked a window themselves; that screen is now the baseline for the next glance.
            guard let self, let window else { return }
            classifier?.assume(screen: window.screenID)
        }
        activity.start()
        tracker.onPose = { [weak self] in self?.handle(pose: $0) }
        tracker.onError = { [weak self] in
            self?.cameraError = $0
            self?.lastEvent = $0
            self?.updateIcon()
        }

        hotKey = HotKey(KeyCombo(keyCode: UInt32(kVK_ANSI_G), carbonModifiers: UInt32(cmdKey | shiftKey), label: "G")) { [weak self] in
            self?.togglePaused()
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            screens = ScreenInfo.all()
            rebuildClassifier()
            updateCameraState()
        }

        // Don't run the camera while the Mac is locked or the displays are asleep.
        let wc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            observers.append(wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.setCameraSuspended(true) })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            observers.append(wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.setCameraSuspended(false) })
        }
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: glanceNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let raw = note.userInfo?["screen"] as? String, let n = Int(raw), (1...screens.count).contains(n) else { return }
            log.notice("Simulated glance at screen \(n)")
            glanced(at: screens[n - 1].uuid, simulated: true)
        })

        Task { @MainActor in await startUp() }
    }

    private var observers: [Any] = []
    private var cameraSuspended = false
    private var elsewhereSince: TimeInterval?
    private var elsewhereLogged = false

    private func setCameraSuspended(_ suspended: Bool) {
        guard suspended != cameraSuspended else { return }
        cameraSuspended = suspended
        updateCameraState()
    }

    /// With one display there is nothing to switch between, so the camera stays off entirely.
    private var singleDisplay: Bool { screens.count < 2 }
    private var cameraAllowed = false
    private var cameraRunning = false

    /// The camera runs only when access is granted, the Mac is awake and unlocked, and there are at least two displays.
    private func updateCameraState() {
        let shouldRun = cameraAllowed && !cameraSuspended && !singleDisplay && !paused
        guard shouldRun != cameraRunning else { return }
        cameraRunning = shouldRun
        if shouldRun {
            tracker.start(cameraID: settings.cameraID)
            lastEvent = "Camera on: \(screens.count) displays."
        } else {
            tracker.stop()
            classifier?.lostFace()
            faceSeen = false
            lookingAt = nil
            lastEvent = paused ? "Paused with ⇧⌘G; camera off."
                : singleDisplay ? "Single display, idle: camera off until another screen is connected."
                : "Camera paused while the screen is locked or asleep."
        }
        updateIcon()
    }

    @MainActor private func startUp() async {
        if !Accessibility.isTrusted { Accessibility.requestAccess() }
        log.notice("Started. Accessibility trusted: \(Accessibility.isTrusted). Screens: \(self.screens.map(\.name).joined(separator: ", "), privacy: .public)")
        let allowed = await GazeTracker.requestAccess()
        guard allowed else {
            cameraError = "Camera access denied. Enable it in System Settings → Privacy & Security → Camera."
            lastEvent = cameraError!
            updateIcon()
            return
        }
        cameraAllowed = true
        updateCameraState()
        if settings.calibration.isEmpty {
            // Don't throw the calibration overlay over the Accessibility prompt on first launch.
            if Accessibility.isTrusted {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                calibrate()
            } else {
                lastEvent = "Not calibrated: choose Calibrate Screens from the menu."
            }
        }
    }

    // MARK: - Gaze → focus

    /// Noise floor per feature (yaw, pitch, faceX, faceY, gazeX, gazeY), so a feature that happened to be
    /// rock-steady during calibration doesn't get an absurd weight.
    private static let noiseFloor: [Double] = [0.05, 0.05, 0.03, 0.03, 0.03, 0.04]

    private func rebuildClassifier() {
        let calibration = settings.calibration
        let noise = settings.calibrationNoise
        let signatures = screens.compactMap { screen in
            calibration[screen.uuid].map { GazeClassifier.Signature(screenID: screen.uuid, features: $0) }
        }
        guard signatures.count >= 2 else {
            classifier = nil
            return
        }
        // Pooled per-feature noise across screens → scale = 1 / noise.
        let n = HeadPose.featureNames.count
        var pooled = [Double](repeating: 0, count: n)
        var counted = 0
        for sig in signatures {
            guard let sd = noise[sig.screenID], sd.count == n else { continue }
            for i in 0..<n { pooled[i] += sd[i] * sd[i] }
            counted += 1
        }
        let scale: [Double] = (0..<n).map { i in
            let sd = counted > 0 ? (pooled[i] / Double(counted)).squareRoot() : Self.noiseFloor[i] * 3
            return 1 / max(sd, Self.noiseFloor[i])
        }
        var c = GazeClassifier(signatures: signatures, dwell: settings.dwell, featureScale: scale)
        // "Looking elsewhere" only when well beyond the span of the screens themselves (phone, keyboard, colleague).
        var maxSeparation = 0.0
        for a in signatures { for b in signatures { maxSeparation = max(maxSeparation, c.distance(a.features, b.features)) } }
        c.maxDistance = max(8, maxSeparation * 1.5)
        c.assume(screen: focus.current?.screenID)
        classifier = c

        let name = { (id: String) in self.screens.first { $0.uuid == id }?.name ?? "?" }
        for sig in signatures {
            let f = zip(HeadPose.featureNames, sig.features).map { "\($0)=\(String(format: "%.3f", $1))" }.joined(separator: " ")
            log.notice("Signature \(name(sig.screenID), privacy: .public): \(f, privacy: .public)")
        }
        log.notice("Feature scale: \(scale.map { String(format: "%.1f", $0) }.joined(separator: " "), privacy: .public)")
        if let (a, b, d) = c.closestPair() {
            log.notice("Closest screens: \(name(a.screenID), privacy: .public) / \(name(b.screenID), privacy: .public) at \(String(format: "%.1f", d), privacy: .public) sigma")
            if d < 4 {
                lastEvent = "\(name(a.screenID)) and \(name(b.screenID)) look too similar (\(String(format: "%.1f", d))σ); recalibrate, turning head and eyes to each."
            }
        }
    }

    private func handle(pose: HeadPose?) {
        if calibrator.isRunning {
            calibrator.feed(pose)
            return
        }
        let seen = pose != nil
        if seen != faceSeen {
            faceSeen = seen
            log.notice("Face \(seen ? "found" : "lost", privacy: .public)")
            updateIcon()
        }
        guard let pose else {
            classifier?.lostFace()
            lookingAt = nil
            return
        }
        guard classifier != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let switched = classifier!.observe(pose, at: now) {
            lookingAt = switched
            glanced(at: switched)
        } else if let candidate = classifier?.candidate {
            lookingAt = candidate
            elsewhereSince = nil
        } else if elsewhereSince == nil {
            elsewhereSince = now
        } else if now - elsewhereSince! > 2, !elsewhereLogged {
            elsewhereLogged = true
            log.notice("Looking at none of the screens for 2 s (nearest \(String(format: "%.1f", self.classifier!.lastDistance), privacy: .public) sigma, limit \(String(format: "%.1f", self.classifier!.maxDistance), privacy: .public))")
        }
        if classifier?.candidate != nil { elsewhereLogged = false }
    }

    private func glanced(at screenID: String, simulated: Bool = false) {
        guard !paused, let screen = screens.first(where: { $0.uuid == screenID }) else { return }
        guard Accessibility.isTrusted else {
            lastEvent = "Needs Accessibility access to switch windows (see menu)."
            classifier?.assume(screen: screenID)
            return
        }
        if activity.mouseButtonDown, !simulated { return }
        if settings.holdWhileTyping, activity.isTyping(within: settings.typingHold), !simulated {
            lastEvent = "Glanced at \(screen.name) while typing; held focus."
            // Re-arm so the next frame can settle again once typing stops.
            classifier?.assume(screen: focus.current?.screenID)
            return
        }
        focus.poll()
        if focus.current?.screenID == screenID {
            lastEvent = "Looking at \(screen.name); focus already there."
            return
        }
        // Bring the pointer along: scrolling follows the pointer on macOS, and a moving hand usually wants to continue on the new screen.
        let pointer: WindowSwitcher.PointerTarget
        if !settings.movePointer {
            pointer = .stay
        } else if let spot = activity.lastPointerPosition[screenID] {
            pointer = .restore(spot)
        } else {
            pointer = .window
        }
        switch WindowSwitcher.focus(screen: screen, remembered: focus.lastWindow[screenID], fallback: settings.fallbackToTopWindow, pointer: pointer) {
        case .raised(let label): lastEvent = "\(screen.name) → \(label)"
        case .alreadyThere: lastEvent = "Looking at \(screen.name); focus already there."
        case .nothingToRaise:
            // Treat the glance as handled; try again only after the gaze moves to another screen and back.
            lastEvent = "Looking at \(screen.name); no window to raise there."
            classifier?.assume(screen: screenID)
        case .failed(let why):
            lastEvent = "Could not switch to \(screen.name): \(why)"
            focus.forget(screenID: screenID)
        }
    }

    // MARK: - Actions

    @objc private func togglePaused() {
        paused.toggle()
        lastEvent = paused ? "Paused with ⇧⌘G; camera off." : "Resumed."
        updateCameraState()
        updateIcon()
    }

    @objc private func calibrate() {
        guard !calibrator.isRunning else { return }
        screens = ScreenInfo.all()
        guard !singleDisplay else {
            lastEvent = "Connect a second display before calibrating."
            return
        }
        calibrator.start(screens: screens) { [weak self] result in
            guard let self else { return }
            if let result {
                settings.calibration = result.mapValues(\.mean)
                settings.calibrationNoise = result.mapValues(\.noise)
                lastEvent = "Calibrated \(result.count) screens."
            } else {
                lastEvent = "Calibration cancelled."
            }
            rebuildClassifier()
            updateIcon()
        }
    }

    @objc private func clearCalibration() {
        settings.clearCalibration()
        rebuildClassifier()
        lastEvent = "Calibration cleared."
    }

    @objc private func chooseCamera(_ sender: NSMenuItem) {
        settings.cameraID = sender.representedObject as? String
        cameraError = nil
        if cameraRunning { tracker.start(cameraID: settings.cameraID) }
    }

    @objc private func setDwell(_ sender: NSMenuItem) {
        settings.dwell = sender.tag == 0 ? 0.2 : sender.tag == 1 ? 0.35 : 0.6
        classifier?.dwell = settings.dwell
    }

    @objc private func toggleHoldWhileTyping() { settings.holdWhileTyping.toggle() }
    @objc private func toggleFallback() { settings.fallbackToTopWindow.toggle() }
    @objc private func toggleMovePointer() { settings.movePointer.toggle() }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            lastEvent = "Launch at login failed: \(error.localizedDescription)"
        }
    }

    @objc private func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") { NSWorkspace.shared.open(url) }
    }

    @objc private func openAccessibilitySettings() { Accessibility.requestAccess() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Status item & menu

    private func updateIcon() {
        let name: String
        if singleDisplay { name = "eye.slash" }
        else if paused { name = "eye.slash" }
        else if cameraError != nil || classifier == nil { name = "eye.trianglebadge.exclamationmark" }
        else { name = faceSeen ? "eyes" : "eyes.inverse" }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Looksee")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = statusLine
    }

    private var statusLine: String {
        if singleDisplay { return "Idle: only one display connected" }
        if paused { return "Paused (⇧⌘G to resume)" }
        if let cameraError { return cameraError }
        if !Accessibility.isTrusted { return "Needs Accessibility access to switch windows" }
        if classifier == nil { return "Not calibrated yet" }
        let fps = "camera \(tracker.deliveredFPS) fps, analysed \(tracker.analysedFPS)"
        return faceSeen ? "Active (\(fps))" : "Active, no face in view (\(fps))"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
        menuRefreshTimer?.invalidate()
        menuRefreshTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshLiveItems() }
        RunLoop.main.add(menuRefreshTimer!, forMode: .common)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuRefreshTimer?.invalidate()
        menuRefreshTimer = nil
    }

    private var statusMenuItem: NSMenuItem?
    private var lookingMenuItem: NSMenuItem?
    private var eventMenuItem: NSMenuItem?

    private func refreshLiveItems() {
        statusMenuItem?.title = "Looksee — \(statusLine)"
        lookingMenuItem?.title = "Looking at: \(lookingAt.flatMap { id in screens.first { $0.uuid == id }?.name } ?? "—")"
        eventMenuItem?.title = lastEvent
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let calibration = settings.calibration

        statusMenuItem = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        lookingMenuItem = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        eventMenuItem = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        [statusMenuItem, lookingMenuItem, eventMenuItem].forEach { $0?.isEnabled = false }
        refreshLiveItems()
        menu.addItem(.separator())

        let pause = menu.addItem(withTitle: paused ? "Resume" : "Pause", action: #selector(togglePaused), keyEquivalent: "g")
        pause.keyEquivalentModifierMask = [.command, .shift]
        pause.target = self
        menu.addItem(withTitle: calibration.isEmpty ? "Calibrate Screens…" : "Recalibrate Screens…", action: #selector(calibrate), keyEquivalent: "").target = self
        menu.addItem(.separator())

        for screen in screens {
            let calibrated = calibration[screen.uuid] != nil
            let remembered = focus.lastWindow[screen.uuid].map { "\($0.appName)\($0.title.isEmpty ? "" : " — \($0.title)")" } ?? "nothing remembered yet"
            let item = menu.addItem(withTitle: "\(calibrated ? "●" : "○") \(screen.name): \(remembered.prefix(48))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.toolTip = calibrated ? "Calibrated" : "Not calibrated: run Calibrate Screens"
        }
        menu.addItem(.separator())

        let options = NSMenu()
        let hold = options.addItem(withTitle: "Hold focus while typing", action: #selector(toggleHoldWhileTyping), keyEquivalent: "")
        hold.state = settings.holdWhileTyping ? .on : .off
        let fallback = options.addItem(withTitle: "Raise top window if nothing remembered", action: #selector(toggleFallback), keyEquivalent: "")
        fallback.state = settings.fallbackToTopWindow ? .on : .off
        let pointer = options.addItem(withTitle: "Move pointer along", action: #selector(toggleMovePointer), keyEquivalent: "")
        pointer.state = settings.movePointer ? .on : .off
        options.addItem(.separator())
        for (tag, name, value) in [(0, "Quick (0.2 s)", 0.2), (1, "Normal (0.35 s)", 0.35), (2, "Relaxed (0.6 s)", 0.6)] {
            let item = options.addItem(withTitle: "Dwell: \(name)", action: #selector(setDwell(_:)), keyEquivalent: "")
            item.tag = tag
            item.state = abs(settings.dwell - value) < 0.01 ? .on : .off
        }
        options.addItem(.separator())
        let login = options.addItem(withTitle: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        options.addItem(withTitle: "Clear calibration", action: #selector(clearCalibration), keyEquivalent: "")
        options.items.forEach { $0.target = self }
        let optionsItem = menu.addItem(withTitle: "Options", action: nil, keyEquivalent: "")
        menu.setSubmenu(options, for: optionsItem)

        let cameras = NSMenu()
        for device in GazeTracker.availableCameras {
            let item = cameras.addItem(withTitle: device.localizedName, action: #selector(chooseCamera(_:)), keyEquivalent: "")
            item.representedObject = device.uniqueID
            item.target = self
            let isCurrent = device.uniqueID == settings.cameraID || (settings.cameraID == nil && device == AVCaptureDevice.default(for: .video))
            item.state = isCurrent ? .on : .off
        }
        let cameraItem = menu.addItem(withTitle: "Camera", action: nil, keyEquivalent: "")
        menu.setSubmenu(cameras, for: cameraItem)

        if cameraError != nil || !Accessibility.isTrusted {
            menu.addItem(.separator())
            if cameraError != nil {
                menu.addItem(withTitle: "Allow Camera Access…", action: #selector(openCameraSettings), keyEquivalent: "").target = self
            }
            if !Accessibility.isTrusted {
                menu.addItem(withTitle: "Allow Accessibility Access…", action: #selector(openAccessibilitySettings), keyEquivalent: "").target = self
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Looksee", action: #selector(quit), keyEquivalent: "q").target = self
    }
}

import AVFoundation
