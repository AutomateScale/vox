import Cocoa
import AVFoundation
import Vision
import CoreImage

// Convert RGB (0..1) to HSV (H: 0..360, S: 0..1, V: 0..1)
func rgbToHSV(r: Float, g: Float, b: Float) -> (Float, Float, Float) {
    let minVal = min(r, min(g, b))
    let maxVal = max(r, max(g, b))
    let delta = maxVal - minVal
    
    var h: Float = 0
    var s: Float = 0
    let v: Float = maxVal
    
    if maxVal != 0 {
        s = delta / maxVal
    } else {
        return (0, 0, 0)
    }
    
    if delta == 0 {
        h = 0
    } else if r == maxVal {
        h = (g - b) / delta
    } else if g == maxVal {
        h = 2 + (b - r) / delta
    } else {
        h = 4 + (r - g) / delta
    }
    
    h *= 60
    if h < 0 { h += 360 }
    
    return (h, s, v)
}

// Generate 64x64x64 GPU CIColorCube data for ultra-fast Chroma Keying of green backgrounds
func makeGreenChromaKeyCube() -> Data {
    let size = 64
    var cubeData = [Float]()
    cubeData.reserveCapacity(size * size * size * 4)
    
    for z in 0..<size {
        let b = Float(z) / Float(size - 1)
        for y in 0..<size {
            let g = Float(y) / Float(size - 1)
            for x in 0..<size {
                let r = Float(x) / Float(size - 1)
                
                let (h, s, v) = rgbToHSV(r: r, g: g, b: b)
                
                // Detect green hue range (75° to 170°) with sufficient saturation and brightness
                let isGreen = (h >= 75 && h <= 170) && (s >= 0.20) && (v >= 0.15)
                
                // Key out green: alpha = 0 for green, alpha = 1 for non-green
                let alpha: Float = isGreen ? 0.0 : 1.0
                
                cubeData.append(r * alpha)
                cubeData.append(g * alpha)
                cubeData.append(b * alpha)
                cubeData.append(alpha)
            }
        }
    }
    
    return cubeData.withUnsafeBufferPointer { Data(buffer: $0) }
}

class WebcamWindowController: NSWindowController, NSWindowDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    var captureSession: AVCaptureSession?
    var videoOutput: AVCaptureVideoDataOutput?
    var renderLayer: CALayer?
    var ciContext: CIContext?
    
    var greenScreenMode: String = "chroma" // "chroma" (keys out green screen), "cutout" (AI cutout), "off"
    let segmentationRequest = VNGeneratePersonSegmentationRequest()
    var chromaKeyFilter: CIFilter?
    
    init(size: CGFloat = 180.0, cornerPosition: String = "bottom-left", bgMode: String = "chroma") {
        self.greenScreenMode = bgMode
        
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let margin: CGFloat = 30.0
        
        var x: CGFloat = screen.minX + margin
        var y: CGFloat = screen.minY + margin
        
        if cornerPosition.contains("right") {
            x = screen.maxX - size - margin
        }
        if cornerPosition.contains("top") {
            y = screen.maxY - size - margin
        }
        
        let rect = NSRect(x: x, y: y, width: size, height: size)
        
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.displaysWhenScreenProfileChanges = true
        
        super.init(window: window)
        window.delegate = self
        
        segmentationRequest.qualityLevel = .fast
        segmentationRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
        
        // Build GPU Chroma Key Filter
        let cubeData = makeGreenChromaKeyCube()
        let filter = CIFilter(name: "CIColorCube")
        filter?.setValue(64, forKey: "inputCubeDimension")
        filter?.setValue(cubeData, forKey: "inputCubeData")
        self.chromaKeyFilter = filter
        
        setupContentView(size: size)
        setupCamera()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupContentView(size: CGFloat) {
        guard let window = self.window else { return }
        
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        containerView.wantsLayer = true
        
        // Original Vox Cyan Circular Accent Border Ring
        let circleLayer = CALayer()
        circleLayer.frame = containerView.bounds
        circleLayer.cornerRadius = size / 2.0
        circleLayer.masksToBounds = true
        circleLayer.borderColor = NSColor(red: 0.1, green: 0.85, blue: 0.75, alpha: 0.9).cgColor
        circleLayer.borderWidth = 3.0
        circleLayer.backgroundColor = NSColor.clear.cgColor
        
        containerView.layer = circleLayer
        window.contentView = containerView
        
        let imageLayer = CALayer()
        imageLayer.frame = containerView.bounds
        imageLayer.masksToBounds = true
        imageLayer.cornerRadius = size / 2.0
        
        circleLayer.addSublayer(imageLayer)
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
        
        inputCIImage = inputCIImage.oriented(.upMirrored)
        var finalImage: CIImage = inputCIImage
        
        if greenScreenMode == "chroma" || greenScreenMode == "green" || greenScreenMode == "keygreen" {
            // GPU Chroma Keying: Key out green screen background cleanly on GPU
            if let filter = chromaKeyFilter {
                filter.setValue(inputCIImage, forKey: kCIInputImageKey)
                if let keyed = filter.outputImage {
                    finalImage = keyed
                }
            }
        } else if greenScreenMode == "cutout" || greenScreenMode == "transparent" {
            // AI Person Segmentation Cutout
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

var size: CGFloat = 180.0
var position = "bottom-left"
var bgMode = "chroma" // GPU Chroma Keying (Keys out green screen) by default!

let args = CommandLine.arguments
for i in 0..<args.count {
    if args[i] == "--size", i + 1 < args.count, let s = Double(args[i+1]) {
        size = CGFloat(s)
    }
    if args[i] == "--position", i + 1 < args.count {
        position = args[i+1]
    }
    if args[i] == "--bg", i + 1 < args.count {
        bgMode = args[i+1]
    }
}

let controller = WebcamWindowController(size: size, cornerPosition: position, bgMode: bgMode)
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
