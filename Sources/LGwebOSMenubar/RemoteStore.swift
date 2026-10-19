import SwiftUI
import AppKit

struct TVApp: Identifiable, Codable { let id: String; let title: String; let icon: String? }
struct TVInput: Identifiable { let id: String; let label: String; let connected: Bool; let appID: String }
struct RemoteEvent: Identifiable, Codable { let id: UUID; let date: Date; let title: String; let detail: String
    init(title: String, detail: String) { id = UUID(); date = Date(); self.title = title; self.detail = detail }
}

@MainActor final class RemoteStore: ObservableObject {
    @Published var host = TVConfiguration().host
    @Published var name = TVConfiguration().name
    @Published var model = TVConfiguration().model
    @Published var mac = TVConfiguration().mac
    @Published var connected = false
    @Published var pointerReady = false
    @Published var connecting = false
    @Published var pairing = false
    @Published var discovering = false
    @Published var devices: [TVDevice] = []
    @Published var apps: [TVApp] = []
    @Published var inputs: [TVInput] = []
    @Published var volume: Double = 0
    @Published var hasVolume = false
    @Published var muted = false
    @Published var foregroundID = ""
    @Published var foregroundName = ""
    @Published private var homePresentation = HomePresentation()
    @Published var error: String?
    @Published var notice: String?
    @Published var events: [RemoteEvent] = []
    @Published var firmware = ""
    @Published var webOS = ""
    @Published var picture: [String: Int] = [:]
    @Published var pictureApplying = false
    @Published var usageRevision = 0
    @Published var mediaFile: URL?
    @Published var mediaBusy = false
    @Published var casting = false
    @Published var mediaStatus = "Choose a video, a song, or a photo."
    @Published var preferredPanelHeight: CGFloat = 740
    @Published var favorites = Set(UserDefaults.standard.stringArray(forKey: "tv.favorites") ?? ["netflix", "youtube.leanback.v4", "amazon", "com.disney.disneyplus-prod"])
    /// Lets the panel owner hide the menu bar panel before a modal dialog, so the
    /// dialog is never rendered underneath the floating panel. Setting a higher
    /// window level does not help: runModal resets it to the modal-panel level.
    var dismissMenuBarPanel: (() -> Void)?
    private(set) var connection: WebOSConnection?
    private var connectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private var autoReconnect = false
    private let catalog: [TVApp]
    private let dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("br.local.LGRemote")
    private lazy var journal = UsageJournal(url: dataDirectory.appendingPathComponent("usage.json"))
    private var observers: [NSObjectProtocol] = []
    private var fileServer: MediaFileServer?
    private var transportURL: URL?
    private var powerActive = false
    init() {
        catalog = (try? AppResources.bundle.url(forResource: "app-catalog", withExtension: "json").map {
            try JSONDecoder().decode([TVApp].self, from: Data(contentsOf: $0))
        }) ?? []
        events = (try? JSONDecoder().decode([RemoteEvent].self, from: Data(contentsOf: dataDirectory.appendingPathComponent("events.json")))) ?? []
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pauseUsage() }
        })
    }

    var pinnedApps: [TVApp] { shortcuts.filter { favorites.contains($0.id) } }
    var homeRequested: Bool { homePresentation.requested }
    var displayForegroundID: String { homeRequested ? "com.webos.app.home" : foregroundID }
    var currentInput: TVInput? { homeRequested ? nil : inputs.first { $0.appID == foregroundID } }
    var orderedInputs: [TVInput] {
        inputs.enumerated().sorted { a, b in
            let aActive = a.element.appID == displayForegroundID
            let bActive = b.element.appID == displayForegroundID
            return aActive != bActive ? aActive : a.offset < b.offset
        }.map(\.element)
    }
    func log(_ title: String, _ detail: String) {
        events.insert(RemoteEvent(title: title, detail: detail), at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
        if title != "Read" {
            let persisted = events.filter { $0.title != "Read" }
            do { try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true); try JSONEncoder().encode(persisted).write(to: dataDirectory.appendingPathComponent("events.json"), options: .atomic) }
            catch { notice = "Could not save the local event history." }
        }
    }

    var status: String { pairing ? "Accept the connection on your TV" : connecting ? "Connecting…" : connected ? "Connected" : "Disconnected" }
    var currentApp: String { homeRequested ? "Home menu" : foregroundName.isEmpty ? (connected ? "TV is on" : "Your TV, on your Mac.") : foregroundName }
    var shortcuts: [TVApp] {
        let preferred = ["netflix", "youtube", "amazon", "disney", "globoplay", "spotify", "hbo", "apple"]
        return apps.sorted { a, b in
            if favorites.contains(a.id) != favorites.contains(b.id) { return favorites.contains(a.id) }
            let ai = preferred.firstIndex { a.id.localizedCaseInsensitiveContains($0) } ?? 100
            let bi = preferred.firstIndex { b.id.localizedCaseInsensitiveContains($0) } ?? 100
            return ai != bi ? ai < bi : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
    func connect(allowFirstUseTrust: Bool = true) {
        guard !connecting else { return }
        guard WebOSConnection.localHost(host) else { error = "Enter the TV's local IPv4 address or discover a TV on your network."; return }
        autoReconnect = true; error = nil; connecting = true; pairing = false
        pauseUsage()
        homePresentation.dismiss()
        connection?.close(); refreshTask?.cancel(); pointerReady = false
        let client = WebOSConnection(host: host); connection = client
        client.onCertificateTrust = { [weak self] host, fingerprint in
            // Hide the panel so the trust dialog is visible and clickable.
            self?.dismissMenuBarPanel?()
            return await ConnectionTrustPrompt.confirm(host: host, fingerprint: fingerprint)
        }
        client.onPairing = { [weak self] in self?.pairing = true }
        client.onEvent = { [weak self] title, detail in self?.log(title, detail) }
        client.onPointerState = { [weak self, weak client] ready in
            guard let self, self.connection === client else { return }
            self.pointerReady = ready
        }
        client.onDisconnect = { [weak self, weak client] failure in
            guard let self, self.connection === client else { return }
            self.connected = false; self.pointerReady = false; self.hasVolume = false; self.pointerMotionTask?.cancel(); self.motion = PointerMotion()
            self.homePresentation.dismiss()
            self.pauseUsage()
            self.log("Connection lost", failure.localizedDescription)
            if !self.connecting {
                self.notice = "Connection lost. Reconnecting…"
                self.scheduleReconnect()
            }
        }
        connectTask = Task {
            do {
                try await client.connect(allowFirstUseTrust: allowFirstUseTrust)
                guard connection === client else { return }
                connected = true; connecting = false; pairing = false; notice = nil
                log("Connected", "\(name) · \(host)")
                UserDefaults.standard.set(host, forKey: "tv.host")
                UserDefaults.standard.set(name, forKey: "tv.name")
                UserDefaults.standard.set(mac, forKey: "tv.mac")
                if let system = try? await client.request("system/getSystemInfo"), let detectedModel = system["modelName"] as? String {
                    model = detectedModel
                }
                UserDefaults.standard.set(model, forKey: "tv.model")
                await refresh()
                try? await client.subscribe("audio/getVolume") { [weak self] in self?.updateVolume($0) }
                try? await client.subscribe("com.webos.applicationManager/getForegroundAppInfo") { [weak self] in self?.updateForeground($0) }
                if let info = try? await client.request("com.webos.service.update/getCurrentSWInformation") {
                    firmware = info["major_ver"] as? String ?? ""
                    if let minor = info["minor_ver"] as? String { firmware += "." + minor }
                    if let micro = info["micro_ver"] as? String { firmware += "." + micro }
                    webOS = info["product_name"] as? String ?? ""
                }
                await refreshPicture()
                // Warm up and verify the input socket without issuing any TV input.
                do { try await client.checkPointer(); log("Remote ready", "Navigation connection is ready and verified.") }
                catch { log("Remote unavailable", error.localizedDescription) }
                refreshTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 20_000_000_000)
                        if Task.isCancelled { break }
                        await refreshState()
                    }
                }
            } catch {
                guard connection === client else { return }
                client.close(); connected = false; connecting = false; pairing = false
                self.error = "\(error.localizedDescription) Make sure the TV is on and on the same Wi-Fi network."
                log("Connection failed", error.localizedDescription)
                if allowFirstUseTrust { autoReconnect = false }
                scheduleReconnect()
            }
        }
    }
    private func scheduleReconnect() {
        guard autoReconnect else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if !Task.isCancelled { connect(allowFirstUseTrust: false) } }
    }
    func disconnect() {
        pauseUsage()
        pointerMotionTask?.cancel(); motion = PointerMotion()
        fileServer?.stop(); fileServer = nil; casting = false; transportURL = nil
        autoReconnect = false; connectTask?.cancel(); reconnectTask?.cancel(); refreshTask?.cancel(); volumeTask?.cancel()
        connection?.close(); connection = nil; connected = false; pointerReady = false; connecting = false; pairing = false; hasVolume = false
        foregroundID = ""; foregroundName = ""; apps = []; inputs = []
        homePresentation.dismiss()
    }
    func discover() {
        guard !discovering else { return }; discovering = true; error = nil
        Task { devices = await TVDiscovery.search(); discovering = false; if devices.isEmpty { notice = "No TV found. Turn on your TV or enter its IP address below." } }
    }
    func select(_ tv: TVDevice) {
        disconnect(); host = tv.host; name = tv.name; model = tv.model; mac = tv.mac ?? ""
        connect()
    }
    func refresh() async {
        guard let client = connection, connected else { return }
        do {
            let result = try await client.request("com.webos.applicationManager/listLaunchPoints")
            var seen = Set<String>()
            apps = (result["launchPoints"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["id"] as? String, let title = $0["title"] as? String else { return nil }
                guard seen.insert(id).inserted else { return nil }
                let known = catalog.first(where: { $0.id == id })
                return TVApp(id: id, title: known?.title ?? title, icon: known?.icon)
            }
        } catch { self.error = "Could not list apps: \(error.localizedDescription)" }
        if let result = try? await client.request("tv/getExternalInputList") {
            inputs = (result["devices"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["id"] as? String else { return nil }
                var label = $0["label"] as? String ?? id
                if label.hasPrefix("HDMI"), let children = $0["subList"] as? [[String: Any]],
                   let cecName = children.compactMap({ $0["osdName"] as? String }).first, !cecName.isEmpty {
                    label = cecName
                }
                return TVInput(id: id, label: label, connected: $0["connected"] as? Bool ?? false, appID: $0["appId"] as? String ?? "")
            }
        }
        await refreshState()
    }
    func refreshState() async {
        guard let client = connection, connected else { return }
        if let answer = try? await client.request("com.webos.service.tvpower/power/getPowerState") { powerActive = (answer["state"] as? String)?.lowercased() == "active" }
        else { powerActive = false; pauseUsage() }
        if let answer = try? await client.request("audio/getVolume") { updateVolume(answer) }
        if let answer = try? await client.request("com.webos.applicationManager/getForegroundAppInfo") { updateForeground(answer) }
    }
    private func updateVolume(_ payload: [String: Any]) {
        let p = payload["volumeStatus"] as? [String: Any] ?? payload
        if let number = p["volume"] as? NSNumber { volume = number.doubleValue; hasVolume = true }
        if let mute = p["muteStatus"] as? Bool ?? p["mute"] as? Bool ?? p["muted"] as? Bool { muted = mute }
    }
    private func updateForeground(_ payload: [String: Any]) {
        let previous = foregroundID
        foregroundID = payload["appId"] as? String ?? ""
        homePresentation.observe(appID: foregroundID)
        if foregroundID.hasPrefix("com.webos.app.hdmi") {
            let inputID = "HDMI" + foregroundID.replacingOccurrences(of: "com.webos.app.hdmi", with: "")
            let label = inputs.first(where: { $0.id.replacingOccurrences(of: "_", with: "") == inputID })?.label ?? inputID
            foregroundName = label == inputID ? inputID : "\(label) · \(inputID)"
        } else {
            foregroundName = payload["title"] as? String ?? apps.first(where: { $0.id == foregroundID })?.title ?? "TV is on"
        }
        if previous != foregroundID { log("Reported app", foregroundName) }
        if powerActive && connected && !homeRequested { journal.observe(host: host, appID: foregroundID, title: currentInput?.label ?? foregroundName); saveUsage() }
        else if homeRequested { journal.pause(); saveUsage() }
        else { pauseUsage() }
    }
    func perform(_ action: @escaping (WebOSConnection) async throws -> Void) {
        guard connected, let client = connection else { return }
        error = nil
        Task { do { try await action(client) } catch { self.error = error.localizedDescription; self.log("Command failed", error.localizedDescription) } }
    }
    func press(_ button: String) {
        if button == "HOME" { goHome(); return }
        log("Remote", button); perform {
            try await $0.button(button)
            if ["BACK", "EXIT"].contains(button) { self.homePresentation.dismiss(); await self.refreshState() }
        }
    }
    @Published var navigatingHome = false
    func goHome() {
        guard connected, !navigatingHome, let client = connection else { return }
        navigatingHome = true; error = nil
        log("Remote", "HOME · close the app and open the menu")
        Task {
            defer { navigatingHome = false }
            do {
                // Home on webOS 5 overlays the running app. Close a foreground user app first;
                // never close an HDMI input, the launcher or a system service.
                let foreground = try await client.request("com.webos.applicationManager/getForegroundAppInfo")
                let id = foreground["appId"] as? String ?? ""
                try await HomeNavigation.run(appID: id, installedApps: Set(apps.map(\.id)), closeApp: { appID in
                    self.log("Close app", self.apps.first { $0.id == appID }?.title ?? appID)
                    _ = try await client.request("system.launcher/close", ["id": appID])
                }, pressHome: {
                    try await client.button("HOME")
                    // Read the app underneath after closing; keep Home presentation across polls.
                    await self.refreshState()
                    self.homePresentation.didSendHome(underlyingID: self.foregroundID)
                    self.journal.pause(); self.saveUsage()
                })
                await refreshState()
            } catch { self.error = error.localizedDescription; log("Could not open Home", error.localizedDescription) }
        }
    }
    private var motion = PointerMotion()
    private var pointerMotionTask: Task<Void, Never>?
    func movePointer(dx: Int, dy: Int) {
        guard connected, let client = connection, dx != 0 || dy != 0 else { return }
        motion.add(dx: dx, dy: dy)
        guard pointerMotionTask == nil else { return }
        pointerMotionTask = Task {
            defer { pointerMotionTask = nil }
            do {
                while !Task.isCancelled && connected && connection === client && !motion.isEmpty {
                    let delta = motion.next()
                    try await client.move(dx: delta.dx, dy: delta.dy)
                    try await Task.sleep(nanoseconds: 16_000_000)
                }
            } catch {
                motion = PointerMotion()
                if !Task.isCancelled { self.error = error.localizedDescription; log("Pointer failed", error.localizedDescription) }
            }
        }
    }
    func clickPointer() { log("Remote", "OK / click"); perform { try await $0.click(); self.homePresentation.dismiss(); await self.refreshState() } }
    func launch(_ app: TVApp) {
        log("Launch app", app.title)
        perform { client in _ = try await client.request("system.launcher/launch", ["id": app.id]); self.homePresentation.dismiss(); try? await Task.sleep(nanoseconds: 600_000_000); await self.refreshState() }
    }
    func changeVolume(_ value: Double) {
        volume = min(100, max(0, value)); volumeTask?.cancel()
        volumeTask = Task {
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, let client = connection, connected else { return }
            do { _ = try await client.request("audio/setVolume", ["volume": Int(volume)]); await refreshState() }
            catch { self.error = error.localizedDescription }
        }
    }
    func volumeStep(_ up: Bool) { perform { client in _ = try await client.request(up ? "audio/volumeUp" : "audio/volumeDown"); await self.refreshState() } }
    func toggleMute() { perform { client in _ = try await client.request("audio/setMute", ["mute": !self.muted]); await self.refreshState() } }
    func input(_ input: TVInput) { log("Switch input", input.label); perform { client in _ = try await client.request("tv/switchInput", ["inputId": input.id]); self.homePresentation.dismiss(); try? await Task.sleep(nanoseconds: 500_000_000); await self.refreshState() } }
    func media(_ command: String) { perform { _ = try await $0.request("media.controls/" + command) } }
    func sendText(_ text: String) { guard !text.isEmpty else { return }; perform { _ = try await $0.request("com.webos.service.ime/insertText", ["text": text, "replace": 0]) } }
    func enterText() { perform { _ = try await $0.request("com.webos.service.ime/sendEnterKey") } }
    func toggleFavorite(_ app: TVApp) {
        if favorites.contains(app.id) { favorites.remove(app.id) } else { favorites.insert(app.id) }
        UserDefaults.standard.set(Array(favorites), forKey: "tv.favorites")
    }
    func refreshPicture() async {
        guard let client = connection, connected else { return }
        if let result = try? await client.request("settings/getSystemSettings", ["category": "picture", "keys": ["contrast", "backlight", "brightness", "color"]]), let settings = result["settings"] as? [String: Any] {
            picture = settings.compactMapValues { ($0 as? NSNumber)?.intValue ?? ($0 as? String).flatMap(Int.init) }
        }
    }
    private func saveUsage() {
        do { try journal.save() } catch { notice = "Could not save usage history." }
        usageRevision += 1
    }
    private func pauseUsage() { journal.pause(); saveUsage(); powerActive = false }
    func usage(days: Int) -> [UsageTotal] {
        let since = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-Double(max(0, days - 1)) * 86400)
        return journal.totals(host: host, since: since)
    }
    var mostUsedApps: [TVApp] { usage(days: 7).compactMap { total in apps.first { $0.id == total.id } } }
    func applyPicture(_ settings: [String: Int]) {
        guard connected, let client = connection, !pictureApplying else { return }
        let allowed = Set(["backlight", "brightness", "contrast", "color"])
        let validated = settings.filter { allowed.contains($0.key) }.mapValues { min(100, max(0, $0)) }
        pictureApplying = true; error = nil
        Task {
            defer { pictureApplying = false }
            do {
                _ = try await client.request("settings/setSystemSettings", ["category": "picture", "settings": validated])
                await refreshPicture()
                guard validated.allSatisfy({ picture[$0.key] == $0.value }) else { throw RemoteError.message("The TV did not confirm these settings. The displayed values have been read again.") }
                notice = "Picture updated."; log("Picture", "Picture settings applied.")
            } catch { await refreshPicture(); self.error = "Settings are unavailable on this connection: \(error.localizedDescription)" }
        }
    }
    func chooseMedia() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.movie, .audio, .image]; picker.prompt = "Select"; picker.title = "Send media to your LG TV"
        if picker.runModal() == .OK { mediaFile = picker.url; mediaStatus = "Ready to send. This will open the file on your TV." }
    }
    func castMedia() {
        guard !mediaBusy, connected, let file = mediaFile else { return }
        mediaBusy = true; error = nil
        let targetHost = host
        Task {
            defer { mediaBusy = false }
            var newServer: MediaFileServer?
            do {
                let control = try await DLNATransport.discover(host: targetHost)
                let server = MediaFileServer(file: file, allowedHost: targetHost); newServer = server
                let url = try await server.start()
                _ = try await DLNATransport.command(control, action: "SetAVTransportURI", parameters: [("CurrentURI", url.absoluteString), ("CurrentURIMetaData", DLNATransport.metadata(url: url, title: file.lastPathComponent, mime: server.mime))])
                _ = try await DLNATransport.command(control, action: "Play", parameters: [("Speed", "1")])
                fileServer?.stop(); fileServer = server; transportURL = control; casting = true
                mediaStatus = "Sent to TV · \(file.lastPathComponent)"; log("Send media", file.lastPathComponent)
            } catch { newServer?.stop(); self.error = error.localizedDescription; mediaStatus = "Could not play this file." }
        }
    }
    func controlCast(_ action: String) {
        guard casting, !mediaBusy, let control = transportURL, ["Play", "Pause", "Stop"].contains(action) else { return }
        mediaBusy = true
        Task {
            defer { mediaBusy = false }
            do {
                _ = try await DLNATransport.command(control, action: action, parameters: action == "Play" ? [("Speed", "1")] : [])
                if action == "Stop" { fileServer?.stop(); fileServer = nil; casting = false; mediaStatus = "Casting stopped." }
                else { mediaStatus = action == "Pause" ? "Media paused on TV." : "Playing on TV." }
            } catch { self.error = error.localizedDescription }
        }
    }
    func power() {
        if connected { perform { client in _ = try await client.request("system/turnOff"); self.disconnect(); self.notice = "TV turned off." } }
        else {
            do { try TVDiscovery.wake(mac: mac, host: host); notice = "Wake signal sent. Enable Wi-Fi wake on the TV first." }
            catch { self.error = error.localizedDescription }
        }
    }
    func forgetPairing() {
        guard !host.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Forget this TV's pairing?"
        alert.informativeText = "The saved key and certificate for this TV will be removed from this Mac. You can connect and pair again."
        alert.addButton(withTitle: "Forget pairing"); alert.addButton(withTitle: "Cancel")
        // Hide the panel first so this modal cannot be rendered underneath it,
        // the same hidden-dialog issue as the certificate trust prompt.
        dismissMenuBarPanel?()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pairingHost = host
        disconnect()
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try PairingKey.delete(pairingHost) }.value
                notice = "Saved pairing removed. Connect to pair this TV again."
            } catch {
                self.error = "Could not remove saved pairing: \(error.localizedDescription)"
            }
        }
    }
}
