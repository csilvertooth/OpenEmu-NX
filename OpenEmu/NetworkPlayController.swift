// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
import Cocoa
import CoreData
import Network

private final class NetworkPlayNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Only bounded, typed progress crosses from the file reader to the UI actor.
private struct NetworkPlayProgress: Sendable {
    let resumed: UInt64
    let total: UInt64
    let confirmed: UInt64
    let videoFrames: UInt64
    let saved: UInt64
    let saveError: String
    let lobbyReconnecting: Bool
    let networkRoute: String
    let networkRTT: Int

    nonisolated static func read(_ url: URL) -> NetworkPlayProgress? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Reports are a few KB. A partial atomic replacement or malformed report
        // is ignored until the next poll rather than presented as a game error.
        guard let data = try? handle.read(upToCount: 65_537), data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func number(_ key: String) -> UInt64 { (object[key] as? NSNumber)?.uint64Value ?? 0 }
        return NetworkPlayProgress(resumed: number("resume_frame"), total: number("resume_total"),
                                   confirmed: number("confirmed_frame"), videoFrames: number("received_video_frames"),
                                   saved: number("save_completed_frame"),
                                   saveError: String((object["save_error"] as? String ?? "").prefix(512)),
                                   lobbyReconnecting: object["lobby_reconnecting"] as? Bool ?? false,
                                   networkRoute: object["network_route"] as? String ?? "connecting",
                                   networkRTT: (object["network_rtt_ms"] as? NSNumber)?.intValue ?? -1)
    }
}

@MainActor
final class NetworkPlayController: NSObject, NSMenuItemValidation, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTabViewDelegate {
    static let shared = NetworkPlayController()
    private let defaults = UserDefaults.standard
    private let prefix = "networkPlay."
    private var panel: NSWindow!
    private let tabs = NSTabView()
    private let name = NSTextField(string: "")
    private let endpoint = NSTextField(string: "")
    private let route = NSPopUpButton()
    private let stunProvider = NSPopUpButton()
    private let customSTUN = NSTextField(string: "")
    private let networkResult = NSTextField(wrappingLabelWithString: "Check this network before playing. Direct connectivity is confirmed when both players connect.")
    private var networkCheckRunning = false
    private var liveRoute = "connecting"
    private var liveRTT = -1
    private let delay = NSPopUpButton()
    private let title = NSTextField(string: "")
    private let publicRoom = NSButton(checkboxWithTitle: "List this game publicly", target: nil, action: nil)
    private let protectedRoom = NSButton(checkboxWithTitle: "Require a room password", target: nil, action: nil)
    private let password = NSSecureTextField(string: "")
    private let shareROM = NSButton(checkboxWithTitle: "Allow Player 2 to download this ROM", target: nil, action: nil)
    private var transferProcess: Process?
    private let cancelTransferButton = NSButton(title: "Cancel ROM Transfer", target: nil, action: nil)
    private let spectators = NSButton(checkboxWithTitle: "Allow spectators", target: nil, action: nil)
    private let spectatorLimit = NSPopUpButton()
    private let invite = NSTextField(string: "")
    private let joinPassword = NSSecureTextField(string: "")
    private let joinRole = NSPopUpButton()
    private let roomList = NSTableView()
    private let relayTable = NSTableView()
    private let relayPicker = NSPopUpButton()
    private var relays: [[String: String]] = [["id": "nx-west", "name": "OpenEmu-NX US West", "endpoint": "https://netplay.azimuthsystems.net", "region": "US West", "operator": "OpenEmu-NX"]]
    private var relayStatus: [String: String] = [:]
    private var catalogMessage = ""
    private var directoryURL: URL? { (Bundle.main.object(forInfoDictionaryKey: "NXRelayDirectoryURL") as? String).flatMap(URL.init(string:)) }

    private let browsePassword = NSSecureTextField(string: "")
    private let browseRole = NSPopUpButton()
    private let gameLabel = NSTextField(wrappingLabelWithString: "Choose a game from your OpenEmu library.")
    private let status = NSTextField(wrappingLabelWithString: "Not connected to a room.")
    private let roomStatus = NSTextField(wrappingLabelWithString: "")
    private var operationButtons: [NSButton] = []
    private var createButton: NSButton!
    private var joinButton: NSButton!
    private var browseJoinButton: NSButton!
    private var leaveButton: NSButton!
    private var copyButton: NSButton!
    private var updateButton: NSButton!
    private var chooseButton: NSButton!
    private var saveButton: NSButton!
    private var launchButton: NSButton!
    private var resumeGameButton: NSButton!
    private var newGameButton: NSButton!
    private let resumeLabel = NSTextField(wrappingLabelWithString: "Start a new multiplayer game.")
    private var resumeURL: URL?
    private var currentAutosaveURL: URL?
    private var gameProcess: Process?
    private var gameStopping = false
    private var lastGameError: String?
    private var gameMessage: String?
    private var progressTask: Task<Void, Never>?
    private var progressID: UUID?
    private var progressURL: URL?
    private var lastSavedFrame: UInt64 = 0
    private var selectedROM: OEDBRom?
    private var libraryBrowser: NetworkPlayLibraryBrowser?
    private var room: [String: Any]?
    private var memberToken = ""
    private var activeEndpoint: URL?
    private var listedRooms: [[String: Any]] = []
    private var heartbeatTask: Task<Void, Never>?
    private var busy = false
    private var heartbeatInFlight = false
    private var gameConnected = false
    private var gameLaunching = false
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: NetworkPlayNoRedirect(), delegateQueue: nil)
    }()

    func installMenu() {
        guard let main = NSApp.mainMenu, main.item(withTitle: "Network Play") == nil else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelProgress(); self?.gameProcess?.terminate() }
        }
        let menu = NSMenu(title: "Network Play")
        for (label, action) in [("Host Game…", #selector(showHost)), ("Join with Invite…", #selector(showJoin)),
                                ("Browse Games…", #selector(showBrowse)), ("Show Room…", #selector(showRoom)),
                                ("Copy Invite", #selector(copyInvite)), ("Leave Room", #selector(leaveRoom)),
                                ("Export Multiplayer Save…", #selector(saveMultiplayerGame)),
                                ("Relay Directory…", #selector(showRelays)),
                                ("Network Play Settings…", #selector(showSettings))] {
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        let root = NSMenuItem(title: "Network Play", action: nil, keyEquivalent: "")
        root.submenu = menu
        let helpIndex = main.items.firstIndex(where: { $0.submenu == NSApp.helpMenu }) ?? main.numberOfItems
        main.insertItem(root, at: helpIndex)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copyInvite) { return room?["role"] as? String == "host" && room?["invite_code"] is String }
        if item.action == #selector(leaveRoom) { return room != nil && !busy }
        if item.action == #selector(saveMultiplayerGame) {
            return !busy && currentAutosaveURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
        }
        return true
    }
    @objc private func showHost() { show(0) }
    @objc private func showJoin() { show(1) }
    @objc private func showBrowse() { show(2); if !busy { refreshDirectory() } }
    @objc private func showRelays() { show(3); if !busy { refreshDirectory() } }
    @objc private func showSettings() { show(4) }
    @objc private func showRoom() { show(0) }
    private func show(_ index: Int) {
        if panel == nil { buildWindow() }
        tabs.selectTabViewItem(at: index)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func label(_ value: String) -> NSTextField { NSTextField(wrappingLabelWithString: value) }
    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let caption = label(title); caption.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let stack = NSStackView(views: [caption, control]); stack.orientation = .horizontal; stack.spacing = 12
        control.widthAnchor.constraint(equalToConstant: 360).isActive = true
        return stack
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded; operationButtons.append(result); return result
    }
    private func tab(_ title: String, _ views: [NSView]) {
        let item = NSTabViewItem(identifier: title); item.label = title
        let holder = NSView(); let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; holder.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 20),
                                     stack.topAnchor.constraint(equalTo: holder.topAnchor, constant: 20),
                                     stack.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -20),
                                     stack.bottomAnchor.constraint(lessThanOrEqualTo: holder.bottomAnchor, constant: -20)])
        for view in views where view is NSScrollView {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            let preferredHeight = view.heightAnchor.constraint(equalTo: holder.heightAnchor, constant: -170)
            preferredHeight.priority = .defaultHigh
            preferredHeight.isActive = true
        }
        item.view = holder; tabs.addTabViewItem(item)
    }
    private func buildWindow() {
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 840),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = "Network Play"; panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 760, height: 820)
        panel.center()
        name.stringValue = defaults.string(forKey: prefix + "displayName") ?? "Player"
        endpoint.stringValue = defaults.string(forKey: prefix + "endpoint") ?? "https://netplay.azimuthsystems.net"
        route.addItems(withTitles: ["Automatic (direct or relay)", "Direct only", "Relay only"])
        // Earlier test builds persisted Relay only. New sessions prefer direct ICE.
        if !defaults.bool(forKey: prefix + "automaticRoutingV1") {
            defaults.set(0, forKey: prefix + "route")
            defaults.set(true, forKey: prefix + "automaticRoutingV1")
        }
        route.selectItem(at: min(max(defaults.integer(forKey: prefix + "route"), 0), 2))
        stunProvider.addItems(withTitles: ["Cloudflare (public)", "Custom STUN server", "Lobby-provided STUN"])
        stunProvider.selectItem(at: min(max(defaults.integer(forKey: prefix + "stunProvider"), 0), 2))
        customSTUN.stringValue = defaults.string(forKey: prefix + "customSTUN") ?? ""
        customSTUN.placeholderString = "stun.example.com:3478"
        delay.addItems(withTitles: (1...12).map { "\($0) frames" })
        delay.selectItem(at: min(max(defaults.integer(forKey: prefix + "delay") - 1, 0), 11))
        if defaults.object(forKey: prefix + "delay") == nil { delay.selectItem(at: 2) }
        title.stringValue = "Super Mario Kart with friends"
        publicRoom.state = defaults.bool(forKey: prefix + "public") ? .on : .off
        protectedRoom.state = defaults.bool(forKey: prefix + "passwordRequired") ? .on : .off
        spectators.state = defaults.bool(forKey: prefix + "spectators") ? .on : .off
        spectatorLimit.addItems(withTitles: (1...16).map(String.init))
        spectatorLimit.selectItem(at: min(max(defaults.integer(forKey: prefix + "spectatorLimit") - 1, 0), 15))
        if defaults.object(forKey: prefix + "spectatorLimit") == nil { spectatorLimit.selectItem(at: 3) }
        for control in [protectedRoom, spectators] { control.target = self; control.action = #selector(optionsChanged) }
        for popup in [joinRole, browseRole] { popup.addItems(withTitles: ["Player", "Spectator"]); popup.setAccessibilityLabel("Join as") }
        for field in [password, joinPassword, browsePassword] { field.placeholderString = "Room password (if required)"; field.setAccessibilityLabel("Room password") }
        name.setAccessibilityLabel("Display name"); endpoint.setAccessibilityLabel("Lobby server")
        title.setAccessibilityLabel("Room name"); invite.setAccessibilityLabel("Invite code")
        invite.delegate = self; invite.placeholderString = "ABCD-EFGH"
        // Selection belongs to this library, not to an arbitrary external path.
        defaults.removeObject(forKey: prefix + "gamePath")
        if let context = OELibraryDatabase.default?.mainThreadContext,
           let saved = defaults.string(forKey: prefix + "romID"), let uri = URL(string: saved),
           let id = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: uri),
           let rom = try? context.existingObject(with: id) as? OEDBRom, !rom.isDeleted {
            selectedROM = rom; gameLabel.stringValue = rom.game?.gameTitle ?? rom.game?.name ?? "Library game"
        }
        createButton = button("Create Room", #selector(createRoom))
        updateButton = button("Update Host Options", #selector(updateHost))
        joinButton = button("Join Room", #selector(joinInvite))
        browseJoinButton = button("Join Selected Room", #selector(joinListed))
        saveButton = button("Save Defaults", #selector(saveDefaults))
        resumeGameButton = button("Resume Multiplayer Game…", #selector(chooseMultiplayerSave))
        newGameButton = button("New Game", #selector(clearMultiplayerSave))
        tab("Host Game", [row("Room name", title), publicRoom, protectedRoom, row("Password", password),
                          spectators, row("Watcher limit", spectatorLimit), shareROM,
                          label("Watchers use the room password and separate slots. Private games stay unlisted."),
                          NSStackView(views: [createButton, updateButton]), resumeLabel,
                          NSStackView(views: [resumeGameButton, newGameButton]),
                          label("Multiplayer saves rebuild the shared game before starting. Long sessions may take time to load. Current game support is Super Mario Kart.")])
        cancelTransferButton.target = self; cancelTransferButton.action = #selector(cancelROMTransfer); cancelTransferButton.isHidden = true
        tab("Join with Invite", [row("Invite code", invite), row("Password", joinPassword), row("Join as", joinRole), joinButton])
        rebuildRelayPicker()
        relayPicker.target = self; relayPicker.action = #selector(selectRelay)
        relayPicker.setAccessibilityLabel("Relay for hosting and invites")
        tab("Browse Games", [makeDirectoryTable(roomList, columns: [("game", "Game / Host", 210), ("relay", "Relay", 135), ("players", "Players", 65), ("options", "Options", 100)]),
                             row("Password", browsePassword), row("Join as", browseRole),
                             NSStackView(views: [browseJoinButton, button("Refresh Games", #selector(refreshDirectory))])])
        tab("Relays", [makeDirectoryTable(relayTable, columns: [("name", "Relay / Region", 220), ("operator", "Operator", 180), ("health", "Status", 140)]),
                       NSStackView(views: [button("Refresh Relays", #selector(refreshDirectory)), button("Use Selected Relay", #selector(useSelectedRelay)), button("Register a Relay…", #selector(registerRelay))])])
        tab("Settings", [row("Display name", name), row("Lobby server", endpoint), row("Connection", route),
                         row("STUN service", stunProvider), row("Custom server", customSTUN),
                         label("STUN discovers a route; it does not carry gameplay. The selected provider sees your public network address. Changes apply to the next connection."),
                         button("Check Network…", #selector(checkNetwork)), networkResult,
                         row("Input response", label("Rollback · no added input delay")),
                         label("Both players need a rollback-compatible build. Automatic negotiates a direct connection or a configured relay. Relay only requires a lobby with TURN service. Internet lobbies require HTTPS."), saveButton])
        chooseButton = button("Choose Game…", #selector(chooseGame))
        copyButton = button("Copy Invite", #selector(copyInvite))
        leaveButton = button("Leave Room", #selector(leaveRoom))
        launchButton = button("Connect to Game", #selector(launchGame))
        let top = NSStackView(views: [gameLabel, chooseButton]); top.orientation = .horizontal
        status.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [top, row("Host / Invite relay", relayPicker), tabs, roomStatus, status, label("The host’s multiplayer game saves automatically. To keep a separate copy, use Network Play → Export Multiplayer Save. Closing this panel keeps you connected; use Leave Room to disconnect."), NSStackView(views: [launchButton, leaveButton, copyButton, cancelTransferButton])])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
                                     stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 20),
                                     stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
                                     stack.bottomAnchor.constraint(lessThanOrEqualTo: panel.contentView!.bottomAnchor, constant: -20),
                                     tabs.widthAnchor.constraint(equalTo: stack.widthAnchor), tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 430),
                                     status.widthAnchor.constraint(equalTo: stack.widthAnchor), roomStatus.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        let preferredTabHeight = tabs.heightAnchor.constraint(equalTo: panel.contentView!.heightAnchor, constant: -410)
        preferredTabHeight.priority = .defaultHigh
        preferredTabHeight.isActive = true
        tabs.delegate = self
        refreshControls()
    }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard !busy, let identifier = tabViewItem?.identifier as? String,
              identifier == "Browse Games" || identifier == "Relays" else { return }
        refreshDirectory()
    }
    @objc private func optionsChanged() { refreshControls() }
    private func refreshControls() {
        guard panel != nil else { return }
        for button in operationButtons { button.isEnabled = !busy }
        shareROM.isEnabled = !busy && gameProcess == nil
        resumeGameButton.isEnabled = !busy && room == nil && gameProcess == nil
        newGameButton.isEnabled = !busy && room == nil && resumeURL != nil
        let isHost = room?["role"] as? String == "host"
        let waitingForPlayer = isHost && (room?["occupancy"] as? Int ?? 0) < 2
        let waitingForHost = room != nil && !isHost && room?["state"] as? String != "playing"
        launchButton.title = gameConnected ? "Connected" : (gameLaunching || gameProcess != nil) ? "Connecting…" : waitingForPlayer ? "Waiting for Player 2" : waitingForHost ? "Waiting for Host" : isHost ? "Start Game" : "Connect to Game"
        relayPicker.isEnabled = !busy && room == nil && gameProcess == nil
        launchButton.isEnabled = !busy && room != nil && gameProcess == nil && !waitingForPlayer && !waitingForHost
        createButton.isEnabled = !busy && room == nil && gameProcess == nil
        joinButton.isEnabled = !busy && room == nil && gameProcess == nil
        browseJoinButton.isEnabled = !busy && room == nil && gameProcess == nil && listedRooms.indices.contains(roomList.selectedRow)
        copyButton.isHidden = room?["role"] as? String != "host"
        copyButton.isEnabled = !busy && room?["role"] as? String == "host" && room?["invite_code"] is String
        leaveButton.isEnabled = !busy && room != nil
        updateButton.isEnabled = !busy && room?["role"] as? String == "host"
        chooseButton.isEnabled = !busy && room == nil; saveButton.isEnabled = !busy && room == nil
        endpoint.isEnabled = !busy && room == nil; name.isEnabled = !busy && room == nil
        password.isEnabled = !busy && protectedRoom.state == .on
        spectatorLimit.isEnabled = !busy && spectators.state == .on
    }
    private func fail(_ message: String) -> NSError { NSError(domain: "NetworkPlay", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func baseURL() throws -> URL {
        guard var parts = URLComponents(string: endpoint.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", parts.scheme == "https" || (parts.scheme == "http" && Self.isLANHost(host)) else {
            throw fail("Use HTTPS for Internet lobbies, or a numeric private LAN address for the development lobby.")
        }
        if host == "localhost" { parts.host = "127.0.0.1" }
        parts.path = ""; guard let url = parts.url else { throw fail("Check the lobby address.") }; return url
    }
    private static func isLANHost(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" { return true }
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        let parts = components.compactMap { UInt8($0) }
        return parts.count == 4 && (parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])))
    }
    @objc private func launchGame() {
        guard #available(macOS 14.0, *) else { status.stringValue = "This Network Play preview requires macOS 14 or newer."; return }
        guard !busy, gameProcess == nil, let base = activeEndpoint, let id = room?["id"] as? String,
              let rom = selectedROM, !rom.isDeleted, let url = rom.url else { status.stringValue = "Choose your library game and join a room first."; return }
        if room?["role"] as? String == "host" && (room?["occupancy"] as? Int ?? 1) < 2 {
            status.stringValue = "Share your invite and wait for the second player to join, then choose Start Game."; return
        }
        gameLaunching = true
        perform {
            defer { self.gameLaunching = false }
            let expected = (self.room?["compatibility"] as? [String: Any])?["rom_sha256"] as? String
            _ = try await self.identity(expectedSHA: expected)
            let process = Process(), input = Pipe(), output = Pipe()
            let launchID = UUID()
            let diagnostics = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenEmu-NX-NetworkPlay-" + launchID.uuidString + ".json")
            process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NetworkPlay/NetworkPlay.app/Contents/MacOS/emu-live")
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            var config: [String: Any] = ["endpoint": base.absoluteString, "room_id": id, "token": self.memberToken,
                                       "rom": url.path, "rollback": true, "connection": ["automatic", "direct", "relay"][self.route.indexOfSelectedItem], "audio_report": diagnostics.path, "delay": self.delay.indexOfSelectedItem + 1]
            if let servers = try self.selectedSTUN() { config["stun_servers"] = servers }
            if self.route.indexOfSelectedItem != 1 {
                // Request room-scoped relay credentials once before play.
                // Direct-only play does not request relay access.
                config["relay_network"] = try await self.authorizeRelay(base, roomID: id)
            }
            config["allow_rom_transfer"] = self.shareROM.state == .on
            self.currentAutosaveURL = nil
            if self.room?["role"] as? String == "host" {
                let folder = URL.oeApplicationSupportDirectory.appendingPathComponent("Multiplayer Sessions/Autosaves", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let autosave = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("emuxsave")
                self.currentAutosaveURL = autosave; config["autosave_path"] = autosave.path
                if let resume = self.resumeURL { config["resume_path"] = resume.path }
            }
            var bytes = try JSONSerialization.data(withJSONObject: config); bytes.append(10)
            process.terminationHandler = { [weak self] task in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
                let result = lines.last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                let saveError = NetworkPlayProgress.read(diagnostics)?.saveError ?? ""
                let finalError = result?["error"] as? String ?? (saveError.isEmpty ? nil : saveError)
                let message = finalError ?? "Network game ended."
                try? FileManager.default.removeItem(at: diagnostics)
                Task { @MainActor in
                    guard let self, self.gameProcess === task else { return }
                    self.cancelProgress()
                    self.gameProcess = nil; self.gameStopping = false; self.gameConnected = false
                    self.lastGameError = finalError ?? self.lastGameError
                    self.gameMessage = self.lastGameError ?? message
                    self.status.stringValue = self.gameMessage!; self.refreshControls()
                }
            }
            self.gameMessage = nil; self.gameStopping = false; self.lastGameError = nil; self.gameConnected = false
            try process.run(); self.gameProcess = process
            input.fileHandleForWriting.write(bytes); try? input.fileHandleForWriting.close()
            self.gameMessage = "Opening network game. Waiting for the other player…"
            self.status.stringValue = self.gameMessage!
            self.monitorProgress(at: diagnostics, id: launchID)
        }
    }
    private func cancelProgress() {
        progressTask?.cancel(); progressTask = nil; progressID = nil
        if let progressURL { try? FileManager.default.removeItem(at: progressURL) }
        progressURL = nil
    }
    private func monitorProgress(at url: URL, id: UUID) {
        cancelProgress()
        progressID = id; progressURL = url; lastSavedFrame = 0
        progressTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let progress = NetworkPlayProgress.read(url)
                guard !Task.isCancelled else { return }
                if let progress {
                    await self?.applyProgress(progress, id: id)
                }
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            }
        }
    }
    private func applyProgress(_ progress: NetworkPlayProgress, id: UUID) {
        guard progressID == id, gameProcess != nil else { return }
        liveRoute = progress.networkRoute; liveRTT = progress.networkRTT
        let connected = progress.confirmed > 0 || progress.videoFrames > 0
        if connected && !gameConnected {
            gameConnected = true
            refreshControls()
        }
        let message: String
        if progress.total > 0 && progress.resumed < progress.total {
            let percent = Int(min(100, Double(progress.resumed) / Double(progress.total) * 100))
            message = "Loading saved multiplayer game: \(percent)%…"
        } else if progress.confirmed > 0 || progress.videoFrames > 0 {
            message = room?["role"] as? String == "spectator"
                ? "Watching live. Spectators are read-only." : "Network game is running."
        } else if progress.total > 0 {
            message = "Saved game loaded. Waiting for the other player…"
        } else {
            message = "Waiting for the other player to start…"
        }
        if !progress.saveError.isEmpty { lastGameError = "Multiplayer autosave failed: " + progress.saveError }
        let connectionMessage = progress.lobbyReconnecting ? message + " Reconnecting to lobby…" : message
        gameMessage = progress.saveError.isEmpty ? connectionMessage : connectionMessage + " Multiplayer autosave failed: " + progress.saveError
        status.stringValue = gameMessage!
        // The file is written before the completed-frame counter advances.
        // Refresh immediately, rather than waiting for the lobby heartbeat.
        if progress.saved != lastSavedFrame {
            lastSavedFrame = progress.saved
            refreshControls()
        }
    }
    @objc private func chooseMultiplayerSave() {
        guard room == nil, gameProcess == nil else { return }
        let chooser = NSOpenPanel(); chooser.title = "Resume Multiplayer Game"
        chooser.allowedFileTypes = ["emuxsave"]; chooser.allowsMultipleSelection = false
        chooser.canChooseDirectories = false
        let folder = URL.oeApplicationSupportDirectory.appendingPathComponent("Multiplayer Sessions/Autosaves", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { status.stringValue = "Could not open multiplayer saves: " + error.localizedDescription; return }
        chooser.directoryURL = folder
        guard chooser.runModal() == .OK, let url = chooser.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 8_000_512 else { throw fail("This is not a supported multiplayer save.") }
            resumeURL = url; resumeLabel.stringValue = "Resume: " + url.lastPathComponent
            status.stringValue = "Choose the matching library game, then create a new room. Both players verify the saved game before starting."
            refreshControls()
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func clearMultiplayerSave() {
        resumeURL = nil; resumeLabel.stringValue = "Start a new multiplayer game."; refreshControls()
    }
    @objc private func saveMultiplayerGame() {
        guard let source = currentAutosaveURL else { return }
        do {
            let values = try source.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size > 0, size <= 8_000_512 else { throw fail("A confirmed multiplayer save is not ready yet.") }
            // The runtime atomically replaces this file; capture one complete
            // version before showing the destination panel.
            let data = try Data(contentsOf: source)
            guard data.count <= 8_000_512, data.prefix(8) == Data("EMUXJNL1".utf8) else { throw fail("The multiplayer save could not be read.") }
            let chooser = NSSavePanel(); chooser.title = "Save Multiplayer Game"
            chooser.allowedFileTypes = ["emuxsave"]; chooser.nameFieldStringValue = "Multiplayer Game.emuxsave"
            chooser.directoryURL = URL.oeApplicationSupportDirectory.appendingPathComponent("Multiplayer Sessions", isDirectory: true)
            guard chooser.runModal() == .OK, let destination = chooser.url else { return }
            try data.write(to: destination, options: .atomic)
            status.stringValue = "Multiplayer game saved. Resume it from Host Game when everyone returns."
        } catch { status.stringValue = error.localizedDescription }
    }
    private func displayName() throws -> String {
        let value = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 32 else { throw fail("Enter a display name of 1–32 characters in Settings.") }; return value
    }
    private func authorizeRelay(_ base: URL, roomID: String) async throws -> [String: Any] {
        let result = try await api(base, "POST", "v1/rooms/" + roomID + "/relay-access", [:], token: memberToken)
        guard let network = result["network"] as? [String: Any],
              let servers = network["turn_servers"] as? [String], servers.count <= 4 else {
            throw fail("The lobby returned invalid relay connection settings.")
        }
        if servers.isEmpty {
            guard route.indexOfSelectedItem == 0 else { throw fail("This lobby has no relay available. Choose Automatic or Direct only.") }
            return network
        }
        guard let username = network["turn_username"] as? String, !username.isEmpty, username.utf8.count <= 512,
              let password = network["turn_password"] as? String, !password.isEmpty, password.utf8.count <= 512 else {
            throw fail("The relay returned incomplete connection credentials.")
        }
        return network
    }
    private func api(_ base: URL, _ method: String, _ path: String, _ body: [String: Any]? = nil, token: String = "") async throws -> [String: Any] {
        let url = base.appendingPathComponent(path)
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if base.scheme == "http", !["localhost", "127.0.0.1", "::1"].contains(base.host ?? "") {
            throw fail("Internet lobbies require HTTPS. Local development is limited to this Mac.")
        }
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: request)
        guard data.count <= 128*1024, let response = response as? HTTPURLResponse,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw fail("The lobby sent an invalid response.") }
        guard (200..<300).contains(response.statusCode) else {
            let code = object["error"] as? String ?? "unavailable"
            let messages = ["not_found": "This relay needs an update to support automatic game matching.", "invalid_invite_code": "Enter the eight-character invite code, such as ABCD-EFGH.", "join_denied": "The room password is incorrect.", "room_unavailable": "Room not found on this lobby server. Check that both Macs use the same server in Settings and that the invite is current.",
                            "room_full": "Both player slots are occupied. Ask the host about watching.", "spectators_full": "All watcher slots are occupied.",
                            "spectators_disabled": "The host is not allowing spectators.", "incompatible_session": "The room compatibility does not match. Verify the game SHA-256 and install the same OpenEmu-NX build on both Macs.",
                            "rate_limited": "Too many attempts. Please wait a minute and try again.", "unauthorized": "Your room membership has expired.",
                            "invalid_password": "Use a password of at most 128 characters.", "host_required": "Only the host can change this room.",
                            "relay_unavailable": "This lobby has no relay available. Choose Automatic or Direct only."]
            throw NSError(domain: "NetworkPlayLobby", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: messages[code] ?? "The lobby could not complete this request (\(code))."])
        }
        return object
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; status.stringValue = "Contacting lobby…"; refreshControls()
        Task { @MainActor in
            defer { self.busy = false; self.refreshControls() }
            do { try await operation() } catch { self.status.stringValue = error.localizedDescription }
        }
    }
    @objc private func chooseGame() {
        guard let context = OELibraryDatabase.default?.mainThreadContext else {
            status.stringValue = "Finish opening your OpenEmu library first."; return
        }
        do {
            let request = NSFetchRequest<OEDBRom>(entityName: OEDBRom.entityName)
            let games = try context.fetch(request).filter { !$0.isDeleted && $0.game != nil }
            let browser = NetworkPlayLibraryBrowser(roms: games, selected: selectedROM)
            libraryBrowser = browser
            browser.present(on: panel) { [weak self] rom in
                guard let self else { return }
                self.libraryBrowser = nil
                guard let rom else { return }
                self.selectedROM = rom
                self.gameLabel.stringValue = rom.game?.gameTitle ?? rom.game?.name ?? "Library game"
                self.defaults.set(rom.objectID.uriRepresentation().absoluteString, forKey: self.prefix + "romID")
                self.status.stringValue = "Library game selected. Compatibility is checked when creating or joining a room."
            }
        } catch { status.stringValue = "Could not read your library: " + error.localizedDescription }
    }
    private func matchLibraryGame(expectedSHA: String, profile: String, allowTransfer: Bool = false) async throws -> Bool {
        guard let context = OELibraryDatabase.default?.mainThreadContext else { throw fail("Open your game library first.") }
        let request = NSFetchRequest<OEDBRom>(entityName: OEDBRom.entityName)
        let games = try context.fetch(request).filter {
            !$0.isDeleted && $0.game != nil && $0.archiveFileIndex == nil && $0.url != nil
                && (!profile.hasPrefix("snes9x-") || $0.game?.system?.systemIdentifier == "openemu.system.snes")
        }
        let urls = games.compactMap(\.url)
        status.stringValue = "Finding the host’s game in your library by SHA-256…"
        let match = await Task.detached(priority: .userInitiated) {
            for (index, url) in urls.enumerated() {
                if Task.isCancelled { return Optional<Int>.none }
                if (try? FileManager.default.hashFile(at: url, hashFunction: .sha256)) == expectedSHA { return index }
            }
            return Optional<Int>.none
        }.value
        var chosen: OEDBRom?
        if let match { chosen = games[match] }
        else {
            let alert = NSAlert(); alert.messageText = "Matching game not found in your library"
            alert.informativeText = "No readable, uncompressed library game matches the host’s SHA-256:\n\(expectedSHA)\n\nChoose a library game to verify it, or cancel and import the matching game first. Different revisions will not connect."
            alert.addButton(withTitle: "Choose Library Game…"); alert.addButton(withTitle: "Cancel")
            if allowTransfer { alert.addButton(withTitle: "Request ROM from Host…") }
            let answer = alert.runModal()
            if allowTransfer && answer == .alertThirdButtonReturn {
                let consent = NSAlert()
                consent.messageText = "Request this ROM from the host?"
                consent.informativeText = "Only accept if you own this game and are authorized to receive this copy. The host must enable ROM sharing and start the game. The file is sent over the peer connection, using the relay if needed. Its SHA-256 will be checked before import. Existing ROMs and saves will not be replaced."
                consent.addButton(withTitle: "I Own the Game — Request ROM")
                consent.addButton(withTitle: "Cancel")
                guard consent.runModal() == .alertFirstButtonReturn else { throw fail("ROM request cancelled.") }
                return false
            }
            guard answer == .alertFirstButtonReturn else { throw fail("Join cancelled. Import the matching game and try again. Expected SHA-256: \(expectedSHA)") }
            let allGames = try context.fetch(request).filter { !$0.isDeleted && $0.game != nil }
            let browser = NetworkPlayLibraryBrowser(roms: allGames, selected: selectedROM)
            libraryBrowser = browser
            chosen = await withCheckedContinuation { continuation in
                browser.present(on: panel) { rom in continuation.resume(returning: rom) }
            }
            libraryBrowser = nil
            guard let rom = chosen, let url = rom.url else { throw fail("Join cancelled.") }
            guard rom.archiveFileIndex == nil else { throw fail("Import an uncompressed copy of this game before joining. Expected SHA-256: \(expectedSHA)") }
            let actual = try await Task.detached(priority: .userInitiated) {
                try FileManager.default.hashFile(at: url, hashFunction: .sha256)
            }.value
            guard actual == expectedSHA else {
                let mismatch = NSAlert(); mismatch.messageText = "Game SHA-256 does not match"
                mismatch.informativeText = "Host: \(expectedSHA)\nYour file: \(actual)\n\nThese are different game files. Choose the same revision as the host."
                mismatch.runModal()
                throw fail("Game SHA-256 mismatch. Host: \(expectedSHA). Your file: \(actual).")
            }
        }
        guard let rom = chosen, !rom.isDeleted else { throw fail("The library game is no longer available.") }
        selectedROM = rom
        gameLabel.stringValue = rom.game?.gameTitle ?? rom.game?.name ?? "Library game"
        defaults.set(rom.objectID.uriRepresentation().absoluteString, forKey: prefix + "romID")
        status.stringValue = "Matching game selected; SHA-256 verified. Joining…"
        return true
    }
    private func identity(expectedSHA: String? = nil) async throws -> [String: Any] {
        guard let rom = selectedROM, !rom.isDeleted, rom.managedObjectContext != nil,
              let gameURL = rom.url else { throw fail("Choose an imported game from your OpenEmu library first.") }
        guard rom.archiveFileIndex == nil else { throw fail("This Network Play preview requires an uncompressed library game. Compressed library games are not supported yet.") }
        guard FileManager.default.isReadableFile(atPath: gameURL.path) else { throw fail("The selected library game's file is missing. Relocate it in OpenEmu, then select it again.") }
        let expected = expectedSHA?.lowercased()
        if let expected {
            // Report a different file as a SHA mismatch before the runtime's
            // supported-game gate can turn it into an unrelated error.
            let actual = try await Task.detached(priority: .userInitiated) {
                try FileManager.default.hashFile(at: gameURL, hashFunction: .sha256)
            }.value
            guard actual == expected else {
                throw fail("Game SHA-256 mismatch. Host: \(expected). Your file: \(actual). Choose the same game revision as the host.")
            }
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NetworkPlay/emu-identity")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw fail("This build is missing Network Play runtime support.") }
        let process = Process(); let pipe = Pipe(); process.executableURL = helper; process.arguments = [gameURL.path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { task in
                let result = pipe.fileHandleForReading.readDataToEndOfFile()
                if task.terminationStatus == 0 { continuation.resume(returning: result) }
                else {
                    // Termination handlers run off the main thread. Check again
                    // if the file changed while the identity helper was reading.
                    let message: String
                    if let expected,
                       let actual = try? FileManager.default.hashFile(at: gameURL, hashFunction: .sha256),
                       actual != expected {
                        message = "Game SHA-256 mismatch. Host: \(expected). Your file: \(actual). Choose the same game revision as the host."
                    } else {
                        message = "This game is not supported by the current Network Play build. Choose Super Mario Kart NTSC v1.0 from your library."
                    }
                    continuation.resume(throwing: NSError(domain: "NetworkPlay", code: 2, userInfo: [NSLocalizedDescriptionKey: message]))
                }
            }
            do { try process.run() } catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
        }
        guard let output = String(data: data, encoding: .utf8),
              let line = output.split(separator: "\n").last(where: { $0.hasPrefix("{\"protocol\"") }),
              let result = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { throw fail("Could not check game compatibility.") }
        if let expected {
            guard let actual = result["rom_sha256"] as? String else { throw fail("Could not verify the game file SHA-256.") }
            guard actual.lowercased() == expected else {
                throw fail("Game SHA-256 mismatch. Host: \(expected). Your file: \(actual). Choose the same game revision as the host.")
            }
        }
        return result
    }
    private func hostOptions(newRoom: Bool) throws -> [String: Any] {
        var result: [String: Any] = ["allow_spectators": spectators.state == .on, "spectator_limit": spectatorLimit.indexOfSelectedItem + 1]
        if newRoom || (room?["occupancy"] as? Int ?? 1) < 2 {
            result["title"] = title.stringValue
            result["visibility"] = publicRoom.state == .on ? "public" : "unlisted"
            if protectedRoom.state == .off { result["password"] = "" }
            else if !password.stringValue.isEmpty { result["password"] = password.stringValue }
            else if newRoom { throw fail("Enter a password, or turn off Require a room password.") }
        }
        return result
    }
    @objc private func createRoom() {
        guard room == nil, gameProcess == nil else { return }
        perform {
            let base = try self.baseURL(); let username = try self.displayName()
            var body = try self.hostOptions(newRoom: true); self.password.stringValue = ""
            body["username"] = username; body["compatibility"] = try await self.identity()
            let response = try await self.api(base, "POST", "v1/rooms", body)
            try self.admit(response, tokenKey: "owner_token", base: base)
        }
    }
    private static func displayInvite(_ value: String) -> String {
        let code = value.uppercased().filter { "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".contains($0) }
        guard code.count > 4 && code.count <= 8 else { return code }
        return String(code.prefix(4)) + "-" + String(code.dropFirst(4))
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === invite else { return }
        let formatted = Self.displayInvite(field.stringValue)
        if field.stringValue != formatted { field.stringValue = formatted }
    }
    @objc private func joinInvite() {
        guard !busy, room == nil, gameProcess == nil else { return }
        // ICE prioritizes direct host/STUN candidates; TURN is the fallback.
        route.selectItem(at: 0)
        join(locator: ["invite_code": invite.stringValue], secret: joinPassword.stringValue, role: joinRole.indexOfSelectedItem)
    }
    @objc private func joinListed() {
        let index = roomList.selectedRow; guard listedRooms.indices.contains(index), let id = listedRooms[index]["id"] as? String else { return }
        join(locator: ["room_id": id], secret: browsePassword.stringValue, role: browseRole.indexOfSelectedItem, lobby: (listedRooms[index]["relay_endpoint"] as? String).flatMap(URL.init(string:)))
    }
    private func join(locator: [String: Any], secret: String, role: Int, lobby: URL? = nil) {
        guard room == nil, gameProcess == nil else { return }
        perform {
            let base = try lobby ?? self.baseURL()
            var lookup = locator; lookup["password"] = secret
            let resolved = try await self.api(base, "POST", "v1/resolve", lookup)
            guard let target = resolved["room"] as? [String: Any],
                  let compatibility = target["compatibility"] as? [String: Any],
                  let expected = compatibility["rom_sha256"] as? String,
                  expected.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil else {
                throw self.fail("The host did not provide a valid game SHA-256.")
            }
            let haveROM = try await self.matchLibraryGame(expectedSHA: expected.lowercased(), profile: compatibility["profile"] as? String ?? "", allowTransfer: role == 0)
            var body = locator
            body["username"] = try self.displayName(); body["password"] = secret; body["role"] = role == 0 ? "player" : "spectator"
            body["compatibility"] = haveROM ? try await self.identity(expectedSHA: expected) : compatibility
            let response = try await self.api(base, "POST", "v1/join", body)
            self.joinPassword.stringValue = ""; self.browsePassword.stringValue = ""
            try self.admit(response, tokenKey: "member_token", base: base)
            if !haveROM {
                do {
                    try await self.receiveROM(expectedSHA: expected.lowercased(), base: base)
                    _ = try await self.identity(expectedSHA: expected)
                    self.status.stringValue = "ROM received, SHA-256 verified and imported. Choose Connect to Game."
                } catch {
                    if let id = self.room?["id"] as? String {
                        _ = try? await self.api(base, "DELETE", "v1/rooms/" + id + "/membership", [:], token: self.memberToken)
                    }
                    self.clearRoom()
                    throw error
                }
            }
        }
    }
    @objc private func cancelROMTransfer() { transferProcess?.terminate() }
    private func receiveROM(expectedSHA: String, base: URL) async throws {
        guard let id = room?["id"] as? String, let database = OELibraryDatabase.default else { throw fail("Room or library unavailable.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NX-ROM-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let title = room?["game"] as? String ?? "Network Game"
        let safeTitle = String(title.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || " -_".unicodeScalars.contains($0) }.prefix(100))
        let destination = directory.appendingPathComponent((safeTitle.isEmpty ? "Network Game" : safeTitle) + ".sfc")
        var importURL = destination
        if !UserDefaults.standard.bool(forKey: OECopyToLibraryKey) {
            // In-place libraries need a user-selected permanent source, just as
            // a normal local import does. Never retain a temporary download URL.
            let save = NSSavePanel()
            save.title = "Save Downloaded ROM"
            save.message = "Your library keeps ROMs in their original locations. Choose where to keep this game."
            save.directoryURL = database.romsFolderURL
            save.nameFieldStringValue = destination.lastPathComponent
            guard await save.beginSheetModal(for: panel) == .OK, let url = save.url else { throw fail("ROM transfer cancelled.") }
            guard !FileManager.default.fileExists(atPath: url.path) else { throw fail("Choose a new filename; downloads never replace existing ROMs.") }
            importURL = url
        }
        var launch: [String: Any] = ["endpoint": base.absoluteString, "room_id": id, "token": memberToken,
                                   "receive_rom": destination.path, "expected_rom_sha256": expectedSHA,
                                   "connection": "automatic", "headless": true]
        if let servers = try selectedSTUN() { launch["stun_servers"] = servers }
        launch["relay_network"] = try await authorizeRelay(base, roomID: id)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NetworkPlay/NetworkPlay.app/Contents/MacOS/emu-live")
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        transferProcess = process
        cancelTransferButton.isHidden = false
        defer { transferProcess = nil; cancelTransferButton.isHidden = true }
        status.stringValue = "Waiting for the host to enable ROM sharing and Start Game. Transfer times out after three minutes."
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: launch) + Data([10]))
        try input.fileHandleForWriting.close()
        let result = await Task.detached(priority: .utility) { () -> (Int32, Data) in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data)
        }.value
        guard result.0 == 0 else {
            let response = try? JSONSerialization.jsonObject(with: result.1) as? [String: Any]
            throw fail(response?["error"] as? String ?? "ROM transfer failed. Ask the host to allow ROM downloads, then try again.")
        }
        let actual = try await Task.detached(priority: .utility) { try FileManager.default.hashFile(at: destination, hashFunction: .sha256) }.value
        guard actual == expectedSHA else { throw fail("Received ROM SHA-256 does not match the host. The file was not imported.") }
        if importURL != destination { try FileManager.default.copyItem(at: destination, to: importURL) }
        status.stringValue = "SHA-256 verified. Importing the received game…"
        let romID: NSManagedObjectID? = await withCheckedContinuation { continuation in
            let started = database.importer.importItem(at: importURL) { id in continuation.resume(returning: id) }
            if !started { continuation.resume(returning: nil) }
        }
        guard let romID, let rom = try database.mainThreadContext.existingObject(with: romID) as? OEDBRom else {
            throw fail("The ROM passed verification but could not be imported. Please retry the transfer or import your local copy.")
        }
        selectedROM = rom
        gameLabel.stringValue = rom.game?.gameTitle ?? rom.game?.name ?? "Received game"
        defaults.set(rom.objectID.uriRepresentation().absoluteString, forKey: prefix + "romID")
    }

    private func admit(_ response: [String: Any], tokenKey: String, base: URL) throws {
        guard let room = response["room"] as? [String: Any], let token = response[tokenKey] as? String, room["id"] is String else { throw fail("The lobby returned an incomplete room.") }
        gameMessage = nil; self.room = room; memberToken = token; activeEndpoint = base; renderRoom()
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                guard let self, self.room != nil else { return }
                if !self.busy { await self.heartbeat() }
            }
        }
    }
    private func renderRoom() {
        guard let room else { roomStatus.stringValue = ""; return }
        let role = room["role"] as? String ?? "member"
        roomStatus.stringValue = "\(room["title"] as? String ?? "Room") · \(role.capitalized)\nPlayers: \(room["occupancy"] as? Int ?? 1)/2 · Watchers: \(room["spectators"] as? Int ?? 0)/\(room["spectator_limit"] as? Int ?? 0)"
        if let code = room["invite_code"] as? String { roomStatus.stringValue += "\nInvite: \(Self.displayInvite(code))" }
        if let remaining = room["lifetime_remaining_seconds"] as? Int, remaining <= 900 {
            let minutes = max(0, Int(ceil(Double(remaining) / 60)))
            roomStatus.stringValue += "\nSession ends in \(minutes) minute\(minutes == 1 ? "" : "s"). Save and start a new room to continue."
        }
        status.stringValue = gameMessage ?? (gameProcess == nil ? (role == "host" ? ((room["occupancy"] as? Int ?? 1) < 2 ? "You are hosting. Share your invite; waiting for Player 2." : "Both players are in the room. Choose Start Game.") : (room["state"] as? String == "playing" ? "The host has started. Choose Connect to Game." : "You have joined the room. Waiting for the host to start the game.")) : "Network game window is open. Spectators are read-only.")
        refreshControls()
    }
    private func heartbeat() async {
        guard !heartbeatInFlight, let base = activeEndpoint, let id = room?["id"] as? String else { return }
        let token = memberToken
        heartbeatInFlight = true
        defer { heartbeatInFlight = false }
        do {
            let result = try await api(base, "POST", "v1/rooms/\(id)/heartbeat", [:], token: token)
            guard room?["id"] as? String == id, memberToken == token, !busy else { return }
            if let current = result["room"] as? [String: Any] { room = current; renderRoom() }
        } catch {
            guard room?["id"] as? String == id, memberToken == token, !busy else { return }
            let failure = error as NSError
            if failure.domain == "NetworkPlayLobby" && [401,404].contains(failure.code) { clearRoom() }
            status.stringValue = "Room update failed: " + error.localizedDescription
        }
    }
    private func makeDirectoryTable(_ table: NSTableView, columns: [(String, String, CGFloat)]) -> NSScrollView {
        for (key, name, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = name; column.width = width; column.minWidth = width; table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.rowHeight = 48
        table.usesAlternatingRowBackgroundColors = true; table.allowsEmptySelection = true
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        // Let the list yield space to the admission controls. The tab's bottom
        // constraint keeps every button inside its parent's hit-testing bounds.
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        return scroll
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === roomList ? listedRooms.count : relays.count }
    func tableViewSelectionDidChange(_ notification: Notification) { refreshControls() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let key = tableColumn?.identifier.rawValue else { return nil }
        let text: String
        if tableView === roomList {
            guard listedRooms.indices.contains(row) else { return nil }
            let item = listedRooms[row]
            switch key {
            case "game": text = "\(item["title"] as? String ?? "Game")\nHost: \(item["host_name"] as? String ?? "Player")"
            case "relay": text = item["relay_name"] as? String ?? "Relay"
            case "players": text = "\(item["occupancy"] as? Int ?? 0)/2"
            default: text = (item["requires_password"] as? Bool == true ? "Password" : "Open") + (item["allow_spectators"] as? Bool == true ? " · Watch" : "")
            }
        } else {
            guard relays.indices.contains(row) else { return nil }
            let relay = relays[row]
            switch key {
            case "name": text = "\(relay["name"] ?? "Relay")\n\(relay["region"] ?? "")"
            case "operator": text = relay["operator"] ?? ""
            default: text = relayStatus[relay["endpoint"] ?? ""] ?? "Not checked"
            }
        }
        let cell = NSTableCellView(); let field = NSTextField(labelWithString: text)
        field.maximumNumberOfLines = 2; field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(field); cell.textField = field
        NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6), field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    private func rebuildRelayPicker() {
        let selected = endpoint.stringValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        relayPicker.removeAllItems()
        for relay in relays { relayPicker.addItem(withTitle: "\(relay["name"] ?? "Relay") · \(relay["region"] ?? "")") }
        if let index = relays.firstIndex(where: { $0["endpoint"] == selected }) { relayPicker.selectItem(at: index) }
        else { relayPicker.addItem(withTitle: "Custom server (Settings)"); relayPicker.selectItem(at: relays.count) }
        relayTable.reloadData()
    }
    @objc private func selectRelay() {
        guard room == nil, gameProcess == nil, relays.indices.contains(relayPicker.indexOfSelectedItem), let address = relays[relayPicker.indexOfSelectedItem]["endpoint"] else { return }
        endpoint.stringValue = address
        defaults.set(address, forKey: prefix + "endpoint")
        status.stringValue = "Hosting and invites will use the selected relay."
    }
    @objc private func useSelectedRelay() {
        guard !busy, room == nil, gameProcess == nil, relays.indices.contains(relayTable.selectedRow) else { return }
        relayPicker.selectItem(at: relayTable.selectedRow); selectRelay()
    }
    @objc private func registerRelay() { if let url = directoryURL { NSWorkspace.shared.open(url) } }
    @objc private func refreshDirectory() {
        perform {
            self.catalogMessage = ""
            if let directory = self.directoryURL {
                do {
                    let result = try await self.api(directory, "GET", "v1/relays")
                    guard result["schema"] as? Int == 1, let items = result["relays"] as? [[String: Any]], items.count <= 100 else { throw self.fail("Invalid relay directory.") }
                    var valid: [[String: String]] = []
                    for item in items {
                        guard let address = item["endpoint"] as? String, let url = URL(string: address), url.scheme == "https", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/", url.port == nil || url.port == 443,
                              let host = url.host, host.contains("."), !Self.isLANHost(host), let name = item["name"] as? String, name.count <= 64, item["protocol"] as? Int == 1 else { continue }
                        valid.append(["id": item["id"] as? String ?? address, "name": name, "endpoint": address, "region": String((item["region"] as? String ?? "").prefix(48)), "operator": String((item["operator"] as? String ?? "").prefix(80))])
                    }
                    guard !valid.isEmpty else { throw self.fail("No approved relays are available yet.") }
                    self.relays = Array(valid.prefix(8)); self.rebuildRelayPicker()
                } catch { self.catalogMessage = "Directory unavailable; showing the built-in or last loaded relays. " }
            }
            self.listedRooms = []; self.relayStatus = [:]
            for relay in self.relays {
                guard let address = relay["endpoint"], let base = URL(string: address) else { continue }
                do {
                    let result = try await self.api(base, "GET", "v1/rooms")
                    guard let rooms = result["rooms"] as? [[String: Any]], rooms.count <= 64 else { throw self.fail("Invalid room list.") }
                    self.relayStatus[address] = "Online"
                    for var room in rooms where room["visibility"] as? String == "public" {
                        room["relay_endpoint"] = address; room["relay_name"] = relay["name"]
                        self.listedRooms.append(room)
                    }
                } catch { self.relayStatus[address] = "Unreachable" }
                self.relayTable.reloadData(); self.roomList.reloadData()
            }
            if !self.listedRooms.isEmpty { self.roomList.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            let offline = self.relayStatus.values.filter { $0 != "Online" }.count
            self.status.stringValue = self.catalogMessage + "\(self.listedRooms.count) public game(s) across \(self.relays.count) relay(s)." + (offline > 0 ? " \(offline) relay(s) could not be reached." : "") + " Private rooms require an invite and the host’s relay."
        }
    }
    @objc private func updateHost() {
        guard let base = activeEndpoint, let id = room?["id"] as? String else { return }
        perform {
            let options = try self.hostOptions(newRoom: false); self.password.stringValue = ""
            let result = try await self.api(base, "POST", "v1/rooms/\(id)/settings", options, token: self.memberToken)
            self.room = result["room"] as? [String: Any]; self.renderRoom()
        }
    }
    @objc private func copyInvite() {
        guard room?["role"] as? String == "host", let code = room?["invite_code"] as? String else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Self.displayInvite(code), forType: .string)
        status.stringValue = "Invite copied. Share the room password separately."
    }
    @objc private func leaveRoom() {
        guard !busy, let base = activeEndpoint, let id = room?["id"] as? String else { return }
        let token = memberToken
        let suffix = room?["role"] as? String == "host" ? "" : "/membership"
        heartbeatTask?.cancel(); heartbeatTask = nil
        perform {
            if let process = self.gameProcess {
                self.gameStopping = true; self.cancelProgress()
                self.gameMessage = "Leaving room and finishing the multiplayer save…"
                self.status.stringValue = self.gameMessage!
                process.terminate()
                // Keep the process identity until its handler has captured final
                // save errors. No new connection can start during this cleanup.
                while self.gameProcess === process {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            var message = "Left the room."
            do { _ = try await self.api(base, "DELETE", "v1/rooms/\(id)\(suffix)", [:], token: token) }
            catch {
                message = "Disconnected from this Mac. The lobby could not confirm removal; the room membership will expire automatically."
            }
            let finalError = self.lastGameError
            self.clearRoom()
            if let finalError { message += " Game reported: " + finalError }
            self.gameMessage = message; self.status.stringValue = message
        }
    }
    private func clearRoom() {
        cancelProgress()
        // If the lobby disappears, still wait for graceful helper termination
        // before enabling another connection. Its handler clears gameProcess.
        if let process = gameProcess { gameStopping = true; process.terminate() }
        heartbeatTask?.cancel(); heartbeatTask = nil
        liveRoute = "connecting"; liveRTT = -1
        room = nil; memberToken = ""; activeEndpoint = nil
        renderRoom(); refreshControls()
    }
    private func selectedSTUN() throws -> [String]? {
        switch stunProvider.indexOfSelectedItem {
        case 0: return ["stun.cloudflare.com:3478"]
        case 2: return nil
        default:
            let value = customSTUN.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard NXSTUNProbe.server(value) != nil else {
                throw NSError(domain: "NetworkCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a STUN hostname and port, such as stun.example.com:3478."])
            }
            return [value]
        }
    }

    @objc private func checkNetwork() {
        guard !networkCheckRunning else { return }
        do {
            let servers = try selectedSTUN(), base = try baseURL()
            networkCheckRunning = true
            networkResult.stringValue = "Checking lobby and UDP reachability…"
            Task { @MainActor in
                defer { networkCheckRunning = false }
                var results: [String] = []
                do {
                    _ = try await api(base, "GET", "/health")
                    results.append("Lobby: reachable.")
                } catch {
                    results.append("Lobby: unavailable. Check your Internet connection and lobby address.")
                }
                if let server = servers?.first {
                    let reachable = await NXSTUNProbe.check(server)
                    results.append(reachable ? "STUN: UDP reachable." : "STUN: no valid UDP response. Try another STUN server; check whether your VPN, router or network policy blocks outbound UDP.")
                } else {
                    results.append("STUN: lobby settings are supplied when connecting. Select Cloudflare or Custom to run a standalone UDP check.")
                }
                if gameConnected && liveRoute == "direct" {
                    results.append("Direct play: confirmed with the current player (\(liveRTT) ms round trip).")
                } else if gameConnected && liveRoute == "relay" {
                    results.append("Current game: relayed (\(liveRTT) ms round trip). Relay use alone does not prove direct play is impossible, especially in Relay only mode.")
                } else {
                    results.append("Direct play: not yet verified. Connect both players using Automatic; a STUN response alone cannot prove a direct path.")
                }
                results.append("If Automatic cannot connect directly: check both networks for double NAT, or ask your ISP about carrier-grade NAT and public IPv4/IPv6 access. Keep Automatic enabled to use the relay when needed. Keep your firewall enabled.")
                networkResult.stringValue = results.prefix(2).joined(separator: " ")
                let alert = NSAlert()
                alert.messageText = "Network Check"
                let details = NSTextField(wrappingLabelWithString: results.joined(separator: "\n\n"))
                details.font = .systemFont(ofSize: 13)
                details.preferredMaxLayoutWidth = 620
                details.frame = NSRect(x: 0, y: 0, width: 620, height: 270)
                alert.accessoryView = details
                alert.addButton(withTitle: "Done")
                _ = await alert.beginSheetModal(for: panel)
            }
        } catch { networkResult.stringValue = error.localizedDescription }
    }

    @objc private func saveDefaults() {
        do {
            _ = try selectedSTUN()
            defaults.set(stunProvider.indexOfSelectedItem, forKey: prefix + "stunProvider")
            defaults.set(customSTUN.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: prefix + "customSTUN")
            let base = try baseURL(); let user = try displayName()
            defaults.set(user, forKey: prefix + "displayName"); defaults.set(base.absoluteString, forKey: prefix + "endpoint")
            defaults.set(route.indexOfSelectedItem, forKey: prefix + "route"); defaults.set(delay.indexOfSelectedItem + 1, forKey: prefix + "delay")
            defaults.set(publicRoom.state == .on, forKey: prefix + "public"); defaults.set(protectedRoom.state == .on, forKey: prefix + "passwordRequired")
            defaults.set(spectators.state == .on, forKey: prefix + "spectators"); defaults.set(spectatorLimit.indexOfSelectedItem + 1, forKey: prefix + "spectatorLimit")
            rebuildRelayPicker()
            status.stringValue = "Defaults saved. Passwords and room access tokens stay out of saved preferences."
        } catch { status.stringValue = error.localizedDescription }
    }
}

/// A searchable two-column view of the existing library; never imports or launches games.
@MainActor
private final class NetworkPlayLibraryBrowser: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let roms: [OEDBRom]
    private var systems: [OEDBSystem] = []
    private var visible: [OEDBRom] = []
    private let rail = NSTableView()
    private let games = NSTableView()
    private let search = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let choose = NSButton(title: "Choose Game", target: nil, action: nil)
    private let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 560),
                                 styleMask: [.titled], backing: .buffered, defer: false)
    private var completion: ((OEDBRom?) -> Void)?
    private var initial: OEDBRom?
    init(roms: [OEDBRom], selected: OEDBRom?) {
        self.roms = roms; initial = selected
        super.init()
        systems = Array(Set(roms.compactMap { $0.game?.system })).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        sheet.title = "Choose from Your Library"; sheet.isReleasedWhenClosed = false
        search.placeholderString = "Search games in selected system"; search.delegate = self
        search.setAccessibilityLabel("Search library games")
        rail.setAccessibilityLabel("Library systems"); games.setAccessibilityLabel("Imported games")
        for table in [rail, games] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); column.title = ""
            table.addTableColumn(column); table.headerView = nil; table.rowHeight = 32
            table.delegate = self; table.dataSource = self; table.allowsMultipleSelection = false
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        }
        rail.style = .sourceList; games.style = .plain; games.usesAlternatingRowBackgroundColors = true
        games.target = self; games.doubleAction = #selector(confirm)
        func scroll(_ table: NSTableView) -> NSScrollView {
            let view = NSScrollView(); view.documentView = table; view.hasVerticalScroller = true
            view.autohidesScrollers = true; view.borderType = .bezelBorder; return view
        }
        let sidebar = scroll(rail), list = scroll(games)
        let columns = NSStackView(views: [sidebar, list]); columns.orientation = .horizontal; columns.spacing = 12; columns.alignment = .top
        sidebar.widthAnchor.constraint(equalToConstant: 190).isActive = true
        sidebar.heightAnchor.constraint(equalTo: columns.heightAnchor).isActive = true
        list.heightAnchor.constraint(equalTo: columns.heightAnchor).isActive = true
        list.widthAnchor.constraint(equalTo: columns.widthAnchor, constant: -202).isActive = true
        let heading = NSTextField(labelWithString: "Your Library"); heading.font = .boldSystemFont(ofSize: 20)
        let note = NSTextField(wrappingLabelWithString: "Browse your imported games by system. This preview supports Super Mario Kart NTSC v1.0 only; its file hash is checked before joining.")
        note.textColor = .secondaryLabelColor
        choose.target = self; choose.action = #selector(confirm); choose.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSelection)); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let actions = NSStackView(views: [cancel, choose]); actions.orientation = .horizontal
        let stack = NSStackView(views: [heading, search, columns, count, note, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        sheet.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: sheet.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: sheet.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: sheet.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: sheet.contentView!.bottomAnchor, constant: -20),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor), columns.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor), columns.heightAnchor.constraint(greaterThanOrEqualToConstant: 300)])
    }
    func present(on parent: NSWindow, completion: @escaping (OEDBRom?) -> Void) {
        self.completion = completion
        let systemIndex = initial.flatMap { rom in systems.firstIndex { $0 == rom.game?.system } }.map { $0 + 1 } ?? 0
        rail.selectRowIndexes(IndexSet(integer: systemIndex), byExtendingSelection: false)
        reloadGames()
        if let initial, let index = visible.firstIndex(of: initial) { games.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); games.scrollRowToVisible(index) }
        parent.beginSheet(sheet)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === rail ? systems.count + 1 : visible.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let value: String
        if tableView === rail { value = row == 0 ? "All Systems" : systems[row-1].name }
        else {
            let rom = visible[row]; let title = rom.game?.gameTitle ?? rom.game?.name ?? "Untitled game"
            value = title + "  ·  " + (rom.game?.system?.name ?? "Unknown system") + ((rom.game?.roms.count ?? 0) > 1 ? "  ·  " + (rom.fileName ?? "ROM") : "")
        }
        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = .byTruncatingTail; field.toolTip = value
        field.maximumNumberOfLines = 1; field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field); cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === rail { reloadGames() }
        choose.isEnabled = visible.indices.contains(games.selectedRow)
    }
    func controlTextDidChange(_ obj: Notification) { reloadGames() }
    private func reloadGames() {
        let selected = visible.indices.contains(games.selectedRow) ? visible[games.selectedRow] : nil
        let system = rail.selectedRow > 0 ? systems[rail.selectedRow-1] : nil
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visible = roms.filter { rom in
            (system == nil || rom.game?.system == system) && (query.isEmpty || (rom.game?.gameTitle ?? rom.game?.name ?? "").localizedStandardContains(query))
        }.sorted { ($0.game?.gameTitle ?? $0.game?.name ?? "").localizedStandardCompare($1.game?.gameTitle ?? $1.game?.name ?? "") == .orderedAscending }
        games.reloadData(); games.deselectAll(nil)
        if let selected, let index = visible.firstIndex(of: selected) { games.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        choose.isEnabled = visible.indices.contains(games.selectedRow)
        count.stringValue = visible.isEmpty ? (roms.isEmpty ? "Your library is empty. Import games in OpenEmu first." : "No games match this search.") : "\(visible.count) imported game(s)"
    }
    @objc private func confirm() {
        guard visible.indices.contains(games.selectedRow) else { return }
        finish(visible[games.selectedRow])
    }
    @objc private func cancelSelection() { finish(nil) }
    private func finish(_ rom: OEDBRom?) {
        sheet.sheetParent?.endSheet(sheet); sheet.orderOut(nil)
        let callback = completion; completion = nil; callback?(rom)
    }
}

// MARK: - Bounded UDP STUN check (no room or gameplay mutations)
private final class NXSTUNProbe: @unchecked Sendable {
    // All mutable state is confined to this serial queue.
    private let queue = DispatchQueue(label: "net.openemu.nx.stun-check")
    private var finished = false
    private var connection: NWConnection?
    private var completion: ((Bool) -> Void)?
    private let transaction = (0..<12).map { _ in UInt8.random(in: 0...255) }

    static func server(_ value: String) -> (String, UInt16)? {
        guard value.range(of: "^[A-Za-z0-9.-]{1,253}:[0-9]{1,5}$", options: .regularExpression) != nil else { return nil }
        let parts = value.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]), port > 0 else { return nil }
        return (String(parts[0]), port)
    }

    static func validResponse(_ data: Data, transaction: [UInt8]) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 20, bytes.count <= 2048, transaction.count == 12,
              bytes[0] == 1, bytes[1] == 1,
              Array(bytes[4..<8]) == [0x21, 0x12, 0xa4, 0x42],
              Array(bytes[8..<20]) == transaction else { return false }
        let size = Int(bytes[2]) * 256 + Int(bytes[3])
        guard size % 4 == 0, size + 20 == bytes.count else { return false }
        var offset = 20, mapped = false
        while offset < bytes.count {
            guard offset + 4 <= bytes.count else { return false }
            let type = Int(bytes[offset]) * 256 + Int(bytes[offset+1])
            let length = Int(bytes[offset+2]) * 256 + Int(bytes[offset+3])
            offset += 4
            guard offset + length <= bytes.count else { return false }
            if type == 0x20 {
                guard length >= 4, bytes[offset] == 0 else { return false }
                let family = bytes[offset+1]
                guard (family == 1 && length == 8) || (family == 2 && length == 20) else { return false }
                mapped = true
            }
            offset += (length + 3) & ~3
        }
        return mapped && offset == bytes.count
    }

    static func check(_ address: String) async -> Bool {
        guard let (host, port) = server(address) else { return false }
        return await withCheckedContinuation { continuation in
            let probe = NXSTUNProbe()
            probe.queue.async {
                probe.completion = { continuation.resume(returning: $0) }
                let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
                probe.connection = connection
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        probe.receive()
                        probe.send()
                        for delay in [1.0, 2.5] {
                            probe.queue.asyncAfter(deadline: .now() + delay) { probe.send() }
                        }
                    case .failed: probe.finish(false)
                    default: break
                    }
                }
                probe.queue.asyncAfter(deadline: .now() + 5) { probe.finish(false) }
                connection.start(queue: probe.queue)
            }
        }
    }

    private func send() {
        guard !finished else { return }
        let request = Data([0, 1, 0, 0, 0x21, 0x12, 0xa4, 0x42] + transaction)
        connection?.send(content: request, completion: .contentProcessed { [self] error in
            if error != nil { finish(false) }
        })
    }
    private func receive() {
        connection?.receiveMessage { [self] data, _, _, error in
            guard !finished else { return }
            if let data, Self.validResponse(data, transaction: transaction) { finish(true) }
            else if error != nil { finish(false) }
            else { receive() }
        }
    }
    private func finish(_ result: Bool) {
        guard !finished else { return }
        finished = true
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        let callback = completion; completion = nil
        callback?(result)
    }
}
