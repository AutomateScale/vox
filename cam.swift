import Cocoa
import AVFoundation
import Vision
import CoreImage
import Metal
import QuartzCore

enum CamState {
    static var chromaCube: Data? = nil
    static var hexMask: CIImage? = nil
    static var hexMaskSize: CGSize = .zero
}

func logMsg(_ msg: String) {
    fputs("CAM_LOG: \(msg)\n", stderr)
    fflush(stderr)
}

class ResizableCutoutView: NSView {
    weak var windowController: WebcamWindowController?
    var isHovered: Bool = false
    var trackingArea: NSTrackingArea?
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }
    
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        windowController?.showControlsPill(true)
    }
    
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        windowController?.showControlsPill(false)
    }
    
    override func scrollWheel(with event: NSEvent) {
        let delta = event.deltaY
        if abs(delta) > 0.1 {
            windowController?.adjustSize(by: delta * 12.0)
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            windowController?.cycleSizePreset()
        } else {
            window?.performDrag(with: event)
        }
    }
}

class WebcamWindowController: NSWindowController, NSWindowDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    var captureSession: AVCaptureSession?
    var videoOutput: AVCaptureVideoDataOutput?
    var renderLayer: CALayer?
    var metalDevice: MTLDevice?
    var ciContext: CIContext?
    var pillLayer: CATextLayer?
    var sampleQueue: DispatchQueue?
    
    var currentSize: CGFloat = 340.0
    var lastRenderTime: CFTimeInterval = 0
    var frameCount: Int = 0
    let segmentationRequest: VNGeneratePersonSegmentationRequest = {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .accurate
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return req
    }()
    var trackedBodyRect: CGRect? = nil
    var prevMaskData: [Float]? = nil
    var segFrameCounter: Int = 0          // adaptive segmentation cadence
    var rawShape: String = "circle"       // circle | squircle | portrait | hex
    var framing: String = "wide"          // wide (16:9) | tall (portrait, follows you)
    var followX: CGFloat = 0              // smoothed person-center for tall framing
    var followEnabled: Bool = false       // off by default: fixed center crop
    var cachedCleanMask: CIImage? = nil   // last finished matte (reused on skip frames)
    
    var filterMode: String = "clean"
    var captureQuality: String = "auto"   // auto | hd | 4k
    let sizePresets: [CGFloat] = [260.0, 380.0, 520.0, 720.0, 950.0, 1200.0]
    var currentPresetIndex: Int = 1
    
    var alienStartPoint: CGPoint? = nil
    var targetWindowRect: NSRect? = nil
    
    var deviceParam: String? = nil
    var prevRowMinData: [Int]? = nil
    var prevRowMaxData: [Int]? = nil
    var currentMotionVelocity: Double = 0.0
    
    init(size: CGFloat = 380.0, cornerPosition: String = "bottom-left", filterMode: String = "mint", alienPoint: CGPoint? = nil, targetPoint: CGPoint? = nil, deviceName: String? = nil, shape: String = "circle", framing: String = "wide", follow: Bool = false, quality: String = "auto") {
        self.currentSize = size
        self.captureQuality = quality
        self.filterMode = filterMode
        self.rawShape = shape
        self.framing = framing
        self.followEnabled = follow
        self.alienStartPoint = alienPoint
        self.deviceParam = deviceName
        
        let primaryScreen = NSScreen.screens.first ?? NSScreen.main
        let screen = primaryScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let margin: CGFloat = 35.0
        
        let width = (framing == "tall") ? size * 0.75
                  : (framing == "wide") ? size * 1.3 : size
        let height = (framing == "wide") ? size * 0.75 : size
        
        var targetX: CGFloat = screen.minX + margin
        var targetY: CGFloat = screen.minY + margin
        
        if let tp = targetPoint {
            targetX = tp.x
            targetY = tp.y
        } else {
            if cornerPosition.contains("right") {
                targetX = screen.maxX - width - margin
            }
            if cornerPosition.contains("top") {
                targetY = screen.maxY - height - margin
            }
            targetX = max(screen.minX + margin, min(screen.maxX - width - margin, targetX))
            targetY = max(screen.minY + margin, min(screen.maxY - height - margin, targetY))
        }
        
        let finalRect = NSRect(x: targetX, y: targetY, width: width, height: height)
        self.targetWindowRect = finalRect
        
        // If Alien hub point is provided, start tiny at Alien location for Genie Fly-Out!
        var initRect = finalRect
        if let ap = alienPoint {
            initRect = NSRect(x: ap.x - 15, y: ap.y - 15, width: 30, height: 30)
        }
        
        logMsg("Creating window at initRect: \(initRect), targetRect: \(finalRect)")
        
        let window = NSWindow(
            contentRect: initRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.displaysWhenScreenProfileChanges = true
        window.hidesOnDeactivate = false
        window.sharingType = .readWrite
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        
        if alienPoint != nil {
            window.alphaValue = 0.05
        }
        
        window.orderFrontRegardless()
        
        super.init(window: window)
        window.delegate = self
        
        segmentationRequest.qualityLevel = .balanced
        segmentationRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
        
        setupMetal()
        setupContentView(width: width, height: height)
        setupCamera(requestedDevice: deviceName)
        
        // Trigger Genie Fly-Out Spring Animation!
        if alienPoint != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.animateGenieFlyOut()
            }
        }
    }
    
    func animateGenieFlyOut() {
        guard let win = self.window, let targetRect = self.targetWindowRect else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.48
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            win.animator().setFrame(targetRect, display: true)
            win.animator().alphaValue = 1.0
        }, completionHandler: nil)
    }
    
    func animateGenieFlyIn(completion: @escaping () -> Void) {
        guard let win = self.window, let ap = self.alienStartPoint else {
            closeWebcam()
            completion()
            return
        }
        let returnRect = NSRect(x: ap.x - 15, y: ap.y - 15, width: 30, height: 30)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.7, 0.0, 0.84, 0.0)
            win.animator().setFrame(returnRect, display: true)
            win.animator().alphaValue = 0.0
        }, completionHandler: {
            self.closeWebcam()
            completion()
        })
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupMetal() {
        if let device = MTLCreateSystemDefaultDevice() {
            self.metalDevice = device
            self.ciContext = CIContext(mtlDevice: device)
        } else {
            self.ciContext = CIContext()
        }
    }
    
    private func setupContentView(width: CGFloat, height: CGFloat) {
        guard let window = self.window else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        
        let containerView = ResizableCutoutView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        containerView.windowController = self
        containerView.wantsLayer = true
        
        let layer = CALayer()
        layer.frame = containerView.bounds
        layer.contentsScale = scale
        layer.backgroundColor = NSColor.clear.cgColor
        layer.isOpaque = false
        
        containerView.layer = layer
        self.renderLayer = layer
        
        let pill = CATextLayer()
        pill.string = " 🔍 Double-Click to Expand • Scroll to Resize "
        pill.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        pill.fontSize = 11
        pill.alignmentMode = .center
        pill.foregroundColor = NSColor.white.cgColor
        pill.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        pill.cornerRadius = 10.0
        pill.frame = CGRect(x: 10, y: 10, width: width - 20, height: 22)
        pill.opacity = 0.0
        layer.addSublayer(pill)
        self.pillLayer = pill
        
        window.contentView = containerView
    }
    
    func showControlsPill(_ show: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        self.pillLayer?.opacity = show ? 1.0 : 0.0
        CATransaction.commit()
    }
    
    func updateWindowSize(newWidth: CGFloat, newHeight: CGFloat) {
        guard let window = self.window, let contentView = window.contentView else { return }
        let frame = window.frame
        let newRect = NSRect(x: frame.minX, y: frame.minY, width: newWidth, height: newHeight)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        
        DispatchQueue.main.async {
            window.setFrame(newRect, display: true, animate: true)
            contentView.frame = NSRect(x: 0, y: 0, width: newWidth, height: newHeight)
            self.renderLayer?.frame = NSRect(x: 0, y: 0, width: newWidth, height: newHeight)
            self.renderLayer?.contentsScale = scale
            self.pillLayer?.frame = CGRect(x: 10, y: 10, width: newWidth - 20, height: 22)
        }
    }
    
    func cycleSizePreset() {
        currentPresetIndex = (currentPresetIndex + 1) % sizePresets.count
        let targetSize = sizePresets[currentPresetIndex]
        setSize(targetSize)
    }
    
    func adjustSize(by delta: CGFloat) {
        let minSize: CGFloat = 160.0
        // grow to nearly full screen height — talking-head takes want BIG
        let maxSize: CGFloat = max(900.0, (window?.screen ?? NSScreen.main).map { $0.frame.height * 0.92 } ?? 900.0)
        let newSize = max(minSize, min(maxSize, currentSize + delta))
        if newSize != currentSize {
            setSize(newSize)
        }
    }
    
    private func setSize(_ newSize: CGFloat) {
        guard let window = self.window, let contentView = window.contentView else { return }
        currentSize = newSize
        print("CAM_LOG: SIZE_NOW=\(Int(newSize))")
        fflush(stdout)
        if captureQuality == "auto", let session = captureSession {
            let lightMode = (filterMode == "raw" || filterMode == "chroma")
            let is4K = session.sessionPreset == .hd4K3840x2160
            var target: AVCaptureSession.Preset? = nil
            if !is4K && newSize >= 720 && lightMode && session.canSetSessionPreset(.hd4K3840x2160) {
                target = .hd4K3840x2160
            } else if is4K && newSize < 560 && session.canSetSessionPreset(.hd1920x1080) {
                target = .hd1920x1080
            }
            if let t = target {
                sampleQueue?.async {
                    session.beginConfiguration()
                    session.sessionPreset = t
                    session.commitConfiguration()
                }
                print("CAM_LOG: capture quality -> \(t == .hd4K3840x2160 ? "4K UHD" : "1080p") (window \(Int(newSize)))")
                fflush(stdout)
            }
        }
        let frame = window.frame
        let newWidth = (self.framing == "tall") ? newSize * 0.75
                     : (self.framing == "wide") ? newSize * 1.3 : newSize
        let newHeight = (self.framing == "wide") ? newSize * 0.75 : newSize
        let newRect = NSRect(x: frame.minX, y: frame.minY, width: newWidth, height: newHeight)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        
        DispatchQueue.main.async {
            window.setFrame(newRect, display: true, animate: true)
            contentView.frame = NSRect(x: 0, y: 0, width: newWidth, height: newHeight)
            self.renderLayer?.frame = NSRect(x: 0, y: 0, width: newWidth, height: newHeight)
            self.renderLayer?.contentsScale = scale
            self.pillLayer?.frame = CGRect(x: 10, y: 10, width: newWidth - 20, height: 22)
        }
    }
    
    private func setupCamera(requestedDevice: String? = nil) {
        logMsg("Config: mode=\(filterMode) shape=\(rawShape) framing=\(framing) follow=\(followEnabled)")
        logMsg("Setting up camera session with requested device: \(requestedDevice ?? "default")...")
        let session = AVCaptureSession()
        
        let videoDevices = AVCaptureDevice.devices(for: .video)
        logMsg("Found \(videoDevices.count) video devices:")
        for (idx, dev) in videoDevices.enumerated() {
            logMsg("  [\(idx)] Device: \(dev.localizedName) (ID: \(dev.uniqueID))")
        }
        
        var selectedDevice: AVCaptureDevice? = nil
        if let req = requestedDevice, !req.isEmpty {
            if let idx = Int(req), idx >= 0, idx < videoDevices.count {
                selectedDevice = videoDevices[idx]
            } else {
                selectedDevice = videoDevices.first(where: { $0.localizedName.localizedCaseInsensitiveContains(req) || $0.uniqueID == req })
            }
        }
        
        let device = selectedDevice ?? videoDevices.first ?? AVCaptureDevice.default(for: .video)
        guard let dev = device else {
            logMsg("ERROR - No video camera found.")
            return
        }
        logMsg("Using video device: \(dev.localizedName)")
        
        do {
            let input = try AVCaptureDeviceInput(device: dev)
            if session.canAddInput(input) {
                session.addInput(input)
                logMsg("Input added successfully.")
            }
        } catch {
            logMsg("ERROR initializing camera input: \(error)")
            return
        }
        
        let lightMode = (filterMode == "raw" || filterMode == "chroma")
        let want4K = (captureQuality == "4k")
                  || (captureQuality == "auto" && currentSize >= 720 && lightMode)
        if want4K && session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
            logMsg("Camera session preset set to 4K UHD (3840x2160) — big-window sharpness")
        } else if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
            logMsg("Camera session preset set to 1080p Full HD (1920x1080)")
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
            logMsg("Camera session preset set to High")
        }
        
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        
        let queue = DispatchQueue(label: "camera.processing.queue", qos: .userInteractive)
        self.sampleQueue = queue
        output.setSampleBufferDelegate(self, queue: queue)
        
        if session.canAddOutput(output) {
            session.addOutput(output)
            logMsg("Output added successfully.")
        }
        
        self.videoOutput = output
        self.captureSession = session
        
        DispatchQueue.global(qos: .userInitiated).async {
            logMsg("Starting session.startRunning()...")
            session.startRunning()
            logMsg("session.startRunning() finished. Is running: \(session.isRunning)")
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCount += 1
        if frameCount % 30 == 0 {
            logMsg("Frame received #\(frameCount)")
        }
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let rawCIImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        let rawOriginX = rawCIImage.extent.origin.x
        let rawOriginY = rawCIImage.extent.origin.y
        let baseInputCIImage = rawCIImage
            .transformed(by: CGAffineTransform(translationX: -rawOriginX, y: -rawOriginY))
            .oriented(.upMirrored)
        
        let isClean = (self.filterMode == "cutout" || self.filterMode == "clean")
        
        // Fast-Path: In clean cutout mode, skip heavy 3-pass GPU denoise & blur for 60 FPS native speed
        var denoisedCIImage = baseInputCIImage
        if !isClean {
            if let denoiseFilter = CIFilter(name: "CINoiseReduction") {
                denoiseFilter.setValue(baseInputCIImage, forKey: kCIInputImageKey)
                denoiseFilter.setValue(0.035, forKey: "inputNoiseLevel")
                denoiseFilter.setValue(0.50, forKey: "inputSharpness")
                if let output = denoiseFilter.outputImage {
                    denoisedCIImage = output.cropped(to: baseInputCIImage.extent)
                }
            }
            
            let blurFilter = CIFilter(name: "CIGaussianBlur")
            blurFilter?.setValue(denoisedCIImage, forKey: kCIInputImageKey)
            blurFilter?.setValue(1.2, forKey: kCIInputRadiusKey)
            if let blurredLuma = blurFilter?.outputImage?.cropped(to: baseInputCIImage.extent) {
                let lumaBlend = CIFilter(name: "CIBlendWithLuminosity")
                lumaBlend?.setValue(blurredLuma, forKey: kCIInputImageKey)
                lumaBlend?.setValue(denoisedCIImage, forKey: kCIInputBackgroundImageKey)
                if let output = lumaBlend?.outputImage {
                    denoisedCIImage = output.cropped(to: baseInputCIImage.extent)
                }
            }
        }
        
        // Pure Natural sRGB Luminance Sharpness (Ultra-fast 0.1ms execution)
        let sharpener = CIFilter(name: "CISharpenLuminance")
        sharpener?.setValue(denoisedCIImage, forKey: kCIInputImageKey)
        sharpener?.setValue(0.20, forKey: kCIInputSharpnessKey)
        var inputCIImage = sharpener?.outputImage?.cropped(to: baseInputCIImage.extent) ?? denoisedCIImage
        // RAW/CHROMA: apply the framing crop FIRST, dead-center — the shape
        // masks then build on final geometry and are centered by
        // construction in every framing (no tracking exists in these modes,
        // so nothing can shove the crop around).
        let isSegMode = !(self.filterMode == "raw" || self.filterMode == "off"
                       || self.filterMode == "chroma" || self.filterMode == "keygreen")
        if !isSegMode && (self.framing == "tall" || self.framing == "square") {
            let fext = inputCIImage.extent
            let w = fext.height * (self.framing == "square" ? 1.0 : 0.75)
            let x = fext.midX - w / 2
            let rect = CGRect(x: x, y: fext.minY, width: w, height: fext.height)
            inputCIImage = inputCIImage.cropped(to: rect)
                .transformed(by: CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y))
        }
        var finalImage: CIImage = inputCIImage
        
        // REAL GREEN-SCREEN CHROMA KEY: 'chroma'/'keygreen' previously fell
        // through to the ML cutout (label without implementation). A color
        // cube zeroes alpha on green-dominant pixels — crisper edges and a
        // fraction of the CPU when a physical green screen exists.
        if self.filterMode == "chroma" || self.filterMode == "keygreen" {
            if CamState.chromaCube == nil {
                let size = 32
                var cube = [Float](repeating: 0, count: size * size * size * 4)
                var o = 0
                for b in 0..<size {
                    for g in 0..<size {
                        for r in 0..<size {
                            let rf = Float(r) / Float(size - 1)
                            let gf = Float(g) / Float(size - 1)
                            let bf = Float(b) / Float(size - 1)
                            // green-dominant test with soft falloff
                            let dominance = gf - max(rf, bf)
                            let alpha: Float = dominance > 0.18 ? 0
                                : (dominance > 0.08 ? (0.18 - dominance) / 0.10 : 1)
                            cube[o] = rf * alpha; cube[o+1] = gf * alpha
                            cube[o+2] = bf * alpha; cube[o+3] = alpha
                            o += 4
                        }
                    }
                }
                CamState.chromaCube = cube.withUnsafeBufferPointer { Data(buffer: $0) }
            }
            if let cubeData = CamState.chromaCube,
               let keyer = CIFilter(name: "CIColorCubeWithColorSpace") {
                keyer.setValue(32, forKey: "inputCubeDimension")
                keyer.setValue(cubeData, forKey: "inputCubeData")
                keyer.setValue(CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")
                keyer.setValue(inputCIImage, forKey: kCIInputImageKey)
                if let keyed = keyer.outputImage?.cropped(to: inputCIImage.extent) {
                    finalImage = keyed
                }
            }
        }
        // RAW CAMERA SHAPE VIEW: crisp raw feed clipped to the chosen shape
        else if self.filterMode == "raw" || self.filterMode == "off" {
            let transparentBg = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: inputCIImage.extent)
            let ext = inputCIImage.extent
            let center = CGPoint(x: ext.width / 2.0, y: ext.height / 2.0)
            let side = min(ext.width, ext.height)
            var circleMask: CIImage = inputCIImage

            func roundedMask(_ rect: CGRect, _ radius: CGFloat) -> CIImage? {
                let gen = CIFilter(name: "CIRoundedRectangleGenerator")
                gen?.setValue(rect, forKey: "inputExtent")
                gen?.setValue(radius, forKey: "inputRadius")
                return gen?.outputImage?.cropped(to: ext)
            }

            switch self.rawShape {
            case "squircle":
                let s = side * 0.92
                let rect = CGRect(x: center.x - s/2, y: center.y - s/2, width: s, height: s)
                circleMask = roundedMask(rect, s * 0.28) ?? inputCIImage
            case "portrait":
                let h = ext.height * 0.94, w = min(ext.width * 0.94, h * 0.75)
                let rect = CGRect(x: center.x - w/2, y: center.y - h/2, width: w, height: h)
                circleMask = roundedMask(rect, side * 0.10) ?? inputCIImage
            case "hex":
                if CamState.hexMask == nil || CamState.hexMaskSize != ext.size {
                    let img = NSImage(size: ext.size)
                    img.lockFocus()
                    NSColor.black.setFill()
                    NSRect(origin: .zero, size: ext.size).fill()
                    let R = side * 0.47
                    let path = NSBezierPath()
                    for i in 0..<6 {
                        let ang = CGFloat(i) * .pi / 3 + .pi / 6
                        let pt = NSPoint(x: center.x + R * cos(ang), y: center.y + R * sin(ang))
                        if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
                    }
                    path.close()
                    NSColor.white.setFill()
                    path.fill()
                    img.unlockFocus()
                    if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        CamState.hexMask = CIImage(cgImage: cg)
                        CamState.hexMaskSize = ext.size
                    }
                }
                circleMask = CamState.hexMask?.cropped(to: ext) ?? inputCIImage
            default: // circle
                let radius = side * 0.46
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                circleMask = roundedMask(rect, radius) ?? inputCIImage
            }
            
            let rawBlend = CIFilter(name: "CIBlendWithMask")
            rawBlend?.setValue(inputCIImage, forKey: kCIInputImageKey)
            rawBlend?.setValue(transparentBg, forKey: kCIInputBackgroundImageKey)
            rawBlend?.setValue(circleMask, forKey: kCIInputMaskImageKey)
            finalImage = rawBlend?.outputImage ?? inputCIImage
        } else {
            // Neural Segmentation Modes: mint, hero, goddess, cyber
            let transparentBg = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: inputCIImage.extent)
            // ADAPTIVE SEGMENTATION CADENCE: when the silhouette is still
            // (talking-head mode — most of any recording), run the ML
            // segmentation + CPU mask passes on every 3rd frame and reuse
            // the cached matte between. Mask staleness is capped at ~0.1s;
            // the raw VIDEO under the matte still refreshes every frame.
            // High motion -> every frame, exactly as before.
            self.segFrameCounter &+= 1
            let runSeg = self.cachedCleanMask == nil
                      || self.currentMotionVelocity > 0.006
                      || (self.segFrameCounter % 3 == 0)
            if runSeg {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .upMirrored, options: [:])
            do {
                try handler.perform([segmentationRequest])
                if let maskBuffer = segmentationRequest.results?.first?.pixelBuffer {
                    let maskRaw = CIImage(cvPixelBuffer: maskBuffer)
                    let maskNorm = maskRaw.transformed(by: CGAffineTransform(translationX: -maskRaw.extent.origin.x, y: -maskRaw.extent.origin.y))
                    
                    let scaleX = inputCIImage.extent.width / maskNorm.extent.width
                    let scaleY = inputCIImage.extent.height / maskNorm.extent.height
                    
                    // 1. 60 FPS Temporal Pixel-Level EMA Smoother & Smoothstep Sigmoidal Filter (Eliminates hand/finger edge flickering)
                    CVPixelBufferLockBaseAddress(maskBuffer, [])
                    let mw = CVPixelBufferGetWidth(maskBuffer)
                    let mh = CVPixelBufferGetHeight(maskBuffer)
                    let bytesPerRow = CVPixelBufferGetBytesPerRow(maskBuffer)
                    let totalPixels = mw * mh
                    if self.prevMaskData == nil || self.prevMaskData?.count != totalPixels {
                        self.prevMaskData = Array(repeating: 0.0, count: totalPixels)
                    }
                    
                    if let baseAddr = CVPixelBufferGetBaseAddress(maskBuffer) {
                        let ptr = baseAddr.assumingMemoryBound(to: UInt8.self)
                        
                        // 1. Pass 1: Extract row-by-row body extremities (head, arms, hands, shoulders, torso)
                        var rowMin = Array(repeating: mw, count: mh)
                        var rowMax = Array(repeating: -1, count: mh)
                        var globalMinY = mh, globalMaxY = 0
                        var totalBodyCount = 0

                        var totalDeltaSum: Float = 0.0
                        let isFastMotion = self.currentMotionVelocity > 0.008
                        for y in 0..<mh {
                            let rowOffset = y * bytesPerRow
                            let flatOffset = y * mw
                            for x in 0..<mw {
                                let rawVal = Float(ptr[rowOffset + x]) / 255.0
                                let prevVal = self.prevMaskData![flatOffset + x]
                                let delta = abs(rawVal - prevVal)
                                totalDeltaSum += delta
                                let blendWeight: Float = (self.currentMotionVelocity > 0.008) ? 0.70 : max(0.12, min(0.50, 0.12 + (delta / 0.15) * 0.38))
                                let smoothedVal = prevVal * (1.0 - blendWeight) + rawVal * blendWeight
                                self.prevMaskData![flatOffset + x] = smoothedVal

                                if smoothedVal >= 0.30 {
                                    if x < rowMin[y] { rowMin[y] = x }
                                    if x > rowMax[y] { rowMax[y] = x }
                                    if y < globalMinY { globalMinY = y }
                                    if y > globalMaxY { globalMaxY = y }
                                    totalBodyCount += 1
                                }
                            }
                        }
                        
                        let frameMotion = totalBodyCount > 0 ? Double(totalDeltaSum / Float(totalBodyCount)) : 0.0
                        self.currentMotionVelocity = self.currentMotionVelocity * 0.65 + frameMotion * 0.35

                        // Tight Anatomic Arm & Body Perimeter Gate (Tight 8px margin completely erases chair & room background)
                        var cleanRowMin = rowMin
                        var cleanRowMax = rowMax
                        let marginPx = 8 // Tight 8px anatomic margin eliminates chair back & room background leakage
                        
                        if totalBodyCount > 40 {
                            let gaussWeights: [Double] = [0.0625, 0.25, 0.375, 0.25, 0.0625]
                            for y in max(0, globalMinY - 4)...min(mh - 1, globalMaxY + 4) {
                                var sumMin: Double = 0.0
                                var sumMax: Double = 0.0
                                var wSum: Double = 0.0
                                for (idx, dy) in [-2, -1, 0, 1, 2].enumerated() {
                                    let ny = max(0, min(mh - 1, y + dy))
                                    if rowMin[ny] < mw && rowMax[ny] >= 0 {
                                        let w = gaussWeights[idx]
                                        sumMin += Double(rowMin[ny]) * w
                                        sumMax += Double(rowMax[ny]) * w
                                        wSum += w
                                    }
                                }
                                if wSum > 0 {
                                    let cMinVal = Int(round(sumMin / wSum))
                                    let cMaxVal = Int(round(sumMax / wSum))
                                    // Directional Motion Lead-in: expand perimeter ONLY in the direction of motion so head never clips!
                                    cleanRowMin[y] = max(0, cMinVal - marginPx - (isFastMotion ? 8 : 0))
                                    cleanRowMax[y] = min(mw - 1, cMaxVal + marginPx + (isFastMotion ? 8 : 0))
                                }
                            }
                        }

                        // 60 FPS Motion-Predictive Dynamic Row Tracking (Directional lead-in eliminates motion lag!)
                        if self.prevRowMinData == nil || self.prevRowMinData?.count != mh {
                            self.prevRowMinData = cleanRowMin
                            self.prevRowMaxData = cleanRowMax
                        } else {
                            let alphaPrev = isFastMotion ? 0.20 : 0.45
                            let alphaNew = 1.0 - alphaPrev
                            for y in 0..<mh {
                                let pMin = Double(self.prevRowMinData![y])
                                let pMax = Double(self.prevRowMaxData![y])
                                let cMin = Double(cleanRowMin[y])
                                let cMax = Double(cleanRowMax[y])
                                
                                let smMin = Int(round(pMin * alphaPrev + cMin * alphaNew))
                                let smMax = Int(round(pMax * alphaPrev + cMax * alphaNew))
                                
                                self.prevRowMinData![y] = smMin
                                self.prevRowMaxData![y] = smMax
                                cleanRowMin[y] = smMin
                                cleanRowMax[y] = smMax
                            }
                        }

                        // 2. Pass 2: ANATOMIC PERIMETER GATE WITH LOW-LIGHT NOISE FLOOR (ERASES CHAIR & ROOM NOISE)
                        for y in 0..<mh {
                            let rowOffset = y * bytesPerRow
                            let flatOffset = y * mw
                            let isBodyRow = (y >= max(0, globalMinY - 4) && y <= min(mh - 1, globalMaxY + 4))
                            let minAllowedX = cleanRowMin[y]
                            let maxAllowedX = cleanRowMax[y]

                            for x in 0..<mw {
                                var finalByte: UInt8 = 0
                                if isBodyRow && x >= minAllowedX && x <= maxAllowedX {
                                    let smoothedVal = self.prevMaskData![flatOffset + x]
                                    // Proven Low-Light Dark Room Noise Gate (0.32 floor completely zeroes chair back & room noise)
                                    if smoothedVal >= 0.32 {
                                        if smoothedVal >= 0.78 {
                                            finalByte = 255
                                        } else {
                                            let t = (smoothedVal - 0.32) / (0.78 - 0.32)
                                            let smoothstep = t * t * (3.0 - 2.0 * t) // Cubic Hermite Sigmoid
                                            finalByte = UInt8(clamping: Int(smoothstep * 255.0))
                                        }
                                    }
                                }
                                ptr[rowOffset + x] = finalByte
                            }
                        }
                        if totalBodyCount > 40 {
                            let padX = Int(Double(mw) * 0.16)
                            let padY = Int(Double(mh) * 0.16)
                            let nMinX = CGFloat(max(0, cleanRowMin.min() ?? 0 - padX)) / CGFloat(mw)
                            let nMaxX = CGFloat(min(mw, cleanRowMax.max() ?? mw + padX)) / CGFloat(mw)
                            let nMinY = CGFloat(max(0, globalMinY - padY)) / CGFloat(mh)
                            let nMaxY = CGFloat(min(mh, globalMaxY + padY)) / CGFloat(mh)
                            let targetRect = CGRect(x: nMinX, y: nMinY, width: nMaxX - nMinX, height: nMaxY - nMinY)
                            if let prev = self.trackedBodyRect {
                                let boxAlphaPrev = isFastMotion ? 0.15 : 0.35
                                let boxAlphaNew = 1.0 - boxAlphaPrev
                                let smX = prev.origin.x * boxAlphaPrev + targetRect.origin.x * boxAlphaNew
                                let smY = prev.origin.y * boxAlphaPrev + targetRect.origin.y * boxAlphaNew
                                let smW = prev.size.width * boxAlphaPrev + targetRect.size.width * boxAlphaNew
                                let smH = prev.size.height * boxAlphaPrev + targetRect.size.height * boxAlphaNew
                                self.trackedBodyRect = CGRect(x: smX, y: smY, width: smW, height: smH)
                            } else {
                                self.trackedBodyRect = targetRect
                            }
                        }
                    }
                    CVPixelBufferUnlockBaseAddress(maskBuffer, [])

                    // Re-create CIImage from the SMOOTHED, NOISE-ERASED CVPixelBuffer bytes!
                    let smoothedMaskRaw = CIImage(cvPixelBuffer: maskBuffer)
                    let smoothedMaskNorm = smoothedMaskRaw.transformed(by: CGAffineTransform(translationX: -smoothedMaskRaw.extent.origin.x, y: -smoothedMaskRaw.extent.origin.y))
                    let cleanScaledMask = smoothedMaskNorm.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)).cropped(to: inputCIImage.extent)

                    // HIGH-DEFINITION LUMA-GUIDED HAIR MATTING ENGINE (CIGuidedFilter)
                    // Uses the 1080p/4K camera luma guide to snap the neural mask directly to fine hair strands, stopping light drift!
                    var hairRefinedMask = cleanScaledMask
                    if let guidedFilter = CIFilter(name: "CIGuidedFilter") {
                        guidedFilter.setValue(smoothedMaskNorm, forKey: "inputImage")
                        guidedFilter.setValue(inputCIImage, forKey: "inputGuideImage")
                        guidedFilter.setValue(2, forKey: "inputRadius")
                        guidedFilter.setValue(0.0001, forKey: "inputEpsilon")
                        if let output = guidedFilter.outputImage {
                            hairRefinedMask = output.cropped(to: inputCIImage.extent)
                        }
                    }

                    // GPU Sub-Pixel Vector Anti-Aliasing (Wipes any pixelation from hair edges)
                    var rawCleanMask = hairRefinedMask
                    if let antiAliasFilter = CIFilter(name: "CIGaussianBlur") {
                        antiAliasFilter.setValue(hairRefinedMask, forKey: kCIInputImageKey)
                        antiAliasFilter.setValue(0.8, forKey: kCIInputRadiusKey)
                        if let output = antiAliasFilter.outputImage {
                            rawCleanMask = output.cropped(to: inputCIImage.extent)
                        }
                    }

                    // 2. HARD SPATIAL ERASURE: Erase ALL pixels outside the Dynamic Humanoid Movement Envelope
                    var cleanMask = rawCleanMask
                    if let bRect = self.trackedBodyRect {
                        let imgW = inputCIImage.extent.width
                        let imgH = inputCIImage.extent.height
                        let cropX = bRect.origin.x * imgW
                        let cropY = (1.0 - bRect.origin.y - bRect.size.height) * imgH // Flips Y for CIImage bottom-left origin
                        let cropW = bRect.size.width * imgW
                        let cropH = bRect.size.height * imgH
                        let envelopeExtent = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
                        
                        let envelopeBox = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: envelopeExtent)
                        let spatialMask = envelopeBox.composited(over: transparentBg).cropped(to: inputCIImage.extent)
                        
                        let multiplyFilter = CIFilter(name: "CIMultiplyCompositing")
                        multiplyFilter?.setValue(rawCleanMask, forKey: kCIInputImageKey)
                        multiplyFilter?.setValue(spatialMask, forKey: kCIInputBackgroundImageKey)
                        cleanMask = multiplyFilter?.outputImage?.cropped(to: inputCIImage.extent) ?? rawCleanMask
                    }
                    self.cachedCleanMask = cleanMask
                }
            } catch {
                logMsg("Segmentation error: \(error)")
            }
            }
            // PHASE 2 — compositing runs EVERY frame (all GPU) from the
            // freshest matte, so the live video never freezes even when
            // segmentation is coasting on the cache.
            if let cleanMask = self.cachedCleanMask {
                let cleanLook = (self.filterMode == "cutout" || self.filterMode == "clean")
                var stagedFinal: CIImage = finalImage
                
                if cleanLook {
                    // FAST-PATH: Photo Booth Zero-Latency Cutout Engine (1 Single Filter on Metal GPU)
                    let cutoutFilter = CIFilter(name: "CIBlendWithMask")
                    cutoutFilter?.setValue(inputCIImage, forKey: kCIInputImageKey)
                    cutoutFilter?.setValue(transparentBg, forKey: kCIInputBackgroundImageKey)
                    cutoutFilter?.setValue(cleanMask, forKey: kCIInputMaskImageKey)
                    stagedFinal = cutoutFilter?.outputImage?.cropped(to: inputCIImage.extent) ?? inputCIImage
                } else {
                    // Dynamic Humanoid Contour Outline (Dilate - Erode Difference)
                    let maxFilter = CIFilter(name: "CIMorphologyMaximum")
                    maxFilter?.setValue(cleanMask, forKey: kCIInputImageKey)
                    maxFilter?.setValue(2, forKey: kCIInputRadiusKey)
                    let dilatedMask = maxFilter?.outputImage?.cropped(to: inputCIImage.extent) ?? cleanMask

                    let minFilter = CIFilter(name: "CIMorphologyMinimum")
                    minFilter?.setValue(cleanMask, forKey: kCIInputImageKey)
                    minFilter?.setValue(1, forKey: kCIInputRadiusKey)
                    let erodedMask = minFilter?.outputImage?.cropped(to: inputCIImage.extent) ?? cleanMask

                    let subtractFilter = CIFilter(name: "CISubtractBlendMode")
                    subtractFilter?.setValue(dilatedMask, forKey: kCIInputImageKey)
                    subtractFilter?.setValue(erodedMask, forKey: kCIInputBackgroundImageKey)
                    let rawOutlineStroke = subtractFilter?.outputImage?.cropped(to: inputCIImage.extent) ?? cleanMask

                    // High-Quality Studio Anti-Aliased Contour Stroke Filter (Silky smooth broadcast finish)
                    let antiAliasFilter = CIFilter(name: "CIGaussianBlur")
                    antiAliasFilter?.setValue(rawOutlineStroke, forKey: kCIInputImageKey)
                    antiAliasFilter?.setValue(1.0, forKey: kCIInputRadiusKey)
                    let outlineStrokeMask = antiAliasFilter?.outputImage?.cropped(to: inputCIImage.extent) ?? rawOutlineStroke

                    // Select Color Preset Based on Mode
                    var outlineCIColor = CIColor(red: 0.45, green: 0.97, blue: 0.72, alpha: 0.35) // Chilled Mint Accent
                    if self.filterMode == "hero" || self.filterMode == "male" {
                        outlineCIColor = CIColor(red: 0.30, green: 0.75, blue: 1.0, alpha: 0.35) // Chilled Slate Hero
                    } else if self.filterMode == "goddess" || self.filterMode == "fem" {
                        outlineCIColor = CIColor(red: 1.0, green: 0.82, blue: 0.88, alpha: 0.35) // Chilled Champagne Rose
                    } else if self.filterMode == "cyber" || self.filterMode == "neon" {
                        outlineCIColor = CIColor(red: 0.0, green: 1.0, blue: 0.95, alpha: 0.40) // Chilled Cyan
                    }
                    
                    let outlineColor = CIImage(color: outlineCIColor).cropped(to: inputCIImage.extent)

                    let outlineImage = CIFilter(name: "CIBlendWithMask")
                    outlineImage?.setValue(outlineColor, forKey: kCIInputImageKey)
                    outlineImage?.setValue(transparentBg, forKey: kCIInputBackgroundImageKey)
                    outlineImage?.setValue(outlineStrokeMask, forKey: kCIInputMaskImageKey)

                    // 1. Noise-Absorbing Soft Studio Shadow Cushion (Absorbs edge chatter & black flickering!)
                    let shadowMaxFilter = CIFilter(name: "CIMorphologyMaximum")
                    shadowMaxFilter?.setValue(cleanMask, forKey: kCIInputImageKey)
                    shadowMaxFilter?.setValue(8, forKey: kCIInputRadiusKey)
                    let shadowBaseMask = shadowMaxFilter?.outputImage?.cropped(to: inputCIImage.extent) ?? cleanMask

                    let shadowBlur = CIFilter(name: "CIGaussianBlur")
                    shadowBlur?.setValue(shadowBaseMask, forKey: kCIInputImageKey)
                    shadowBlur?.setValue(10.0, forKey: kCIInputRadiusKey)
                    let softShadowMask = shadowBlur?.outputImage?.cropped(to: inputCIImage.extent) ?? shadowBaseMask

                    let darkShadowColor = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45)).cropped(to: inputCIImage.extent)
                    let shadowImage = CIFilter(name: "CIBlendWithMask")
                    shadowImage?.setValue(darkShadowColor, forKey: kCIInputImageKey)
                    shadowImage?.setValue(transparentBg, forKey: kCIInputBackgroundImageKey)
                    shadowImage?.setValue(softShadowMask, forKey: kCIInputMaskImageKey)

                    // Subtle Chilled Studio Aura Engine (Ultra-Soft, Whisper-Thin)
                    let motionScale = min(1.0, max(0.0, (self.currentMotionVelocity - 0.005) / 0.025))
                    
                    // 1. Silky 20px Feathered Ambient Radiance
                    let auraMax = CIFilter(name: "CIMorphologyMaximum")
                    auraMax?.setValue(cleanMask, forKey: kCIInputImageKey)
                    auraMax?.setValue(Int(8 + motionScale * 6), forKey: kCIInputRadiusKey)
                    let auraExpanded = auraMax?.outputImage?.cropped(to: inputCIImage.extent) ?? cleanMask

                    let auraBlur = CIFilter(name: "CIGaussianBlur")
                    auraBlur?.setValue(auraExpanded, forKey: kCIInputImageKey)
                    auraBlur?.setValue(18.0 + motionScale * 6.0, forKey: kCIInputRadiusKey)
                    let softHighClassMask = auraBlur?.outputImage?.cropped(to: inputCIImage.extent) ?? auraExpanded

                    // Chilled High-Class Palette
                    var auraR: CGFloat = 0.45, auraG: CGFloat = 0.95, auraB: CGFloat = 0.80
                    if self.filterMode == "hero" || self.filterMode == "male" {
                        auraR = 0.35; auraG = 0.70; auraB = 0.95
                    } else if self.filterMode == "goddess" || self.filterMode == "fem" {
                        auraR = 0.98; auraG = 0.88; auraB = 0.76
                    } else if self.filterMode == "cyber" || self.filterMode == "neon" {
                        auraR = 0.20; auraG = 0.90; auraB = 0.90
                    }

                    // Chilled Opacity (0.04 when still -> 0.08 when gesturing)
                    let highClassAlpha = 0.04 + motionScale * 0.04
                    
                    let auraCIColor = CIColor(red: auraR, green: auraG, blue: auraB, alpha: CGFloat(highClassAlpha))
                    let auraColorImg = CIImage(color: auraCIColor).cropped(to: inputCIImage.extent)

                    let auraImage = CIFilter(name: "CIBlendWithMask")
                    auraImage?.setValue(auraColorImg, forKey: kCIInputImageKey)
                    auraImage?.setValue(transparentBg, forKey: kCIInputBackgroundImageKey)
                    auraImage?.setValue(softHighClassMask, forKey: kCIInputMaskImageKey)

                    // Composite Subtle High-Class Aura OVER Studio Drop-Shadow
                    let auraWithShadow = CIFilter(name: "CISourceOverCompositing")
                    auraWithShadow?.setValue(auraImage?.outputImage, forKey: kCIInputImageKey)
                    auraWithShadow?.setValue(shadowImage?.outputImage, forKey: kCIInputBackgroundImageKey)

                    // MATTE REFINEMENT: erode 1px then feather 0.8px — pulls the
                    // matte just inside the true silhouette so no background
                    // fringe halos around hair/fingers (the "sticker" tell).
                    // Only the SUBJECT matte: outline/shadow/aura keep the
                    // crisp geometry mask above.
                    let matteErode = CIFilter(name: "CIMorphologyMinimum")
                    matteErode?.setValue(cleanMask, forKey: kCIInputImageKey)
                    matteErode?.setValue(1, forKey: kCIInputRadiusKey)
                    let matteEroded = matteErode?.outputImage?.cropped(to: inputCIImage.extent) ?? cleanMask
                    let matteFeather = CIFilter(name: "CIGaussianBlur")
                    matteFeather?.setValue(matteEroded, forKey: kCIInputImageKey)
                    matteFeather?.setValue(0.8, forKey: kCIInputRadiusKey)
                    let subjectMatte = matteFeather?.outputImage?.cropped(to: inputCIImage.extent) ?? matteEroded

                    // 100% Baseline Subject Cutout (Zero color or light modifications)
                    let cutoutFilter = CIFilter(name: "CIBlendWithMask")
                    cutoutFilter?.setValue(inputCIImage, forKey: kCIInputImageKey)
                    cutoutFilter?.setValue(transparentBg, forKey: kCIInputBackgroundImageKey)
                    cutoutFilter?.setValue(subjectMatte, forKey: kCIInputMaskImageKey)
                    let subjectCutout = cutoutFilter?.outputImage ?? inputCIImage

                    // Composite Subject Cutout OVER Aura + Shadow
                    let subjectWithAura = CIFilter(name: "CISourceOverCompositing")
                    subjectWithAura?.setValue(subjectCutout, forKey: kCIInputImageKey)
                    subjectWithAura?.setValue(auraWithShadow?.outputImage, forKey: kCIInputBackgroundImageKey)

                    // Composite Dynamic Humanoid Outline OVER Subject + Aura + Shadow
                    let overFilter = CIFilter(name: "CISourceOverCompositing")
                    overFilter?.setValue(outlineImage?.outputImage, forKey: kCIInputImageKey)
                    overFilter?.setValue(subjectWithAura?.outputImage, forKey: kCIInputBackgroundImageKey)

                    // ABSOLUTE 100.00% OUTER SAFETY GUARD: Mask final render by softShadowMask so NOTHING outside shadow bounds can ever render!
                    let finalSafetyGuard = CIFilter(name: "CIBlendWithMask")
                    finalSafetyGuard?.setValue(overFilter?.outputImage, forKey: kCIInputImageKey)
                    finalSafetyGuard?.setValue(transparentBg, forKey: kCIInputBackgroundImageKey)
                    finalSafetyGuard?.setValue(softShadowMask, forKey: kCIInputMaskImageKey)

                    stagedFinal = finalSafetyGuard?.outputImage ?? finalImage
                }

                    // BUST MODE: when the presenter window floats mid-page
                    // (not hugging the screen bottom), the hard crop line
                    // looks wrong — dissolve the lower body smoothly like a
                    // bust emerging from the page, and set a soft glowing
                    // pedestal ellipse (mode color) underneath. Docked at
                    // the bottom edge -> classic hard cut, untouched.
                    // window-bottom RELATIVE TO ITS SCREEN — global AppKit
                    // coords never tripped the threshold on multi-monitor rigs
                    var winBottomY: CGFloat = 0
                    if let w = self.window {
                        let scrY = (w.screen ?? NSScreen.main)?.frame.origin.y ?? 0
                        winBottomY = w.frame.origin.y - scrY
                    }
                    if winBottomY > 80, let bRect = self.trackedBodyRect {
                        // BUST DISSOLVE, anchored to the PERSON: an elliptical
                        // soft mask centered on the tracked body box, so the
                        // fade hugs the torso in a rounded bust curve instead
                        // of slicing a flat band across the frame. Everything
                        // above the chest stays fully opaque.
                        let ext = inputCIImage.extent
                        let px = bRect.origin.x * ext.width
                        let pw = bRect.size.width * ext.width
                        let py = (1.0 - bRect.origin.y - bRect.size.height) * ext.height
                        let ph = bRect.size.height * ext.height
                        let cx = px + pw / 2
                        let chestY = py + ph * 0.34         // dissolve line ≈ lower chest
                        let squash: CGFloat = 0.62

                        var bustMask: CIImage? = nil
                        if let radial = CIFilter(name: "CIRadialGradient") {
                            radial.setValue(CIVector(x: cx, y: chestY / squash), forKey: "inputCenter")
                            radial.setValue(max(40, pw * 0.42), forKey: "inputRadius0")
                            radial.setValue(max(80, pw * 0.85), forKey: "inputRadius1")
                            radial.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor0")
                            radial.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 0), forKey: "inputColor1")
                            bustMask = radial.outputImage?
                                .transformed(by: CGAffineTransform(scaleX: 1.0, y: squash))
                                .cropped(to: ext)
                        }
                        // keep everything ABOVE the chest fully opaque: max the
                        // ellipse with a smooth vertical "opaque-above" gradient
                        if let upper = CIFilter(name: "CISmoothLinearGradient") {
                            upper.setValue(CIVector(x: cx, y: chestY - ph * 0.10), forKey: "inputPoint0")
                            upper.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 0), forKey: "inputColor0")
                            upper.setValue(CIVector(x: cx, y: chestY + ph * 0.08), forKey: "inputPoint1")
                            upper.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor1")
                            if let up = upper.outputImage?.cropped(to: ext), let bm = bustMask {
                                let mx = CIFilter(name: "CIMaximumCompositing")
                                mx?.setValue(up, forKey: kCIInputImageKey)
                                mx?.setValue(bm, forKey: kCIInputBackgroundImageKey)
                                bustMask = mx?.outputImage?.cropped(to: ext) ?? bm
                            }
                        }
                        if let bm = bustMask {
                            let bustBlend = CIFilter(name: "CIBlendWithMask")
                            bustBlend?.setValue(stagedFinal, forKey: kCIInputImageKey)
                            bustBlend?.setValue(transparentBg, forKey: kCIInputBackgroundImageKey)
                            bustBlend?.setValue(bm, forKey: kCIInputMaskImageKey)
                            if let faded = bustBlend?.outputImage {
                                stagedFinal = faded
                            }
                        }
                    }
                    finalImage = stagedFinal
            }
        }
        
        // TALL FRAMING: center-crop the 16:9 feed to portrait and FOLLOW the
        // person horizontally (smoothed) — full sensor height on screen, and
        // the subject can roam the camera's whole field of view while the
        // crop keeps them centered. Pure crop: zero distortion.
        if isSegMode && (self.framing == "tall" || self.framing == "square") {
            let fext = inputCIImage.extent
            var cx = fext.midX
            if self.followEnabled, let b = self.trackedBodyRect, b.size.width > 0 {
                // DEADZONE FOLLOW: constant bbox-chasing 'pushed me all
                // around'. Now the crop holds perfectly still until the
                // person strays >12% off-center, then glides gently.
                let target = (b.origin.x + b.size.width / 2) * fext.width
                if self.followX == 0 { self.followX = target }
                if abs(target - self.followX) > fext.width * 0.12 {
                    self.followX = self.followX * 0.97 + target * 0.03
                }
                cx = self.followX
            } else {
                self.followX = 0
            }
            // square = full sensor height at 1:1 (max width that keeps it);
            // tall = tighter 3:4 portrait
            let w = fext.height * (self.framing == "square" ? 1.0 : 0.75)
            let x = max(fext.minX, min(fext.maxX - w, cx - w / 2))
            let rect = CGRect(x: x, y: fext.minY, width: w, height: fext.height)
            finalImage = finalImage.cropped(to: rect)
                .transformed(by: CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y))
        }

        guard let context = self.ciContext,
              let window = self.window else { return }
        
        let containerBounds = window.contentView?.bounds ?? CGRect(x: 0, y: 0, width: 476, height: 323)
        let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0
        let renderWidth = containerBounds.width * scaleFactor
        let renderHeight = containerBounds.height * scaleFactor
        
        // Broadcast 1080p Sharpness Filter (Restores crisp facial, hair, and clothing detail)
        var sharpenedFinal = finalImage
        if let sharpenFilter = CIFilter(name: "CISharpenLuminance") {
            sharpenFilter.setValue(finalImage, forKey: kCIInputImageKey)
            sharpenFilter.setValue(0.35, forKey: "inputSharpness")
            if let output = sharpenFilter.outputImage {
                sharpenedFinal = output.cropped(to: finalImage.extent)
            }
        }

        let originX = sharpenedFinal.extent.origin.x
        let originY = sharpenedFinal.extent.origin.y
        let normalizedImage = sharpenedFinal.transformed(by: CGAffineTransform(translationX: -originX, y: -originY))
        
        let scale = min(renderWidth / normalizedImage.extent.width, renderHeight / normalizedImage.extent.height)
        let scaledImage = normalizedImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        let offsetX = (renderWidth - (normalizedImage.extent.width * scale)) / 2.0
        let offsetY = (renderHeight - (normalizedImage.extent.height * scale)) / 2.0
        let centeredFinal = scaledImage.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
        
        let renderRect = CGRect(x: 0, y: 0, width: renderWidth, height: renderHeight)
        let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        
        if let cgImage = context.createCGImage(centeredFinal, from: renderRect, format: .RGBA8, colorSpace: srgbSpace) {
            DispatchQueue.main.async {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.renderLayer?.contents = cgImage
                CATransaction.commit()
            }
        }
    }
    
    func closeWebcam() {
        captureSession?.stopRunning()
        window?.close()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: WebcamWindowController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        var size: CGFloat = 340.0
        var position = "bottom-left"
        var mode = "mint"
        var alienPt: CGPoint? = nil
        var targetPt: CGPoint? = nil
        
        var aX: CGFloat? = nil, aY: CGFloat? = nil
        var tX: CGFloat? = nil, tY: CGFloat? = nil
        
        var devName: String? = nil
        var requestedShape = "circle"
        var requestedFraming = "wide"
        var requestedFollow = false
        var requestedQuality = "auto"
        
        let args = CommandLine.arguments
        for i in 0..<args.count {
            if args[i] == "--list" {
                for (idx, dev) in AVCaptureDevice.devices(for: .video).enumerated() {
                    print("\(idx)\t\(dev.localizedName)")
                }
                exit(0)
            }
            if args[i] == "--size", i + 1 < args.count, let s = Double(args[i+1]) {
                size = CGFloat(s)
            }
            if args[i] == "--position", i + 1 < args.count {
                position = args[i+1]
            }
            if args[i] == "--shape", i + 1 < args.count {
                requestedShape = args[i+1]
            }
            if args[i] == "--framing", i + 1 < args.count {
                requestedFraming = args[i+1]
            }
            if args[i] == "--follow" { requestedFollow = true }
            if args[i] == "--quality", i + 1 < args.count {
                requestedQuality = args[i+1].lowercased()
            }
            if args[i] == "--mode", i + 1 < args.count {
                mode = args[i+1]
            }
            if args[i] == "--device", i + 1 < args.count {
                devName = args[i+1]
            }
            if args[i] == "--alienX", i + 1 < args.count, let v = Double(args[i+1]) { aX = CGFloat(v) }
            if args[i] == "--alienY", i + 1 < args.count, let v = Double(args[i+1]) { aY = CGFloat(v) }
            if args[i] == "--targetX", i + 1 < args.count, let v = Double(args[i+1]) { tX = CGFloat(v) }
            if args[i] == "--targetY", i + 1 < args.count, let v = Double(args[i+1]) { tY = CGFloat(v) }
        }
        
        if let x = aX, let y = aY { alienPt = CGPoint(x: x, y: y) }
        if let x = tX, let y = tY { targetPt = CGPoint(x: x, y: y) }
        
        let wc = WebcamWindowController(size: size, cornerPosition: position, filterMode: mode, alienPoint: alienPt, targetPoint: targetPt, deviceName: devName, shape: requestedShape, framing: requestedFraming, follow: requestedFollow, quality: requestedQuality)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        wc.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.controller = wc
    }
}

// --list runs BEFORE the single-instance guard: it's a query, not an
// instance — it must work even while a presenter window is up (the
// camera cycler depends on it).
if CommandLine.arguments.contains("--list") {
    for (idx, dev) in AVCaptureDevice.devices(for: .video).enumerated() {
        print("\(idx)\t\(dev.localizedName)")
    }
    exit(0)
}

// Single instance enforcement guard (Exact PID filtering)
let myPID = getpid()
let duplicateCount = NSWorkspace.shared.runningApplications.filter { app in
    return app.executableURL?.lastPathComponent == "cam-bin" && app.processIdentifier != myPID
}.count

if duplicateCount > 0 {
    // The launcher killalls the old instance right before spawning us —
    // the corpse can still be in the process table. Wait it out once.
    Thread.sleep(forTimeInterval: 0.6)
    let stillThere = NSWorkspace.shared.runningApplications.filter { app in
        return app.executableURL?.lastPathComponent == "cam-bin" && app.processIdentifier != myPID
    }.count
    if stillThere > 0 {
        logMsg("cam-bin is already running (PID != \(myPID)). Terminating duplicate instance.")
        exit(0)
    }
    logMsg("previous instance finished dying — continuing as the only cam-bin")
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigSource.setEventHandler {
    delegate.controller?.closeWebcam()
    exit(0)
}
sigSource.resume()
signal(SIGINT, SIG_IGN)

let growSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
growSource.setEventHandler { delegate.controller?.adjustSize(by: 90) }
growSource.resume()
signal(SIGUSR1, SIG_IGN)

let shrinkSource = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
shrinkSource.setEventHandler { delegate.controller?.adjustSize(by: -90) }
shrinkSource.resume()
signal(SIGUSR2, SIG_IGN)

let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler {
    delegate.controller?.closeWebcam()
    exit(0)
}
termSource.resume()
signal(SIGTERM, SIG_IGN)

app.run()
