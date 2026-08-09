import Cocoa
import AVFoundation
import Vision
import CoreImage

class WebcamWindowController: NSWindowController, NSWindowDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    var captureSession: AVCaptureSession?
    var videoOutput: AVCaptureVideoDataOutput?
    var renderLayer: CALayer?
    var ciContext: CIContext?
    
    let segmentationRequest = VNGeneratePersonSegmentationRequest()
    
    init(size: CGFloat = 240.0, cornerPosition: String = "bottom-left") {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let margin: CGFloat = 20.0
        
        var x: CGFloat = screen.minX + margin
        var y: CGFloat = screen.minY + margin
        
        if cornerPosition.contains("right") {
            x = screen.maxX - size - margin
        }
        if cornerPosition.contains("top") {
            y = screen.maxY - size - margin
        }
        
        // Rectangular presenter window frame (no circle)
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
        window.hasShadow = false // Zero rectangular window box shadow
        window.isMovableByWindowBackground = true
        window.displaysWhenScreenProfileChanges = true
        
        super.init(window: window)
        window.delegate = self
        
        // High precision neural engine person segmentation
        segmentationRequest.qualityLevel = .accurate
        segmentationRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
        
        setupContentView(width: size, height: size * 1.25)
        setupCamera()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupContentView(width: CGFloat, height: CGFloat) {
        guard let window = self.window else { return }
        
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        containerView.wantsLayer = true
        
        // Completely borderless, frameless transparent root layer (Zero Circle!)
        let rootLayer = CALayer()
        rootLayer.frame = containerView.bounds
        rootLayer.masksToBounds = false
        rootLayer.backgroundColor = NSColor.clear.cgColor
        rootLayer.cornerRadius = 0.0
        rootLayer.borderWidth = 0.0
        rootLayer.borderColor = NSColor.clear.cgColor
        
        containerView.layer = rootLayer
        window.contentView = containerView
        
        let imageLayer = CALayer()
        imageLayer.frame = containerView.bounds
        imageLayer.masksToBounds = false
        imageLayer.backgroundColor = NSColor.clear.cgColor
        imageLayer.borderWidth = 0.0
        imageLayer.borderColor = NSColor.clear.cgColor
        
        rootLayer.addSublayer(imageLayer)
        self.renderLayer = imageLayer
        
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: metalDevice)
        } else {
            self.ciContext = CIContext()
        }
    }
    
    private func setupCamera() {
        let session = AVCaptureSession()
        session.sessionPreset = .vga640x480
        
        guard let device = AVCaptureDevice.default(for: .video) else {
            print("No video camera found.")
            return
        }
        
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }
            
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera.processing.queue", qos: .userInteractive))
            
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
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var inputCIImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Mirror horizontally for camera presenter orientation
        inputCIImage = inputCIImage.oriented(.upMirrored)
        
        var finalImage: CIImage = inputCIImage
        
        // Neural ML Person Segmentation — Keeps 100% of person (shirt, arms, skin) while removing room background
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .upMirrored, options: [:])
        do {
            try handler.perform([segmentationRequest])
            if let maskBuffer = segmentationRequest.results?.first?.pixelBuffer {
                let maskCIImage = CIImage(cvPixelBuffer: maskBuffer)
                
                let scaleX = inputCIImage.extent.width / maskCIImage.extent.width
                let scaleY = inputCIImage.extent.height / maskCIImage.extent.height
                let scaledMask = maskCIImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                
                // 100% Transparent Background
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
            print("Person segmentation error: \(error)")
        }
        
        if let cgImage = self.ciContext?.createCGImage(finalImage, from: finalImage.extent) {
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

// Command Line Handler
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var size: CGFloat = 240.0
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
