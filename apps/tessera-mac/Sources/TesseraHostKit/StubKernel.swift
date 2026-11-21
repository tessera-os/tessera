import AppKit
import IOSurface

public final class StubKernel: HostedKernel, HIDProvider {
    private let devices: HostDevices
    private weak var host: KernelHost?
    private var timer: DispatchSourceTimer?
    private var outputs: [DisplayOutput] = []
    private var stages = ["firmware", "tarwind", "tessera.init", "services", "MosaicDisplay", "desktop"]
    private var tick = 0
    private var frame: UInt64 = 0
    private var cursor = CGPoint(x: 500, y: 300)
    private var typed = ""
    private let desktopOnly: Bool
    public init(devices: HostDevices, desktopOnly: Bool = false) {
        self.devices = devices; self.desktopOnly = desktopOnly; devices.hid = self
        if desktopOnly { stages = [] }
    }
    public func start(config: KernelConfig, host: KernelHost) {
        shutdown(); self.host = host; outputs = config.outputs; tick = 0; frame = 0
        do {
            let disk = try DiskImage.open(at: URL(fileURLWithPath: config.diskPath))
            host.console("TRFS block device: boot #\(try disk.incrementBootCount())")
        } catch { host.panic(record: Array("Disk error: \(error)".utf8)); return }
        outputs.forEach { devices.display.outputChanged($0) }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30)
        timer.setEventHandler { [weak self] in self?.step() }
        self.timer = timer; timer.resume()
    }
    public func shutdown() { timer?.cancel(); timer = nil }
    public func deliver(_ event: HostEvent) {
        if event.kind == "pointer" || event.kind == "pointerDown" { cursor = CGPoint(x: event.x, y: event.y) }
        if event.kind == "keyDown" {
            if event.keyCode == 51 { if !typed.isEmpty { typed.removeLast() } }
            else { typed += event.text; typed = String(typed.suffix(100)) }
        }
    }
    public func resize(_ output: DisplayOutput) {
        if let index = outputs.firstIndex(where: { $0.id == output.id }) { outputs[index] = output }
        else { outputs.append(output) }
        devices.display.outputChanged(output)
    }
    private func step() {
        if tick % 8 == 0 && tick / 8 < stages.count {
            let stage = stages[tick / 8]; host?.bootStage(stage); host?.console("[boot] \(stage)")
        }
        tick += 1
        guard tick > stages.count * 8 else { return }
        frame += 1
        for output in outputs { render(output) }
        if frame == 1 { host?.ready() }
    }
    private func render(_ output: DisplayOutput) {
        let w = max(64, min(output.width, 4096)), h = max(64, min(output.height, 4096))
        let properties: [IOSurfacePropertyKey: Any] = [.width: w, .height: h, .bytesPerElement: 4,
            .bytesPerRow: w * 4, .pixelFormat: UInt32(0x42475241)]
        guard let surface = IOSurface(properties: properties) else { return }
        surface.lock(options: [], seed: nil)
        guard let context = CGContext(data: surface.baseAddress, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: surface.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            surface.unlock(options: [], seed: nil); return
        }
        let colors = [NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.28, alpha: 1).cgColor,
                      NSColor(calibratedRed: 0.18, green: 0.47, blue: 0.48, alpha: 1).cgColor]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        func text(_ value: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 16, color: NSColor = .white) {
            (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
        }
        NSColor.black.withAlphaComponent(0.24).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: h - 38, width: w, height: 38)).fill()
        text("Tessera", 24, CGFloat(h - 28), size: 18)
        text(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short), CGFloat(w - 110), CGFloat(h - 27))
        text("Your space, reassembled.", 64, CGFloat(h) * 0.61, size: 36)
        text(desktopOnly ? "TarwindKernel  •  Preview display" : "Hosted Tarwin  •  Stub kernel preview", 66, CGFloat(h) * 0.61 - 35, size: 16)
        text(typed.isEmpty ? "Type anywhere to begin…" : typed, 66, CGFloat(h) * 0.61 - 85, size: 20)
        let dock = NSRect(x: CGFloat(w) / 2 - 172, y: 24, width: 344, height: 82)
        NSColor.white.withAlphaComponent(0.15).setFill(); NSBezierPath(roundedRect: dock, xRadius: 22, yRadius: 22).fill()
        for (i, label) in ["Files", "Web", "Notes", "Settings"].enumerated() {
            let x = dock.minX + 14 + CGFloat(i * 80)
            NSColor(calibratedHue: CGFloat(i) * 0.16 + 0.45, saturation: 0.4, brightness: 0.9, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x + 10, y: 53, width: 42, height: 40), xRadius: 11, yRadius: 11).fill()
            text(label, x + 4, 32, size: 12)
        }
        let p = NSBezierPath(); p.move(to: cursor); p.line(to: CGPoint(x: cursor.x + 5, y: cursor.y - 22))
        p.line(to: CGPoint(x: cursor.x + 11, y: cursor.y - 14)); p.line(to: CGPoint(x: cursor.x + 21, y: cursor.y - 12)); p.close()
        NSColor.white.setFill(); p.fill(); NSColor.black.setStroke(); p.stroke()
        NSGraphicsContext.restoreGraphicsState()
        surface.unlock(options: [], seed: nil)
        devices.display.present(surface, output: output.id, frame: frame)
    }
}
