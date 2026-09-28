//
//  CardCamera.swift
//  magic-hat
//
//  The Scan tab's camera: an AVCaptureSession on its own queue (starting
//  a session blocks, and never on the main thread), a video output whose
//  frames are read by Vision's text recogniser inside the card guide only,
//  a few times a second and never two at once. Lines come back to the main
//  actor as plain values; the frames never leave this queue.
//
//  The guide is given in the preview's coordinates and mapped here to the
//  upright image the recogniser sees (`regionOfInterest`), through the
//  preview's aspect-fill crop — `guideRegion`, pure and tested. The
//  rotation coordinator keeps the preview level and tells Vision which
//  way up the frames are, so the tab works in landscape too.
//
//  Still photos go through the same recogniser (`recognize(image:)`),
//  which is also what makes the scanner testable on a simulator with no
//  camera.
//

import AVFoundation
import Vision
import UIKit

/// A back camera the scanner can use, for the settings picker.
nonisolated struct CameraOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

nonisolated final class CardCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "magic-hat.camera", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    /// The camera asked for (CameraOption.id); nil is the default.
    private var requestedID: String?

    /// Read on the camera queue; written from the main actor.
    private let lock = NSLock()
    private var _region = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var _isPaused = false
    private var busy = false
    private var lastFrame = Date.distantPast

    /// Recognised lines per analysed frame, on the main actor.
    var onLines: (@MainActor @Sendable ([RecognizedLine]) -> Void)?

    static let interval: TimeInterval = 0.22

    var isAvailable: Bool { AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil }

    /// The back cameras, the multi-lens ones first: on a Pro phone they
    /// switch to the ultra wide's macro by themselves when a card is held
    /// close, which is what a scanner wants.
    private static let deviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
        .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera,
    ]

    static func cameras() -> [CameraOption] {
        AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .back)
            .devices.map { CameraOption(id: $0.uniqueID, name: displayName($0)) }
    }

    private static func displayName(_ device: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .builtInTripleCamera, .builtInDualWideCamera: return "Automatic (Macro)"
        case .builtInDualCamera: return "Automatic"
        case .builtInWideAngleCamera: return "Wide"
        case .builtInUltraWideCamera: return "Ultra Wide"
        case .builtInTelephotoCamera: return "Telephoto"
        default: return device.localizedName
        }
    }

    private func chosenDevice() -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: Self.deviceTypes, mediaType: .video, position: .back).devices
        if let requestedID, let match = devices.first(where: { $0.uniqueID == requestedID }) { return match }
        return devices.first
    }

    /// Switches to another camera (nil: the default), keeping the session.
    func select(cameraID: String?) {
        queue.async {
            self.requestedID = cameraID
            guard !self.session.inputs.isEmpty, let device = self.chosenDevice(), device != self.device else { return }
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            if let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) {
                self.session.addInput(input)
                self.device = device
            }
            self.session.commitConfiguration()
            self.configureFocus(device)
            DispatchQueue.main.async { self.attachRotation() }
        }
    }

    /// The guide, as a normalised rect in the upright image (Vision's
    /// coordinates, origin bottom-left).
    var region: CGRect {
        get { lock.withLock { _region } }
        set { lock.withLock { _region = newValue } }
    }

    var isPaused: Bool {
        get { lock.withLock { _isPaused } }
        set { lock.withLock { _isPaused = newValue } }
    }

    static func authorize() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Builds the session once; returns the rotation coordinator's preview
    /// layer needs, on the main actor.
    /// On the main actor (the preview layer is UIKit's); the session is
    /// built on the camera's queue while this waits.
    @MainActor
    func configure(previewLayer: AVCaptureVideoPreviewLayer, cameraID: String?) async throws {
        requestedID = cameraID
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.configureSession()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        previewLayer.session = session
        self.previewLayer = previewLayer
        attachRotation()
    }

    /// A rotation coordinator for the current device and preview.
    @MainActor private func attachRotation() {
        guard let device, let previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotation = coordinator
        previewLayer.connection?.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
    }

    enum CameraError: Error, LocalizedError {
        case unavailable
        var errorDescription: String? { "This device has no camera the app can use." }
    }

    private func configureSession() throws {
        guard session.inputs.isEmpty else { return }
        guard let device = chosenDevice() else {
            throw CameraError.unavailable
        }
        self.device = device
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) { session.addInput(input) }
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configureFocus(device)
    }

    /// Cards are read close up: focus near, continuously.
    private func configureFocus(_ device: AVCaptureDevice) {
        try? device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
        device.unlockForConfiguration()
    }

    func start() { queue.async { if !self.session.isRunning { self.session.startRunning() } } }
    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }

    /// Torch for dim rooms and foils.
    func setTorch(_ on: Bool) {
        queue.async {
            guard let device = self.device, device.hasTorch else { return }
            try? device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        }
    }

    /// The preview's level angle, for a rotation.
    @MainActor func previewAngle() -> CGFloat? { rotation?.videoRotationAngleForHorizonLevelPreview }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isPaused, !busy, Date().timeIntervalSince(lastFrame) >= Self.interval,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        busy = true
        lastFrame = Date()
        defer { busy = false }
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
        let lines = Self.recognize(CIImage(cvPixelBuffer: pixels), orientation: Self.orientation(forAngle: angle), region: region)
        let callback = onLines
        Task { @MainActor in callback?(lines) }
    }

    /// Vision's orientation for the capture connection's rotation angle.
    static func orientation(forAngle angle: CGFloat) -> CGImagePropertyOrientation {
        switch Int(angle.rounded()) % 360 {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }

    static func recognize(_ image: CIImage, orientation: CGImagePropertyOrientation, region: CGRect) -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false   // names are not dictionary words
        request.minimumTextHeight = 0.015
        request.regionOfInterest = region
        let handler = VNImageRequestHandler(ciImage: image, orientation: orientation)
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { observation in
            guard let top = observation.topCandidates(1).first else { return nil }
            return RecognizedLine(text: top.string, confidence: top.confidence, box: observation.boundingBox)
        }
    }

    /// A still photo (the photo picker), the whole frame as the card.
    static func recognize(image: UIImage) -> [RecognizedLine] {
        guard let ci = CIImage(image: image) else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return recognize(ci, orientation: orientation, region: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Maps the guide (in the preview view's points) into the upright
    /// image's normalised coordinates, origin bottom-left, through the
    /// preview's aspect-fill: the image is scaled to cover the view and
    /// centred, so part of it lies outside.
    static func guideRegion(guide: CGRect, in view: CGSize, imageSize: CGSize) -> CGRect {
        guard view.width > 0, view.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let scale = max(view.width / imageSize.width, view.height / imageSize.height)
        let shown = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let offset = CGPoint(x: (shown.width - view.width) / 2, y: (shown.height - view.height) / 2)
        let x = (guide.minX + offset.x) / shown.width
        let yTop = (guide.minY + offset.y) / shown.height
        let w = guide.width / shown.width
        let h = guide.height / shown.height
        let rect = CGRect(x: x, y: 1 - yTop - h, width: w, height: h)
        return rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

nonisolated extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
