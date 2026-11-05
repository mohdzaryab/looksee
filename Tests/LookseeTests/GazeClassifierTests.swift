import Testing
@testable import Looksee

private let left = GazeClassifier.Signature(screenID: "left", features: HeadPose(yaw: -0.5, pitch: 0, centerX: 0.4, centerY: 0.5).features)
private let center = GazeClassifier.Signature(screenID: "center", features: HeadPose(yaw: 0, pitch: 0, centerX: 0.5, centerY: 0.5).features)
private let right = GazeClassifier.Signature(screenID: "right", features: HeadPose(yaw: 0.5, pitch: 0, centerX: 0.6, centerY: 0.5).features)

private func pose(yaw: Double, pitch: Double = 0, x: Double = 0.5) -> HeadPose {
    HeadPose(yaw: yaw, pitch: pitch, centerX: x, centerY: 0.5)
}

@Suite struct GazeClassifierTests {
    @Test func settlesAfterDwell() {
        var c = GazeClassifier(signatures: [left, center, right], dwell: 0.3)
        c.smoothing = 1
        c.assume(screen: "center")
        #expect(c.observe(pose(yaw: 0.5, x: 0.6), at: 0) == nil)
        #expect(c.observe(pose(yaw: 0.5, x: 0.6), at: 0.1) == nil)
        #expect(c.observe(pose(yaw: 0.5, x: 0.6), at: 0.35) == "right")
        #expect(c.settled == "right")
        // No repeat notification while the user keeps looking there.
        #expect(c.observe(pose(yaw: 0.5, x: 0.6), at: 0.6) == nil)
    }

    @Test func briefGlanceDoesNotSwitch() {
        var c = GazeClassifier(signatures: [left, center, right], dwell: 0.3)
        c.smoothing = 1
        c.assume(screen: "center")
        #expect(c.observe(pose(yaw: -0.5, x: 0.4), at: 0) == nil)
        #expect(c.observe(pose(yaw: 0, x: 0.5), at: 0.2) == nil)
        #expect(c.observe(pose(yaw: 0, x: 0.5), at: 0.6) == nil)
        #expect(c.settled == "center")
    }

    @Test func hysteresisKeepsCurrentScreenNearBoundary() {
        var c = GazeClassifier(signatures: [left, center, right], dwell: 0)
        c.smoothing = 1
        c.assume(screen: "center")
        // Past the midpoint toward "right" (60% of the way), but not past the 70% switch threshold.
        #expect(c.observe(pose(yaw: 0.3, x: 0.56), at: 0) == nil)
        #expect(c.settled == "center")
        // 80% of the way: switch.
        #expect(c.observe(pose(yaw: 0.4, x: 0.58), at: 0.1) == "right")
    }

    @Test func featureScaleWeightsNoisyFeaturesLess() {
        // Pitch is very noisy (scale 1), yaw is precise (scale 10): a pitch difference alone should not matter much.
        let a = GazeClassifier.Signature(screenID: "a", features: [0, 0, 0.5, 0.5, 0, 0])
        let b = GazeClassifier.Signature(screenID: "b", features: [0, 0.3, 0.5, 0.5, 0, 0])
        var c = GazeClassifier(signatures: [a, b], dwell: 0, featureScale: [10, 1, 1, 1, 1, 1])
        c.smoothing = 1
        c.assume(screen: "a")
        #expect(c.distance(a.features, b.features) == 0.3)
        #expect(c.closestPair()?.2 == 0.3)
    }

    @Test func statistics() {
        let rows: [[Double]] = [[1, 10], [3, 10], [5, 10]]
        #expect(Statistics.mean(rows) == [3, 10])
        #expect(Statistics.standardDeviation(rows) == [2, 0])
    }

    @Test func farPoseIsIgnored() {
        var c = GazeClassifier(signatures: [left, center, right], dwell: 0)
        c.smoothing = 1
        c.maxDistance = 0.7 // unscaled features in this test
        c.assume(screen: "center")
        #expect(c.observe(pose(yaw: 1.4, pitch: 0.9, x: 0.95), at: 0) == nil)
        #expect(c.candidate == nil)
    }

    @Test func lostFaceResetsCandidate() {
        var c = GazeClassifier(signatures: [left, center, right], dwell: 0.3)
        c.smoothing = 1
        c.assume(screen: "center")
        c.observe(pose(yaw: 0.5, x: 0.6), at: 0)
        c.lostFace()
        #expect(c.observe(pose(yaw: 0.5, x: 0.6), at: 0.35) == nil)
        #expect(c.observe(pose(yaw: 0.5, x: 0.6), at: 0.7) == "right")
    }

    @Test func meanAndBlend() {
        let m = HeadPose.mean([pose(yaw: 0), pose(yaw: 1)])
        #expect(m?.yaw == 0.5)
        #expect(pose(yaw: 0).blended(toward: pose(yaw: 1), alpha: 0.25).yaw == 0.25)
        #expect(HeadPose.mean([]) == nil)
    }
}
