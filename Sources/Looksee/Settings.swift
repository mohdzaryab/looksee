import Foundation

/// Persisted preferences and calibration. Everything is local to this Mac.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    /// How long the head must stay turned toward a screen before focus moves.
    var dwell: TimeInterval {
        get { defaults.object(forKey: "dwell") as? Double ?? 0.5 }
        set { defaults.set(newValue, forKey: "dwell") }
    }

    /// Glances are ignored for this long after a keystroke, so reading off one screen while typing on another doesn't move focus.
    var typingHold: TimeInterval {
        get { defaults.object(forKey: "typingHold") as? Double ?? 0.8 }
        set { defaults.set(newValue, forKey: "typingHold") }
    }

    var holdWhileTyping: Bool {
        get { defaults.object(forKey: "holdWhileTyping") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "holdWhileTyping") }
    }

    /// Also move the pointer onto the screen that gained focus, back to where it last was there.
    var movePointer: Bool {
        get { defaults.object(forKey: "movePointer") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "movePointer") }
    }

    /// If no window is remembered for a screen, raise whatever window is on top there.
    var fallbackToTopWindow: Bool {
        get { defaults.object(forKey: "fallbackToTopWindow") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "fallbackToTopWindow") }
    }

    var cameraID: String? {
        get { defaults.string(forKey: "cameraID") }
        set { defaults.set(newValue, forKey: "cameraID") }
    }

    /// Bumped whenever the feature vector changes, so stale calibrations are discarded.
    static let calibrationVersion = 2

    /// Head-pose signature (mean) per display UUID, written by the calibrator.
    var calibration: [String: [Double]] {
        get {
            guard defaults.integer(forKey: "calibrationVersion") == Self.calibrationVersion else { return [:] }
            return defaults.dictionary(forKey: "calibration") as? [String: [Double]] ?? [:]
        }
        set {
            defaults.set(newValue, forKey: "calibration")
            defaults.set(Self.calibrationVersion, forKey: "calibrationVersion")
        }
    }

    /// Per-feature standard deviation measured while the user held still on each screen.
    var calibrationNoise: [String: [Double]] {
        get { defaults.dictionary(forKey: "calibrationNoise") as? [String: [Double]] ?? [:] }
        set { defaults.set(newValue, forKey: "calibrationNoise") }
    }

    func clearCalibration() {
        defaults.removeObject(forKey: "calibration")
        defaults.removeObject(forKey: "calibrationNoise")
    }
}
