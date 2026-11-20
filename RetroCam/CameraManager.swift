import AVFoundation
import CoreImage
import UIKit

enum WB: String, CaseIterable {
    case auto = "Auto", daylight = "Daylight", cloudy = "Cloudy", shade = "Shade", tungsten = "Tungsten", fluorescent = "Fluor."
    var kelvin: Float? { [.daylight: 5500, .cloudy: 6500, .shade: 7500, .tungsten: 3200, .fluorescent: 4000][self] }
}

struct Caps {
    var iso: ClosedRange<Float>?; var shutter: ClosedRange<Double>?; var manualFocus = false
    var flash = false; var wbLock = false; var maxZoom: CGFloat = 1; var bias: ClosedRange<Float> = -2...2
}

final class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.session")
    private let videoQueue = DispatchQueue(label: "camera.video")
    private let videoOut = AVCaptureVideoDataOutput(), photoOut = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private let lock = NSLock()
    private var _state = (p: Preset.builtIn[0].params, k: 1.0)
    private var frameSeed: UInt64 = 1

    @Published var preview: CGImage?
    @Published var caps = Caps()
    @Published var presetIndex = 0 { didSet { if presetIndex < allPresets.count { params = allPresets[presetIndex].params } } }
    @Published var params = Preset.builtIn[0].params { didSet { sync() } }
    @Published var strength = 1.0 { didSet { sync() } }
    @Published var flash: AVCaptureDevice.FlashMode = .off
    @Published var isFront = false
    @Published var customPresets: [Preset] = (try? JSONDecoder().decode([Preset].self, from: UserDefaults.standard.data(forKey: "presets") ?? Data())) ?? []
    var allPresets: [Preset] { Preset.builtIn + customPresets }
    var presetName: String { presetIndex < allPresets.count ? allPresets[presetIndex].name : "Custom" }

    private func sync() { lock.lock(); _state = (params, strength); lock.unlock() }
    private func state() -> (FilterParams, Double) { lock.lock(); defer { lock.unlock() }; return _state }

    func savePreset(_ name: String) {
        customPresets.append(Preset(name: name, params: params))
        UserDefaults.standard.set(try? JSONEncoder().encode(customPresets), forKey: "presets")
        presetIndex = allPresets.count - 1
    }

    // MARK: Session
    func start() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { return }
            self.queue.async { self.configure(front: false); self.session.startRunning() }
        }
    }
    func flip() { isFront.toggle(); let f = isFront; queue.async { self.configure(front: f) } }

    private func configure(front: Bool) {
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.inputs.forEach { session.removeInput($0) }
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back),
              let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else { session.commitConfiguration(); return }
        session.addInput(input); device = dev
        if session.outputs.isEmpty {
            videoOut.alwaysDiscardsLateVideoFrames = true
            videoOut.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOut) { session.addOutput(videoOut) }
            if session.canAddOutput(photoOut) { session.addOutput(photoOut) }
        }
        if let c = videoOut.connection(with: .video) {
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = front
        }
        session.commitConfiguration()
        let f = dev.activeFormat
        let c = Caps(iso: f.minISO < f.maxISO ? f.minISO...f.maxISO : nil,
                     shutter: f.minExposureDuration.seconds < f.maxExposureDuration.seconds ? f.minExposureDuration.seconds...f.maxExposureDuration.seconds : nil,
                     manualFocus: dev.isLockingFocusWithCustomLensPositionSupported, flash: dev.hasFlash && photoOut.supportedFlashModes.contains(.on),
                     wbLock: dev.isLockingWhiteBalanceWithCustomDeviceGainsSupported, maxZoom: min(f.videoMaxZoomFactor, 10),
                     bias: dev.minExposureTargetBias...dev.maxExposureTargetBias)
        DispatchQueue.main.async { self.caps = c }
    }

    // MARK: Controls (all run on session queue under device lock)
    private func cfg(_ body: @escaping (AVCaptureDevice) -> Void) {
        queue.async { guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }; body(d); d.unlockForConfiguration() }
    }
    func focus(normalized n: CGPoint) {
        let p = isFront ? CGPoint(x: n.y, y: n.x) : CGPoint(x: n.y, y: 1 - n.x) // portrait view -> sensor space
        cfg { d in
            if d.isFocusPointOfInterestSupported && d.isFocusModeSupported(.autoFocus) { d.focusPointOfInterest = p; d.focusMode = .autoFocus }
            if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = p; d.exposureMode = .continuousAutoExposure }
        }
    }
    func setBias(_ v: Float) { cfg { d in d.setExposureTargetBias(min(max(v, d.minExposureTargetBias), d.maxExposureTargetBias)) } }
    func setAutoExposure() { cfg { d in d.exposureMode = .continuousAutoExposure } }
    func setManualExposure(iso: Float, shutter: Double) {
        cfg { d in
            let f = d.activeFormat
            d.setExposureModeCustom(duration: CMTimeMakeWithSeconds(min(max(shutter, f.minExposureDuration.seconds), f.maxExposureDuration.seconds), preferredTimescale: 1_000_000),
                                    iso: min(max(iso, f.minISO), f.maxISO))
        }
    }
    func setZoom(_ z: CGFloat) { cfg { d in d.videoZoomFactor = min(max(z, 1), min(d.activeFormat.videoMaxZoomFactor, 10)) } }
    func setLens(_ v: Float) { cfg { d in if d.isLockingFocusWithCustomLensPositionSupported { d.setFocusModeLocked(lensPosition: v) } } }
    func setAutoFocus() { cfg { d in if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus } } }
    func setWB(_ wb: WB) {
        cfg { d in
            guard let k = wb.kelvin else { if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }; return }
            guard d.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
            var g = d.deviceWhiteBalanceGains(for: .init(temperature: k, tint: 0))
            let m = d.maxWhiteBalanceGain
            g.redGain = min(max(g.redGain, 1), m); g.greenGain = min(max(g.greenGain, 1), m); g.blueGain = min(max(g.blueGain, 1), m)
            d.setWhiteBalanceModeLocked(with: g)
        }
    }

    // MARK: Live preview (downscaled, filtered)
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        var img = CIImage(cvPixelBuffer: pb)
        let s = min(1, 800 / img.extent.width)
        img = img.transformed(by: .init(scaleX: s, y: s))
        let (p, k) = state(); frameSeed &+= 1
        let out = FilterEngine.apply(img, p, seed: frameSeed, scale: s, strength: k)
        guard let cg = FilterEngine.ctx.createCGImage(out, from: img.extent) else { return }
        DispatchQueue.main.async { self.preview = cg }
    }

    // MARK: Capture
    func capture() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let s = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        if photoOut.supportedFlashModes.contains(flash) { s.flashMode = flash }
        photoOut.capturePhoto(with: s, delegate: self)
    }
    func photoOutput(_ o: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        let exif = photo.metadata["{Exif}"] as? [String: Any]
        let iso = (exif?["ISOSpeedRatings"] as? [Double])?.first, sh = exif?["ExposureTime"] as? Double
        let (p, k) = state(), name = presetName
        DispatchQueue.global(qos: .userInitiated).async {
            Library.shared.save(original: data, params: p, strength: k, filter: name, iso: iso, shutter: sh, id: nil, toPhotos: true)
        }
    }
}
