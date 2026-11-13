// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
import Cocoa
import CoreData
import Network
import QuartzCore
import Darwin
import OpenEmuSystem
import OpenEmuBase

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

// Network input uses the same responder and live bindings as local emulation.
// Local player one is mapped to this machine's negotiated network slot.
private final class NetworkInputResponder: OESystemResponder, OESystemResponderClient, OESystemBindingsObserver {
    private var bindings: OESystemBindings?
    private var monitor: Any?
    private var memory: UnsafeMutableRawPointer?
    private var mask: UInt32 = 0
    private var frameCallback: ((TimeInterval) -> Void)?
    private var timer: Timer?
    let inputURL: URL

    init(system: OESystemController) throws {
        inputURL = FileManager.default.temporaryDirectory.appendingPathComponent("nx-input-" + UUID().uuidString)
        super.init(controller: system)
        let fd = Darwin.open(inputURL.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(fd) }
        guard ftruncate(fd, 516) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let ptr = mmap(nil, 516, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard ptr != MAP_FAILED, let ptr else { throw CocoaError(.fileWriteUnknown) }
        memory = ptr; ptr.initializeMemory(as: UInt8.self, repeating: 0, count: 516)
        client = self
        bindings = OEBindingsController.default.systemBindings(for: system)
        bindings?.add(self)
        monitor = OEDeviceManager.shared.addGlobalEventMonitorHandler { [weak self] _, event in
            if event.type.rawValue != 4 { self?.handle(event) }
            return true
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.frameCallback?(1.0 / 60)
        }
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func stop() {
        timer?.invalidate(); timer = nil
        if let monitor { OEDeviceManager.shared.removeMonitor(monitor) }; monitor = nil
        bindings?.remove(self); bindings = nil
        if let memory { memory.storeBytes(of: UInt32(0), as: UInt32.self); munmap(memory, 516) }; memory = nil
        try? FileManager.default.removeItem(at: inputURL)
    }
    override func pressEmulatorKey(_ key: OESystemKey) {
        guard key.player == 1, key.key < 12 else { return }
        mask |= UInt32(1) << key.key; memory?.storeBytes(of: mask, as: UInt32.self)
    }
    override func releaseEmulatorKey(_ key: OESystemKey) {
        guard key.player == 1, key.key < 12 else { return }
        mask &= ~(UInt32(1) << key.key); memory?.storeBytes(of: mask, as: UInt32.self)
    }
    func systemBindings(_ sender: OESystemBindings, didSetEvent event: OEHIDEvent, forBinding binding: OEBindingDescription, playerNumber: UInt) {
        if event.type.rawValue == 4 {
            if playerNumber == 1, let key = binding as? OEKeyBindingDescription,
               key.index < 12, event.virtualKeyCode < 128 {
                memory?.storeBytes(of: UInt32(1) << key.index, toByteOffset: 4 + Int(event.virtualKeyCode) * 4, as: UInt32.self)
            }
            return
        }
        systemBindingsDidSetEvent(event, forBinding: binding, playerNumber: playerNumber)
    }
    func systemBindings(_ sender: OESystemBindings, didUnsetEvent event: OEHIDEvent, forBinding binding: OEBindingDescription, playerNumber: UInt) {
        mask = 0; memory?.storeBytes(of: mask, as: UInt32.self)
        if event.type.rawValue == 4 {
            if playerNumber == 1, event.virtualKeyCode < 128 {
                memory?.storeBytes(of: UInt32(0), toByteOffset: 4 + Int(event.virtualKeyCode) * 4, as: UInt32.self)
            }
            return
        }
        systemBindingsDidUnsetEvent(event, forBinding: binding, playerNumber: playerNumber)
    }
    func perform(_ block: @escaping () -> Void) { block() }
    func setFrameCallback(_ block: @escaping (TimeInterval) -> Void) { frameCallback = block }
    func fastForward(_ flag: Bool) {}
    func fastForward(atSpeed speed: CGFloat) {}
    func rewind(_ flag: Bool) {}
    func rewind(atSpeed speed: CGFloat) {}
    func slowMotion(atSpeed speed: CGFloat) {}
    func stepFrameForward() {}
    func stepFrameBackward() {}
}

// Identifier fields must not open prose-completion panels. AppKit's
// automaticTextCompletionEnabled controls Touch Bar candidates, not the regular
// completion panel, so also suppress the documented NSCompletion entry points.
@MainActor
private final class NetworkPlayIdentifierEditor: NSTextView {
    func configurePlainInput() {
        isRichText = false
        isAutomaticTextCompletionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        enabledTextCheckingTypes = 0
        if #available(macOS 14.0, *) { inlinePredictionType = .no }
        if #available(macOS 15.0, *) {
            writingToolsBehavior = .none
            mathExpressionCompletionType = .no
        }
    }

    override func becomeFirstResponder() -> Bool {
        // NSTextField configures its field editor after requesting it from the
        // window delegate. Apply the policy at editing time, not only at init.
        configurePlainInput()
        let accepted = super.becomeFirstResponder()
        configurePlainInput()
        return accepted
    }

    // AppKit may reapply the user's text preferences after first responder
    // setup. Keep these policies fixed for identifiers rather than allowing
    // a later field-editor configuration to re-enable suggestion panels.
    override var isAutomaticTextCompletionEnabled: Bool {
        get { false }
        set { super.isAutomaticTextCompletionEnabled = false }
    }
    override var isAutomaticSpellingCorrectionEnabled: Bool {
        get { false }
        set { super.isAutomaticSpellingCorrectionEnabled = false }
    }
    @available(macOS 14.0, *)
    override var inlinePredictionType: NSTextInputTraitType {
        get { .no }
        set { super.inlinePredictionType = .no }
    }
    override var rangeForUserCompletion: NSRange { NSRange(location: NSNotFound, length: 0) }
    override func complete(_ sender: Any?) {}
    override func completions(forPartialWordRange charRange: NSRange,
                              indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? { [] }
    override func updateCandidates() {}
}

@MainActor
final class NetworkPlayController: NSObject, NSMenuItemValidation, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTabViewDelegate, NSSplitViewDelegate, NSWindowDelegate {
    static let shared = NetworkPlayController()
    private let defaults = UserDefaults.standard
    private let prefix = "networkPlay."
    private lazy var identifierEditor: NetworkPlayIdentifierEditor = {
        let editor = NetworkPlayIdentifierEditor()
        editor.isFieldEditor = true
        editor.configurePlainInput()
        return editor
    }()
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard let field = client as? NSTextField,
              [title, name, hostName, invite].contains(where: { $0 === field }) else { return nil }
        return identifierEditor
    }
    private var panel: NSWindow!
    private let tabs = NSTabView()
    private var designNavigation: [NXDesignButton] = []
    private let navigation = NSSegmentedControl(labels: ["Host Game", "Join Game", "Relays", "Settings"], trackingMode: .selectOne, target: nil, action: nil)
    private let joinIdentity = NSTextField(wrappingLabelWithString: "")
    private let romMatch = NSTextField(wrappingLabelWithString: "")
    private let keepUncompressed = NXDesignCheckbox(checkboxWithTitle: "Keep uncompressed copies for netplay", target: nil, action: nil)
    private var verifiedSHA: String?
    private var downloadButton: NSButton!
    private var exportButton: NSButton!
    private var hostOptionsDirty = false
    private var directoryTask: Task<Void, Never>?
    private var directoryRefreshing = false
    private var operationError: String?
    private var artworkKey = ""
    private var statusSplit: NSSplitView?
    private var statusPaneView: NSView?
    private var gameHeaderView: NSView?
    private var actionSurfaceView: NSView?
    private var saveNoteView: NSView?
    private var savedStatusHeight: CGFloat = 150
    private var arrangingStatus = false
    private let name = NSTextField(string: "")
    private let hostName = NSTextField(string: "")
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
    private let playerLimit = NSPopUpButton()
    private var joiningPlayerCount: Int?
    private var selectedPlayerCount: Int {
        room?["capacity"] as? Int ?? joiningPlayerCount ?? (selectedROM?.game?.system?.systemIdentifier == "openemu.system.snes" ? max(2, playerLimit.indexOfSelectedItem + 2) : 2)
    }
    private let publicRoom = NXDesignCheckbox(checkboxWithTitle: "List this game publicly", target: nil, action: nil)
    private let protectedRoom = NXDesignCheckbox(checkboxWithTitle: "Require a room password", target: nil, action: nil)
    private let password = NSSecureTextField(string: "")
    private let shareROM = NXDesignCheckbox(checkboxWithTitle: "Allow game downloads for players", target: nil, action: nil)
    private var transferProcess: Process?
    private let transferProgress = NSProgressIndicator()
    private var promptedROMRequests = Set<String>()
    private var connectPulseActive = false
    private let cancelTransferButton = NSButton(title: "Cancel ROM Transfer", target: nil, action: nil)
    private let spectators = NXDesignCheckbox(checkboxWithTitle: "Allow spectators", target: nil, action: nil)
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
    private let gameArtwork = NSImageView()
    private let gameValidation = NSTextField(wrappingLabelWithString: "")
    private var selectionRevision = UUID()
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
    private let resumeLabel = NSTextField(wrappingLabelWithString: "")
    private var resumeURL: URL?
    private var currentAutosaveURL: URL?
    private var gameProcess: Process?
    private var networkInput: NetworkInputResponder?
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
    private var roomEventsTask: Task<Void, Never>?
    private var roomSocket: URLSessionWebSocketTask?
    private var roomEventsConnected = false
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
        for (label, action) in [("Host…", #selector(showHost)), ("Join…", #selector(showJoin)),
                                ("Network Settings…", #selector(showSettings))] {
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
    @objc private func showBrowse() { show(1); if !busy { refreshDirectory() } }
    @objc private func showRelays() { show(2); if !busy { refreshDirectory() } }
    @objc private func showSettings() { show(3) }
    @objc private func showRoom() { show(0) }
    private func show(_ index: Int) {
        if panel == nil { buildWindow() }
        navigation.selectedSegment = index
        tabs.selectTabViewItem(at: index)
        refreshArtwork()
        refreshJoinIdentity()
        refreshControls()
        if room == nil && !busy && index < 3 { refreshDirectory() }
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
        let result = NXDesignButton(title: title, target: self, action: action)
        result.bezelStyle = .rounded; operationButtons.append(result); return result
    }
    private func tab(_ title: String, _ views: [NSView]) {
        let item = NSTabViewItem(identifier: title); item.label = title
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let holder = NXNetworkDocumentView(); let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16; stack.distribution = .fill
        holder.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = holder; holder.addSubview(stack)
        NSLayoutConstraint.activate([
            holder.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: holder.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -16)])
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if view is NSScrollView { view.heightAnchor.constraint(equalToConstant: 220).isActive = true }
        }
        if title == "Host Game" {
            // The host form is fixed; reserve its complete height above the divider.
            stack.removeFromSuperview()
            let fixed = NSView(); fixed.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: fixed.leadingAnchor, constant: 4),
                stack.trailingAnchor.constraint(equalTo: fixed.trailingAnchor, constant: -4),
                stack.topAnchor.constraint(equalTo: fixed.topAnchor, constant: 12),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: fixed.bottomAnchor, constant: -12)])
            item.view = fixed
        } else { item.view = scroll }
        tabs.addTabViewItem(item)
    }
    private func settingsColumn(_ heading: String, _ views: [NSView]) -> NSView {
        let headingLabel = label(heading); headingLabel.font = .boldSystemFont(ofSize: 14)
        let stack = NSStackView(views: [headingLabel] + views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            view.setContentHuggingPriority(.required, for: .vertical)
        }
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.distribution = .fill
        return NXContentSurface(content: stack)
    }
    private func fieldGroup(_ caption: String, _ control: NSView) -> NSStackView {
        let captionLabel = label(caption)
        if caption == "Relay Fallback" { captionLabel.font = .boldSystemFont(ofSize: 13) }
        let stack = NSStackView(views: [captionLabel, control])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6; stack.distribution = .fill
        stack.setContentHuggingPriority(.required, for: .vertical)
        control.setContentHuggingPriority(.required, for: .vertical)
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }
    private func buildWindow() {
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 940),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = "Network Play"; panel.isReleasedWhenClosed = false
        NXDesign.apply(to: panel)
        panel.delegate = self
        panel.titleVisibility = .hidden
        if let frameView = panel.contentView?.superview, let close = panel.standardWindowButton(.closeButton) {
            let centeredTitle = label("Network Play"); centeredTitle.font = .boldSystemFont(ofSize: 13)
            centeredTitle.translatesAutoresizingMaskIntoConstraints = false; frameView.addSubview(centeredTitle)
            NSLayoutConstraint.activate([centeredTitle.centerXAnchor.constraint(equalTo: frameView.centerXAnchor),
                centeredTitle.centerYAnchor.constraint(equalTo: close.centerYAnchor)])
        }
        panel.contentMinSize = NSSize(width: 840, height: 700)
        panel.center()
        name.stringValue = defaults.string(forKey: prefix + "displayName") ?? ""
        hostName.stringValue = name.stringValue
        let central = Bundle.main.object(forInfoDictionaryKey: "NXCentralLobbyURL") as? String ?? "https://lobby.azimuthsystems.net"
        let savedEndpoint = defaults.string(forKey: prefix + "endpoint")
        let retiredDefaults = ["https://netplay.azimuthsystems.net", "https://97s93wu2jc.execute-api.us-west-2.amazonaws.com"]
        endpoint.stringValue = savedEndpoint == nil || retiredDefaults.contains(savedEndpoint!.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) ? central : savedEndpoint!
        defaults.set(endpoint.stringValue, forKey: prefix + "endpoint")
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
        // Room/player names and invite codes are plain identifiers, not prose.
        // Keep system completion and Writing Tools popovers out of this form.
        for field in [title, name, hostName, invite] {
            field.isAutomaticTextCompletionEnabled = false
            if #available(macOS 15.2, *) { field.allowsWritingTools = false }
        }
        title.placeholderString = "Leave blank to use the game name"
        title.stringValue = defaults.string(forKey: prefix + "roomName") ?? ""
        publicRoom.state = defaults.bool(forKey: prefix + "public") ? .on : .off
        protectedRoom.state = defaults.bool(forKey: prefix + "passwordRequired") ? .on : .off
        spectators.state = defaults.bool(forKey: prefix + "spectators") ? .on : .off
        playerLimit.addItems(withTitles: (2...5).map { "\($0) players" })
        playerLimit.target = self; playerLimit.action = #selector(optionsChanged)
        playerLimit.toolTip = "SNES multitap is experimental. Choose the number supported by this game; all selected players must join before starting."
        spectatorLimit.addItems(withTitles: (1...16).map(String.init))
        spectatorLimit.selectItem(at: min(max(defaults.integer(forKey: prefix + "spectatorLimit") - 1, 0), 15))
        if defaults.object(forKey: prefix + "spectatorLimit") == nil { spectatorLimit.selectItem(at: 3) }
        for control in [publicRoom, protectedRoom, spectators, shareROM] { control.target = self; control.action = #selector(optionsChanged) }
        for popup in [joinRole, browseRole] { popup.addItems(withTitles: ["Player", "Spectator"]); popup.setAccessibilityLabel("Join as") }
        for field in [password, joinPassword, browsePassword] { field.placeholderString = "Room password (if required)"; field.setAccessibilityLabel("Room password") }
        for field in [name, hostName] {
            field.placeholderString = "Enter Player Name Here"
            field.setAccessibilityLabel("Player name")
            field.delegate = self
        }
        name.setAccessibilityLabel("Player name"); endpoint.setAccessibilityLabel("Lobby server")
        title.setAccessibilityLabel("Room name"); invite.setAccessibilityLabel("Invite code")
        title.delegate = self; password.delegate = self; name.delegate = self
        spectatorLimit.target = self; spectatorLimit.action = #selector(optionsChanged)
        invite.delegate = self; invite.placeholderString = "ABCD-EFGH"
        // Selection belongs to this library, not to an arbitrary external path.
        defaults.removeObject(forKey: prefix + "gamePath")
        if let context = OELibraryDatabase.default?.mainThreadContext,
           let saved = defaults.string(forKey: prefix + "romID"), let uri = URL(string: saved),
           let id = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: uri),
           let rom = try? context.existingObject(with: id) as? OEDBRom, !rom.isDeleted {
            selectedROM = rom; updateSelectedGame()
        }
        createButton = button("Create Room", #selector(createRoom))
        updateButton = button("Save Room Changes", #selector(updateHost))
        joinButton = button("Join Room", #selector(joinInvite))
        browseJoinButton = button("Join Room", #selector(joinListed))
        saveButton = button("Save Defaults", #selector(saveDefaults))
        resumeGameButton = button("Resume Multiplayer Game…", #selector(chooseMultiplayerSave))
        newGameButton = button("Start Fresh", #selector(clearMultiplayerSave))
        cancelTransferButton.target = self; cancelTransferButton.action = #selector(cancelROMTransfer); cancelTransferButton.isHidden = true
        rebuildRelayPicker()
        relayPicker.target = self; relayPicker.action = #selector(selectRelay)
        relayPicker.setAccessibilityLabel("Relay fallback")
        roomList.target = self; roomList.doubleAction = #selector(joinListed)
        let joinItem = NSTabViewItem(identifier: "Join Game"); joinItem.label = "Join Game"
        let joinHolder = NSView()
        let hostList = makeDirectoryTable(roomList, columns: [("game", "Game / Host", 230), ("relay", "Relay", 170), ("players", "Players", 70), ("options", "Options", 130)])
        hostList.autohidesScrollers = true
        roomList.rowHeight = 44
        hostList.heightAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        let joinFields = NSStackView(views: [row("Player name", name), row("Join as", joinRole),
            row("Invite code", invite), row("Room password", joinPassword)])
        joinFields.orientation = .vertical; joinFields.alignment = .leading; joinFields.spacing = 8
        joinFields.distribution = .fill
        for fieldRow in joinFields.arrangedSubviews {
            fieldRow.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        joinFields.heightAnchor.constraint(equalToConstant: 136).isActive = true
        joinFields.setContentHuggingPriority(.required, for: .vertical)
        joinFields.setContentCompressionResistancePriority(.required, for: .vertical)
        let refreshGames = button("Refresh Games", #selector(refreshDirectory))
        refreshGames.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let refreshRow = NSStackView(views: [refreshGames, NSView()])
        refreshRow.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let joinStack = NSStackView(views: [joinFields, hostList, refreshRow])
        joinStack.orientation = .vertical; joinStack.alignment = .leading; joinStack.spacing = 12; joinStack.distribution = .fill
        joinStack.translatesAutoresizingMaskIntoConstraints = false; joinHolder.addSubview(joinStack)
        NSLayoutConstraint.activate([joinStack.leadingAnchor.constraint(equalTo: joinHolder.leadingAnchor),
            joinStack.trailingAnchor.constraint(equalTo: joinHolder.trailingAnchor),
            joinStack.topAnchor.constraint(equalTo: joinHolder.topAnchor),
            joinStack.bottomAnchor.constraint(equalTo: joinHolder.bottomAnchor, constant: -10),
            hostList.widthAnchor.constraint(equalTo: joinStack.widthAnchor),
            refreshRow.widthAnchor.constraint(equalTo: joinStack.widthAnchor)])
        hostList.setContentHuggingPriority(.defaultLow, for: .vertical)
        hostList.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        joinItem.view = joinHolder; tabs.addTabViewItem(joinItem)
        tab("Relays", [makeDirectoryTable(relayTable, columns: [("name", "Relay / Region", 220), ("operator", "Operator", 180), ("health", "Status", 140)]),
                       NSStackView(views: [button("Refresh Relays", #selector(refreshDirectory)), button("Use Selected Relay", #selector(useSelectedRelay)), button("Register a Relay…", #selector(registerRelay))])])
        keepUncompressed.state = defaults.bool(forKey: prefix + "keepUncompressed") ? .on : .off
        keepUncompressed.target = self; keepUncompressed.action = #selector(saveROMCachePreference)
        let connectionSettings = settingsColumn("Connection", [
            fieldGroup("Lobby server", endpoint), fieldGroup("Connection preference", route),
            fieldGroup("STUN service", stunProvider), fieldGroup("Custom STUN server", customSTUN),
            label("Direct play is tried first. A relay carries gameplay only when a direct connection is unavailable."),
            button("Check Network…", #selector(checkNetwork)), networkResult])
        let loadingSettings = settingsColumn("Game Loading", [keepUncompressed,
            label("Keep an extracted copy for faster netplay loading. This uses additional disk space; original ROMs and saves stay unchanged."),
            fieldGroup("Input response", label("Rollback · no added input delay")),
            label("Each player uses their own saved controller settings."),
            label("STUN discovers connection routes. The selected provider sees your public network address. Changes apply to the next connection.")])
        let settingsGroups = NSStackView(views: [connectionSettings, loadingSettings])
        settingsGroups.orientation = .horizontal; settingsGroups.alignment = .top
        settingsGroups.spacing = 20; settingsGroups.distribution = .fillEqually
        tab("Settings", [settingsGroups, saveButton])
        chooseButton = button("Choose Game…", #selector(chooseGame))
        copyButton = button("Copy Invite", #selector(copyInvite))
        leaveButton = button("Leave Room", #selector(leaveRoom))
        launchButton = button("Create Room", #selector(primaryRoomAction))
        gameArtwork.imageScaling = .scaleProportionallyUpOrDown
        gameArtwork.setAccessibilityLabel("Selected game artwork")
        NXDesign.addArtworkShadow(to: gameArtwork)
        gameArtwork.widthAnchor.constraint(equalToConstant: 140).isActive = true
        gameArtwork.heightAnchor.constraint(equalToConstant: 120).isActive = true
        gameLabel.font = .boldSystemFont(ofSize: 21)
        gameValidation.font = .systemFont(ofSize: 12)
        let details = NSStackView(views: [gameLabel, gameValidation]); details.orientation = .vertical; details.alignment = .leading
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chooseButton.setContentHuggingPriority(.required, for: .horizontal)
        let top = NSStackView(views: [gameArtwork, details, spacer, chooseButton]); top.orientation = .horizontal; top.spacing = 12
        transferProgress.isHidden = true; transferProgress.style = .bar; transferProgress.minValue = 0; transferProgress.maxValue = 100
        status.textColor = .secondaryLabelColor
        let directHint = label("Direct connection is tried first. The relay is used only when needed.")
        directHint.textColor = .secondaryLabelColor
        let resumeActions = NSStackView(views: [resumeGameButton, newGameButton])
        resumeActions.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let roomColumn = settingsColumn("Room", [fieldGroup("Player name", hostName), fieldGroup("Room name", title),
            fieldGroup("Relay Fallback", relayPicker), directHint,
            fieldGroup("Saved Multiplayer Session", resumeActions), resumeLabel])
        let downloadHint = label("Players only, with your approval. Spectators cannot download games.")
        downloadHint.textColor = .secondaryLabelColor
        let accessColumn = settingsColumn("Access & Players", [fieldGroup("Players", playerLimit), publicRoom, protectedRoom,
            fieldGroup("Room password", password), spectators, fieldGroup("Spectator limit", spectatorLimit), shareROM, downloadHint])
        let columns = NSStackView(views: [roomColumn, accessColumn])
        columns.orientation = .horizontal; columns.alignment = .top; columns.spacing = 20; columns.distribution = .fillEqually
        roomColumn.widthAnchor.constraint(equalTo: accessColumn.widthAnchor).isActive = true
        let createActions = NSStackView(views: [NSView(), updateButton])
        tab("Host Game", [columns, createActions])
        let hostTab = tabs.tabViewItems.last!; tabs.removeTabViewItem(hostTab); tabs.insertTabViewItem(hostTab, at: 0)
        tabs.tabViewType = .noTabsNoBorder
        navigation.segmentStyle = .rounded; navigation.controlSize = .large
        navigation.target = self; navigation.action = #selector(selectSection); navigation.selectedSegment = 0
        tabs.selectTabViewItem(at: 0)
        for primary in [launchButton!, createButton!] {
            if #available(macOS 26.0, *) { primary.bezelStyle = .glass } else { primary.bezelStyle = .rounded }
            primary.controlSize = .large; primary.font = .boldSystemFont(ofSize: 15)
            primary.heightAnchor.constraint(equalToConstant: 44).isActive = true
            primary.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
            (primary as? NXDesignButton)?.primary = true
        }
        downloadButton = button("Download Game…", #selector(downloadGame))
        exportButton = button("Export Multiplayer Save…", #selector(saveMultiplayerGame))

        let actions = NSStackView(views: [leaveButton, copyButton, downloadButton, cancelTransferButton, NSView(), launchButton])
        actions.spacing = 10
        let statusHeading = label("Game Status"); statusHeading.font = .boldSystemFont(ofSize: 13)
        let footer = NSStackView(views: [statusHeading, roomStatus, romMatch, status, transferProgress])
        footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 10; footer.distribution = .fill
        for view in [roomStatus, romMatch, status, transferProgress] {
            view.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
            view.setContentCompressionResistancePriority(.required, for: .vertical)
            view.setContentHuggingPriority(.required, for: .vertical)
        }
        designNavigation = ["Host Game", "Join Game", "Relays", "Settings"].enumerated().map { index, title in
            let button = NXDesignButton(title: title, target: nil, action: nil)
            button.tabStyle = true; button.filledTab = true; button.selected = index == 0
            button.handler = { [weak self, weak button] in
                guard let self else { return }
                self.navigation.selectedSegment = index
                self.panel.makeFirstResponder(button)
                self.selectSection()
            }
            button.target = button; button.action = #selector(NXDesignButton.invoke)
            return button
        }
        let navigationSurface = NSStackView(views: designNavigation)
        navigationSurface.spacing = 28
        // Keep actions as floating native glass controls, not a full-width glass slab.
        let actionSurface = actions
        actions.alignment = .centerY
        actions.heightAnchor.constraint(equalToConstant: 48).isActive = true
        for control in [leaveButton, copyButton, downloadButton, cancelTransferButton].compactMap({ $0 }) {
            control.controlSize = .large
            if #available(macOS 26.0, *) { control.bezelStyle = .glass }
        }
        let saveNote = NSStackView(views: [label("The host’s multiplayer game saves automatically."), exportButton])
        let statusPane = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false; statusPane.addSubview(footer)
        NSLayoutConstraint.activate([footer.topAnchor.constraint(equalTo: statusPane.topAnchor, constant: 14),
            footer.leadingAnchor.constraint(equalTo: statusPane.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: statusPane.trailingAnchor),
            footer.bottomAnchor.constraint(lessThanOrEqualTo: statusPane.bottomAnchor, constant: -8)])
        let split = NSSplitView(); statusSplit = split; statusPaneView = statusPane; gameHeaderView = top; actionSurfaceView = actionSurface; saveNoteView = saveNote
        split.isVertical = false; split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(tabs); split.addArrangedSubview(statusPane)
        let navigationRow = NSView()
        navigationSurface.translatesAutoresizingMaskIntoConstraints = false; navigationRow.addSubview(navigationSurface)
        NSLayoutConstraint.activate([navigationSurface.centerXAnchor.constraint(equalTo: navigationRow.centerXAnchor),
            navigationSurface.topAnchor.constraint(equalTo: navigationRow.topAnchor),
            navigationSurface.bottomAnchor.constraint(equalTo: navigationRow.bottomAnchor)])
        let stack = NSStackView(views: [navigationRow, top, split, actionSurface, saveNote])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18; stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -20),
            navigationRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor),
            split.widthAnchor.constraint(equalTo: stack.widthAnchor),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
            actionSurface.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        NXDesign.apply(to: panel)
        panel.contentView?.layoutSubtreeIfNeeded()
        layoutStatusSplit(split)
        footer.setContentHuggingPriority(.required, for: .vertical)
        footer.setContentCompressionResistancePriority(.required, for: .vertical)
        tabs.delegate = self
        updateSelectedGame()
        refreshControls()
        directoryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                guard let self else { return }
                guard self.panel.isVisible else { continue }
                self.refreshArtwork()
                // Public catalogs refresh only on opening or explicit request.
            }
        }
    }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        // Switching tabs uses the cached catalog; explicit Refresh fetches changes.
        refreshControls()
    }
    @objc private func selectSection() {
        tabs.selectTabViewItem(at: navigation.selectedSegment)
        refreshJoinIdentity()
        refreshControls()
    }
    private func refreshJoinIdentity() {
        let value = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        joinIdentity.stringValue = value.isEmpty ? "Your name is not set. Enter a player name above before joining." : "Joining as \(value)"
    }
    @objc private func optionsChanged() { hostOptionsDirty = room?["role"] as? String == "host"; refreshControls() }
    private func refreshControls() {
        guard panel != nil else { return }
        for (index, button) in designNavigation.enumerated() { button.selected = index == navigation.selectedSegment }
        updatePageLayout()
        roomStatus.isHidden = roomStatus.stringValue.isEmpty
        romMatch.isHidden = romMatch.stringValue.isEmpty
        for button in operationButtons { button.isEnabled = !busy }
        shareROM.isEnabled = !busy && gameProcess == nil
        resumeGameButton.isEnabled = !busy && room == nil && gameProcess == nil
        resumeLabel.isHidden = resumeURL == nil
        newGameButton.isHidden = resumeURL == nil
        newGameButton.isEnabled = !busy && room == nil && resumeURL != nil
        let isHost = room?["role"] as? String == "host"
        let waitingForPlayer = isHost && (room?["occupancy"] as? Int ?? 0) < selectedPlayerCount
        let waitingForHost = room != nil && !isHost && room?["state"] as? String != "playing"
        let transferState = (room?["rom_request"] as? [String: Any])?["status"] as? String
        let transferPending = transferProcess != nil || room?["state"] as? String == "transferring" || transferState == "pending" || transferState == "approved"
        let creatingRoom = room == nil && navigation.selectedSegment == 0
        let joiningRoom = room == nil && navigation.selectedSegment == 1
        let hasInvite = !invite.stringValue.isEmpty
        let selectedHost = listedRooms.indices.contains(roomList.selectedRow) ? listedRooms[roomList.selectedRow] : nil
        let joinTitle = hasInvite ? "Join by Code" : selectedHost.map { "Join " + String(($0["host_name"] as? String ?? $0["title"] as? String ?? "Host").prefix(32)) } ?? "Join Game"
        launchButton.title = creatingRoom ? "Create Room" : joiningRoom ? joinTitle : gameConnected ? "Connected" : (gameLaunching || gameProcess != nil) ? "Connecting…" : waitingForHost ? "Waiting for host to start…" : isHost ? "Start Game" : "Connect to Game"
        playerLimit.isEnabled = !busy && room == nil && gameProcess == nil && selectedROM?.game?.system?.systemIdentifier == "openemu.system.snes"
        relayPicker.isEnabled = !busy && room == nil && gameProcess == nil
        launchButton.isEnabled = !busy && gameProcess == nil && (creatingRoom ? selectedROM != nil : joiningRoom ? (!name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (hasInvite || selectedHost != nil)) : room != nil && !waitingForPlayer && !waitingForHost && !transferPending && verifiedSHA != nil)
        launchButton.isHidden = navigation.selectedSegment > 1
        launchButton.keyEquivalent = launchButton.isEnabled && !launchButton.isHidden ? "\r" : ""
        launchButton.toolTip = waitingForPlayer ? "Waiting for all selected players to join before starting." : nil
        updateConnectPulse(launchButton.isEnabled && room != nil && !gameConnected)
        createButton.isEnabled = !busy && room == nil && gameProcess == nil
        joinButton.isEnabled = !busy && room == nil && gameProcess == nil
        browseJoinButton.isEnabled = !busy && room == nil && gameProcess == nil && listedRooms.indices.contains(roomList.selectedRow)
        copyButton.isHidden = room?["role"] as? String != "host"
        copyButton.isEnabled = !busy && room?["role"] as? String == "host" && room?["invite_code"] is String
        leaveButton.isEnabled = !busy && room != nil
        updateButton.isHidden = !isHost || !hostOptionsDirty
        updateButton.isEnabled = !busy && isHost && hostOptionsDirty
        createButton.isHidden = room != nil
        downloadButton.isHidden = room == nil || isHost || room?["role"] as? String == "spectator" || verifiedSHA != nil || room?["allow_downloads"] as? Bool != true
        downloadButton.isEnabled = !busy && !transferPending && room?["state"] as? String != "playing"
        exportButton.isHidden = currentAutosaveURL == nil
        exportButton.isEnabled = !busy && currentAutosaveURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
        chooseButton.isEnabled = !busy && room == nil; saveButton.isEnabled = !busy && room == nil
        endpoint.isEnabled = !busy && room == nil; name.isEnabled = !busy && room == nil; hostName.isEnabled = name.isEnabled
        refreshJoinIdentity()
        let editable = !busy && (room == nil || isHost)
        for control in [publicRoom, protectedRoom, spectators, shareROM] { control.isEnabled = editable }
        title.isEnabled = editable && (room?["occupancy"] as? Int ?? 1) < 2
        password.isEnabled = editable && protectedRoom.state == .on && (room?["occupancy"] as? Int ?? 1) < 2
        spectatorLimit.isEnabled = editable && spectators.state == .on
        publicRoom.isEnabled = editable && (room?["occupancy"] as? Int ?? 1) < 2
        protectedRoom.isEnabled = publicRoom.isEnabled
    }
    private func updateConnectPulse(_ ready: Bool) {
        let animate = ready && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animate != connectPulseActive else { return }
        connectPulseActive = animate; launchButton.wantsLayer = true
        launchButton.layer?.removeAnimation(forKey: "connectReady")
        if animate {
            // Animate the native glass rendering, never a rectangular backing fill.
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.72
            pulse.toValue = 1.0
            pulse.duration = 1.2
            pulse.autoreverses = true; pulse.repeatCount = .infinity
            launchButton.layer?.add(pulse, forKey: "connectReady")
        }
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 420 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { max(420, splitView.bounds.height - 110) }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitView(_ sender: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        layoutStatusSplit(sender)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !arrangingStatus, let split = statusSplit, let pane = statusPaneView, !pane.isHidden,
              NSApp.currentEvent?.type == .leftMouseDragged else { return }
        savedStatusHeight = max(110, pane.frame.height)
    }
    private func layoutStatusSplit(_ split: NSSplitView) {
        guard !arrangingStatus, let pane = statusPaneView else { return }
        arrangingStatus = true
        defer { arrangingStatus = false }
        let size = split.bounds.size
        if pane.isHidden {
            tabs.frame = NSRect(origin: .zero, size: size)
            return
        }
        let statusHeight = min(savedStatusHeight, max(110, size.height - 421))
        let topHeight = max(0, size.height - statusHeight - split.dividerThickness)
        tabs.frame = NSRect(x: 0, y: 0, width: size.width, height: topHeight)
        pane.frame = NSRect(x: 0, y: topHeight + split.dividerThickness, width: size.width, height: statusHeight)
    }
    private func updatePageLayout() {
        guard let split = statusSplit, let pane = statusPaneView else { return }
        let gamePage = navigation.selectedSegment < 2
        let changingPageKind = pane.isHidden == gamePage
        gameHeaderView?.isHidden = !gamePage
        actionSurfaceView?.isHidden = !gamePage
        saveNoteView?.isHidden = !gamePage
        pane.isHidden = !gamePage
        panel.contentMinSize = NSSize(width: 840, height: gamePage ? 840 : 700)
        if changingPageKind {
            panel.contentView?.layoutSubtreeIfNeeded()
            layoutStatusSplit(split)
        }
    }
    @objc private func primaryRoomAction() {
        if room == nil {
            if navigation.selectedSegment == 0 { createRoom() }
            else if !invite.stringValue.isEmpty { joinInvite() }
            else { joinListed() }
        } else { launchGame() }
    }
    private func glassSurface(_ content: NSView, inset: CGFloat) -> NSView {
        let surface: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(); glass.cornerRadius = 20
            let holder = NSView(); glass.contentView = holder; surface = glass
            content.translatesAutoresizingMaskIntoConstraints = false; holder.addSubview(content)
            NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: inset),
                content.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -inset),
                content.topAnchor.constraint(equalTo: holder.topAnchor, constant: inset),
                content.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -inset)])
        } else {
            let effect = NSVisualEffectView(); effect.material = .sidebar; effect.blendingMode = .withinWindow
            surface = effect; content.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(content)
            NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: inset),
                content.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -inset),
                content.topAnchor.constraint(equalTo: effect.topAnchor, constant: inset),
                content.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -inset)])
        }
        return surface
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
              let rom = selectedROM, !rom.isDeleted, rom.url != nil else { status.stringValue = "Choose your library game and join a room first."; return }
        if room?["role"] as? String == "host" && (room?["occupancy"] as? Int ?? 1) < selectedPlayerCount {
            status.stringValue = "Share your invite and wait for the second player to join, then choose Start Game."; return
        }
        gameLaunching = true
        perform {
            defer { self.gameLaunching = false }
            let expected = (self.room?["compatibility"] as? [String: Any])?["rom_sha256"] as? String
            _ = try await self.identity(expectedSHA: expected)
            let url = try await self.preparedROM(rom).url
            let process = Process(), input = Pipe(), output = Pipe()
            process.environment = try self.runtimeEnvironment(for: rom.game?.system?.systemIdentifier)
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
                let autosave = self.newMultiplayerSaveURL(in: folder)
                self.currentAutosaveURL = autosave; config["autosave_path"] = autosave.path
                if let resume = self.resumeURL { config["resume_path"] = resume.path }
            }
            guard let system = rom.game?.system?.plugin?.controller else { throw CocoaError(.fileReadUnknown) }
            let controls = try NetworkInputResponder(system: system)
            var launched = false
            defer { if !launched { controls.stop() } }
            config["input_state_path"] = controls.inputURL.path
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
                    self.networkInput?.stop(); self.networkInput = nil
                    self.gameProcess = nil; self.gameStopping = false; self.gameConnected = false
                    self.lastGameError = finalError ?? self.lastGameError
                    self.gameMessage = self.lastGameError ?? message
                    self.status.stringValue = self.gameMessage!; self.refreshControls()
                }
            }
            self.gameMessage = nil; self.gameStopping = false; self.lastGameError = nil; self.gameConnected = false
            try process.run(); self.gameProcess = process
            self.networkInput = controls; launched = true
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
        let browser = NXMultiplayerSavesViewController()
        let window = NSWindow()
        browser.onClose = { [weak self, weak window] in
            if let window { self?.panel.endSheet(window) }
        }
        window.contentViewController = browser
        window.title = "Multiplayer Saves"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 520))
        window.minSize = NSSize(width: 620, height: 360)
        browser.onResume = { [weak self, weak window] url in
            if let window { self?.panel.endSheet(window) }
            self?.selectMultiplayerSave(url)
        }
        panel.beginSheet(window)
    }
    static func isActiveMultiplayerSave(_ url: URL) -> Bool {
        shared.gameProcess != nil && shared.currentAutosaveURL?.standardizedFileURL == url.standardizedFileURL
    }
    private func newMultiplayerSaveURL(in folder: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let game = selectedROM?.game?.displayName ?? "Multiplayer Game"
        let safeGame = String(game.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-").prefix(90))
        let stem = "\(safeGame) — \(formatter.string(from: Date())) — \(selectedPlayerCount) players"
        var result = folder.appendingPathComponent(stem).appendingPathExtension("emuxsave")
        var suffix = 2
        while FileManager.default.fileExists(atPath: result.path) {
            result = folder.appendingPathComponent("\(stem) (\(suffix))").appendingPathExtension("emuxsave")
            suffix += 1
        }
        return result
    }
    static func resumeSavedSession(_ url: URL, game: OEDBGame? = nil) {
        if let game {
            guard shared.prepareLibraryGameForHosting(game) else { return }
        } else { shared.show(0) }
        shared.selectMultiplayerSave(url)
    }
    private func selectMultiplayerSave(_ url: URL) {
        guard room == nil, gameProcess == nil else {
            let alert = NSAlert(); alert.messageText = "Leave the current room before resuming a saved session."
            alert.runModal(); return
        }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 14_000_512 else { throw fail("This is not a supported multiplayer save.") }
            let header = try Data(contentsOf: url).prefix(12)
            if header.count == 12, header.prefix(8) == Data("EMUXJNL1".utf8), header[8] == 2, (3...5).contains(Int(header[10])) {
                playerLimit.selectItem(at: Int(header[10]) - 2)
            } else { playerLimit.selectItem(at: 0) }
            resumeURL = url; resumeLabel.stringValue = "Resume: " + url.lastPathComponent
            status.stringValue = selectedROM == nil
                ? "Choose the matching library game, then create a room. All players verify the saved game before starting."
                : "Saved session selected for \(selectedROM?.game?.displayName ?? "the selected game"). Create a room to resume; all players verify the saved game before starting."
            refreshControls()
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func clearMultiplayerSave() {
        resumeURL = nil; resumeLabel.stringValue = ""; refreshControls()
    }
    @objc private func saveMultiplayerGame() {
        guard let source = currentAutosaveURL else { return }
        do {
            let values = try source.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size > 0, size <= 14_000_512 else { throw fail("A confirmed multiplayer save is not ready yet.") }
            // The runtime atomically replaces this file; capture one complete
            // version before showing the destination panel.
            let data = try Data(contentsOf: source)
            guard data.count <= 14_000_512, data.prefix(8) == Data("EMUXJNL1".utf8) else { throw fail("The multiplayer save could not be read.") }
            let chooser = NSSavePanel(); chooser.title = "Save Multiplayer Game"
            chooser.allowedFileTypes = ["emuxsave"]; chooser.nameFieldStringValue = source.lastPathComponent
            chooser.directoryURL = URL.oeApplicationSupportDirectory.appendingPathComponent("Multiplayer Sessions", isDirectory: true)
            guard chooser.runModal() == .OK, let destination = chooser.url else { return }
            try data.write(to: destination, options: .atomic)
            status.stringValue = "Multiplayer game saved. Resume it from Host Game when everyone returns."
        } catch { status.stringValue = error.localizedDescription }
    }
    private func displayName() throws -> String {
        let value = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 32 else { throw fail("Enter a player name of 1–32 characters before creating or joining a room.") }; return value
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
                            "downloads_disabled": "The host has disabled game downloads for this room.", "invalid_password": "Use a password of at most 128 characters.", "rom_transfer_pending": "Wait for the ROM transfer and import to finish before starting the game.", "rom_request_before_start": "The host has already opened the game connection. Leave and rejoin a fresh room, then request the ROM before starting.", "stale_rom_request": "This ROM request is no longer active.", "player_required": "Only players can request a ROM.", "host_required": "Only the host can change this room.",
                            "relay_unavailable": "This lobby has no relay available. Choose Automatic or Direct only."]
            throw NSError(domain: "NetworkPlayLobby", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: messages[code] ?? "The lobby could not complete this request (\(code))."])
        }
        return object
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        // Commit the field editor before disabling controls; otherwise AppKit can
        // discard the room name/password still being edited when a button fires.
        guard panel.makeFirstResponder(nil) else { return }
        busy = true; operationError = nil; status.stringValue = "Contacting lobby…"; refreshControls()
        Task { @MainActor in
            defer { self.busy = false; self.refreshControls() }
            do { try await operation() } catch {
                self.operationError = error.localizedDescription
                self.status.stringValue = error.localizedDescription
                let alert = NSAlert()
                alert.messageText = "Network Play could not complete the request"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                await alert.beginSheetModal(for: self.panel)
            }
        }
    }
    @objc static func hostLibraryGame(_ game: OEDBGame) {
        _ = shared.prepareLibraryGameForHosting(game)
    }
    static func browseMultiplayerSaves() {
        shared.show(0)
        shared.chooseMultiplayerSave()
    }
    @objc static func resumeLibraryGame(_ game: OEDBGame) {
        guard shared.prepareLibraryGameForHosting(game) else { return }
        shared.chooseMultiplayerSave()
    }
    @discardableResult
    private func prepareLibraryGameForHosting(_ game: OEDBGame) -> Bool {
        show(0)
        guard !busy, room == nil, gameProcess == nil else {
            status.stringValue = "Leave your current room before hosting another game."
            return false
        }
        guard let rom = game.defaultROM else {
            status.stringValue = "This game has no available ROM. Locate its file in your library first."
            return false
        }
        // A detail-page action must not carry another game's resume file into
        // the new room. The normal Host form remains responsible for options.
        if selectedROM?.objectID != rom.objectID { clearMultiplayerSave() }
        selectedROM = rom
        defaults.set(rom.objectID.uriRepresentation().absoluteString, forKey: prefix + "romID")
        updateSelectedGame()
        refreshControls()
        status.stringValue = "Choose your host options, then Create Room. Your invite code appears after the room is created."
        return true
    }
    private func updateSelectedGame() {
        let revision = UUID(); selectionRevision = revision
        guard let rom = selectedROM else { gameValidation.stringValue = ""; refreshArtwork(); return }
        refreshArtwork()
        gameValidation.textColor = .systemOrange
        gameValidation.stringValue = "! Untested"
        let system = rom.game?.system?.systemIdentifier ?? ""
        guard ["openemu.system.snes", "openemu.system.nes", "openemu.system.sg", "openemu.system.gba"].contains(system) else {
            gameValidation.stringValue = "! Experimental — this system needs a netplay core adapter"
            return
        }
        guard let source = rom.url else { return }
        let archiveIndex = rom.archiveFileIndex?.intValue
        Task { @MainActor [weak self] in
            let prepared = try? await NetworkROMPreparation.shared.prepare(source: source, index: archiveIndex, retainedRoot: nil)
            let sha = prepared?.sha256
            guard let self, self.selectionRevision == revision else { return }
            struct Catalog: Decodable { let games: [Entry] }
            struct Entry: Decodable { let rom_sha256: String; let runtime_profile: String; let status: String; let notes: String }
            let catalog = Bundle.main.url(forResource: "NetplayCompatibility", withExtension: "json")
                .flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Catalog.self, from: $0) }
            if system == "openemu.system.snes", let entry = catalog?.games.first(where: { $0.rom_sha256 == sha && $0.runtime_profile == "snes9x-1.63-general-v2-abi1" && $0.status == "tested" }) {
                self.gameValidation.stringValue = "✓ Tested — " + entry.notes
                self.gameValidation.textColor = .secondaryLabelColor
            } else {
                self.gameValidation.stringValue = "! Untested — experimental netplay; synchronization and saves are not validated"
            }
        }
    }
    private func refreshArtwork() {
        guard let game = selectedROM?.game else {
            gameLabel.stringValue = room?["game"] as? String ?? "Choose a game from your library."
            gameArtwork.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "No cover artwork")
            artworkKey = ""; return
        }
        gameLabel.stringValue = game.displayName
        let url = game.boxImage?.imageURL
        let stamp = url.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }?.timeIntervalSince1970 ?? 0
        let key = game.objectID.uriRepresentation().absoluteString + (url?.path ?? "") + String(stamp)
        guard key != artworkKey else { return }
        artworkKey = key
        gameArtwork.image = url.flatMap(NSImage.init(contentsOf:)) ?? NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "Artwork not available yet")
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
                self.updateSelectedGame()
                self.defaults.set(rom.objectID.uriRepresentation().absoluteString, forKey: self.prefix + "romID")
                self.status.stringValue = "Library game selected. Compatibility is checked when creating or joining a room."
            }
        } catch { status.stringValue = "Could not read your library: " + error.localizedDescription }
    }
    @objc private func saveROMCachePreference() {
        defaults.set(keepUncompressed.state == .on, forKey: prefix + "keepUncompressed")
    }
    private func preparedROM(_ rom: OEDBRom) async throws -> NetworkROMPreparation.Prepared {
        guard let source = rom.url else { throw fail("The library ROM is missing.") }
        let index = rom.archiveFileIndex?.intValue
        let retained = keepUncompressed.state == .on
            ? URL.oeApplicationSupportDirectory.appendingPathComponent("Netplay ROM Cache", isDirectory: true) : nil
        if index != nil { status.stringValue = "Preparing compressed ROM for netplay…" }
        return try await NetworkROMPreparation.shared.prepare(source: source, index: index, retainedRoot: retained)
    }
    private func matchLibraryGame(expectedSHA: String, profile: String, allowTransfer: Bool = false) async throws -> Bool {
        guard let context = OELibraryDatabase.default?.mainThreadContext else { throw fail("Open your game library first.") }
        let request = NSFetchRequest<OEDBRom>(entityName: OEDBRom.entityName)
        let games = try context.fetch(request).filter {
            !$0.isDeleted && $0.game != nil && $0.url != nil
                && ($0.game?.system?.systemIdentifier == (profile.hasPrefix("oe1.nes.") ? "openemu.system.nes" : profile.hasPrefix("oe1.sg.") ? "openemu.system.sg" : profile.hasPrefix("oe1.gbalink.") ? "openemu.system.gba" : "openemu.system.snes"))
        }
        status.stringValue = "Finding the host’s game in your library by extracted ROM SHA-256…"
        var match: Int?
        for (index, rom) in games.enumerated() {
            try Task.checkCancellation()
            if let prepared = try? await preparedROM(rom), prepared.sha256 == expectedSHA {
                match = index; break
            }
        }
        var chosen: OEDBRom?
        if let match { chosen = games[match] }
        else {
            let alert = NSAlert(); alert.messageText = "Matching game not found in your library"
            alert.informativeText = "No readable library game matches the host’s SHA-256:\n\(expectedSHA)\n\nChoose a library game to verify it, or cancel and import the matching game first. Different revisions will not connect."
            alert.addButton(withTitle: "Choose Library Game…"); alert.addButton(withTitle: "Cancel")
            if allowTransfer { alert.addButton(withTitle: "Join Room to Download…") }
            let answer = alert.runModal()
            if allowTransfer && answer == .alertThirdButtonReturn {
                selectedROM = nil; verifiedSHA = nil; refreshArtwork()
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
            guard let rom = chosen else { throw fail("Join cancelled.") }
            let actual = try await preparedROM(rom).sha256
            guard actual == expectedSHA else {
                let mismatch = NSAlert(); mismatch.messageText = "Game SHA-256 does not match"
                mismatch.informativeText = "Host: \(expectedSHA)\nYour file: \(actual)\n\nThese are different game files. Choose the same revision as the host."
                mismatch.runModal()
                throw fail("Game SHA-256 mismatch. Host: \(expectedSHA). Your file: \(actual).")
            }
        }
        guard let rom = chosen, !rom.isDeleted else { throw fail("The library game is no longer available.") }
        selectedROM = rom
        verifiedSHA = expectedSHA
        romMatch.stringValue = "✓ ROM matches the host — SHA-256 verified."
        updateSelectedGame()
        defaults.set(rom.objectID.uriRepresentation().absoluteString, forKey: prefix + "romID")
        status.stringValue = "Matching game selected; SHA-256 verified. Joining…"
        return true
    }
    private func runtimeEnvironment(for selectedSystem: String?) throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // Only trusted local metadata selects executable code; never use a remote plugin path.
        for key in ["NX_NETPLAY_BACKEND", "NX_NETPLAY_CORE", "NX_NETPLAY_SYSTEM", "NX_NETPLAY_VIEW", "NX_NETPLAY_PLAYERS"] { environment.removeValue(forKey: key) }
        let profile = (room?["compatibility"] as? [String: Any])?["profile"] as? String ?? ""
        let system = selectedSystem ?? (profile.hasPrefix("oe1.nes.") ? "openemu.system.nes" : profile.hasPrefix("oe1.sg.") ? "openemu.system.sg" : profile.hasPrefix("oe1.gbalink.") ? "openemu.system.gba" : "openemu.system.snes")
        if system == "openemu.system.snes" { environment["NX_NETPLAY_BACKEND"] = "snes9x"; environment["NX_NETPLAY_PLAYERS"] = String(selectedPlayerCount); return environment }
        if system == "openemu.system.nes" || system == "openemu.system.sg" || system == "openemu.system.gba" {
            let coreName = system == "openemu.system.nes" ? "Nestopia" : system == "openemu.system.sg" ? "GenesisPlus" : "mGBA"
            let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NetworkPlay/Cores/\(coreName).oecoreplugin")
            let core = FileManager.default.fileExists(atPath: bundled.path) ? bundled : URL.oeApplicationSupportDirectory.appendingPathComponent("Cores/\(coreName).oecoreplugin")
            guard let bundle = Bundle(url: core), bundle.bundleIdentifier == "org.openemu.\(coreName)",
                  let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw fail("Install the \(coreName) core in Settings → Cores to use experimental netplay.")
            }
            environment["NX_NETPLAY_BACKEND"] = "openemu"
            environment["NX_NETPLAY_CORE"] = core.path
            environment["NX_NETPLAY_SYSTEM"] = system
            return environment
        }
        throw fail("Experimental netplay for this system still needs a compatible core adapter. Local play remains available.")
    }
    private func identity(expectedSHA: String? = nil) async throws -> [String: Any] {
        guard let rom = selectedROM, !rom.isDeleted, rom.managedObjectContext != nil,
              rom.url != nil else { throw fail("Choose an imported game from your OpenEmu library first.") }
        let runtimeEnvironment = try runtimeEnvironment(for: rom.game?.system?.systemIdentifier)
        let gameURL = try await preparedROM(rom).url
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
        let process = Process(); process.environment = runtimeEnvironment; let pipe = Pipe(); process.executableURL = helper; process.arguments = [gameURL.path]
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
                        message = "The network runtime could not load this game. Check that it is a valid ROM for the selected system and that its core is installed."
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
        var result: [String: Any] = ["allow_downloads": shareROM.state == .on, "allow_spectators": spectators.state == .on, "spectator_limit": spectatorLimit.indexOfSelectedItem + 1]
        if newRoom { result["capacity"] = selectedPlayerCount; result["game"] = selectedROM?.game?.displayName ?? "Network game" }
        if newRoom || (room?["occupancy"] as? Int ?? 1) < 2 {
            let enteredName = title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let gameName = selectedROM?.game?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let roomName = enteredName.isEmpty ? String((gameName.isEmpty ? "Game with friends" : gameName + " with friends").prefix(64)) : enteredName
            title.stringValue = roomName
            defaults.set(roomName, forKey: prefix + "roomName")
            result["title"] = roomName
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
            var body = try self.hostOptions(newRoom: true)
            if self.relays.indices.contains(self.relayPicker.indexOfSelectedItem) {
                body["relay_id"] = self.relays[self.relayPicker.indexOfSelectedItem]["id"]
            }
            body["username"] = username; let compatibility = try await self.identity(); body["compatibility"] = compatibility
            self.verifiedSHA = compatibility["rom_sha256"] as? String
            self.romMatch.stringValue = "✓ Host game verified. Players must match its SHA-256."
            let response = try await self.api(base, "POST", "v1/rooms", body)
            try self.admit(response, tokenKey: "owner_token", base: base)
            self.password.stringValue = ""
        }
    }
    private static func displayInvite(_ value: String) -> String {
        let code = value.uppercased().filter { "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".contains($0) }
        guard code.count > 4 && code.count <= 8 else { return code }
        return String(code.prefix(4)) + "-" + String(code.dropFirst(4))
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === title {
            defaults.set(field.stringValue, forKey: prefix + "roomName")
            optionsChanged(); return
        }
        if field === password { optionsChanged(); return }
        if field === name || field === hostName {
            let value = field.stringValue
            // Update only the other page's field; leave the active editor and
            // any marked (input-method) text under AppKit's control.
            let otherName = field === name ? hostName : name
            if otherName.stringValue != value { otherName.stringValue = value }
            defaults.set(value, forKey: prefix + "displayName")
            refreshJoinIdentity(); refreshControls(); return
        }
        guard field === invite else { return }
        let formatted = Self.displayInvite(field.stringValue)
        if field.stringValue != formatted { field.stringValue = formatted }
        if !formatted.isEmpty { roomList.deselectAll(nil) }
        refreshControls()
    }
    @objc private func joinInvite() {
        guard !busy, room == nil, gameProcess == nil else { return }
        // ICE prioritizes direct host/STUN candidates; TURN is the fallback.
        route.selectItem(at: 0)
        join(locator: ["invite_code": invite.stringValue], secret: joinPassword.stringValue, role: joinRole.indexOfSelectedItem)
    }
    @objc private func joinListed() {
        let index = roomList.selectedRow; guard listedRooms.indices.contains(index), let id = listedRooms[index]["id"] as? String else { return }
        join(locator: ["room_id": id], secret: joinPassword.stringValue, role: joinRole.indexOfSelectedItem, lobby: (listedRooms[index]["relay_endpoint"] as? String).flatMap(URL.init(string:)))
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
            self.joiningPlayerCount = target["capacity"] as? Int ?? 2
            defer { self.joiningPlayerCount = nil }
            let haveROM = try await self.matchLibraryGame(expectedSHA: expected.lowercased(), profile: compatibility["profile"] as? String ?? "", allowTransfer: role == 0 && target["allow_downloads"] as? Bool == true)
            var body = locator
            body["username"] = try self.displayName(); body["password"] = secret; body["role"] = role == 0 ? "player" : "spectator"
            body["compatibility"] = haveROM ? try await self.identity(expectedSHA: expected) : compatibility
            let response = try await self.api(base, "POST", "v1/join", body)
            self.joinPassword.stringValue = ""; self.browsePassword.stringValue = ""
            try self.admit(response, tokenKey: "member_token", base: base)
            if !haveROM {
                self.romMatch.stringValue = "! No matching ROM in your library. Download the game before connecting."
                self.status.stringValue = "Joined the room. Choose Download Game to request a copy from the host."
            }
        }
    }
    @objc private func downloadGame() {
        guard !busy, let base = activeEndpoint, let compatibility = room?["compatibility"] as? [String: Any],
              let expected = compatibility["rom_sha256"] as? String, room?["allow_downloads"] as? Bool == true else { return }
        let consent = NSAlert(); consent.messageText = "Download this game from the host?"
        consent.informativeText = "Only accept if you own the game and are authorized to receive this copy. The host must approve. The file is verified by SHA-256 and imported into your library without replacing your ROMs or saves."
        consent.addButton(withTitle: "I Own the Game — Request Download"); consent.addButton(withTitle: "Cancel")
        guard consent.runModal() == .alertFirstButtonReturn else { return }
        perform {
            try await self.receiveROM(expectedSHA: expected.lowercased(), base: base)
            _ = try await self.identity(expectedSHA: expected)
            self.romMatch.stringValue = "✓ Download complete — SHA-256 matches the host."
            self.status.stringValue = "Game imported. Waiting for the host to start."
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
        let profile = (room?["compatibility"] as? [String: Any])?["profile"] as? String ?? ""
        let fileExtension = profile.hasPrefix("oe1.nes.") ? ".nes" : profile.hasPrefix("oe1.sg.") ? ".gen" : profile.hasPrefix("oe1.gbalink.") ? ".gba" : ".sfc"
        let destination = directory.appendingPathComponent((safeTitle.isEmpty ? "Network Game" : safeTitle) + fileExtension)
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
        status.stringValue = "Requesting permission from the host…"
        _ = try await api(base, "POST", "v1/rooms/\(id)/rom-request", [:], token: memberToken)
        let progressURL = directory.appendingPathComponent("transfer-progress.json")
        var launch: [String: Any] = ["endpoint": base.absoluteString, "room_id": id, "token": memberToken,
                                   "rom_transfer_progress": progressURL.path, "require_rom_approval": true,
                                   "receive_rom": destination.path, "expected_rom_sha256": expectedSHA,
                                   "connection": "automatic", "headless": true]
        if let servers = try selectedSTUN() { launch["stun_servers"] = servers }
        launch["relay_network"] = try await authorizeRelay(base, roomID: id)
        let process = Process(), input = Pipe(), output = Pipe()
        process.environment = try runtimeEnvironment(for: selectedROM?.game?.system?.systemIdentifier)
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NetworkPlay/NetworkPlay.app/Contents/MacOS/emu-live")
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        transferProcess = process
        cancelTransferButton.isHidden = false
        transferProgress.isHidden = false; transferProgress.isIndeterminate = true; transferProgress.startAnimation(nil)
        let monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let data = try? Data(contentsOf: progressURL), data.count < 4096,
                   let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let self {
                    let received = report["received"] as? Double ?? 0, total = report["total"] as? Double ?? 0
                    self.transferProgress.isIndeterminate = total <= 0
                    if total > 0 {
                        self.transferProgress.stopAnimation(nil); self.transferProgress.doubleValue = received / total * 100
                        self.status.stringValue = "Downloading ROM: \(Int(received / total * 100))% — \(Int(received / 1024)) / \(Int(total / 1024)) KB"
                    } else { self.status.stringValue = report["phase"] as? String ?? "Waiting for host approval…" }
                }
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { break }
            }
        }
        defer { monitor.cancel(); transferProgress.stopAnimation(nil); transferProgress.isHidden = true; transferProcess = nil; cancelTransferButton.isHidden = true }
        status.stringValue = "Waiting for host approval… You can cancel below."
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
        monitor.cancel(); status.stringValue = "Download complete. Verifying SHA-256…"
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
        if rom.game?.boxImage == nil { rom.game?.requestInfoSync() }
        verifiedSHA = expectedSHA
        romMatch.stringValue = "✓ ROM matches the host — SHA-256 verified."
        updateSelectedGame()
        defaults.set(rom.objectID.uriRepresentation().absoluteString, forKey: prefix + "romID")
        _ = try await api(base, "POST", "v1/rooms/\(id)/rom-request", ["complete": true], token: memberToken)
    }

    private func admit(_ response: [String: Any], tokenKey: String, base: URL) throws {
        guard let room = response["room"] as? [String: Any], let token = response[tokenKey] as? String, room["id"] is String else { throw fail("The lobby returned an incomplete room.") }
        hostOptionsDirty = false; gameMessage = nil; self.room = room; memberToken = token; activeEndpoint = base; renderRoom()
        startRoomEvents(response["events_url"] as? String)
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: self?.roomEventsConnected == true ? 20_000_000_000 : 3_000_000_000) } catch { return }
                guard let self, self.room != nil else { return }
                self.roomSocket?.sendPing { _ in }
                if !self.busy { await self.heartbeat() }
            }
        }
    }
    private func startRoomEvents(_ address: String?) {
        stopRoomEvents()
        // Never send membership credentials to a URL supplied by an arbitrary lobby.
        guard let address, address == Bundle.main.object(forInfoDictionaryKey: "NXRoomEventsURL") as? String,
              let url = URL(string: address), url.scheme == "wss",
              let id = room?["id"] as? String else { return }
        let token = memberToken
        roomEventsTask = Task { @MainActor [weak self] in
            var backoff: UInt64 = 1
            while !Task.isCancelled {
                guard let self, self.room?["id"] as? String == id, self.memberToken == token else { return }
                var request = URLRequest(url: url)
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                request.setValue(id, forHTTPHeaderField: "X-NX-Room-ID")
                let socket = self.session.webSocketTask(with: request)
                self.roomSocket = socket; socket.maximumMessageSize = 4096; socket.resume()
                do {
                    // Snapshot after subscribing closes the subscribe/snapshot race.
                    try await socket.send(.string("{\"action\":\"ping\"}"))
                    self.roomEventsConnected = true
                    await self.heartbeat()
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let data: Data
                        switch message {
                        case .string(let text): data = Data(text.utf8)
                        case .data(let bytes): data = bytes
                        @unknown default: continue
                        }
                        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              event["room_id"] as? String == id else { continue }
                        backoff = 1
                        // Fetch the authenticated view; events never contain room secrets.
                        await self.heartbeat()
                    }
                } catch { /* Heartbeat polling covers reconnects and service outages. */ }
                self.roomEventsConnected = false
                socket.cancel(with: .goingAway, reason: nil)
                guard !Task.isCancelled else { return }
                do { try await Task.sleep(nanoseconds: backoff * 1_000_000_000) } catch { return }
                backoff = min(backoff * 2, 30)
            }
        }
    }
    private func stopRoomEvents() {
        roomEventsTask?.cancel(); roomEventsTask = nil
        roomSocket?.cancel(with: .goingAway, reason: nil); roomSocket = nil
        roomEventsConnected = false
    }
    private func renderRoom() {
        guard let room else { roomStatus.stringValue = ""; return }
        let role = room["role"] as? String ?? "member"
        roomStatus.stringValue = "\(room["title"] as? String ?? "Room") · \(role.capitalized)\nPlayers connected: \(room["occupancy"] as? Int ?? 1)/\(room["capacity"] as? Int ?? 2) · Spectators: \(room["spectators"] as? Int ?? 0)/\(room["spectator_limit"] as? Int ?? 0)"
        if let code = room["invite_code"] as? String { roomStatus.stringValue += "\nInvite: \(Self.displayInvite(code))" }
        if let remaining = room["lifetime_remaining_seconds"] as? Int, remaining <= 900 {
            let minutes = max(0, Int(ceil(Double(remaining) / 60)))
            roomStatus.stringValue += "\nSession ends in \(minutes) minute\(minutes == 1 ? "" : "s"). Save and start a new room to continue."
        }
        status.stringValue = gameMessage ?? (gameProcess == nil ? (role == "host" ? ((room["occupancy"] as? Int ?? 1) < selectedPlayerCount ? "You are hosting. Share your invite; waiting for all selected players." : "Players are in the room. Choose Start Game.") : (room["state"] as? String == "playing" ? "The host has started. Choose Connect to Game." : "You have joined the room. Waiting for the host to start the game.")) : "Network game window is open. Spectators are read-only.")
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
            if let current = result["room"] as? [String: Any] { room = current; renderRoom(); offerROMRequest() }
        } catch {
            guard room?["id"] as? String == id, memberToken == token, !busy else { return }
            let failure = error as NSError
            if failure.domain == "NetworkPlayLobby" && [401,404].contains(failure.code) { clearRoom() }
            status.stringValue = "Room update failed: " + error.localizedDescription
        }
    }
    private func sendRequestedROM(base: URL, roomID: String) async throws {
        guard let selectedROM else { throw fail("Choose the host’s game first.") }
        let rom = try await preparedROM(selectedROM).url
        let progressDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: progressDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: progressDirectory) }
        let progressURL = progressDirectory.appendingPathComponent("upload.json")
        var config: [String: Any] = ["endpoint": base.absoluteString, "room_id": roomID, "token": memberToken,
                                    "rom_transfer_progress": progressURL.path, "rom": rom.path, "serve_rom": true, "headless": true, "allow_rom_transfer": true,
                                    "connection": "automatic", "rollback": true, "delay": 3]
        if let servers = try selectedSTUN() { config["stun_servers"] = servers }
        config["relay_network"] = try await authorizeRelay(base, roomID: roomID)
        if base.scheme == "http", ["127.0.0.1", "localhost"].contains(base.host ?? "") { config["local_test_mode"] = true }
        let process = Process(), input = Pipe(), output = Pipe()
        process.environment = try runtimeEnvironment(for: selectedROM.game?.system?.systemIdentifier)
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NetworkPlay/NetworkPlay.app/Contents/MacOS/emu-live")
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        transferProcess = process; cancelTransferButton.isHidden = false
        transferProgress.isHidden = false; transferProgress.isIndeterminate = true; transferProgress.startAnimation(nil)
        let monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let self, let data = try? Data(contentsOf: progressURL), data.count < 4096,
                   let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let sent = report["received"] as? Double, let total = report["total"] as? Double,
                   total > 0, sent >= 0, sent <= total {
                    self.transferProgress.stopAnimation(nil); self.transferProgress.isIndeterminate = false
                    self.transferProgress.doubleValue = sent / total * 100
                    self.status.stringValue = sent == total ? "Upload sent. Waiting for the player to verify and import the game…" :
                        "Uploading ROM: \(Int(sent / total * 100))% — \(Int(sent / 1024)) / \(Int(total / 1024)) KB"
                }
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { break }
            }
        }
        defer { monitor.cancel() }
        defer { transferProcess = nil; cancelTransferButton.isHidden = true; transferProgress.stopAnimation(nil); transferProgress.isHidden = true }
        status.stringValue = "Sending the ROM to the player. Waiting for verification and library import…"
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: config) + Data([10])); try input.fileHandleForWriting.close()
        let result = await Task.detached(priority: .utility) { () -> (Int32, Data) in
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); return (process.terminationStatus, data)
        }.value
        guard result.0 == 0 else {
            let lines = String(data: result.1, encoding: .utf8)?.split(separator: "\n") ?? []
            let response = lines.last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            throw fail(response?["error"] as? String ?? "ROM transfer cancelled or failed.")
        }
        let current = try await api(base, "GET", "v1/rooms/\(roomID)", nil, token: memberToken)
        if let value = current["room"] as? [String: Any] { room = value; renderRoom() }
        status.stringValue = "ROM received and imported by the player. You can now Start Game."
    }
    private func offerROMRequest() {
        guard room?["role"] as? String == "host", !busy, gameProcess == nil,
              let request = room?["rom_request"] as? [String: Any], request["status"] as? String == "pending",
              let requestID = request["id"] as? String, !promptedROMRequests.contains(requestID),
              panel.attachedSheet == nil, let base = activeEndpoint, let roomID = room?["id"] as? String else { return }
        promptedROMRequests.insert(requestID)
        let alert = NSAlert(); alert.messageText = "Send this ROM to the player?"
        alert.informativeText = "\(request["username"] as? String ?? "Player 2") needs \(selectedROM?.game?.displayName ?? "the selected game") and has confirmed ownership. Send only if you are authorized to share this copy. The ROM is transferred and imported before you start the game. No game window opens during the transfer."
        alert.addButton(withTitle: "Send ROM"); alert.addButton(withTitle: "Decline")
        alert.beginSheetModal(for: panel) { [weak self] answer in
            guard let self, self.room?["id"] as? String == roomID else { return }
            let allow = answer == .alertFirstButtonReturn
            self.perform {
                _ = try await self.api(base, "POST", "v1/rooms/\(roomID)/rom-request", ["id": requestID, "allow": allow], token: self.memberToken)
                if allow {
                    self.shareROM.state = .on
                    self.status.stringValue = "ROM request approved. Opening the transfer connection…"
                    try await self.sendRequestedROM(base: base, roomID: roomID)
                } else { self.status.stringValue = "ROM request declined. The player has been notified." }
            }
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
    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === roomList, roomList.selectedRow >= 0 { invite.stringValue = "" }
        refreshControls()
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let key = tableColumn?.identifier.rawValue else { return nil }
        let text: String
        if tableView === roomList {
            guard listedRooms.indices.contains(row) else { return nil }
            let item = listedRooms[row]
            switch key {
            case "game": text = "\(item["title"] as? String ?? "Game")\nHost: \(item["host_name"] as? String ?? "Player")"
            case "relay": text = item["relay_name"] as? String ?? "Relay"
            case "players": text = "\(item["occupancy"] as? Int ?? 0)/\(item["capacity"] as? Int ?? 2)"
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
        let selected = defaults.string(forKey: prefix + "relayID") ?? "nx-west"
        relayPicker.removeAllItems()
        for relay in relays { relayPicker.addItem(withTitle: "\(relay["name"] ?? "Relay") · \(relay["region"] ?? "")") }
        if let index = relays.firstIndex(where: { $0["id"] == selected }) { relayPicker.selectItem(at: index) }
        relayTable.reloadData()
    }
    @objc private func selectRelay() {
        guard room == nil, relays.indices.contains(relayPicker.indexOfSelectedItem) else { return }
        defaults.set(relays[relayPicker.indexOfSelectedItem]["id"], forKey: prefix + "relayID")
        status.stringValue = "Relay fallback selected. Automatic connections still try direct play first."
    }
    @objc private func useSelectedRelay() {
        guard !busy, room == nil, gameProcess == nil, relays.indices.contains(relayTable.selectedRow) else { return }
        relayPicker.selectItem(at: relayTable.selectedRow); selectRelay()
    }
    @objc private func registerRelay() { if let url = directoryURL { NSWorkspace.shared.open(url) } }
    @objc private func refreshDirectory() {
        guard !directoryRefreshing else { return }
        directoryRefreshing = true
        Task { @MainActor in
            defer { self.directoryRefreshing = false; self.refreshControls() }
            self.catalogMessage = ""
            var refreshedRooms: [[String: Any]] = []
            do {
                let base = try self.baseURL()
                let result = try await self.api(base, "GET", "v1/relays")
                guard result["schema"] as? Int == 2, let items = result["relays"] as? [[String: Any]], items.count <= 100 else { throw self.fail("Invalid relay directory.") }
                self.relays = items.compactMap { item in
                    guard let id = item["id"] as? String, let name = item["name"] as? String,
                          let region = item["region"] as? String, let operatorName = item["operator"] as? String else { return nil }
                    return ["id": id, "name": name, "region": region, "operator": operatorName, "endpoint": base.absoluteString]
                }
                self.rebuildRelayPicker()
                let listing = try await self.api(base, "GET", "v1/rooms")
                guard let rooms = listing["rooms"] as? [[String: Any]], rooms.count <= 1024 else { throw self.fail("Invalid room list.") }
                for var room in rooms where room["visibility"] as? String == "public" {
                    room["relay_endpoint"] = base.absoluteString
                    refreshedRooms.append(room)
                }
                self.relayStatus = [base.absoluteString: "Registered"]
            } catch {
                self.catalogMessage = "Catalog refresh failed: " + error.localizedDescription
                if self.room == nil && !self.busy && self.operationError == nil { self.status.stringValue = self.catalogMessage }
                return
            }
            let selected = self.listedRooms.indices.contains(self.roomList.selectedRow) ? self.listedRooms[self.roomList.selectedRow] : nil
            self.listedRooms = refreshedRooms
            self.relayTable.reloadData(); self.roomList.reloadData()
            if let selected, let index = refreshedRooms.firstIndex(where: { $0["id"] as? String == selected["id"] as? String && $0["relay_endpoint"] as? String == selected["relay_endpoint"] as? String }) {
                self.roomList.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
            let offline = self.relayStatus.values.filter { $0 == "Unreachable" }.count
            if self.room == nil && !self.busy && self.operationError == nil && self.navigation.selectedSegment == 1 { self.status.stringValue = self.catalogMessage + "\(self.listedRooms.count) public game(s) across \(self.relays.count) relay(s)." + (offline > 0 ? " \(offline) relay(s) could not be reached." : "") + " Choose Refresh Games to update the list." }
        }
    }
    @objc private func updateHost() {
        guard let base = activeEndpoint, let id = room?["id"] as? String else { return }
        perform {
            let options = try self.hostOptions(newRoom: false); self.password.stringValue = ""
            let result = try await self.api(base, "POST", "v1/rooms/\(id)/settings", options, token: self.memberToken)
            self.room = result["room"] as? [String: Any]; self.hostOptionsDirty = false; self.renderRoom()
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
        heartbeatTask?.cancel(); heartbeatTask = nil; stopRoomEvents()
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
        heartbeatTask?.cancel(); heartbeatTask = nil; stopRoomEvents()
        liveRoute = "connecting"; liveRTT = -1
        room = nil; memberToken = ""; activeEndpoint = nil
        verifiedSHA = nil; romMatch.stringValue = ""
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
    private let choose = NXDesignButton(title: "Choose Game", target: nil, action: nil)
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
        let note = NSTextField(wrappingLabelWithString: "Browse your imported games by system. Untested games are marked ! in Network Play. The exact file hash is checked before joining.")
        note.textColor = .secondaryLabelColor
        choose.target = self; choose.action = #selector(confirm); choose.bezelStyle = .rounded
        let cancel = NXDesignButton(title: "Cancel", target: self, action: #selector(cancelSelection)); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
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
        choose.primary = true
        NXDesign.apply(to: sheet)
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

private final class NXNetworkDocumentView: NSView {
    override var isFlipped: Bool { true }
}
