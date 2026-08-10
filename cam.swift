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
    let segmentationRequest = VNGeneratePersonSegmentationRequest()
    var trackedBodyRect: CGRect? = nil
    var prevMaskData: [Float]? = nil
    
    var filterMode: String = "mint"
    let sizePresets: [CGFloat] = [260.0, 380.0, 520.0, 720.0]
    var currentPresetIndex: Int = 0
    
    init(size: CGFloat = 340.0, cornerPosition: String = "bottom-left", filterMode: String = "mint") {
        self.currentSize = size
        self.filterMode = filterMode
        let primaryScreen = NSScreen.screens.first ?? NSScreen.main
        let screen = primaryScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let margin: CGFloat = 35.0
        
        let width = size * 1.4
        let height = size * 0.95
        
        var x: CGFloat = screen.minX + margin
        var y: CGFloat = screen.minY + margin
        
        if cornerPosition.contains("right") {
            x = screen.maxX - width - margin
        }
        if cornerPosition.contains("top") {
            y = screen.maxY - height - margin
        }
        
        x = max(screen.minX + margin, min(screen.maxX - width - margin, x))
        y = max(screen.minY + margin, min(screen.maxY - height - margin, y))
        
        let rect = NSRect(x: x, y: y, width: width, height: height)
        logMsg("Creating window at rect: \(rect)")
        
        let window = NSWindow(
            contentRect: rect,
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
        window.orderFrontRegardless()
        
        super.init(window: window)
        window.delegate = self
        
        segmentationRequest.qualityLevel = .balanced
        segmentationRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
        
        setupMetal()
        setupContentView(width: width, height: height)
        setupCamera()
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
    
    private func setupCamera() {
        logMsg("Setting up camera session...")
        let session = AVCaptureSession()
        
        let videoDevices = AVCaptureDevice.devices(for: .video)
        logMsg("Found \(videoDevices.count) video devices:")
        for dev in videoDevices {
            logMsg("  -> Device: \(dev.localizedName) (ID: \(dev.uniqueID))")
        }
        
        guard let device = videoDevices.first ?? AVCaptureDevice.default(for: .video) else {
            logMsg("ERROR - No video camera found.")
            return
        }
        logMsg("Using video device: \(device.localizedName)")
        
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                logMsg("Input added successfully.")
            }
        } catch {
            logMsg("ERROR initializing camera input: \(error)")
            return
        }
        
        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
            logMsg("Preset set to High")
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
        let inputCIImage = rawCIImage
            .transformed(by: CGAffineTransform(translationX: -rawOriginX, y: -rawOriginY))
            .oriented(.upMirrored)
        
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
                    let scaledMask = maskNorm.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)).cropped(to: inputCIImage.extent)
                    
                    // 1. 60 FPS Temporal Pixel-Level EMA Smoother & Smoothstep Sigmoidal Filter (Eliminates hand/finger edge flickering)
                    CVPixelBufferLockBaseAddress(maskBuffer, [])
                    let mw = CVPixelBufferGetWidth(maskBuffer)
                    let mh = CVPixelBufferGetHeight(maskBuffer)
                    let bytesPerRow = CVPixelBufferGetBytesPerRow(maskBuffer)
                    let totalPixels = mw * mh
                    
                    if self.prevMaskData == nil || self.prevMaskData?.count != totalPixels {
                        self.prevMaskData = Array(repeating: 0.0, count: totalPixels)
                    }
                    
                    let isHeroMode = (self.filterMode == "hero" || self.filterMode == "male")
                    
                    if let baseAddr = CVPixelBufferGetBaseAddress(maskBuffer) {
                        let ptr = baseAddr.assumingMemoryBound(to: UInt8.self)
                        var minX = mw, maxX = 0, minY = mh, maxY = 0
                        var bodyPixels = 0
                        
                        for y in 0..<mh {
                            let rowOffset = y * bytesPerRow
                            let flatOffset = y * mw
                            let isShoulderZone = isHeroMode && (Double(y) / Double(mh) >= 0.25 && Double(y) / Double(mh) <= 0.72)
                            
                            for x in 0..<mw {
                                var rawVal = Float(ptr[rowOffset + x]) / 255.0
                                
                                // Hero Male Frame Morphology: Broadens shoulder/trap contour (+10% shoulder highlight)
                                if isShoulderZone && rawVal > 0.15 {
                                    rawVal = min(1.0, rawVal * 1.25)
                                }
                                
                                // 60 FPS Temporal Exponential Moving Average: 70% history + 30% new frame
                                let prevVal = self.prevMaskData![flatOffset + x]
                                let smoothedVal = prevVal * 0.70 + rawVal * 0.30
                                self.prevMaskData![flatOffset + x] = smoothedVal
                                
                                // Hermite Smoothstep Sigmoidal Edge Transition
                                var finalByte: UInt8 = 0
                                if smoothedVal >= 0.10 {
                                    if smoothedVal >= 0.78 {
                                        finalByte = 255
                                    } else {
                                        let t = (smoothedVal - 0.10) / (0.78 - 0.10)
                                        let smoothstep = t * t * (3.0 - 2.0 * t) // Cubic Hermite
                                        finalByte = UInt8(clamping: Int(smoothstep * 255.0))
                                    }
                                }
                                ptr[rowOffset + x] = finalByte
                                
                                if finalByte >= 35 {
                                    if x < minX { minX = x }
                                    if x > maxX { maxX = x }
                                    if y < minY { minY = y }
                                    if y > maxY { maxY = y }
                                    bodyPixels += 1
                                }
                            }
                        }
                        if bodyPixels > 40 {
                            let padX = Int(Double(mw) * 0.16) // 16% anatomical movement margin
                            let padY = Int(Double(mh) * 0.16)
                            let nMinX = CGFloat(max(0, minX - padX)) / CGFloat(mw)
                            let nMaxX = CGFloat(min(mw, maxX + padX)) / CGFloat(mw)
                            let nMinY = CGFloat(max(0, minY - padY)) / CGFloat(mh)
                            let nMaxY = CGFloat(min(mh, maxY + padY)) / CGFloat(mh)
                            let targetRect = CGRect(x: nMinX, y: nMinY, width: nMaxX - nMinX, height: nMaxY - nMinY)
                            if let prev = self.trackedBodyRect {
                                let smX = prev.origin.x * 0.82 + targetRect.origin.x * 0.18
                                let smY = prev.origin.y * 0.82 + targetRect.origin.y * 0.18
                                let smW = prev.size.width * 0.82 + targetRect.size.width * 0.18
                                let smH = prev.size.height * 0.82 + targetRect.size.height * 0.18
                                self.trackedBodyRect = CGRect(x: smX, y: smY, width: smW, height: smH)
                            } else {
                                self.trackedBodyRect = targetRect
                            }
                        }
                    }
                    CVPixelBufferUnlockBaseAddress(maskBuffer, [])

                    // Pure Baseline Noise Gate (-0.02 bias wipes far room noise while leaving 100% natural sRGB colors untouched)
                    let noiseGate = CIFilter(name: "CIColorMatrix")
                    noiseGate?.setValue(scaledMask, forKey: kCIInputImageKey)
                    noiseGate?.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
                    noiseGate?.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
                    noiseGate?.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
                    noiseGate?.setValue(CIVector(x: 0, y: 0, z: 0, w: 1.02), forKey: "inputAVector")
                    noiseGate?.setValue(CIVector(x: 0, y: 0, z: 0, w: -0.02), forKey: "inputBiasVector")
                    let rawCleanMask = noiseGate?.outputImage?.cropped(to: inputCIImage.extent) ?? scaledMask

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
                    maxFilter?.setValue(3, forKey: kCIInputRadiusKey)
                    let dilatedMask = maxFilter?.outputImage?.cropped(to: inputCIImage.extent) ?? cleanMask

                    let minFilter = CIFilter(name: "CIMorphologyMinimum")
                    minFilter?.setValue(cleanMask, forKey: kCIInputImageKey)
                    minFilter?.setValue(1, forKey: kCIInputRadiusKey)
                    let erodedMask = minFilter?.outputImage?.cropped(to: inputCIImage.extent) ?? cleanMask

                    let subtractFilter = CIFilter(name: "CISubtractBlendMode")
                    subtractFilter?.setValue(dilatedMask, forKey: kCIInputImageKey)
                    subtractFilter?.setValue(erodedMask, forKey: kCIInputBackgroundImageKey)
                    let outlineStrokeMask = subtractFilter?.outputImage?.cropped(to: inputCIImage.extent) ?? cleanMask

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

                    // 100% Baseline Subject Cutout (Zero color or light modifications)
                    let cutoutFilter = CIFilter(name: "CIBlendWithMask")
                    cutoutFilter?.setValue(inputCIImage, forKey: kCIInputImageKey)
                    cutoutFilter?.setValue(transparentBg, forKey: kCIInputBackgroundImageKey)
                    cutoutFilter?.setValue(cleanMask, forKey: kCIInputMaskImageKey)
                    let subjectCutout = cutoutFilter?.outputImage ?? inputCIImage

                    // Composite Dynamic Humanoid Outline over Baseline Subject Cutout
                    let overFilter = CIFilter(name: "CISourceOverCompositing")
                    overFilter?.setValue(outlineImage?.outputImage, forKey: kCIInputImageKey)
                    overFilter?.setValue(subjectCutout, forKey: kCIInputBackgroundImageKey)

                    // ABSOLUTE 100.00% OUTER SAFETY GUARD: Mask final render by dilatedMask so NOTHING outside the outline can ever render!
                    let finalSafetyGuard = CIFilter(name: "CIBlendWithMask")
                    finalSafetyGuard?.setValue(overFilter?.outputImage, forKey: kCIInputImageKey)
                    finalSafetyGuard?.setValue(transparentBg, forKey: kCIInputBackgroundImageKey)
                    finalSafetyGuard?.setValue(dilatedMask, forKey: kCIInputMaskImageKey)

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
        
        let originX = finalImage.extent.origin.x
        let originY = finalImage.extent.origin.y
        let normalizedImage = finalImage.transformed(by: CGAffineTransform(translationX: -originX, y: -originY))
        
        let scale = min(renderWidth / normalizedImage.extent.width, renderHeight / normalizedImage.extent.height)
        let scaledImage = normalizedImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        let offsetX = (renderWidth - (normalizedImage.extent.width * scale)) / 2.0
        let offsetY = (renderHeight - (normalizedImage.extent.height * scale)) / 2.0
        let centeredFinal = scaledImage.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
        
        let renderRect = CGRect(x: 0, y: 0, width: renderWidth, height: renderHeight)
        if let cgImage = context.createCGImage(centeredFinal, from: renderRect) {
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
        }
        
        let wc = WebcamWindowController(size: size, cornerPosition: position, filterMode: mode)
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
