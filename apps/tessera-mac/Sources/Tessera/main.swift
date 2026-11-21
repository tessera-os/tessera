import AppKit
import IOSurface
import TesseraHostKit

final class App: NSObject, NSApplicationDelegate, TesseraHost, NSWindowDelegate {
    let headless = CommandLine.arguments.contains("--headless")
    let exitReady = CommandLine.arguments.contains("--exit-after-ready")
    var connection: NSXPCConnection?
    var config: KernelConfig!
    var windows: [Int: NSWindow] = [:]
    var views: [Int: DisplayView] = [:]
    var didFrame = false, isReady = false, quitting = false
    var consoleLines: [String] = []
    var remote: TarwindControl? { connection?.remoteObjectProxyWithErrorHandler { error in NSLog("XPC: %@", "\(error)") } as? TarwindControl }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !headless { NSApp.setActivationPolicy(.regular); makeMenu() }
        do {
            var disk = DiskImage.defaultURL
            if let index = CommandLine.arguments.firstIndex(of: "--disk"), index + 1 < CommandLine.arguments.count {
                disk = URL(fileURLWithPath: CommandLine.arguments[index + 1]).appendingPathComponent("system.trfsdisk")
            }
            if !FileManager.default.fileExists(atPath: disk.path) { _ = try DiskImage.create(at: disk) }
            _ = try DiskImage.open(at: disk)
            config = KernelConfig(diskPath: disk.path, systemImagePath: try SystemImage.locate().path,
                panicRecordPath: disk.deletingLastPathComponent().appendingPathComponent("panic.txt").path,
                taskExecutablePath: Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/com.tessera.tarwind.xpc/Contents/MacOS/tarwin-task").path)
            connect()
        } catch { print("ERROR \(error)"); fflush(stdout); exit(1) }
    }
    func connect() {
        let connection = NSXPCConnection(serviceName: "com.tessera.tarwind")
        connection.remoteObjectInterface = NSXPCInterface(with: TarwindControl.self)
        connection.exportedInterface = XPCInterfaces.host(); connection.exportedObject = self
        connection.interruptionHandler = { [weak self] in DispatchQueue.main.async { self?.interrupted() } }
        self.connection = connection; connection.resume(); start()
    }
    func interrupted() {
        guard !quitting else { return }
        let record = (try? String(contentsOfFile: config.panicRecordPath, encoding: .utf8)) ?? "Kernel connection interrupted"
        console("PANIC: \(record)")
        for view in views.values { view.console.isHidden = false }
        connection?.interruptionHandler = nil; connection?.invalidate(); connection = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connect() }
    }
    @objc func start() {
        didFrame = false; isReady = false
        views.values.forEach { $0.console.isHidden = false }
        if let data = try? JSONEncoder().encode(config) { remote?.start(data) }
    }
    @objc func stop() { remote?.shutdown(); console("Kernel shut down"); views.values.forEach { $0.console.isHidden = false } }
    @objc func restart() { views.values.forEach { $0.console.isHidden = false }; remote?.restart() }
    @objc func recovery() { remote?.recovery() }
    func bootStage(_ name: String) { console("Stage: \(name)") }
    func ready() { DispatchQueue.main.async {
        self.isReady = true; print("TESSERA READY"); fflush(stdout)
        self.views.values.forEach { $0.console.isHidden = true }; self.finishIfNeeded()
    } }
    func finishIfNeeded() { if headless && exitReady && didFrame && isReady { quitting = true; remote?.shutdown(); exit(0) } }
    func console(_ line: String) { DispatchQueue.main.async {
        print(line); fflush(stdout); self.consoleLines.append(line); self.consoleLines = Array(self.consoleLines.suffix(30))
        self.views.values.forEach { $0.console.stringValue = self.consoleLines.joined(separator: "\n") }
    } }
    func panic(_ record: Data) { console("PANIC: " + String(decoding: record, as: UTF8.self)) }
    func outputChanged(_ data: Data) { DispatchQueue.main.async {
        guard !self.headless, let output = try? JSONDecoder().decode(DisplayOutput.self, from: data) else { return }
        if self.windows[output.id] != nil { return }
        let view = DisplayView(output: output)
        view.send = { [weak self] event in if let data = try? JSONEncoder().encode(event) { self?.remote?.deliver(data) } }
        view.resized = { [weak self] output in if let data = try? JSONEncoder().encode(output) { self?.remote?.resize(data) } }
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Tessera"; window.contentView = view; window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]; window.acceptsMouseMovedEvents = true
        window.center(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
        self.windows[output.id] = window; self.views[output.id] = view
        NSApp.activate(ignoringOtherApps: true)
    } }
    func present(_ surface: IOSurface, output: Int, frame: UInt64) { DispatchQueue.main.async {
        if !self.didFrame { print("FRAME \(frame)"); fflush(stdout); self.didFrame = true }
        if !self.headless { self.views[output]?.present(surface) }; self.finishIfNeeded()
    } }
    func audio(_ payload: Data) {}
    func power(_ payload: Data) {}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !headless }
    func applicationWillTerminate(_ notification: Notification) { quitting = true; remote?.shutdown(); connection?.invalidate() }
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
