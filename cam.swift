import Cocoa
import AVFoundation
import Vision
import CoreImage
import Metal
import QuartzCore

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
    var metalLayer: CAMetalLayer?
    var metalDevice: MTLDevice?
    var commandQueue: MTLCommandQueue?
    var ciContext: CIContext?
    
    var currentSize: CGFloat = 260.0
    var lastRenderTime: CFTimeInterval = 0
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
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        self.metalDevice = device
        self.commandQueue = device.makeCommandQueue()
        self.ciContext = CIContext(mtlDevice: device, options: [
            .cacheIntermediates: false,
            .useSoftwareRenderer: false
        ])
    }
    
    private func setupContentView(width: CGFloat, height: CGFloat) {
        guard let window = self.window else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        
        let containerView = ResizableCutoutView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        containerView.windowController = self
        containerView.wantsLayer = true
        
        let rootLayer = CALayer()
        rootLayer.frame = containerView.bounds
        rootLayer.backgroundColor = NSColor.clear.cgColor
        containerView.layer = rootLayer
        
        let layer = CAMetalLayer()
        layer.device = metalDevice
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.frame = containerView.bounds
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: width * scale, height: height * scale)
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
        layer.backgroundColor = NSColor.clear.cgColor
        layer.isOpaque = false
        
        rootLayer.addSublayer(layer)
        self.metalLayer = layer
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
            contentView.layer?.frame = NSRect(x: 0, y: 0, width: newSize, height: newHeight)
            self.metalLayer?.frame = NSRect(x: 0, y: 0, width: newSize, height: newHeight)
            self.metalLayer?.drawableSize = CGSize(width: newSize * scale, height: newHeight * scale)
        }
    }
    
    private func setupCamera() {
        let session = AVCaptureSession()
        
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        
        guard let device = AVCaptureDevice.default(for: .video) else {
            print("No video camera found.")
            return
        }
        
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {
            print("Error initializing camera input: \(error)")
            return
        }
        
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera.metal.queue", qos: .userInteractive))
        
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        
        self.videoOutput = output
        self.captureSession = session
        
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        if now - lastRenderTime < 0.030 {
            return
        }
        lastRenderTime = now
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var inputCIImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        inputCIImage = inputCIImage.oriented(.upMirrored)
        var finalImage: CIImage = inputCIImage
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .upMirrored, options: [:])
        do {
            try handler.perform([segmentationRequest])
            if let maskBuffer = segmentationRequest.results?.first?.pixelBuffer {
                let maskCIImage = CIImage(cvPixelBuffer: maskBuffer)
                
                let scaleX = inputCIImage.extent.width / maskCIImage.extent.width
                let scaleY = inputCIImage.extent.height / maskCIImage.extent.height
                let scaledMask = maskCIImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                
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
            print("Segmentation error: \(error)")
        }
        
        guard let metalLayer = self.metalLayer,
              let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let context = self.ciContext else { return }
        
        let drawableSize = metalLayer.drawableSize
        let renderBounds = CGRect(x: 0, y: 0, width: drawableSize.width, height: drawableSize.height)
        
        // Normalize origin coordinates to (0,0) before scaling to prevent off-screen rendering
        let originX = finalImage.extent.origin.x
        let originY = finalImage.extent.origin.y
        let normalizedImage = finalImage.transformed(by: CGAffineTransform(translationX: -originX, y: -originY))
        
        let scaleX = drawableSize.width / normalizedImage.extent.width
        let scaleY = drawableSize.height / normalizedImage.extent.height
        let scaledFinal = normalizedImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        context.render(scaledFinal, to: drawable.texture, commandBuffer: commandBuffer, bounds: renderBounds, colorSpace: colorSpace)
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    func closeWebcam() {
        captureSession?.stopRunning()
        window?.close()
    }
}

// Command Line Handler
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

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

let controller = WebcamWindowController(size: size, cornerPosition: position)
controller.showWindow(nil)

let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigSource.setEventHandler {
    controller.closeWebcam()
    exit(0)
}
sigSource.resume()
signal(SIGINT, SIG_IGN)

let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler {
    controller.closeWebcam()
    exit(0)
}
termSource.resume()
signal(SIGTERM, SIG_IGN)

app.run()
