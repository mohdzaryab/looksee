import Foundation

/// What the camera sees of the head in one frame. Angles in radians, positions normalised 0…1 within the frame,
/// gaze is the pupil offset inside the eye (−0.5…0.5), averaged over both eyes.
struct HeadPose: Equatable {
    var yaw: Double
    var pitch: Double
    var centerX: Double
    var centerY: Double
    var gazeX: Double
    var gazeY: Double

    static let featureNames = ["yaw", "pitch", "faceX", "faceY", "gazeX", "gazeY"]

    /// Raw feature vector; the classifier scales each feature by its calibration noise.
    var features: [Double] { [yaw, pitch, centerX, centerY, gazeX, gazeY] }

    init(yaw: Double, pitch: Double, centerX: Double, centerY: Double, gazeX: Double = 0, gazeY: Double = 0) {
        self.yaw = yaw; self.pitch = pitch; self.centerX = centerX; self.centerY = centerY; self.gazeX = gazeX; self.gazeY = gazeY
    }

    init(features f: [Double]) {
        self.init(yaw: f[0], pitch: f[1], centerX: f[2], centerY: f[3], gazeX: f.count > 4 ? f[4] : 0, gazeY: f.count > 5 ? f[5] : 0)
    }

    static func mean(_ poses: [HeadPose]) -> HeadPose? {
        guard !poses.isEmpty else { return nil }
        return HeadPose(features: Statistics.mean(poses.map(\.features)))
    }

    func blended(toward other: HeadPose, alpha: Double) -> HeadPose {
        HeadPose(features: zip(features, other.features).map { $0 + ($1 - $0) * alpha })
    }
}

enum Statistics {
    static func mean(_ rows: [[Double]]) -> [Double] {
        guard let first = rows.first else { return [] }
        var sum = [Double](repeating: 0, count: first.count)
        for row in rows { for (i, v) in row.enumerated() { sum[i] += v } }
        return sum.map { $0 / Double(rows.count) }
    }

    static func standardDeviation(_ rows: [[Double]]) -> [Double] {
        guard rows.count > 1 else { return rows.first.map { [Double](repeating: 0, count: $0.count) } ?? [] }
        let m = mean(rows)
        var sum = [Double](repeating: 0, count: m.count)
        for row in rows { for (i, v) in row.enumerated() { sum[i] += (v - m[i]) * (v - m[i]) } }
        return sum.map { ($0 / Double(rows.count - 1)).squareRoot() }
    }
}

/// Matches a smoothed head pose against per-screen signatures and reports a stable decision.
///
/// Pure logic, no AppKit, so it can be unit-tested. Feed it `observe` for every frame (or `lostFace`)
/// and read `settled` for the screen the user has been looking at for at least `dwell`.
struct GazeClassifier {
    struct Signature: Equatable {
        let screenID: String
        let features: [Double]
    }

    var signatures: [Signature]
    /// Per-feature multipliers (1 / noise) applied before measuring distance, so each feature counts in units of its own jitter.
    var featureScale: [Double]
    /// Seconds the candidate must persist before it becomes `settled`.
    var dwell: TimeInterval
    /// Smoothing factor for the exponential moving average (1 = no smoothing).
    var smoothing: Double = 0.3
    /// Poses farther than this (in scaled units) from every signature are "looking elsewhere" and ignored.
    var maxDistance: Double = 12
    /// To leave the current screen for another, the pose must be at least this fraction of the way from the
    /// current signature to the other one (0.5 = the midpoint, i.e. no hysteresis).
    var switchFraction: Double = 0.7

    private(set) var smoothed: HeadPose?
    private(set) var candidate: String?
    private var candidateSince: TimeInterval?
    private(set) var settled: String?
    private(set) var lastDistance: Double = .infinity

    init(signatures: [Signature], dwell: TimeInterval, featureScale: [Double]? = nil) {
        self.signatures = signatures
        self.dwell = dwell
        let n = signatures.first?.features.count ?? HeadPose.featureNames.count
        self.featureScale = featureScale ?? [Double](repeating: 1, count: n)
    }

    /// Returns the screen that just became settled, if the decision changed on this frame.
    @discardableResult
    mutating func observe(_ pose: HeadPose, at time: TimeInterval) -> String? {
        smoothed = smoothed.map { $0.blended(toward: pose, alpha: smoothing) } ?? pose
        guard let smoothed, !signatures.isEmpty else { return nil }

        let ranked = signatures
            .map { ($0.screenID, distance($0.features, smoothed.features)) }
            .sorted { $0.1 < $1.1 }
        guard let best = ranked.first else { return nil }
        lastDistance = best.1

        var pick: String? = best.1 <= maxDistance ? best.0 : nil
        // Stay on the current screen unless the pose has clearly crossed toward the new one.
        if let proposed = pick, let settled, proposed != settled,
           let current = signatures.first(where: { $0.screenID == settled }),
           let target = signatures.first(where: { $0.screenID == proposed }) {
            let separation = distance(current.features, target.features)
            let dCurrent = ranked.first { $0.0 == settled }?.1 ?? .infinity
            // Projection of the pose onto the current→target axis, as a fraction of the separation.
            let progress = separation > 0 ? (dCurrent * dCurrent - best.1 * best.1 + separation * separation) / (2 * separation * separation) : 1
            if progress < switchFraction { pick = settled }
        }

        if pick != candidate {
            candidate = pick
            candidateSince = time
        }
        guard let pick, let since = candidateSince, time - since >= dwell, pick != settled else { return nil }
        settled = pick
        return pick
    }

    mutating func lostFace() {
        smoothed = nil
        candidate = nil
        candidateSince = nil
        lastDistance = .infinity
    }

    /// Forces the current decision, e.g. after the user clicked somewhere, so a later glance back counts as a change.
    mutating func assume(screen: String?) {
        settled = screen
        candidate = screen
        candidateSince = nil
    }

    func distance(_ a: [Double], _ b: [Double]) -> Double {
        var sum = 0.0
        for i in 0..<min(a.count, b.count) {
            let d = (a[i] - b[i]) * (i < featureScale.count ? featureScale[i] : 1)
            sum += d * d
        }
        return sum.squareRoot()
    }

    /// The two signatures closest to each other, with their scaled distance.
    func closestPair() -> (Signature, Signature, Double)? {
        var best: (Signature, Signature, Double)?
        for i in 0..<signatures.count {
            for j in (i + 1)..<signatures.count {
                let d = distance(signatures[i].features, signatures[j].features)
                if best == nil || d < best!.2 { best = (signatures[i], signatures[j], d) }
            }
        }
        return best
    }
}
