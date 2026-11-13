// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Cocoa

/// What the box art of a game shows on top of itself.
enum GameIndication {
    case none, fileMissing, processing
}

/// A game in the library grid: box art, title and rating.
final class GameCollectionViewItem: ImageCollectionViewItem {
    
    @IBOutlet weak var ratingIndicator: NSLevelIndicator?
    
    private let indicationView = IndicationView()
    
    /// True while a placeholder stands in for missing box art.
    var isShowingMissingArtwork = false
    
    var indication: GameIndication {
        get { indicationView.indication }
        set { indicationView.indication = newValue }
    }
    
    var rating: Int {
        get { ratingIndicator?.integerValue ?? 0 }
        set { ratingIndicator?.integerValue = newValue }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(indicationView, positioned: .above, relativeTo: imageView)
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        indication = .none
        ratingIndicator?.integerValue = 0
        isShowingMissingArtwork = false
    }
    
    override func viewDidLayout() {
        super.viewDidLayout()
        
        guard let imageView else { return }
        indicationView.frame = view.convert(imageView.croppedBounds, from: imageView)
    }
    
    @IBAction func ratingDidChange(_ sender: NSLevelIndicator) {
        guard let game = representedObject as? OEDBGame else { return }
        game.rating = sender.integerValue as NSNumber
        try? game.managedObjectContext?.save()
    }
}

/// Covers the box art of a game whose file is missing (red, with a warning picture) or that is busy (dark, with a spinner).
/// Clicks go through to the item below.
private final class IndicationView: NSView {
    
    var indication: GameIndication = .none {
        didSet {
            guard indication != oldValue else { return }
            isHidden = indication == .none
            if indication == .processing {
                spinner.startAnimation(nil)
            } else {
                spinner.stopAnimation(nil)
            }
            spinner.isHidden = indication != .processing
            needsDisplay = true
        }
    }
    
    private let spinner: NSProgressIndicator = {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        return spinner
    }()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        addSubview(spinner)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    
    override func layout() {
        super.layout()
        spinner.sizeToFit()
        spinner.frame.origin = NSPoint(x: (bounds.width - spinner.frame.width) / 2, y: (bounds.height - spinner.frame.height) / 2)
    }
    
    override func draw(_ dirtyRect: NSRect) {
        switch indication {
        case .none:
            return
        case .fileMissing:
            NSColor(red: 0.992, green: 0, blue: 0, alpha: 0.4).setFill()
            bounds.fill()
            
            if let image = NSImage(named: "missing_rom") {
                let width = bounds.width * 0.45
                let height = width * 0.9
                image.draw(in: NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height).integral)
            }
        case .processing:
            NSColor(white: 0, alpha: 0.7).setFill()
            bounds.fill()
        }
    }
}

/// A read-only game overview. Launching and navigation stay with the library controller.
@MainActor
final class NXGameDetailViewController: NSViewController {
    let game: OEDBGame
    var onBack: (() -> Void)?
    var onPlay: (() -> Void)?
    var onHost: (() -> Void)?
    var onResumeSave: ((OEDBSaveState) -> Void)?
    var onMultiplayerSaves: (() -> Void)?
    private var multiplayerBrowser: NXMultiplayerSavesViewController?

    private let sections = NSSegmentedControl(labels: ["Save States", "Multiplayer Saves", "Screenshots", "Game Details"], trackingMode: .selectOne, target: nil, action: nil)
    private let sectionBody = NSStackView()
    private let artwork = NSImageView()
    private var sectionButtons: [NXDesignButton] = []
    private var saves: [OEDBSaveState] = []
    private var screenshots: [OEDBScreenshot] = []

    init(game: OEDBGame) {
        self.game = game
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(game:)") }

    override func loadView() {
        let root = NXDesignBackground(color: NXDesign.background)
        view = root
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        let document = NXGameDetailDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let body = NSStackView(); body.orientation = .vertical; body.alignment = .leading; body.spacing = 0
        body.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(body)
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: document.leadingAnchor), body.trailingAnchor.constraint(equalTo: document.trailingAnchor), body.topAnchor.constraint(equalTo: document.topAnchor), body.bottomAnchor.constraint(equalTo: document.bottomAnchor)])

        let hero = NSStackView(); hero.orientation = .horizontal; hero.alignment = .centerY; hero.spacing = 32
        let copy = NSStackView(); copy.orientation = .vertical; copy.alignment = .leading; copy.spacing = 20
        let system = text((game.system?.name ?? "Library").uppercased(), size: 12, weight: .semibold)
        system.textColor = NXDesign.accent
        system.attributedStringValue = NSAttributedString(string: system.stringValue, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NXDesign.accent, .kern: 2])
        copy.addArrangedSubview(system)
        copy.addArrangedSubview(text(game.displayName, size: 34, weight: .bold))
        if let description = game.gameDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            let summary = text(description, size: 15); summary.maximumNumberOfLines = 4; summary.lineBreakMode = .byWordWrapping; summary.preferredMaxLayoutWidth = 320; summary.cell?.wraps = true
            summary.textColor = NXDesign.secondary; copy.addArrangedSubview(summary)
        }
        var metadata: [String] = []
        if let lastPlayed = game.lastPlayed { metadata.append("Last played " + date(lastPlayed)) }
        if game.playTime > 0 {
            let formatter = DateComponentsFormatter(); formatter.allowedUnits = [.hour, .minute]; formatter.unitsStyle = .abbreviated
            if let duration = formatter.string(from: game.playTime) { metadata.append(duration + " played") }
        }
        if !metadata.isEmpty { let meta = text(metadata.joined(separator: "   |   "), size: 12); meta.textColor = NXDesign.secondary; copy.addArrangedSubview(meta) }
        hero.addArrangedSubview(copy); hero.addArrangedSubview(artwork)
        artwork.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); artwork.imageScaling = .scaleProportionallyUpOrDown; artwork.setAccessibilityLabel(game.displayName + " artwork")
        artwork.widthAnchor.constraint(equalTo: hero.widthAnchor, multiplier: 0.44).isActive = true
        artwork.heightAnchor.constraint(equalToConstant: 250).isActive = true
        NXDesign.addArtworkShadow(to: artwork)
        copy.widthAnchor.constraint(equalTo: hero.widthAnchor, multiplier: 0.56, constant: -32).isActive = true
        for child in copy.arrangedSubviews { child.widthAnchor.constraint(equalTo: copy.widthAnchor).isActive = true }
        if let url = game.boxImage?.imageURL { artwork.image = NSImage(contentsOf: url) }
        if artwork.image == nil { artwork.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "No artwork") }
        let heroSurface = NXArtworkHero(content: hero, image: artwork.image)
        body.addArrangedSubview(heroSurface); heroSurface.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        heroSurface.heightAnchor.constraint(greaterThanOrEqualToConstant: 350).isActive = true
        let boundary = divider(); body.addArrangedSubview(boundary); boundary.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        let lower = NSStackView(); lower.orientation = .vertical; lower.alignment = .leading; lower.spacing = 28
        let actions = NSStackView(); actions.orientation = .horizontal; actions.spacing = 12; actions.alignment = .centerY
        let play = action("Play Game", symbol: "play") { [weak self] in self?.onPlay?() }
        (play as? NXDesignButton)?.primary = true
        let host = action("Host Game", symbol: "person.2") { [weak self] in self?.onHost?() }
        for control in [play, host] { control.heightAnchor.constraint(equalToConstant: 46).isActive = true; control.widthAnchor.constraint(equalToConstant: 168).isActive = true; actions.addArrangedSubview(control) }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal); actions.addArrangedSubview(spacer)
        let caveat = text("Netplay · Experimental\nCompatibility not yet validated", size: 12); caveat.textColor = NXDesign.secondary
        caveat.widthAnchor.constraint(equalToConstant: 175).isActive = true; actions.addArrangedSubview(caveat)
        lower.addArrangedSubview(actions); actions.widthAnchor.constraint(equalTo: lower.widthAnchor).isActive = true
        sections.selectedSegment = 0
        let tabs = NSStackView(); tabs.orientation = .horizontal; tabs.spacing = 24
        for (index, title) in ["Save States", "Multiplayer Saves", "Screenshots", "Game Details"].enumerated() {
            let button = NXDesignButton(title: title, target: nil, action: nil); button.tabStyle = true; button.selected = index == 0
            button.handler = { [weak self] in
                guard let self else { return }; self.sections.selectedSegment = index
                self.sectionButtons.enumerated().forEach { $0.element.selected = $0.offset == index }; self.changeSection()
            }
            button.target = button; button.action = #selector(NXDesignButton.invoke)
            button.heightAnchor.constraint(equalToConstant: 42).isActive = true
            tabs.addArrangedSubview(button); sectionButtons.append(button)
        }
        let tabArea = NSStackView(views: [tabs, divider()]); tabArea.orientation = .vertical; tabArea.alignment = .leading; tabArea.spacing = 0
        tabArea.arrangedSubviews.last!.widthAnchor.constraint(equalTo: tabArea.widthAnchor).isActive = true
        lower.addArrangedSubview(tabArea); tabArea.widthAnchor.constraint(equalTo: lower.widthAnchor).isActive = true
        sectionBody.orientation = .vertical; sectionBody.alignment = .leading; sectionBody.spacing = 18
        lower.addArrangedSubview(sectionBody); sectionBody.widthAnchor.constraint(equalTo: lower.widthAnchor).isActive = true
        let lowerArea = NXDesignInset(content: lower, inset: 34)
        body.addArrangedSubview(lowerArea); lowerArea.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        refreshLocalItems(); renderSection()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshLocalItems()
        renderSection()
    }

    private func refreshLocalItems() {
        saves = game.roms.flatMap { $0.saveStates }.filter { !$0.isDeleted }.sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
        screenshots = game.roms.flatMap { $0.screenShots }.filter { !$0.isDeleted }.sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
    }

    @objc private func changeSection() { refreshLocalItems(); renderSection() }

    private func renderSection() {
        for child in sectionBody.arrangedSubviews { sectionBody.removeArrangedSubview(child); child.removeFromSuperview() }
        switch sections.selectedSegment {
        case 0:
            addSectionText("Pick up where you left off", size: 18, weight: .semibold)
            if saves.isEmpty { addSectionText("No save states for this game yet. Save during play to continue here later.") }
            for save in saves {
                let available = save.filesAvailable
                let subtitle = [save.timestamp.map(date), available ? nil : "Save files are missing"].compactMap { $0 }.joined(separator: " · ")
                let row = itemRow(title: save.displayName, subtitle: subtitle, imageURL: save.screenshotURL,
                                  buttonTitle: "Resume", enabled: available) { [weak self, weak save] in
                    guard let save, !save.isDeleted else { return }
                    self?.onResumeSave?(save)
                }
                addFullWidth(row)
            }
        case 1:
            multiplayerBrowser?.removeFromParent()
            let browser = NXMultiplayerSavesViewController()
            browser.onResume = { [weak self] url in
                guard let self else { return }
                NetworkPlayController.resumeSavedSession(url, game: self.game)
            }
            addChild(browser); multiplayerBrowser = browser
            addFullWidth(browser.view)
            browser.view.heightAnchor.constraint(equalToConstant: 360).isActive = true
        case 2:
            addSectionText("Screenshots", size: 18, weight: .semibold)
            if screenshots.isEmpty { addSectionText("No screenshots for this game yet.") }
            for screenshot in screenshots {
                let url = screenshot.url
                let available = FileManager.default.fileExists(atPath: url.path)
                let subtitle = available ? (screenshot.timestamp.map(date) ?? "") : "Screenshot file is missing"
                addFullWidth(itemRow(title: screenshot.name, subtitle: subtitle, imageURL: url,
                                     buttonTitle: "Open", enabled: available) { NSWorkspace.shared.open(url) })
            }
        default:
            addSectionText("Game Details", size: 18, weight: .semibold)
            if let description = game.gameDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty { addSectionText(description) }
            if let system = game.system { addSectionText("System: " + system.name) }
            if let imported = game.importDate { addSectionText("Added to library: " + date(imported)) }
            if let rating = game.rating, rating.intValue > 0 { addSectionText("Your rating: \(rating.intValue) / 5") }
            for rom in game.roms.sorted(by: { ($0.fileName ?? "") < ($1.fileName ?? "") }) {
                guard let url = rom.url else { continue }
                addSectionText("File: " + (rom.fileName ?? url.lastPathComponent))
                if let size = rom.fileSize { addSectionText("Size: " + ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)) }
                sectionBody.addArrangedSubview(action("Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            }
        }
    }

    private func addSectionText(_ value: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) {
        addFullWidth(text(value, size: size, weight: weight))
    }
    private func addFullWidth(_ child: NSView) {
        sectionBody.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: sectionBody.widthAnchor).isActive = true
    }
    private func itemRow(title: String, subtitle: String, imageURL: URL, buttonTitle: String, enabled: Bool, handler: @escaping () -> Void) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.image = NSImage(contentsOf: imageURL) ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        image.widthAnchor.constraint(equalToConstant: 92).isActive = true
        image.heightAnchor.constraint(equalToConstant: 64).isActive = true
        row.addArrangedSubview(image)
        let labels = NSStackView(views: [text(title, size: 14, weight: .medium), text(subtitle, size: 12)])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 5
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(labels)
        for label in labels.arrangedSubviews { label.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true }
        let button = action(buttonTitle, handler: handler)
        button.isEnabled = enabled
        row.addArrangedSubview(button)
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 82).isActive = true
        let group = NSStackView(views: [row, divider()]); group.orientation = .vertical; group.spacing = 18
        row.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        group.arrangedSubviews.last!.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        return group
    }
    private func text(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = NXDesign.foreground
        field.isSelectable = true
        field.preferredMaxLayoutWidth = 400
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    private func action(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) -> NSButton {
        let button = NXDesignButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.handler = handler
        button.target = button
        button.action = #selector(NXDesignButton.invoke)
        if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.imagePosition = .imageLeading }
        return button
    }
    private func divider() -> NSView {
        let line = NSBox()
        line.boxType = .custom; line.borderWidth = 0; line.fillColor = NXDesign.border
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }
    private func date(_ value: Date) -> String { DateFormatter.localizedString(from: value, dateStyle: .medium, timeStyle: .short) }
}

@MainActor
private final class NXGameDetailActionButton: NSButton {
    var handler: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }
    private var clickFeedback = false
    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
        displayIfNeeded()
    }
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        guard isEnabled else { return false }
        clickFeedback = true
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.clickFeedback = false
            self?.needsDisplay = true
        }
        return super.sendAction(action, to: target)
    }
    @objc func invoke() { handler?() }
}

private final class NXGameDetailDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// A restrained native material for content groups, shared by library and netplay.
final class NXContentSurface: NSVisualEffectView {
    init(content: NSView, inset: CGFloat = 16) {
        super.init(frame: .zero)
        material = .contentBackground
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 0.5
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Use init(content:)") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

// Shared visual tokens from the approved desktop design. Native controls retain
// keyboard navigation, accessibility, and their original actions.
enum NXDesign {
    static let background = NSColor(srgbRed: 0.098, green: 0.098, blue: 0.118, alpha: 1)
    static let sidebar = NSColor(srgbRed: 0.133, green: 0.133, blue: 0.161, alpha: 1)
    static let foreground = NSColor(srgbRed: 0.94, green: 0.93, blue: 0.96, alpha: 1)
    static let secondary = NSColor(srgbRed: 0.63, green: 0.62, blue: 0.69, alpha: 1)
    static let accent = NSColor(srgbRed: 0.75, green: 0.63, blue: 1, alpha: 1)
    static let border = NSColor(srgbRed: 0.23, green: 0.22, blue: 0.27, alpha: 1)
}
class NXDesignBackground: NSView {
    let color: NSColor
    init(color: NSColor) { self.color = color; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}
class NXDesignInset: NSView {
    init(content: NSView, inset: CGFloat) {
        super.init(frame: .zero); content.translatesAutoresizingMaskIntoConstraints = false; addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset), content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset), content.topAnchor.constraint(equalTo: topAnchor, constant: inset), content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)])
    }
    required init?(coder: NSCoder) { fatalError() }
}
final class NXArtworkHero: NXDesignInset {
    private var wash: NSImage?
    init(content: NSView, image: NSImage?) {
        if let image, let tiff = image.tiffRepresentation, let input = CIImage(data: tiff) {
            let blurred = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 48]).cropped(to: input.extent)
            if let cg = CIContext().createCGImage(blurred, from: input.extent) { wash = NSImage(cgImage: cg, size: image.size) }
        }
        super.init(content: content, inset: 34)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NXDesign.sidebar.setFill(); bounds.fill()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency { wash?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 0.13) }
    }
}
class NXDesignButton: NSButton {
    var handler: (() -> Void)?
    var primary = false { didSet { needsDisplay = true } }
    var filledTab = false
    var tabStyle = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) { super.init(frame: frame); isBordered = false; font = .systemFont(ofSize: 15); focusRingType = .none }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }
    private var clickFeedback = false
    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
        displayIfNeeded()
    }
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        guard isEnabled else { return false }
        clickFeedback = true
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.clickFeedback = false
            self?.needsDisplay = true
        }
        return super.sendAction(action, to: target)
    }
    @objc func invoke() { handler?() }
    override var intrinsicContentSize: NSSize { NSSize(width: (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 15)]).width + (tabStyle ? (filledTab ? 28 : 0) : 40), height: tabStyle ? 42 : 38) }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        if !tabStyle {
            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            if primary && isEnabled {
                NSGradient(starting: NXDesign.accent, ending: NSColor(srgbRed: 0.47, green: 0.28, blue: 0.78, alpha: 1))?.draw(in: path, angle: 90)
            } else { NXDesign.sidebar.setFill(); path.fill() }
            (primary && isEnabled ? NXDesign.accent : NXDesign.border).setStroke(); path.lineWidth = 1; path.stroke()
            if isHighlighted || clickFeedback { NSColor.white.withAlphaComponent(0.12).setFill(); path.fill() }
        } else if selected {
            if filledTab {
                NXDesign.accent.withAlphaComponent(0.30).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            } else {
                NXDesign.accent.setFill(); NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill()
            }
        }
        if tabStyle && (isHighlighted || clickFeedback) {
            NXDesign.accent.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
        if window?.firstResponder === self {
            NXDesign.accent.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9)
            focus.lineWidth = 2
            focus.stroke()
        }
        let color = isEnabled ? NSColor.white : NSColor(calibratedWhite: 0.72, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 15), .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attributes)
        let iconWidth: CGFloat = image == nil || tabStyle ? 0 : 24
        let x = tabStyle ? (filledTab ? (bounds.width - size.width) / 2 : 0) : (bounds.width - size.width - iconWidth) / 2
        if let image, iconWidth > 0 {
            let symbol = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular).applying(NSImage.SymbolConfiguration(paletteColors: [color]))) ?? image
            symbol.draw(in: NSRect(x: x, y: (bounds.height - 18) / 2, width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: isEnabled ? 0.9 : 0.4, respectFlipped: true, hints: nil)
        }
        (title as NSString).draw(at: NSPoint(x: x + iconWidth, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}


// Shared palette for secondary windows. Keep native control behavior and bindings.
extension NXDesign {
    static func addArtworkShadow(to view: NSView) {
        view.wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.65)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        view.shadow = shadow
    }

    static func apply(to view: NSView) {
        view.appearance = NSAppearance(named: .darkAqua)
        if let field = view as? NSTextField {
            if field.isEditable { field.backgroundColor = sidebar; field.textColor = foreground }
            else if field.textColor == .secondaryLabelColor { field.textColor = NSColor(calibratedWhite: 0.78, alpha: 1) }
            else if field.textColor == .labelColor || field.textColor == .controlTextColor { field.textColor = foreground }
        }
        if let button = view as? NSButton, !(button is NXDesignButton), !(button is ControlsKeyButton) {
            button.contentTintColor = button.accessibilityRole() == .checkBox ? accent : foreground
            if !(button is NSPopUpButton), button.accessibilityRole() != .checkBox, button.bezelStyle == .rounded || button.bezelStyle == .regularSquare {
                button.bezelColor = NSColor(calibratedWhite: 0.23, alpha: 1)
                let title = NSMutableAttributedString(attributedString: button.attributedTitle)
                title.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: title.length))
                button.attributedTitle = title
            }
        }
        if let table = view as? NSTableView { table.backgroundColor = background }
        if let scroll = view as? NSScrollView { scroll.backgroundColor = background }
        for child in view.subviews { apply(to: child) }
    }
    static func apply(to window: NSWindow) {
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = background
        if let content = window.contentView { apply(to: content) }
    }
}

// Keep native checkbox actions, state, keyboard activation and accessibility.
final class NXDesignCheckbox: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: 1, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let shape = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        (state == .on ? NXDesign.accent : NSColor(calibratedWhite: 0.23, alpha: 1)).setFill()
        shape.fill()
        if state == .on {
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: box.minX + 4, y: box.midY))
            tick.line(to: NSPoint(x: box.minX + 7, y: box.minY + (isFlipped ? 12 : 4)))
            tick.line(to: NSPoint(x: box.minX + 13, y: box.minY + (isFlipped ? 4 : 12)))
            NSColor(calibratedWhite: 0.12, alpha: 1).setStroke()
            tick.lineWidth = 2; tick.lineCapStyle = .round; tick.lineJoinStyle = .round; tick.stroke()
        }
        if isHighlighted { NSColor.white.withAlphaComponent(0.2).setFill(); shape.fill() }
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: isEnabled ? NSColor.white : NSColor(calibratedWhite: 0.72, alpha: 1)]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: 25, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}


/// Browses existing host saves without importing, moving, or rewriting them.
final class NXMultiplayerSavesViewController: NSViewController {
    var onResume: ((URL) -> Void)?
    var onClose: (() -> Void)?
    private let rows = NSStackView()
    private let summary = NSTextField(labelWithString: "")
    private static var folder: URL {
        URL.oeApplicationSupportDirectory.appendingPathComponent("Multiplayer Sessions", isDirectory: true)
    }
    override func loadView() {
        view = NXDesignBackground(color: NXDesign.background)
        let title = NSTextField(labelWithString: "Multiplayer Saves")
        title.font = .systemFont(ofSize: 24, weight: .bold); title.textColor = NXDesign.foreground
        summary.textColor = NXDesign.secondary
        let find = makeButton("Find Save…") { [weak self] in self?.findSave() }
        let refresh = makeButton("Refresh") { [weak self] in self?.reload() }
        let header = NSStackView(views: [title, NSView(), refresh, find]); header.spacing = 12
        if onClose != nil { header.addArrangedSubview(makeButton("Done") { [weak self] in self?.onClose?() }) }
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 12
        let document = NXGameDetailDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        rows.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(rows)
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = document
        for child in [header, summary, scroll] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 24), header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28), header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            summary.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12), summary.leadingAnchor.constraint(equalTo: header.leadingAnchor), summary.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 20), scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), rows.leadingAnchor.constraint(equalTo: document.leadingAnchor), rows.trailingAnchor.constraint(equalTo: document.trailingAnchor), rows.topAnchor.constraint(equalTo: document.topAnchor), rows.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        reload()
    }
    private func makeButton(_ title: String, _ action: @escaping () -> Void) -> NXDesignButton {
        let button = NXDesignButton(title: title, target: nil, action: nil)
        button.handler = action; button.target = button; button.action = #selector(NXDesignButton.invoke)
        return button
    }
    private func findSave() {
        let panel = NSOpenPanel(); panel.title = "Find Multiplayer Save"; panel.allowedFileTypes = ["emuxsave"]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.directoryURL = Self.folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onResume?(url)
    }
    private func deleteSave(_ url: URL) {
        let alert = NSAlert()
        if NetworkPlayController.isActiveMultiplayerSave(url) {
            alert.messageText = "This save is in use."
            alert.informativeText = "End the multiplayer game before deleting its autosave."
            alert.runModal(); return
        }
        alert.messageText = "Move this multiplayer save to Trash?"
        alert.informativeText = url.lastPathComponent + "\nYou can restore it from the Trash in Finder."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            reload()
        } catch {
            let failure = NSAlert(error: error); failure.runModal()
        }
    }
    private func reload() {
        for row in rows.arrangedSubviews { rows.removeArrangedSubview(row); row.removeFromSuperview() }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
        var files: [(URL, Date)] = []
        var readError: Error?
        if FileManager.default.fileExists(atPath: Self.folder.path),
           let enumerator = FileManager.default.enumerator(at: Self.folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { _, error in readError = error; return true }) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "emuxsave" {
                if let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
                    files.append((url, values.contentModificationDate ?? .distantPast))
                }
            }
        }
        files.sort { $0.1 > $1.1 }
        summary.stringValue = readError != nil ? "Some saves could not be read. Use Find Save to locate them." : files.isEmpty ? "No multiplayer saves yet. Host a game to create an autosave, or choose Find Save…" : "\(files.count) saved sessions · Newest first"
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
        for (url, date) in files {
            let title = NSTextField(labelWithString: UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil ? "Multiplayer Autosave" : url.deletingPathExtension().lastPathComponent)
            title.font = .systemFont(ofSize: 15, weight: .semibold); title.textColor = NXDesign.foreground
            var info = formatter.string(from: date)
            var valid = false
            if let handle = try? FileHandle(forReadingFrom: url) {
                let header = try? handle.read(upToCount: 152); try? handle.close()
                if let header, header.count == 152, header.prefix(8) == Data("EMUXJNL1".utf8) {
                    let version = Int(header[8]) | Int(header[9]) << 8
                    let count = Int(header[10]) | Int(header[11]) << 8
                    valid = (version == 1 && count == 0) || (version == 2 && (3...5).contains(count))
                    info += " · \(version == 1 ? 2 : count) players"
                }
            }
            if !valid { info += " · Unrecognized save format" }
            let subtitle = NSTextField(labelWithString: info); subtitle.textColor = NXDesign.secondary; subtitle.font = .systemFont(ofSize: 12)
            let labels = NSStackView(views: [title, subtitle]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 5
            labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let reveal = makeButton("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            let resume = makeButton("Resume") { [weak self] in self?.onResume?(url) }; resume.isEnabled = valid
            let delete = makeButton("Delete…") { [weak self] in self?.deleteSave(url) }
            let row = NSStackView(views: [labels, reveal, resume, delete]); row.spacing = 14; row.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
            row.toolTip = url.path
            rows.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            let line = NSBox(); line.boxType = .separator; rows.addArrangedSubview(line); line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }
}
