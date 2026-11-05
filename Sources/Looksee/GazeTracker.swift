import AVFoundation
import Vision

/// Runs the camera and face detection off the main thread, delivering one `HeadPose` per frame.
/// Frames live only in the capture buffer; nothing is written to disk or sent anywhere.
final class GazeTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onPose: ((HeadPose?) -> Void)?
    var onError: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "looksee.camera", qos: .userInteractive)
    private var currentInput: AVCaptureDeviceInput?
    /// Head pose only needs ~10 analysed frames a second. The device is asked for that rate, and
    /// `minInterval` gates analysis by timestamp in case the camera keeps delivering 30 fps anyway.
    private let targetFPS: Int32 = 10
    private let minInterval: TimeInterval = 0.12
    private var lastAnalysis: TimeInterval = 0

    /// Rolling one-second frame counters, for the status menu.
    private(set) var deliveredFPS = 0
    private(set) var analysedFPS = 0
    private var deliveredCount = 0, analysedCount = 0, windowStart: TimeInterval = 0

    private(set) var isRunning = false

    static var availableCameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func start(cameraID: String?) {
        queue.async { [self] in
            configure(cameraID: cameraID)
            if !session.isRunning { session.startRunning() }
            isRunning = session.isRunning
            // Applied after the session is running: committing a preset can reset the active format.
            if let device = currentInput?.device { Self.throttle(device, to: targetFPS) }
        }
    }

    private static func throttle(_ device: AVCaptureDevice, to fps: Int32) {
        let frameDuration = CMTime(value: 1, timescale: fps)
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameDuration <= frameDuration && frameDuration <= $0.maxFrameDuration }),
              (try? device.lockForConfiguration()) != nil else { return }
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        device.unlockForConfiguration()
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            isRunning = false
        }
    }

    private func configure(cameraID: String?) {
        let device = Self.availableCameras.first { $0.uniqueID == cameraID }
            ?? AVCaptureDevice.default(for: .video)
            ?? Self.availableCameras.first
        guard let device else {
            DispatchQueue.main.async { self.onError?("No camera found.") }
            return
        }
        if currentInput?.device == device, session.outputs.contains(output) { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        if let currentInput { session.removeInput(currentInput) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw NSError(domain: "Looksee", code: 1) }
            session.addInput(input)
            currentInput = input
        } catch {
            DispatchQueue.main.async { self.onError?("Could not open \(device.localizedName).") }
            return
        }
        if !session.outputs.contains(output) {
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
    }

    private lazy var faceRequest: VNDetectFaceRectanglesRequest = {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3 // yaw + pitch + roll
        return request
    }()

    private lazy var landmarksRequest: VNDetectFaceLandmarksRequest = {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3 // includes pupils
        return request
    }()

    /// Pupil offset inside each eye, −0.5…0.5 on both axes, averaged over the eyes that were found.
    private static func gaze(_ landmarks: VNFaceLandmarks2D?) -> (x: Double, y: Double) {
        guard let landmarks else { return (0, 0) }
        var xs: [Double] = [], ys: [Double] = []
        for (eye, pupil) in [(landmarks.leftEye, landmarks.leftPupil), (landmarks.rightEye, landmarks.rightPupil)] {
            guard let eye, let pupil, eye.pointCount >= 4, pupil.pointCount >= 1 else { continue }
            let pts = eye.normalizedPoints
            let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
            let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
            guard maxX - minX > 0.001, maxY - minY > 0.001 else { continue }
            let p = pupil.normalizedPoints[0]
            xs.append(Double((p.x - minX) / (maxX - minX)) - 0.5)
            ys.append(Double((p.y - minY) / (maxY - minY)) - 0.5)
        }
        guard !xs.isEmpty else { return (0, 0) }
        return (xs.reduce(0, +) / Double(xs.count), ys.reduce(0, +) / Double(ys.count))
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        deliveredCount += 1
        if now - windowStart >= 1 {
            deliveredFPS = deliveredCount; analysedFPS = analysedCount
            deliveredCount = 0; analysedCount = 0; windowStart = now
        }
        guard now - lastAnalysis >= minInterval, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = now
        analysedCount += 1

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([faceRequest])
        } catch {
            return
        }
        // Largest face wins: the person at the desk, not someone walking past behind them.
        guard let face = (faceRequest.results ?? []).max(by: { $0.boundingBox.area < $1.boundingBox.area }) else {
            DispatchQueue.main.async { self.onPose?(nil) }
            return
        }
        // Landmarks (for the pupils) only on that one face.
        landmarksRequest.inputFaceObservations = [face]
        try? handler.perform([landmarksRequest])
        let gaze = Self.gaze(landmarksRequest.results?.first?.landmarks)
        let pose = HeadPose(
            yaw: face.yaw?.doubleValue ?? 0,
            pitch: face.pitch?.doubleValue ?? 0,
            centerX: face.boundingBox.midX,
            centerY: face.boundingBox.midY,
            gazeX: gaze.x,
            gazeY: gaze.y
        )
        DispatchQueue.main.async { self.onPose?(pose) }
    }
}
