import Cocoa
import AVFoundation
import Vision
import CoreImage
import Metal
import QuartzCore

class ResizableCutoutView: NSView {
    weak var windowController: WebcamWindowController?
    
    override func scrollWheel(with event: NSEvent) {
        // Resizing via scroll wheel / trackpad pinch
        let delta = event.deltaY
        if abs(delta) > 0.1 {
            windowController?.adjustSize(by: delta * 8.0)
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        // Window dragging
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
        
        // Balanced quality level for 30 FPS zero-jitter video performance
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
        
        let containerView = ResizableCutoutView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        containerView.windowController = self
        containerView.wantsLayer = true
        
        let layer = CAMetalLayer()
        layer.device = metalDevice
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.frame = containerView.bounds
        layer.backgroundColor = NSColor.clear.cgColor
        layer.isOpaque = false
        
        containerView.layer = layer
        self.metalLayer = layer
        window.contentView = containerView
    }
    
    func adjustSize(by delta: CGFloat) {
        guard let window = self.window else { return }
        let minSize: CGFloat = 140.0
        let maxSize: CGFloat = 850.0
        
        let newSize = max(minSize, min(maxSize, currentSize + delta))
        if newSize == currentSize { return }
        
        currentSize = newSize
        let frame = window.frame
        let newHeight = newSize * 1.25
        let newRect = NSRect(x: frame.minX, y: frame.minY, width: newSize, height: newHeight)
        
        DispatchQueue.main.async {
            window.setFrame(newRect, display: true, animate: false)
            self.metalLayer?.frame = NSRect(x: 0, y: 0, width: newSize, height: newHeight)
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
            
            // Lock camera device to locked 30 FPS for smooth, efficient video capture
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
            
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
        } catch {
            print("Error initializing camera input: \(error)")
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Enforce 30 FPS max rendering cadence (32ms interval)
        let now = CACurrentMediaTime()
        if now - lastRenderTime < 0.031 {
            return
        }
        lastRenderTime = now
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var inputCIImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Mirror camera for presenter orientation
        inputCIImage = inputCIImage.oriented(.upMirrored)
        
        var finalImage: CIImage = inputCIImage
        
        // High Speed 30 FPS Neural ML Segmentation
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .upMirrored, options: [:])
        do {
            try handler.perform([segmentationRequest])
            if let maskBuffer = segmentationRequest.results?.first?.pixelBuffer {
                let maskCIImage = CIImage(cvPixelBuffer: maskBuffer)
                
                let scaleX = inputCIImage.extent.width / maskCIImage.extent.width
                let scaleY = inputCIImage.extent.height / maskCIImage.extent.height
                let scaledMask = maskCIImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                
                // Pure transparent background
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
        
        // Metal GPU Texture Render (Zero CPU Bottleneck)
        guard let metalLayer = self.metalLayer,
              let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let context = self.ciContext else { return }
        
        let drawableSize = metalLayer.drawableSize
        let renderBounds = CGRect(x: 0, y: 0, width: drawableSize.width, height: drawableSize.height)
        
        let scaleX = drawableSize.width / finalImage.extent.width
        let scaleY = drawableSize.height / finalImage.extent.height
        let scaledFinal = finalImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
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
