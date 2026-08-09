import Cocoa
import AVFoundation

class WebcamWindowController: NSWindowController, NSWindowDelegate {
    var captureSession: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?

    init(size: CGFloat = 180.0, cornerPosition: String = "bottom-left") {
        // Calculate screen frame
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
        
        let circleLayer = CALayer()
        circleLayer.frame = containerView.bounds
        circleLayer.cornerRadius = size / 2.0
        circleLayer.masksToBounds = true
        circleLayer.borderColor = NSColor(red: 0.1, green: 0.85, blue: 0.75, alpha: 0.9).cgColor // Vox Cyan/Emerald accent
        circleLayer.borderWidth = 3.0
        circleLayer.backgroundColor = NSColor.black.cgColor
        
        containerView.layer = circleLayer
        window.contentView = containerView
    }
    
    private func setupCamera() {
        guard let window = self.window, let contentView = window.contentView else { return }
        
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
            
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.frame = contentView.bounds
            preview.videoGravity = .resizeAspectFill
            contentView.layer?.addSublayer(preview)
            
            self.previewLayer = preview
            self.captureSession = session
            
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        } catch {
            print("Error initializing camera input: \(error)")
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

// Signal handling for clean exit
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
