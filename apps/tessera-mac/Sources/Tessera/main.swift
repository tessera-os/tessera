import AppKit
import IOSurface
import TesseraHostKit

final class App: NSObject, NSApplicationDelegate, TesseraHost, NSWindowDelegate {
    let headless = CommandLine.arguments.contains("--headless")
    let exitReady = CommandLine.arguments.contains("--exit-after-ready")
    var connection: NSXPCConnection?
    var deviceHosts: AppDevices?
    var config: KernelConfig!
    var windows: [Int: NSWindow] = [:]
    var views: [Int: DisplayView] = [:]
    var didFrame = false, isReady = false, quitting = false
    var consoleLines: [String] = []
    var bootFailed = false
    var headlessModes: [UInt64: DisplayOutput] = [:]
    var remote: TarwindControl? { connection?.remoteObjectProxyWithErrorHandler { error in NSLog("XPC: %@", "\(error)") } as? TarwindControl }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !headless { NSApp.setActivationPolicy(.regular); makeMenu() }
        do {
            var disk = DiskImage.defaultURL
            if let index = CommandLine.arguments.firstIndex(of: "--disk"), index + 1 < CommandLine.arguments.count {
                disk = URL(fileURLWithPath: CommandLine.arguments[index + 1]).appendingPathComponent("system.trfsdisk")
            }
            if let backup = try DiskImage.prepareForBoot(at: disk) { console("Legacy disk backed up: \(backup.path)") }
            config = KernelConfig(diskPath: disk.path,
                panicRecordPath: disk.deletingLastPathComponent().appendingPathComponent("panic.txt").path,
                taskExecutablePath: Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/com.tessera.tarwind.xpc/Contents/MacOS/tarwin-task").path)
            config.stubKernel = CommandLine.arguments.contains("--stub-kernel")
            connect()
        } catch { print("ERROR \(error)"); fflush(stdout); exit(1) }
    }
    @MainActor func connect() {
        let connection = NSXPCConnection(serviceName: "com.tessera.tarwind")
        connection.remoteObjectInterface = NSXPCInterface(with: TarwindControl.self)
        connection.exportedInterface = XPCInterfaces.host(); connection.exportedObject = self
        connection.interruptionHandler = { [weak self] in DispatchQueue.main.async { self?.interrupted() } }
        self.connection = connection; connection.resume(); start()
    }
    @MainActor func interrupted() {
        guard !quitting else { return }
        deviceHosts?.close(); deviceHosts = nil
        let record = (try? String(contentsOfFile: config.panicRecordPath, encoding: .utf8)) ?? "Kernel connection interrupted"
        console("PANIC: \(record)")
        for view in views.values { view.console.isHidden = false }
        connection?.interruptionHandler = nil; connection?.invalidate(); connection = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connect() }
    }
    @MainActor @objc func start() {
        deviceHosts?.close(); deviceHosts = nil
        didFrame = false; isReady = false
        bootFailed = false
        views.values.forEach { $0.console.isHidden = false }
        views.values.forEach { $0.display?.stop() }; headlessModes.removeAll()
        if let data = try? JSONEncoder().encode(config) { remote?.start(data) }
    }
    @MainActor @objc func stop() { deviceHosts?.close(); deviceHosts = nil; remote?.shutdown(); console("Kernel shut down"); views.values.forEach { $0.console.isHidden = false } }
    @MainActor @objc func restart() { start() }
    @MainActor @objc func recovery() {
        views.values.forEach { $0.console.isHidden = false; $0.display?.stop() }; headlessModes.removeAll()
        remote?.recovery()
    }
    func bootStage(_ name: String) { console("Stage: \(name)") }
    func ready() { DispatchQueue.main.async {
        self.deviceHosts?.close()
        self.deviceHosts = AppDevices { [weak self] data in self?.remote?.deviceFrame(["tw.frame": data]) }
        self.deviceHosts?.hid.setFocused(self.windows.values.contains { $0.isKeyWindow })
        self.isReady = true; print("TESSERA READY"); fflush(stdout)
        self.views.values.forEach { $0.console.isHidden = !self.bootFailed; $0.window?.makeFirstResponder($0) }; self.finishIfNeeded()
    } }
    func finishIfNeeded() { if headless && exitReady && didFrame && isReady { quitting = true; remote?.shutdown(); exit(0) } }
    func console(_ line: String) { DispatchQueue.main.async {
        print(line); fflush(stdout); self.consoleLines.append(line); self.consoleLines = Array(self.consoleLines.suffix(30))
        if line.hasPrefix("Kernel boot failed:") { self.bootFailed = true }
        self.views.values.forEach { $0.console.stringValue = self.consoleLines.joined(separator: "\n") }
    } }
    func panic(_ record: Data) {
        let message = "PANIC: " + String(decoding: record, as: UTF8.self)
        if headless && exitReady { print(message); fflush(stdout); exit(1) }
        console(message)
    }
    func outputChanged(_ data: Data) { DispatchQueue.main.async {
        guard let output = try? JSONDecoder().decode(DisplayOutput.self, from: data), output.id >= 0 else { return }
        if self.headless {
            let id = UInt64(output.id) + 1
            guard self.headlessModes[id] == nil else { return }
            self.headlessModes[id] = output
            self.sendDisplay(.mode(output: id, generation: 1, width: output.width, height: output.height, scale: output.scale, refreshHz: 60))
            return
        }
        if let view = self.views[output.id] {
            let size = view.convertToBacking(view.bounds).size
            view.display?.resume(width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                                 scale: Double(view.window?.backingScaleFactor ?? 1),
                                 refreshHz: view.window?.screen?.maximumFramesPerSecond ?? 60)
            return
        }
        let view = DisplayView(output: output) { [weak self] in self?.remote?.displayEvent($0) }
        view.rawEvent = { [weak self] event, size in
            guard let hid = self?.deviceHosts?.hid else { return }
            InputEvents.translate(event, using: hid, windowSize: size)
        }
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Tessera"; window.contentView = view; window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]; window.acceptsMouseMovedEvents = true
        window.center(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
        self.windows[output.id] = window; self.views[output.id] = view
        view.console.isHidden = self.isReady && !self.bootFailed
        NSApp.activate(ignoringOtherApps: true)
    } }
    @MainActor func sendDisplay(_ event: DisplayTransportEvent) {
        if let data = try? JSONEncoder().encode(event) { remote?.displayEvent(data) }
    }
    func present(_ surface: IOSurface, output: UInt64, generation: UInt64, frame: UInt64) { DispatchQueue.main.async {
        guard output > 0, output <= UInt64(Int.max) else { return }
        let accepted: Bool
        if self.headless {
            accepted = generation == 1 && self.headlessModes[output]?.width == surface.width && self.headlessModes[output]?.height == surface.height
            self.sendDisplay(.discarded(output: output, generation: generation, serial: frame))
        } else if let display = self.views[Int(output - 1)]?.display {
            accepted = display.receive(surface, output: output, generation: generation, serial: frame)
        } else {
            accepted = false; self.sendDisplay(.discarded(output: output, generation: generation, serial: frame))
        }
        if accepted && !self.didFrame { print("FRAME \(frame) output=\(output) generation=\(generation) H5 composition received"); fflush(stdout); self.didFrame = true }
        self.finishIfNeeded()
    } }
    func audio(_ payload: Data) {}
    func audioLink(_ link: AudioLinkEnvelope, reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            guard let hosts = self.deviceHosts else { reply(false); return }
            do { try hosts.attach(link); reply(true) }
            catch { self.console("AUDIO attach failed: \(error)"); reply(false) }
        }
    }
    func power(_ payload: Data) {}
    func deviceFrame(_ dictionary: [String: Data]) {
        guard let data = dictionary["tw.frame"] else { return }
        DispatchQueue.main.async { self.deviceHosts?.receive(data) }
    }
    func windowDidBecomeKey(_ notification: Notification) { deviceHosts?.hid.setFocused(true) }
    func windowDidResignKey(_ notification: Notification) { deviceHosts?.hid.setFocused(false) }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        views[id]?.display?.stop()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !headless }
    func applicationWillTerminate(_ notification: Notification) { quitting = true; deviceHosts?.close(); remote?.shutdown(); connection?.invalidate() }
    func makeMenu() {
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        for (title, action, key) in [("Start", #selector(start), "s"), ("Shut Down", #selector(stop), ""),
                                     ("Restart", #selector(restart), "r"), ("Recovery", #selector(recovery), "")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; appMenu.addItem(item)
        }
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "Quit Tessera", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
    }
}
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
