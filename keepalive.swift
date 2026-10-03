// cam-keepalive — holds a camera's capture session open and does NOTHING
// with the frames. Exists for the Canon EOS M50 Mark II: the moment the
// EOS Webcam Utility session closes (presenter off, recording stopped),
// the camera resets its USB link and, on Archon's hub chain, never
// re-enumerates — Adam had to power-cycle it every time (2026-09-04:
// kernel enumerated it 15:09:50, last client exited 15:13:25, camera gone
// 15:13:28). While this process runs the session is never released.
// Multiple clients share the extension's stream, so the presenter and
// Voom open and close freely on top of it.
//
// Exit codes: 0 SIGTERM/SIGINT, 3 no frames for 15s (service died —
// vox.lua respawns), 2 device not found.
import AVFoundation
import Foundation

let args = CommandLine.arguments
var wanted = "EOS Webcam Utility"
for i in 0..<args.count where args[i] == "--device" && i + 1 < args.count { wanted = args[i + 1] }

func logMsg(_ s: String) { fputs("KEEPALIVE: \(s)\n", stderr); fflush(stderr) }

final class Sink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var frames = 0
    var lastReport = Date()
    var lastFrame = Date()
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frames += 1
        lastFrame = Date()
        if Date().timeIntervalSince(lastReport) >= 60 {
            logMsg("holding \(wanted): \(frames) frames/min")
            frames = 0
            lastReport = Date()
        }
    }
}

let devices = AVCaptureDevice.devices(for: .video)
guard let dev = devices.first(where: { $0.localizedName.localizedCaseInsensitiveContains(wanted) }) else {
    logMsg("device '\(wanted)' not found")
    exit(2)
}
let session = AVCaptureSession()
do {
    let input = try AVCaptureDeviceInput(device: dev)
    if session.canAddInput(input) { session.addInput(input) }
} catch {
    logMsg("input error: \(error)")
    exit(2)
}
if session.canSetSessionPreset(.low) { session.sessionPreset = .low }   // ask for the least
let output = AVCaptureVideoDataOutput()
output.alwaysDiscardsLateVideoFrames = true
let sink = Sink()
output.setSampleBufferDelegate(sink, queue: DispatchQueue(label: "keepalive.sink", qos: .background))
if session.canAddOutput(output) { session.addOutput(output) }
session.startRunning()
logMsg("session open on \(dev.localizedName) (preset \(session.sessionPreset.rawValue))")

// starvation watchdog: the EOS service was bounced/died under us
let watchdog = DispatchSource.makeTimerSource(queue: .main)
watchdog.schedule(deadline: .now() + 15, repeating: 5)
watchdog.setEventHandler {
    if Date().timeIntervalSince(sink.lastFrame) > 15 {
        logMsg("no frames for 15s — exiting for respawn")
        exit(3)
    }
}
watchdog.resume()

for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { session.stopRunning(); logMsg("released"); exit(0) }
    src.resume()
    _ = Unmanaged.passRetained(src)   // keep alive
}
RunLoop.main.run()
