import Cocoa
import AVFoundation
import Vision
import CoreImage
import Metal
import QuartzCore

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
    
    var filterMode: String = "mint"
    let sizePresets: [CGFloat] = [260.0, 380.0, 520.0, 720.0]
    var currentPresetIndex: Int = 0
    
    var alienStartPoint: CGPoint? = nil
    var targetWindowRect: NSRect? = nil
    
    var deviceParam: String? = nil
    var prevRowMinData: [Int]? = nil
    var prevRowMaxData: [Int]? = nil
    var currentMotionVelocity: Double = 0.0
    
    init(size: CGFloat = 340.0, cornerPosition: String = "bottom-left", filterMode: String = "mint", alienPoint: CGPoint? = nil, targetPoint: CGPoint? = nil, deviceName: String? = nil) {
        self.currentSize = size
        self.filterMode = filterMode
        self.alienStartPoint = alienPoint
        self.deviceParam = deviceName
        
        let primaryScreen = NSScreen.screens.first ?? NSScreen.main
        let screen = primaryScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let margin: CGFloat = 35.0
        
        let width = size * 1.4
        let height = size * 0.95
        
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
        let maxSize: CGFloat = 900.0
        let newSize = max(minSize, min(maxSize, currentSize + delta))
        if newSize != currentSize {
            setSize(newSize)
        }
    }
    
    private func setSize(_ newSize: CGFloat) {
        guard let window = self.window, let contentView = window.contentView else { return }
        currentSize = newSize
        let frame = window.frame
        let newWidth = newSize * 1.4
        let newHeight = newSize * 0.95
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
        
        if session.canSetSessionPreset(.hd1920x1080) {
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
        
        let now = CACurrentMediaTime()
        if now - lastRenderTime < 0.030 {
            return
        }
        lastRenderTime = now
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let rawCIImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        let rawOriginX = rawCIImage.extent.origin.x
        let rawOriginY = rawCIImage.extent.origin.y
        let baseInputCIImage = rawCIImage
            .transformed(by: CGAffineTransform(translationX: -rawOriginX, y: -rawOriginY))
            .oriented(.upMirrored)
        
        // Multi-Pass GPU Bilateral Luminance Denoise Engine (Wipes 100% of ISO hardware camera grain & snow!)
        var denoisedCIImage = baseInputCIImage
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
        
        let inputCIImage = denoisedCIImage
        var finalImage: CIImage = inputCIImage
        
        // RAW CAMERA CIRCLE VIEW: If mode is "raw" or "off", render 100% crisp raw camera feed in a floating circle window at 60 FPS!
        if self.filterMode == "raw" || self.filterMode == "off" {
            let transparentBg = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: inputCIImage.extent)
            let radius = min(inputCIImage.extent.width, inputCIImage.extent.height) * 0.46
            let center = CGPoint(x: inputCIImage.extent.width / 2.0, y: inputCIImage.extent.height / 2.0)
            let circleRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2.0, height: radius * 2.0)
            
            let circleGen = CIFilter(name: "CIRoundedRectangleGenerator")
            circleGen?.setValue(circleRect, forKey: "inputExtent")
            circleGen?.setValue(radius, forKey: "inputRadius")
            let circleMask = circleGen?.outputImage?.cropped(to: inputCIImage.extent) ?? inputCIImage
            
            let rawBlend = CIFilter(name: "CIBlendWithMask")
            rawBlend?.setValue(inputCIImage, forKey: kCIInputImageKey)
            rawBlend?.setValue(transparentBg, forKey: kCIInputBackgroundImageKey)
            rawBlend?.setValue(circleMask, forKey: kCIInputMaskImageKey)
            finalImage = rawBlend?.outputImage ?? inputCIImage
        } else {
            // Neural Segmentation Modes: mint, hero, goddess, cyber
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
                        for y in 0..<mh {
                            let rowOffset = y * bytesPerRow
                            let flatOffset = y * mw
                            for x in 0..<mw {
                                let rawVal = Float(ptr[rowOffset + x]) / 255.0
                                let prevVal = self.prevMaskData![flatOffset + x]
                                let delta = abs(rawVal - prevVal)
                                totalDeltaSum += delta
                                let blendWeight: Float = max(0.06, min(0.60, 0.06 + (delta / 0.18) * 0.54))
                                let smoothedVal = prevVal * (1.0 - blendWeight) + rawVal * blendWeight
                                self.prevMaskData![flatOffset + x] = smoothedVal

                                if smoothedVal >= 0.18 {
                                    if x < rowMin[y] { rowMin[y] = x }
                                    if x > rowMax[y] { rowMax[y] = x }
                                    if y < globalMinY { globalMinY = y }
                                    if y > globalMaxY { globalMaxY = y }
                                    totalBodyCount += 1
                                }
                            }
                        }
                        
                        let frameMotion = totalBodyCount > 0 ? Double(totalDeltaSum / Float(totalBodyCount)) : 0.0
                        self.currentMotionVelocity = self.currentMotionVelocity * 0.70 + frameMotion * 0.30

                        // Smooth row extremities vertically (3-row rolling envelope margin)
                        var cleanRowMin = rowMin
                        var cleanRowMax = rowMax
                        let marginPx = 8 // 8px tight safety margin around arms & body
                        
                        if totalBodyCount > 40 {
                            for y in max(0, globalMinY - 4)...min(mh - 1, globalMaxY + 4) {
                                var rMin = mw, rMax = -1
                                for dy in -3...3 {
                                    let ny = max(0, min(mh - 1, y + dy))
                                    if rowMin[ny] < rMin { rMin = rowMin[ny] }
                                    if rowMax[ny] > rMax { rMax = rowMax[ny] }
                                }
                                cleanRowMin[y] = max(0, rMin - marginPx)
                                cleanRowMax[y] = min(mw - 1, rMax + marginPx)
                            }
                        }

                        // 60 FPS Temporal EMA Row-Boundary Smoothing (Eliminates 1-pixel boundary chatter completely!)
                        if self.prevRowMinData == nil || self.prevRowMinData?.count != mh {
                            self.prevRowMinData = cleanRowMin
                            self.prevRowMaxData = cleanRowMax
                        } else {
                            for y in 0..<mh {
                                let pMin = Double(self.prevRowMinData![y])
                                let pMax = Double(self.prevRowMaxData![y])
                                let cMin = Double(cleanRowMin[y])
                                let cMax = Double(cleanRowMax[y])
                                
                                let smMin = Int(round(pMin * 0.70 + cMin * 0.30))
                                let smMax = Int(round(pMax * 0.70 + cMax * 0.30))
                                
                                self.prevRowMinData![y] = smMin
                                self.prevRowMaxData![y] = smMax
                                cleanRowMin[y] = smMin
                                cleanRowMax[y] = smMax
                            }
                        }

                        // 2. Pass 2: HARD ERASE ALL PIXELS OUTSIDE THE ANATOMIC ARM & BODY PERIMETER
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
                                    if smoothedVal >= 0.16 {
                                        if smoothedVal >= 0.68 {
                                            finalByte = 255
                                        } else {
                                            let t = (smoothedVal - 0.16) / (0.68 - 0.16)
                                            let smoothstep = t * t * (3.0 - 2.0 * t) // Cubic Hermite
                                            finalByte = UInt8(clamping: Int(smoothstep * 255.0))
                                        }
                                    }
                                }
                                ptr[rowOffset + x] = finalByte
                            }
                        }
                        if totalBodyCount > 40 {
                            let padX = Int(Double(mw) * 0.12)
                            let padY = Int(Double(mh) * 0.12)
                            let nMinX = CGFloat(max(0, cleanRowMin.min() ?? 0 - padX)) / CGFloat(mw)
                            let nMaxX = CGFloat(min(mw, cleanRowMax.max() ?? mw + padX)) / CGFloat(mw)
                            let nMinY = CGFloat(max(0, globalMinY - padY)) / CGFloat(mh)
                            let nMaxY = CGFloat(min(mh, globalMaxY + padY)) / CGFloat(mh)
                            let targetRect = CGRect(x: nMinX, y: nMinY, width: nMaxX - nMinX, height: nMaxY - nMinY)
                            if let prev = self.trackedBodyRect {
                                let smX = prev.origin.x * 0.50 + targetRect.origin.x * 0.50
                                let smY = prev.origin.y * 0.50 + targetRect.origin.y * 0.50
                                let smW = prev.size.width * 0.50 + targetRect.size.width * 0.50
                                let smH = prev.size.height * 0.50 + targetRect.size.height * 0.50
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

                    // Pure Baseline Noise Gate (-0.02 bias wipes far room noise while leaving 100% natural sRGB colors untouched)
                    let noiseGate = CIFilter(name: "CIColorMatrix")
                    noiseGate?.setValue(cleanScaledMask, forKey: kCIInputImageKey)
                    noiseGate?.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
                    noiseGate?.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
                    noiseGate?.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
                    noiseGate?.setValue(CIVector(x: 0, y: 0, z: 0, w: 1.02), forKey: "inputAVector")
                    noiseGate?.setValue(CIVector(x: 0, y: 0, z: 0, w: -0.02), forKey: "inputBiasVector")
                    let rawCleanMask = noiseGate?.outputImage?.cropped(to: inputCIImage.extent) ?? cleanScaledMask

                    let transparentBg = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: inputCIImage.extent)

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
                    var outlineCIColor = CIColor(red: 0.45, green: 0.97, blue: 0.72, alpha: 0.85) // Mint Default
                    if self.filterMode == "hero" || self.filterMode == "male" {
                        outlineCIColor = CIColor(red: 0.30, green: 0.75, blue: 1.0, alpha: 0.85) // Electric Blue / Slate Hero
                    } else if self.filterMode == "goddess" || self.filterMode == "fem" {
                        outlineCIColor = CIColor(red: 1.0, green: 0.82, blue: 0.88, alpha: 0.85) // Champagne Rose Gold
                    } else if self.filterMode == "cyber" || self.filterMode == "neon" {
                        outlineCIColor = CIColor(red: 0.0, green: 1.0, blue: 0.95, alpha: 0.90) // Electric Cyan
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

                    let darkShadowColor = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.65)).cropped(to: inputCIImage.extent)
                    let shadowImage = CIFilter(name: "CIBlendWithMask")
                    shadowImage?.setValue(darkShadowColor, forKey: kCIInputImageKey)
                    shadowImage?.setValue(transparentBg, forKey: kCIInputBackgroundImageKey)
                    shadowImage?.setValue(softShadowMask, forKey: kCIInputMaskImageKey)

                    // Dual-Ring Harmonic Energy Aura Engine ("Children of the Light" Masterpiece)
                    let motionScale = min(1.0, max(0.0, (self.currentMotionVelocity - 0.005) / 0.025))
                    let time = CACurrentMediaTime()
                    
                    // 1. Inner Neon Core Ring (High Energy)
                    let innerMax = CIFilter(name: "CIMorphologyMaximum")
                    innerMax?.setValue(cleanMask, forKey: kCIInputImageKey)
                    innerMax?.setValue(Int(4 + motionScale * 5), forKey: kCIInputRadiusKey)
                    let innerExpanded = innerMax?.outputImage?.cropped(to: inputCIImage.extent) ?? cleanMask

                    let innerBlur = CIFilter(name: "CIGaussianBlur")
                    innerBlur?.setValue(innerExpanded, forKey: kCIInputImageKey)
                    innerBlur?.setValue(3.5 + motionScale * 3.0, forKey: kCIInputRadiusKey)
                    let innerSoftMask = innerBlur?.outputImage?.cropped(to: inputCIImage.extent) ?? innerExpanded

                    // 2. Outer Soft Ambient Wave Halo (Broad Ethereal Bloom)
                    let outerMax = CIFilter(name: "CIMorphologyMaximum")
                    outerMax?.setValue(cleanMask, forKey: kCIInputImageKey)
                    outerMax?.setValue(Int(10 + motionScale * 8), forKey: kCIInputRadiusKey)
                    let outerExpanded = outerMax?.outputImage?.cropped(to: inputCIImage.extent) ?? cleanMask

                    let outerBlur = CIFilter(name: "CIGaussianBlur")
                    outerBlur?.setValue(outerExpanded, forKey: kCIInputImageKey)
                    outerBlur?.setValue(14.0 + motionScale * 6.0, forKey: kCIInputRadiusKey)
                    let outerSoftMask = outerBlur?.outputImage?.cropped(to: inputCIImage.extent) ?? outerExpanded

                    // Mode-Aware Chromatic Energy Colors
                    var coreR: CGFloat = 0.40, coreG: CGFloat = 0.98, coreB: CGFloat = 0.80 // Mint Core
                    var waveR: CGFloat = 0.20, waveG: CGFloat = 0.70, waveB: CGFloat = 1.00 // Cyan Wave
                    
                    if self.filterMode == "hero" || self.filterMode == "male" {
                        coreR = 0.25; coreG = 0.80; coreB = 1.00 // Electric Blue
                        waveR = 0.50; waveG = 0.30; waveB = 1.00 // Deep Violet
                    } else if self.filterMode == "goddess" || self.filterMode == "fem" {
                        coreR = 1.00; coreG = 0.80; coreB = 0.90 // Rose Gold
                        waveR = 1.00; waveG = 0.50; waveB = 0.75 // Celestial Pink
                    } else if self.filterMode == "cyber" || self.filterMode == "neon" {
                        coreR = 0.00; coreG = 1.00; coreB = 0.95 // Electric Cyan
                        waveR = 1.00; waveG = 0.00; waveB = 0.85 // Hot Magenta
                    }

                    // Dynamic Pulse Phase Modulation
                    let pulse = sin(time * 2.8) * 0.12
                    let coreAlpha = min(0.90, max(0.30, 0.30 + motionScale * 0.60 + pulse))
                    let waveAlpha = min(0.60, max(0.18, 0.18 + motionScale * 0.42 + pulse * 0.5))

                    let innerColor = CIImage(color: CIColor(red: coreR, green: coreG, blue: coreB, alpha: CGFloat(coreAlpha))).cropped(to: inputCIImage.extent)
                    let outerColor = CIImage(color: CIColor(red: waveR, green: waveG, blue: waveB, alpha: CGFloat(waveAlpha))).cropped(to: inputCIImage.extent)

                    let outerAura = CIFilter(name: "CIBlendWithMask")
                    outerAura?.setValue(outerColor, forKey: kCIInputImageKey)
                    outerAura?.setValue(transparentBg, forKey: kCIInputBackgroundImageKey)
                    outerAura?.setValue(outerSoftMask, forKey: kCIInputMaskImageKey)

                    let innerAura = CIFilter(name: "CIBlendWithMask")
                    innerAura?.setValue(innerColor, forKey: kCIInputImageKey)
                    innerAura?.setValue(transparentBg, forKey: kCIInputBackgroundImageKey)
                    innerAura?.setValue(innerSoftMask, forKey: kCIInputMaskImageKey)

                    // Composite Inner Core OVER Outer Halo OVER Studio Drop-Shadow
                    let fullAura = CIFilter(name: "CISourceOverCompositing")
                    fullAura?.setValue(innerAura?.outputImage, forKey: kCIInputImageKey)
                    fullAura?.setValue(outerAura?.outputImage, forKey: kCIInputBackgroundImageKey)

                    let auraWithShadow = CIFilter(name: "CISourceOverCompositing")
                    auraWithShadow?.setValue(fullAura?.outputImage, forKey: kCIInputImageKey)
                    auraWithShadow?.setValue(shadowImage?.outputImage, forKey: kCIInputBackgroundImageKey)

                    // 100% Baseline Subject Cutout (Zero color or light modifications)
                    let cutoutFilter = CIFilter(name: "CIBlendWithMask")
                    cutoutFilter?.setValue(inputCIImage, forKey: kCIInputImageKey)
                    cutoutFilter?.setValue(transparentBg, forKey: kCIInputBackgroundImageKey)
                    cutoutFilter?.setValue(cleanMask, forKey: kCIInputMaskImageKey)
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

                    if let blended = finalSafetyGuard?.outputImage {
                        finalImage = blended
                    }
                }
            } catch {
                logMsg("Segmentation error: \(error)")
            }
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
        
        let args = CommandLine.arguments
        for i in 0..<args.count {
            if args[i] == "--size", i + 1 < args.count, let s = Double(args[i+1]) {
                size = CGFloat(s)
            }
            if args[i] == "--position", i + 1 < args.count {
                position = args[i+1]
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
        
        let wc = WebcamWindowController(size: size, cornerPosition: position, filterMode: mode, alienPoint: alienPt, targetPoint: targetPt, deviceName: devName)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        wc.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.controller = wc
    }
}

// Single instance enforcement guard (Exact PID filtering)
let myPID = getpid()
let duplicateCount = NSWorkspace.shared.runningApplications.filter { app in
    return app.executableURL?.lastPathComponent == "cam-bin" && app.processIdentifier != myPID
}.count

if duplicateCount > 0 {
    logMsg("cam-bin is already running (PID != \(myPID)). Terminating duplicate instance.")
    exit(0)
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

let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler {
    delegate.controller?.closeWebcam()
    exit(0)
}
termSource.resume()
signal(SIGTERM, SIG_IGN)

app.run()
