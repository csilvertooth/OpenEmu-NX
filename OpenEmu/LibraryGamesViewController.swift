// Copyright (c) 2020, OpenEmu Team
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

extension NSNotification.Name {
    static let OELibrarySplitViewResetSidebar = NSNotification.Name("OELibrarySplitViewResetSidebar")
}

/// What `LibraryGamesViewController` needs from the view that shows the games. Both the old
/// `OEGameCollectionViewController` and the new `GameCollectionViewController` provide it, so the
/// new one can be switched on from the debug preferences while it is tested.
protocol GamesCollectionControlling: NSViewController {
    func use(database: OELibraryDatabase?)
    var selectedGames: [OEDBGame] { get }
    var isGridView: Bool { get }
    var isBlankSlate: Bool { get }
    
    func updateBlankSlate()
    func showGridView()
    func showListView()
    func performSearch(_ text: String)
    func zoomGrid(to value: CGFloat)
}

extension OEGameCollectionViewController: GamesCollectionControlling {
    var isGridView: Bool { selectedViewTag == .gridViewTag }
    var isBlankSlate: Bool { shouldShowBlankSlate() }
    func use(database: OELibraryDatabase?) { self.database = database }
    func zoomGrid(to value: CGFloat) { zoomGridView(withValue: value) }
}

extension GameCollectionViewController: GamesCollectionControlling {
    var isGridView: Bool { viewMode == .grid }
    var isBlankSlate: Bool { shouldShowBlankSlate }
    func use(database: OELibraryDatabase?) { self.database = database }
    func zoomGrid(to value: CGFloat) { zoomGridView(zoomValue: value) }
}

extension Key {
    static let useNewGamesViewController: Key = "useNewGamesViewController"
}

extension LibraryGamesViewController {
    @UserDefault(.useNewGamesViewController, defaultValue: false)
    static var useNewGamesViewController: Bool
}

final class LibraryGamesViewController: NSSplitViewController {
    
    private static let skipDiscGuideMessageKey = "OESkipDiscGuideMessageKey"
    private lazy var discGuideMessageSystemIDs: [String?] = []
    
    private let sidebarMinWidth: CGFloat = 250
    private let sidebarDefaultWidth: CGFloat = 250
    private let sidebarMaxWidth: CGFloat = 450
    private let collectionViewMinWidth: CGFloat = 680
    
    private var sidebarController: SidebarController!
    private var collectionController: GamesCollectionControlling!
    private let contentPane = NSViewController()
    private var displayedController: NSViewController?
    private var detailGame: OEDBGame? { didSet { designBack.isHidden = detailGame == nil } }
    private let designBack = NXDesignButton(title: "Back", target: nil, action: nil)
    private let designSearch = NSSearchField()
    private let breadcrumb = NSTextField(labelWithString: "Library")
    private let contentBody = NSView()
    private func buildDesignHeader() {
        let header = NXDesignBackground(color: NXDesign.background)
        let back = designBack
        back.isHidden = detailGame == nil
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        back.widthAnchor.constraint(equalToConstant: 84).isActive = true
        back.heightAnchor.constraint(equalToConstant: 36).isActive = true
        back.handler = { [weak self] in self?.showLibrary() }; back.target = back; back.action = #selector(NXDesignButton.invoke)
        back.setAccessibilityLabel("Back to Library")
        breadcrumb.textColor = NXDesign.secondary; breadcrumb.font = .systemFont(ofSize: 14)
        let grid = NSButton(image: NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Grid view")!, target: self, action: #selector(switchToGridView(_:)))
        let list = NSButton(image: NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List view")!, target: self, action: #selector(switchToListView(_:)))
        for button in [grid, list] { button.isBordered = false; button.contentTintColor = NXDesign.foreground; button.widthAnchor.constraint(equalToConstant: 28).isActive = true }
        let search = designSearch; search.placeholderString = "Search library"; search.font = .systemFont(ofSize: 14)
        search.sendsSearchStringImmediately = true; search.target = self; search.action = #selector(self.search(_:))
        search.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [back, breadcrumb, spacer, grid, list, search]); controls.spacing = 16; controls.alignment = .centerY
        controls.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(controls)
        for child in [header, contentBody] { child.translatesAutoresizingMaskIntoConstraints = false; contentPane.view.addSubview(child) }
        NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo: contentPane.view.leadingAnchor), header.trailingAnchor.constraint(equalTo: contentPane.view.trailingAnchor), header.topAnchor.constraint(equalTo: contentPane.view.topAnchor), header.heightAnchor.constraint(equalToConstant: 70), controls.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 34), controls.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -24), controls.centerYAnchor.constraint(equalTo: header.centerYAnchor), contentBody.leadingAnchor.constraint(equalTo: header.leadingAnchor), contentBody.trailingAnchor.constraint(equalTo: header.trailingAnchor), contentBody.topAnchor.constraint(equalTo: header.bottomAnchor), contentBody.bottomAnchor.constraint(equalTo: contentPane.view.bottomAnchor)])
    }

    private func display(_ controller: NSViewController) {
        guard displayedController !== controller else { return }
        displayedController?.view.removeFromSuperview()
        displayedController?.removeFromParent()
        controller.removeFromParent()
        contentPane.addChild(controller)
        let content = controller.view
        content.translatesAutoresizingMaskIntoConstraints = false
        contentBody.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentBody.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentBody.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentBody.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentBody.bottomAnchor)
        ])
        displayedController = controller
    }

    func showCategory(_ category: LibraryController.Category, contentController: NSViewController?) {
        _ = view
        detailGame = nil
        display(contentController ?? collectionController)
    }

    func selectSidebarCategory(_ category: LibraryController.Category) {
        _ = view
        sidebarController.selectCategory(category)
    }

    private func showLibrary() {
        detailGame = nil
        display(collectionController)
        collectionController.performSearch(designSearch.stringValue)
    }

    @objc func showSelectedGameDetails(_ sender: Any?) {
        guard let game = (sender as? OEDBGame) ?? collectionController.selectedGames.first else { return }
        detailGame = game
        breadcrumb.stringValue = "Library / " + (game.system?.name ?? "All Games")
        let detail = NXGameDetailViewController(game: game)
        detail.onBack = { [weak self] in self?.showLibrary() }
        detail.onPlay = { [weak self] in (self?.parent as? LibraryController)?.start(game: game) }
        detail.onHost = { NetworkPlayController.hostLibraryGame(game) }
        detail.onMultiplayerSaves = { NetworkPlayController.resumeLibraryGame(game) }
        detail.onResumeSave = { [weak self] save in (self?.parent as? LibraryController)?.start(saveState: save) }
        display(detail)
    }
    private var toolbar: LibraryToolbar? {
        (parent as? LibraryController)?.toolbar
    }
    
    var database: OELibraryDatabase?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        sidebarController = SidebarController()
        collectionController = Self.useNewGamesViewController ? GameCollectionViewController() : OEGameCollectionViewController()
        
        setUpSplitView()
        assignDatabase()
        
        NotificationCenter.default.addObserver(self, selector: #selector(updateCollectionContentsFromSidebar), name: .OESidebarSelectionDidChange, object: nil)
    }


    
    override func viewWillAppear() {
        super.viewWillAppear()
        
        setUpSplitViewAutosave()
        updateCollectionContentsFromSidebar()
        
        view.needsDisplay = true
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        
        if displayedController === collectionController { collectionController.updateBlankSlate() }
        
        if #available(macOS 11.0, *) {
            view.window?.titlebarSeparatorStyle = .automatic
        }
    }
    
    override func viewWillDisappear() {
        super.viewWillDisappear()
        
        if #available(macOS 11.0, *) {
            view.window?.titlebarSeparatorStyle = .line
        }
    }
    
    private func assignDatabase() {
        sidebarController.database = database
        collectionController.use(database: database)
    }
    
    // MARK: - Split View
    
    private func setUpSplitView() {
        
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = NSColor.clear.cgColor
        
        let sidebarItem = NSSplitViewItem(viewController: sidebarController)
        sidebarItem.minimumThickness = sidebarMinWidth
        sidebarItem.maximumThickness = sidebarMaxWidth
        sidebarItem.canCollapse = false
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 999)
        if #available(macOS 11.0, *) {
            sidebarItem.titlebarSeparatorStyle = .automatic
        }
        addSplitViewItem(sidebarItem)

        // The NSSplitViewItem sidebar wrapper spans the full left pane but the
        // SidebarController's view may not cover its bottom edge (xib gap between
        // the scroll view and the game-scanner panel). The system's
        // NSVisualEffectView behind the wrapper samples the desktop colour, which
        // renders dark on a dark wallpaper even in light mode.
        //
        // Fix: attach an NSBox directly to the wrapper so it covers every pixel
        // of the pane. Clear in dark mode so it never touches the vibrancy
        // compositor (an opaque fill in dark mode causes ghost-toolbar artifacts).
        if let sidebarWrapper = splitView.subviews.first {
            let gapFill = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? .clear
                    : NSColor(white: 0.88, alpha: 1)
            }
            let bg = NSBox()
            bg.boxType = .custom
            bg.borderWidth = 0
            bg.contentViewMargins = .zero
            bg.fillColor = gapFill
            bg.translatesAutoresizingMaskIntoConstraints = false
            sidebarWrapper.addSubview(bg, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                bg.topAnchor.constraint(equalTo: sidebarWrapper.topAnchor),
                bg.bottomAnchor.constraint(equalTo: sidebarWrapper.bottomAnchor),
                bg.leadingAnchor.constraint(equalTo: sidebarWrapper.leadingAnchor),
                bg.trailingAnchor.constraint(equalTo: sidebarWrapper.trailingAnchor),
            ])
        }

        contentPane.view = NXDesignBackground(color: NXDesign.background)
        buildDesignHeader()
        let collectionItem = NSSplitViewItem(viewController: contentPane)
        collectionItem.minimumThickness = collectionViewMinWidth
        collectionItem.holdingPriority = .defaultLow
        if #available(macOS 11.0, *) {
            collectionItem.titlebarSeparatorStyle = .line
        }
        addSplitViewItem(collectionItem)
        display(collectionController)
        collectionController.performSearch(designSearch.stringValue)
    }
    
    private func setUpSplitViewAutosave() {
        
        if splitView.autosaveName != nil && !(splitView.autosaveName == "") {
            return
        }
        
        let autosaveName = "NXApprovedLibrarySplitView"
        
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(autosaveName)") == nil {
            splitView.setPosition(sidebarDefaultWidth, ofDividerAt: 0)
        }
        
        splitView.autosaveName = autosaveName
        
        NotificationCenter.default.addObserver(self, selector: #selector(resetSidebar), name: .OELibrarySplitViewResetSidebar, object: nil)
    }
    
    @objc func resetSidebar() {
        splitView.setPosition(sidebarDefaultWidth, ofDividerAt: 0)
    }
    
    // MARK: - Actions
    
    @IBAction func newCollection(_ sender: AnyObject?) {
        sidebarController.newCollection(sender)
    }
    
    @IBAction func selectSystems(_ sender: Any?) {
        sidebarController.selectSystems(sender)
    }
    
    @IBAction func switchToGridView(_ sender: Any?) {
        showLibrary()
        collectionController.showGridView()
        collectionController.performSearch(designSearch.stringValue)
    }
    
    @IBAction func switchToListView(_ sender: Any?) {
        showLibrary()
        collectionController.showListView()
        collectionController.performSearch(designSearch.stringValue)
    }
    
    @IBAction func search(_ sender: NSSearchField?) {
        guard let searchField = sender else { return }
        showLibrary()
        collectionController.performSearch(searchField.stringValue)
    }
    
    @IBAction func changeGridSize(_ sender: NSSlider?) {
        guard let slider = toolbar?.gridSizeSlider else { return }
        collectionController.zoomGrid(to: CGFloat(slider.doubleValue))
    }
    
    @IBAction func decreaseGridSize(_ sender: AnyObject?) {
        guard let slider = toolbar?.gridSizeSlider else { return }
        slider.doubleValue -= sender?.tag == 199 ? 0.25 : 0.5
        collectionController.zoomGrid(to: CGFloat(slider.doubleValue))
    }
    
    @IBAction func increaseGridSize(_ sender: AnyObject?) {
        guard let slider = toolbar?.gridSizeSlider else { return }
        slider.doubleValue += sender?.tag == 199 ? 0.25 : 0.5
        collectionController.zoomGrid(to: CGFloat(slider.doubleValue))
    }
    
    @objc func updateCollectionContentsFromSidebar() {
        
        // A fresh profile or collapsed group can temporarily have no selection.
        // The legacy collection controller requires a real collection, never nil.
        if sidebarController.selectedSidebarItem == nil,
           let fallback = sidebarController.collections.first(where: { $0 is GameCollectionViewItemProtocol }) {
            sidebarController.selectItem(fallback)
        }
        if sidebarController.selectedSidebarItem is NXMultiplayerSidebarItem {
            detailGame = nil
            breadcrumb.stringValue = "Library / Multiplayer Saves"
            let browser = NXMultiplayerSavesViewController()
            browser.onResume = { NetworkPlayController.resumeSavedSession($0) }
            display(browser)
            return
        }
        if let destination = sidebarController.selectedSidebarItem as? SidebarDestinationItem {
            if let library = parent as? LibraryController, library.selectedCatagory != destination.category {
                library.selectedCatagory = destination.category
            }
            return
        }
        guard let selectedItem = sidebarController.selectedSidebarItem,
              let collection = selectedItem as? GameCollectionViewItemProtocol else { return }
        if let library = parent as? LibraryController, library.selectedCatagory != .games {
            library.selectedCatagory = .games
        }
        showLibrary()
        collectionController.representedObject = collection
        breadcrumb.stringValue = "Library / " + selectedItem.sidebarName
        
        // For empty collections of disc-based games, display an alert to compel the user to read the disc-importing guide.
        // Delay disc alert by 200 ms to allow navigating past disc-based systems with arrow keys in the sidebar without triggering the alert.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) {
            guard self.sidebarController.selectedSidebarItem === selectedItem else { return }
            
            if let system = selectedItem as? OEDBSystem,
               system.plugin?.supportsDiscsWithDescriptorFile ?? false,
               system.games.isEmpty,
               !self.discGuideMessageSystemIDs.contains(system.systemIdentifier),
               !UserDefaults.standard.bool(forKey: Self.skipDiscGuideMessageKey),
               let window = self.view.window {
                
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("Have you read the guide?", comment: "")
                alert.informativeText = NSLocalizedString("Disc-based games have special requirements. Please read the disc importing guide.", comment: "")
                alert.alertStyle = .informational
                alert.addButton(withTitle: NSLocalizedString("View Guide in Browser", comment: ""))
                alert.addButton(withTitle: NSLocalizedString("Dismiss", comment: ""))
                
                alert.beginSheetModal(for: window) { result in
                    if result == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(.userGuideCDBasedGames)
                    }
                }
                
                self.discGuideMessageSystemIDs.append(system.systemIdentifier)
            }
        }
    }
    
    @objc func makeNewCollectionWithSelectedGames(_ sender: Any?) {
        assert(Thread.isMainThread, "Only call on main thread!")
        
        sidebarController.newCollection(games: selectedGames)
    }
}

extension LibraryGamesViewController: LibrarySubviewControllerGameSelection {
    
    var selectedGames: [OEDBGame] {
        detailGame.map { [$0] } ?? collectionController.selectedGames
    }
}

// MARK: - Validation

extension LibraryGamesViewController: NSMenuItemValidation {
    
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let isGridView = collectionController.isGridView
        let isBlankSlate = collectionController.isBlankSlate
        
        switch menuItem.action {
        case #selector(switchToGridView):
            menuItem.state = isGridView ? .on : .off
            return !isBlankSlate
        case #selector(switchToListView):
            menuItem.state = !isGridView ? .on : .off
            return !isBlankSlate
        default:
            return true
        }
    }
}

