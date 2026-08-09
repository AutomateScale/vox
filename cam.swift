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
    
    override func scrollWheel(with event: NSEvent) {
        let delta = event.deltaY
        if abs(delta) > 0.1 {
            windowController?.adjustSize(by: delta * 8.0)
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

class WebcamWindowController: NSWindowController, NSWindowDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    var captureSession: AVCaptureSession?
    var videoOutput: AVCaptureVideoDataOutput?
    var renderLayer: CALayer?
    var metalDevice: MTLDevice?
    var ciContext: CIContext?
    
    var currentSize: CGFloat = 260.0
    var lastRenderTime: CFTimeInterval = 0
    var frameCount: Int = 0
    let segmentationRequest = VNGeneratePersonSegmentationRequest()
    
    init(size: CGFloat = 260.0, cornerPosition: String = "bottom-left") {
        self.currentSize = size
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let margin: CGFloat = 25.0
        
        var x: CGFloat = screen.minX + margin
        var y: CGFloat = screen.minY + margin
        
        if cornerPosition.contains("right") {
            x = screen.maxX - size - margin
        }
        if cornerPosition.contains("top") {
            y = screen.maxY - size - margin
        }
        
        let rect = NSRect(x: x, y: y, width: size, height: size * 1.25)
        
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
        setupContentView(width: size, height: size * 1.25)
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
        window.contentView = containerView
    }
    
    func adjustSize(by delta: CGFloat) {
        guard let window = self.window, let contentView = window.contentView else { return }
        let minSize: CGFloat = 140.0
        let maxSize: CGFloat = 850.0
        
        let newSize = max(minSize, min(maxSize, currentSize + delta))
        if newSize == currentSize { return }
        
        currentSize = newSize
        let frame = window.frame
        let newHeight = newSize * 1.25
        let newRect = NSRect(x: frame.minX, y: frame.minY, width: newSize, height: newHeight)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        
        DispatchQueue.main.async {
            window.setFrame(newRect, display: true, animate: false)
            contentView.frame = NSRect(x: 0, y: 0, width: newSize, height: newHeight)
            self.renderLayer?.frame = NSRect(x: 0, y: 0, width: newSize, height: newHeight)
            self.renderLayer?.contentsScale = scale
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
        logMsg("Selected camera device: \(device.localizedName)")
        
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                logMsg("Input added successfully.")
            } else {
                logMsg("ERROR - Cannot add input to session.")
                return
            }
        } catch {
            logMsg("ERROR initializing camera input: \(error)")
            return
        }
        
        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
            logMsg("Preset set to High")
        } else if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
            logMsg("Preset set to Medium")
        }
        
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera.processing.queue", qos: .userInteractive))
        
        if session.canAddOutput(output) {
            session.addOutput(output)
            logMsg("Output added successfully.")
        } else {
            logMsg("ERROR - Cannot add output to session.")
        }
        
        self.videoOutput = output
        self.captureSession = session
        
        DispatchQueue.global(qos: .userInitiated).async {
            logMsg("Calling session.startRunning()...")
            session.startRunning()
            logMsg("session.startRunning() completed. Is running: \(session.isRunning)")
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
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .upMirrored, options: [:])
        do {
            try handler.perform([segmentationRequest])
            if let maskBuffer = segmentationRequest.results?.first?.pixelBuffer {
                let maskRaw = CIImage(cvPixelBuffer: maskBuffer)
                let maskNorm = maskRaw.transformed(by: CGAffineTransform(translationX: -maskRaw.extent.origin.x, y: -maskRaw.extent.origin.y))
                
                let scaleX = inputCIImage.extent.width / maskNorm.extent.width
                let scaleY = inputCIImage.extent.height / maskNorm.extent.height
                let scaledMask = maskNorm.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                
                let transparentBg = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: inputCIImage.extent)
                
                let filter = CIFilter(name: "CIBlendWithMask")
                filter?.setValue(inputCIImage, forKey: kCIInputImageKey)
                filter?.setValue(transparentBg, forKey: kCIInputBackgroundImageKey)
                filter?.setValue(scaledMask, forKey: kCIInputMaskImageKey)
                
                if let blended = filter?.outputImage {
                    finalImage = blended
                }
            }
        } catch {
            logMsg("Segmentation error: \(error)")
        }
        
        guard let context = self.ciContext else { return }
        
        let originX = finalImage.extent.origin.x
        let originY = finalImage.extent.origin.y
        let normalizedImage = finalImage.transformed(by: CGAffineTransform(translationX: -originX, y: -originY))
        
        if let cgImage = context.createCGImage(normalizedImage, from: normalizedImage.extent) {
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
        var size: CGFloat = 260.0
        var position = "bottom-left"
        
        let args = CommandLine.arguments
        for i in 0..<args.count {
            if args[i] == "--size", i + 1 < args.count, let s = Double(args[i+1]) {
                size = CGFloat(s)
            }
            if args[i] == "--position", i + 1 < args.count {
                position = args[i+1]
            }
        }
        
        let wc = WebcamWindowController(size: size, cornerPosition: position)
        wc.showWindow(nil)
        wc.window?.orderFrontRegardless()
        self.controller = wc
    }
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
