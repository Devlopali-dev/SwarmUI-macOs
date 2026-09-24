import AppKit
import Metal
import ServiceManagement

let port = 7801
let uiURL = URL(string: "http://localhost:\(port)")!
let supportDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/SwarmUI")
let swarmDir = supportDir.appendingPathComponent("SwarmUI")
let logDir = supportDir.appendingPathComponent("logs")
let logFile = logDir.appendingPathComponent("swarmui.log")
let launcherEnv = supportDir.appendingPathComponent("launcher.env")
let totalRAMGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)

/// Memory cap applied by swarm-launch.sh through launcher.env (MPS watermark + ComfyUI --reserve-vram).
enum MemoryLimit {
    static let choices = [16, 24, 32].filter { $0 < totalRAMGB }

    static func current() -> Int? {
        guard let text = try? String(contentsOf: launcherEnv, encoding: .utf8) else {
            return nil
        }
        for line in text.split(separator: "\n") where line.hasPrefix("SWARM_RAM_LIMIT_GB=") {
            return Int(line.dropFirst("SWARM_RAM_LIMIT_GB=".count))
        }
        return nil
    }

    static func save(_ gb: Int?) throws {
        guard let gb else {
            try? FileManager.default.removeItem(at: launcherEnv)
            return
        }
        // PyTorch expresses the MPS cap as a ratio of Metal's recommended working set, not of total RAM.
        let workingSet = Double(MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize ?? ProcessInfo.processInfo.physicalMemory)
        let high = Double(gb) * 1_073_741_824 / workingSet
        let text = """
        # Généré par SwarmUI > Limite mémoire
        SWARM_RAM_LIMIT_GB=\(gb)
        PYTORCH_MPS_HIGH_WATERMARK_RATIO=\(String(format: "%.4f", high))
        PYTORCH_MPS_LOW_WATERMARK_RATIO=\(String(format: "%.4f", high * 0.8))

        """
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try text.write(to: launcherEnv, atomically: true, encoding: .utf8)
    }
}

enum ServerState {
    case stopped, starting, running, stopping
}

/// Owns the swarm-launch.sh process group (bash + dotnet SwarmUI + python backends).
final class ServerController {
    private(set) var state: ServerState = .stopped {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?
    var onReady: (() -> Void)?
    var lastExitCode: Int32?

    private var pid: pid_t = 0
    private var exitSource: DispatchSourceProcess?
    private var pollTimer: Timer?
    private var afterStop: [() -> Void] = []

    func start() {
        guard state == .stopped else { return }
        guard let script = Bundle.main.url(forResource: "swarm-launch", withExtension: "sh") else {
            NSLog("swarm-launch.sh missing from bundle")
            return
        }
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        rotateLog()

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        // Own process group so stop() can signal SwarmUI and every python child at once.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logFile.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        let args = ["/bin/bash", script.path, "--port", String(port)]
        let cargs = args.map { strdup($0) } + [nil]
        var newPid: pid_t = 0
        let rc = posix_spawn(&newPid, "/bin/bash", &actions, &attr, cargs, environ)
        for arg in cargs {
            free(arg)
        }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        guard rc == 0 else {
            NSLog("posix_spawn failed: \(rc)")
            return
        }

        pid = newPid
        lastExitCode = nil
        state = .starting
        let source = DispatchSource.makeProcessSource(identifier: newPid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            self?.handleExit()
        }
        source.resume()
        exitSource = source
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.pollReady()
        }
    }

    func stop(then completion: (() -> Void)? = nil) {
        if let completion {
            afterStop.append(completion)
        }
        guard state == .starting || state == .running else {
            if state == .stopped {
                runAfterStop()
            }
            return
        }
        state = .stopping
        pollTimer?.invalidate()
        let group = pid
        kill(-group, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            if let self, self.pid == group, self.state == .stopping {
                kill(-group, SIGKILL)
            }
        }
    }

    func restart() {
        stop { [weak self] in
            self?.start()
        }
    }

    private func handleExit() {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        // Reap anything left in the group (e.g. python backends still shutting down).
        kill(-pid, SIGTERM)
        let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
        lastExitCode = state == .stopping ? nil : exitCode
        exitSource?.cancel()
        exitSource = nil
        pollTimer?.invalidate()
        pollTimer = nil
        pid = 0
        state = .stopped
        runAfterStop()
    }

    private func runAfterStop() {
        let callbacks = afterStop
        afterStop = []
        for callback in callbacks {
            callback()
        }
    }

    private func pollReady() {
        var request = URLRequest(url: uiURL)
        request.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            guard response is HTTPURLResponse else { return }
            DispatchQueue.main.async {
                guard let self, self.state == .starting else { return }
                self.pollTimer?.invalidate()
                self.pollTimer = nil
                self.state = .running
                self.onReady?()
            }
        }.resume()
    }

    private func rotateLog() {
        let fm = FileManager.default
        let previous = logDir.appendingPathComponent("swarmui.previous.log")
        try? fm.removeItem(at: previous)
        try? fm.moveItem(at: logFile, to: previous)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let server = ServerController()
    var statusItem: NSStatusItem!
    var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "SwarmUI")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        server.onChange = { [weak self] in
            self?.refreshIcon()
        }
        server.onReady = {
            NSWorkspace.shared.open(uiURL)
        }

        if !FileManager.default.fileExists(atPath: swarmDir.appendingPathComponent(".git").path) {
            showFirstRunNotice()
        }
        server.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if server.state == .stopped || quitting {
            return .terminateNow
        }
        quitting = true
        server.stop {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        addItem(menu, "Ouvrir SwarmUI", #selector(openUI), "o", enabled: server.state == .running)
        switch server.state {
        case .stopped:
            addItem(menu, "Démarrer le serveur", #selector(startServer), "s")
        case .starting, .running:
            addItem(menu, "Arrêter le serveur", #selector(stopServer), "s")
            addItem(menu, "Redémarrer le serveur", #selector(restartServer), "r")
        case .stopping:
            addItem(menu, "Arrêt en cours…", nil, "", enabled: false)
        }
        menu.addItem(.separator())

        let limit = MemoryLimit.current()
        let memoryItem = NSMenuItem(title: "Limite mémoire", action: nil, keyEquivalent: "")
        let memoryMenu = NSMenu()
        for gb in MemoryLimit.choices {
            let item = addItem(memoryMenu, "\(gb) Go", #selector(setMemoryLimit(_:)), "")
            item.tag = gb
            item.state = limit == gb ? .on : .off
        }
        memoryMenu.addItem(.separator())
        let noLimit = addItem(memoryMenu, "Aucune limite (\(totalRAMGB) Go)", #selector(setMemoryLimit(_:)), "")
        noLimit.tag = 0
        noLimit.state = limit == nil ? .on : .off
        memoryItem.submenu = memoryMenu
        menu.addItem(memoryItem)
        menu.addItem(.separator())

        addItem(menu, "Dossier des modèles", #selector(openModels), "m")
        addItem(menu, "Dossier des images générées", #selector(openOutput), "")
        addItem(menu, "Voir les logs", #selector(openLogs), "l")
        menu.addItem(.separator())

        let login = addItem(menu, "Lancer à l'ouverture de session", #selector(toggleLoginItem), "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        addItem(menu, "Quitter SwarmUI", #selector(quit), "q")
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func statusText() -> String {
        switch server.state {
        case .stopped:
            if let code = server.lastExitCode, code != 0 {
                return "Serveur arrêté (erreur \(code), voir les logs)"
            }
            return "Serveur arrêté"
        case .starting:
            return "Démarrage… (1er lancement : plusieurs minutes)"
        case .running:
            if let limit = MemoryLimit.current() {
                return "En cours sur localhost:\(port) · limite \(limit) Go"
            }
            return "En cours sur localhost:\(port)"
        case .stopping:
            return "Arrêt en cours…"
        }
    }

    private func refreshIcon() {
        statusItem.button?.appearsDisabled = server.state != .running
        statusItem.button?.toolTip = "SwarmUI — " + statusText()
    }

    private func showFirstRunNotice() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Installation de SwarmUI"
        alert.informativeText = """
        Premier lancement : SwarmUI va être téléchargé puis compilé (quelques minutes, connexion internet requise).

        Le navigateur s'ouvrira automatiquement sur l'assistant d'installation. Il installera ensuite ComfyUI et PyTorch avec le Python intégré à l'application.

        SwarmUI reste accessible depuis l'icône dans la barre de menus. Tu peux suivre la progression avec « Voir les logs ».
        """
        alert.addButton(withTitle: "Continuer")
        alert.runModal()
    }

    @objc private func openUI() {
        NSWorkspace.shared.open(uiURL)
    }

    @objc private func startServer() {
        server.start()
    }

    @objc private func stopServer() {
        server.stop()
    }

    @objc private func restartServer() {
        server.restart()
    }

    @objc private func setMemoryLimit(_ sender: NSMenuItem) {
        let gb: Int? = sender.tag == 0 ? nil : sender.tag
        if gb == MemoryLimit.current() {
            return
        }
        do {
            try MemoryLimit.save(gb)
        }
        catch {
            NSAlert(error: error).runModal()
            return
        }
        if server.state == .starting || server.state == .running {
            server.restart()
        }
    }

    @objc private func openModels() {
        openFolder(swarmDir.appendingPathComponent("Models"))
    }

    @objc private func openOutput() {
        openFolder(swarmDir.appendingPathComponent("Output"))
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(logFile)
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            else {
                try SMAppService.mainApp.register()
            }
        }
        catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func openFolder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
