import Foundation
import AppKit

enum FeatureChecks {
    static func equal<T: Equatable>(_ a: T, _ b: T) throws { guard a == b else { throw RemoteError.message("Check failed: \(a) != \(b)") } }
    static func truth(_ value: Bool) throws { guard value else { throw RemoteError.message("Check failed") } }
    static func rejects(_ operation: () throws -> Void) throws { do { try operation() } catch { return }; throw RemoteError.message("Expected rejection") }
    static func run() async throws {
        try testPackagedResourcesLoadWithoutDeviceConfiguration()
        try testUsageSurvivesRestartAndClipsMidnightWithoutCountingSleep()
        try testHTTPRangeSupportsSeekSuffixAndRejectsInvalidRanges()
        try await testMediaServerStreamsOnlySelectedFileAndSupportsHeadAndRange()
        try testSOAPMetadataEscapesUserFilenameAndURL()
        try await testPointerConnectionAndRecovery()
        try await testPointerPreflightRecoveryDoesNotReplayCommands()
        try await testPointerCloseCancelsPendingInput()
        try testPointerMotionKeepsEveryDelta()
        try await testHomeClosesUserAppOnceWithoutLaunchingAnything()
        try await testCancelledHomeDoesNotSendAnotherCommand()
        try testHomePresentationSurvivesRepeatedUnderlyingAppReports()
        try testConnectionAcceptsOnlyLocalIPv4Addresses()
        try testCertificateTrustRequiresApprovalAndRejectsChangedPins()
        try testFreshConfigurationHasNoDeviceIdentityAndLoadsCustomParameters()
        print("PASS: packaged registration, catalog and images; usage persistence, midnight clipping, sleep exclusion; HTTP GET/HEAD/Range/404/416; XML escaping; pointer ordering, closure/reconnection, preflight recovery, cancellation, no duplicate clicks, full drag motion; Home closes user apps once, preserves HDMI/system apps, respects cancellation; Home presentation survives polling and clears on navigation/app changes; local IPv4 boundaries, certificate trust, fresh configuration and custom parameters.")
    }

    static func testPackagedResourcesLoadWithoutDeviceConfiguration() throws {
        guard let registrationURL = AppResources.bundle.url(forResource: "registration", withExtension: "json"),
              let registration = try JSONSerialization.jsonObject(with: Data(contentsOf: registrationURL)) as? [String: Any],
              let manifest = registration["manifest"] as? [String: Any],
              let signatures = manifest["signatures"] as? [[String: Any]],
              let permissions = manifest["permissions"] as? [String] else {
            throw RemoteError.message("The packaged pairing manifest is missing or invalid")
        }
        try equal(registration["pairingType"] as? String, "PROMPT")
        try truth(registration["client-key"] == nil)
        try truth(permissions.contains("LAUNCH"))
        try truth(signatures.contains { !($0["signature"] as? String ?? "").isEmpty })
        try truth(WebOSConnection.rejectsSignedManifest("403 Pairing rejected: blacklisted certificate detected"))
        try truth(!WebOSConnection.rejectsSignedManifest("403 cancelled"))
        try truth(WebOSConnection.endsPairingAttempt("403 User denied access"))
        try truth(!WebOSConnection.endsPairingAttempt("400 invalid manifest"))
        let basic = WebOSConnection.unsignedRegistration(registration, extended: false)["manifest"] as? [String: Any] ?? [:]
        try truth(basic["signed"] == nil && basic["signatures"] == nil)
        try equal(basic["permissions"] as? [String], permissions)
        let extended = WebOSConnection.unsignedRegistration(registration, extended: true)
        let extendedPermissions = (extended["manifest"] as? [String: Any])?["permissions"] as? [String] ?? []
        try truth(extendedPermissions.contains("READ_INSTALLED_APPS") && !extendedPermissions.contains("TEST_SECURE"))
        try equal(Set(extendedPermissions).count, extendedPermissions.count)
        try equal(extended["pairingType"] as? String, "PROMPT")
        guard let catalogURL = AppResources.bundle.url(forResource: "app-catalog", withExtension: "json") else {
            throw RemoteError.message("The packaged app catalog is missing")
        }
        let apps = try JSONDecoder().decode([TVApp].self, from: Data(contentsOf: catalogURL))
        try truth(!apps.isEmpty)
        try equal(Set(apps.map(\.id)).count, apps.count)
        for app in apps {
            try truth(!app.id.isEmpty && !app.title.isEmpty)
            guard let icon = app.icon, !icon.contains("/"), !icon.contains(".."),
                  let url = AppResources.bundle.url(forResource: icon, withExtension: nil, subdirectory: "AppAssets"),
                  let image = NSImage(contentsOf: url) else {
                throw RemoteError.message("A packaged catalog icon is missing or invalid")
            }
            try truth(image.isValid)
        }
        for name in ["lg", "playstation", "googlecast", "tv-hero"] {
            guard let url = AppResources.bundle.url(forResource: name, withExtension: "png", subdirectory: "AppAssets"),
                  let image = NSImage(contentsOf: url), image.isValid else {
                throw RemoteError.message("A packaged brand image is missing or invalid")
            }
        }
    }

    static func testConnectionAcceptsOnlyLocalIPv4Addresses() throws {
        let allowed = [[10, 0, 0, 0], [10, 255, 255, 255], [172, 16, 0, 0], [172, 31, 255, 255], [192, 168, 0, 0], [192, 168, 255, 255], [169, 254, 1, 1], [169, 254, 254, 254]]
        for octets in allowed {
            try truth(WebOSConnection.localHost(octets.map(String.init).joined(separator: ".")))
        }
        for host in ["9.255.255.255", "11.0.0.0", "172.15.255.255", "172.32.0.0", "192.167.255.255", "192.169.0.0", "169.253.255.255", "169.255.0.0", "127.0.0.1", "0.0.0.0", "8.8.8.8", "255.255.255.255", "192.168.1.256", "192.168.1", "localhost", "", "::1"] {
            try truth(!WebOSConnection.localHost(host))
        }
    }
    static func testCertificateTrustRequiresApprovalAndRejectsChangedPins() throws {
        try equal(TVCertificatePolicy.decide(expected: "saved-pin", received: "saved-pin", canApprove: false), .matched)
        try equal(TVCertificatePolicy.decide(expected: "saved-pin", received: "saved-pin", canApprove: true), .matched)
        try equal(TVCertificatePolicy.decide(expected: "saved-pin", received: "changed-pin", canApprove: true), .rejected)
        try equal(TVCertificatePolicy.decide(expected: nil, received: "new-pin", canApprove: false), .rejected)
        try equal(TVCertificatePolicy.decide(expected: nil, received: "new-pin", canApprove: true), .approvalRequired)
    }
    static func testFreshConfigurationHasNoDeviceIdentityAndLoadsCustomParameters() throws {
        let suite = "LGwebOSMenubar.FeatureChecks." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw RemoteError.message("Could not create isolated test preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = TVConfiguration(defaults: defaults)
        try equal(fresh.host, "")
        try equal(fresh.name, "LG TV")
        try equal(fresh.model, "")
        try equal(fresh.mac, "")
        let address = "203.0.113.10"
        let mac = ["00", "11", "22", "33", "44", "55"].joined(separator: ":")
        defaults.set(address, forKey: "tv.host")
        defaults.set("Test TV", forKey: "tv.name")
        defaults.set("Test model", forKey: "tv.model")
        defaults.set(mac, forKey: "tv.mac")
        let configured = TVConfiguration(defaults: defaults)
        try equal(configured.host, address)
        try equal(configured.name, "Test TV")
        try equal(configured.model, "Test model")
        try equal(configured.mac, mac)
    }

    static func testUsageSurvivesRestartAndClipsMidnightWithoutCountingSleep() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage.json")
        let midnight = Date(timeIntervalSince1970: 86400 * 20000)
        let journal = UsageJournal(url: file)
        journal.observe(host: "tv", appID: "netflix", title: "Netflix", at: midnight.addingTimeInterval(-10))
        journal.observe(host: "tv", appID: "youtube", title: "YouTube", at: midnight.addingTimeInterval(10))
        journal.observe(host: "tv", appID: "youtube", title: "YouTube", at: midnight.addingTimeInterval(30))
        // An hour offline must contribute zero seconds, even for the same app.
        journal.observe(host: "tv", appID: "youtube", title: "YouTube", at: midnight.addingTimeInterval(3630))
        journal.pause(at: midnight.addingTimeInterval(3640))
        try journal.save()
        let restored = UsageJournal(url: file)
        let totals = restored.totals(host: "tv", since: midnight, until: midnight.addingTimeInterval(4000))
        try equal(totals.first?.id, "youtube")
        try equal(totals.first?.seconds, 30)
        try equal(totals.last?.seconds, 10)
        try truth(restored.totals(host: "other", since: midnight).isEmpty)
    }
    static func testHTTPRangeSupportsSeekSuffixAndRejectsInvalidRanges() throws {
        let seek = try MediaHTTP.range("bytes=5-12", size: 10)
        try equal(seek.start, 5); try equal(seek.end, 9); try truth(seek.partial)
        try equal(try MediaHTTP.range("bytes=-3", size: 10).start, 7)
        try equal(try MediaHTTP.range("bytes=3-", size: 10).end, 9)
        try rejects { _ = try MediaHTTP.range("bytes=10-", size: 10) }
        try rejects { _ = try MediaHTTP.range("bytes=6-2", size: 10) }
        try rejects { _ = try MediaHTTP.range("bytes=0-1,4-5", size: 10) }
    }
    static func testMediaServerStreamsOnlySelectedFileAndSupportsHeadAndRange() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data("0123456789".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let server = MediaFileServer(file: file, allowedHost: "127.0.0.1")
        let url = try await server.start()
        defer { server.stop() }
        var request = URLRequest(url: url); request.setValue("bytes=3-6", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        try equal((response as? HTTPURLResponse)?.statusCode, 206)
        try equal(String(decoding: data, as: UTF8.self), "3456")
        request.httpMethod = "HEAD"
        let (empty, head) = try await URLSession.shared.data(for: request)
        try truth(empty.isEmpty)
        try equal((head as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), "4")
        request.httpMethod = "GET"; request.setValue("bytes=99-", forHTTPHeaderField: "Range")
        let (_, invalid) = try await URLSession.shared.data(for: request)
        try equal((invalid as? HTTPURLResponse)?.statusCode, 416)
        let (_, absent) = try await URLSession.shared.data(from: url.deletingLastPathComponent().appendingPathComponent("secret"))
        try equal((absent as? HTTPURLResponse)?.statusCode, 404)
    }
    static func testSOAPMetadataEscapesUserFilenameAndURL() throws {
        let metadata = DLNATransport.metadata(url: URL(string: "http://127.0.0.1/a?x=1&y=2")!, title: "A < B & C", mime: "video/mp4")
        let envelope = DLNATransport.envelope(action: "SetAVTransportURI", parameters: [("CurrentURIMetaData", metadata)])
        try truth(XMLParser(data: Data(envelope.utf8)).parse())
        try truth(metadata.contains("A &lt; B &amp; C"))
        try truth(envelope.contains("&lt;DIDL-Lite"))
    }
    static func testPointerMotionKeepsEveryDelta() throws {
        var motion = PointerMotion()
        motion.add(dx: 10, dy: 2)
        let first = motion.next()
        // Additional gesture samples arrive while the first send is in progress.
        motion.add(dx: 160, dy: -40); motion.add(dx: 75, dy: -5)
        var x = first.dx, y = first.dy
        while !motion.isEmpty { let delta = motion.next(); x += delta.dx; y += delta.dy; try truth(abs(delta.dx) <= 80 && abs(delta.dy) <= 80) }
        try equal(x, 245); try equal(y, -43)
        try equal(PointerMessage.click, "type:click\n\n")
    }
    static func testHomePresentationSurvivesRepeatedUnderlyingAppReports() throws {
        var state = HomePresentation()
        state.didSendHome(underlyingID: "youtube.leanback.v4")
        for _ in 0..<100 { state.observe(appID: "youtube.leanback.v4") }
        try truth(state.requested)
        state.observe(appID: "com.webos.app.hdmi2")
        try truth(!state.requested)
        state.didSendHome(underlyingID: "com.webos.app.hdmi2")
        state.dismiss() // User selects the same underlying input or presses Back/OK.
        state.observe(appID: "com.webos.app.hdmi2")
        try truth(!state.requested)
        state.didSendHome(underlyingID: "")
        state.observe(appID: "")
        try truth(state.requested)
        state.observe(appID: "netflix")
        try truth(!state.requested)
    }
    @MainActor static func testHomeClosesUserAppOnceWithoutLaunchingAnything() async throws {
        var actions: [String] = []
        let installed: Set<String> = ["youtube.leanback.v4", "com.webos.app.browser"]
        try await HomeNavigation.run(appID: "youtube.leanback.v4", installedApps: installed, closeApp: { actions.append("close:\($0)") }, pressHome: { actions.append("HOME") })
        try equal(actions, ["close:youtube.leanback.v4", "HOME"])
        for id in ["com.webos.app.hdmi2", "com.webos.app.browser", "com.webos.app.livetv", "", "unknown"] {
            actions = []
            try await HomeNavigation.run(appID: id, installedApps: installed, closeApp: { actions.append("close:\($0)") }, pressHome: { actions.append("HOME") })
            try equal(actions, ["HOME"])
        }
        actions = []; var reportedFailure = false
        do {
            try await HomeNavigation.run(appID: "youtube.leanback.v4", installedApps: installed, closeApp: { actions.append("close:\($0)"); throw RemoteError.message("TV refusal") }, pressHome: { actions.append("HOME") })
        } catch { reportedFailure = true }
        try truth(reportedFailure); try equal(actions, ["close:youtube.leanback.v4", "HOME"])
    }
    @MainActor static func testPointerConnectionAndRecovery() async throws {
        let first = FakePointerTransport(), second = FakePointerTransport(), third = FakePointerTransport()
        var opens = 0
        let channel = PointerChannel {
            opens += 1
            try await Task.sleep(nanoseconds: 20_000_000)
            return opens == 1 ? first : opens == 2 ? second : third
        }
        defer { channel.close() }
        let left = Task { try await channel.send(PointerMessage.button("LEFT")) }
        while opens == 0 { await Task.yield() }
        let right = Task { try await channel.send(PointerMessage.button("RIGHT")) }
        try await left.value; try await right.value
        try equal(opens, 1)
        try equal(first.messages, [PointerMessage.button("LEFT"), PointerMessage.button("RIGHT")])
        first.close()
        try await channel.check()
        try equal(opens, 2); try truth(second.messages.isEmpty)
        second.failSend = true
        var failedClick = false
        do { try await channel.send(PointerMessage.click) } catch { failedClick = true }
        try truth(failedClick); try equal(second.sendAttempts, 1); try equal(opens, 2)
        // Only a subsequent user action opens a new connection. No replay of the failed click.
        try await channel.send(PointerMessage.click)
        try equal(opens, 3); try equal(third.messages, [PointerMessage.click])
    }
    @MainActor static func testCancelledHomeDoesNotSendAnotherCommand() async throws {
        var actions: [String] = []
        let operation = Task { @MainActor in
            try await HomeNavigation.run(appID: "netflix", installedApps: ["netflix"], closeApp: { id in
                actions.append("close:\(id)")
                withUnsafeCurrentTask { $0?.cancel() }
            }, pressHome: { actions.append("HOME") })
        }
        var cancelled = false
        do { try await operation.value } catch is CancellationError { cancelled = true }
        try truth(cancelled)
        try equal(actions, ["close:netflix"])
    }
    @MainActor static func testPointerPreflightRecoveryDoesNotReplayCommands() async throws {
        let first = FakePointerTransport(), replacement = FakePointerTransport()
        var opens = 0
        let channel = PointerChannel { opens += 1; return opens == 1 ? first : replacement }
        defer { channel.close() }
        try await channel.send(PointerMessage.button("HOME"))
        first.failPing = true
        try await channel.check()
        try equal(opens, 2)
        try truth(first.closed)
        try equal(first.messages, [PointerMessage.button("HOME")])
        try truth(replacement.messages.isEmpty)
        try await channel.send(PointerMessage.button("BACK"))
        try equal(replacement.messages, [PointerMessage.button("BACK")])
    }
    @MainActor static func testPointerCloseCancelsPendingInput() async throws {
        let transport = FakePointerTransport()
        var opening = false
        let channel = PointerChannel {
            opening = true
            try await Task.sleep(nanoseconds: 20_000_000)
            return transport
        }
        let operation = Task { try await channel.send(PointerMessage.click) }
        for _ in 0..<1000 where !opening { await Task.yield() }
        try truth(opening)
        channel.close()
        var cancelled = false
        do { try await operation.value } catch is CancellationError { cancelled = true }
        try truth(cancelled)
        try equal(transport.sendAttempts, 0)
        do { try await channel.send(PointerMessage.click); throw RemoteError.message("Closed channel accepted input") }
        catch is CancellationError { }
        try equal(transport.sendAttempts, 0)
    }
}

@MainActor private final class FakePointerTransport: PointerTransport {
    var messages: [String] = []
    var sendAttempts = 0
    var failSend = false
    var failPing = false
    var closed = false
    func send(_ message: String) async throws {
        sendAttempts += 1
        guard !closed, !failSend else { throw RemoteError.message("Simulated send failure") }
        messages.append(message)
    }
    func receive() async throws {
        while !closed { try await Task.sleep(nanoseconds: 5_000_000) }
        throw RemoteError.message("Simulated server closure")
    }
    func ping() async throws { if closed || failPing { throw RemoteError.message("Simulated failed ping") } }
    func close() { closed = true }
}
