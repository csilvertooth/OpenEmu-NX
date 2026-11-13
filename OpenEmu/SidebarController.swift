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
import Carbon.HIToolbox.Events
import OpenEmuKit

extension NSNotification.Name {
    static let OESidebarSelectionDidChange = NSNotification.Name("OESidebarSelectionDidChange")
}

private extension NSUserInterfaceItemIdentifier {
    static let headerView = NSUserInterfaceItemIdentifier("SidebarHeaderView")
    static let itemView   = NSUserInterfaceItemIdentifier("SidebarItemView")
}

final class SidebarController: NSViewController {
    
    @IBOutlet var sidebarView: NSOutlineView!
    @IBOutlet var gameScannerViewController: GameScannerViewController!
    
    var database: OELibraryDatabase? {
        didSet {
            // Remove previous context observer when database changes.
            if let old = dbToken {
                NotificationCenter.default.removeObserver(old)
                dbToken = nil
            }

            // Reload sidebar when games are added directly (e.g. via Homebrew),
            // bypassing the ROM importer.
            if let context = database?.mainThreadContext {
                dbToken = NotificationCenter.default.addObserver(
                    forName: .NSManagedObjectContextDidSave,
                    object: context,
                    queue: .main
                ) { [weak self] notification in
                    guard let self = self else { return }
                    let inserted = notification.userInfo?[NSInsertedObjectsKey] as? Set<NSManagedObject> ?? []
                    if inserted.contains(where: { $0 is OEDBGame }) {
                        self.reloadDataAndPreserveSelection()
                    }
                }
            }

            let lastSidebarSelection = self.lastSidebarSelection
            reloadData()
            self.lastSidebarSelection = lastSidebarSelection

            guard
                !lastSidebarSelection.isEmpty,
                let item = lastSidebarSelectionItem
            else { return }

            selectItem(item)
        }
    }
    
    @UserDefault(.lastSidebarSelection, defaultValue: "")
    var lastSidebarSelection: String
    
    var lastSidebarSelectionItem: SidebarItem? {
        systems.first(where: { $0.sidebarID == lastSidebarSelection }) ?? collections.first(where: { $0.sidebarID == lastSidebarSelection}) ?? destinations.first(where: { $0.sidebarID == lastSidebarSelection })
    }

    private let libraryGroup = SidebarGroupItem(name: "Library", autosaveName: .sidebarSubgroupItem, key: "nx.library")
    private let multiplayerDestination = NXMultiplayerSidebarItem()
    private let destinations = [SidebarDestinationItem(category: .saveStates), SidebarDestinationItem(category: .homebrew)]
    private var lastGameSelectionID: String?
    private let consolesGroup = SidebarGroupItem(name: "Consoles", autosaveName: .sidebarConsolesItem)
    private let collectionsGroup = SidebarGroupItem(name: "Collections", autosaveName: .sidebarCollectionsItem)
    private let favoritesGroup = SidebarGroupItem(name: "Favorite Consoles", autosaveName: .sidebarFavoritesItem)
    private var extraGroups: [String: SidebarGroupItem] = [:]
    private var groupChildren: [String: [SidebarItem]] = [:]
    private var restoringExpansion = false
    private static let reorderType = NSPasteboard.PasteboardType("net.openemunx.sidebar-item")
    var groups: [SidebarGroupItem] = []
    private var sidebarDefaults: UserDefaults { .standard }
    private var grouping: String { sidebarDefaults.string(forKey: "NXSidebarGrouping") ?? "vendor" }
    private var favoriteIDs: [String] { sidebarDefaults.stringArray(forKey: "NXSidebarFavorites") ?? [] }
    private func itemID(_ item: SidebarItem) -> String { (item as? SidebarGroupItem)?.key ?? item.sidebarID ?? item.sidebarName }
    private func ordered(_ items: [SidebarItem], key: String) -> [SidebarItem] {
        let ids = sidebarDefaults.stringArray(forKey: key) ?? []
        return items.sorted {
            let a = ids.firstIndex(of: itemID($0)) ?? Int.max
            let b = ids.firstIndex(of: itemID($1)) ?? Int.max
            return a == b ? $0.sidebarName.localizedStandardCompare($1.sidebarName) == .orderedAscending : a < b
        }
    }
    private func vendor(for item: SidebarItem) -> String {
        let id = (item as? OEDBSystem)?.systemIdentifier.lowercased() ?? ""
        let n = item.sidebarName.lowercased()
        if id.contains("nintendo") || n.contains("nintendo") || ["game boy", "gameboy", "gamecube", "wii", "famicom", "virtual boy", "pokémon", "pokemon"].contains(where: n.contains) { return "Nintendo" }
        if id.contains("sega") || ["sega", "dreamcast", "game gear", "sg-1000"].contains(where: n.contains) { return "Sega" }
        if id.contains("sony") || n.contains("playstation") || n.contains("psp") { return "Sony" }
        if n.contains("atari") { return "Atari" }
        if n.contains("turbografx") || n.contains("pc-fx") { return "NEC" }
        if n.contains("neogeo") || n.contains("neo geo") { return "SNK" }
        return "Other"
    }
    private func rebuildGroups() {
        let favoriteSet = Set(favoriteIDs)
        let favorites = ordered(systems.filter { favoriteSet.contains(itemID($0)) }, key: "NXSidebarFavorites")
        let remaining = systems.filter { !favoriteSet.contains(itemID($0)) }
        let allGames = collections.filter { $0 is OEDBAllGamesCollection }
        groupChildren = [libraryGroup.key: allGames + destinations.filter { $0.category != .homebrew } + [multiplayerDestination],
                         favoritesGroup.key: favorites,
                         collectionsGroup.key: ordered(collections.filter { !($0 is OEDBAllGamesCollection) }, key: "NXSidebarCollections")]

        if grouping == "flat" {
            groupChildren[consolesGroup.key] = ordered(remaining, key: "NXSidebarSystems")
        } else {
            let assignments = sidebarDefaults.dictionary(forKey: "NXSidebarCustomGroups") as? [String: String] ?? [:]
            let buckets = Dictionary(grouping: remaining) { grouping == "vendor" ? vendor(for: $0) : assignments[itemID($0)] ?? "Ungrouped" }
            var sections: [SidebarGroupItem] = []
            for title in buckets.keys.sorted() {
                let key = "\(grouping):\(title)"
                let section = extraGroups[key] ?? SidebarGroupItem(name: title, autosaveName: .sidebarSubgroupItem, key: key)
                extraGroups[key] = section; sections.append(section)
                groupChildren[key] = ordered(buckets[title]!, key: "NXSidebarOrder." + key)
            }
            groupChildren[consolesGroup.key] = ordered(sections, key: "NXSidebarGroups." + grouping)
        }
        groupChildren[consolesGroup.key, default: []].append(contentsOf: destinations.filter { $0.category == .homebrew })
        let base = [favoritesGroup, consolesGroup, collectionsGroup]
        let order = sidebarDefaults.stringArray(forKey: "NXSidebarSections") ?? base.map(\.key)
        groups = [libraryGroup] + base.sorted { (order.firstIndex(of: $0.key) ?? 99) < (order.firstIndex(of: $1.key) ?? 99) }
    }
    private func restoreExpansion() {
        restoringExpansion = true
        let collapsed = Set(sidebarDefaults.stringArray(forKey: "NXSidebarCollapsed") ?? [])
        func restore(_ group: SidebarGroupItem) {
            if collapsed.contains(group.key) { sidebarView.collapseItem(group) }
            else {
                sidebarView.expandItem(group)
                for child in groupChildren[group.key] ?? [] { if let nested = child as? SidebarGroupItem { restore(nested) } }
            }
        }
        groups.forEach(restore)
        restoringExpansion = false
    }
    private func rememberExpansion(_ notification: Notification, collapsed: Bool) {
        guard !restoringExpansion, let group = notification.userInfo?["NSObject"] as? SidebarGroupItem else { return }
        var ids = Set(sidebarDefaults.stringArray(forKey: "NXSidebarCollapsed") ?? [])
        if collapsed { ids.insert(group.key) } else { ids.remove(group.key) }
        sidebarDefaults.set(Array(ids), forKey: "NXSidebarCollapsed")
    }
    
    var systems: [SidebarItem] = []
    var collections: [SidebarItem] = []
    
    var selectedSidebarItem: SidebarItem? {
        let item = sidebarView.item(atRow: sidebarView.selectedRow)
        precondition(item == nil || item is SidebarItem, "All sidebar items must confirm to SidebarItem")
        return item as? SidebarItem
    }
    
    private var tokens = [NSObjectProtocol]()
    private var dbToken: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()

        sidebarView.style = .plain
        sidebarView.backgroundColor = NXDesign.sidebar
        sidebarView.selectionHighlightStyle = .regular
        if let scroll = sidebarView.enclosingScrollView {
            scroll.removeFromSuperview()
            scroll.drawsBackground = false; scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            scroll.automaticallyAdjustsContentInsets = false
            let root = NXDesignBackground(color: NXDesign.sidebar)
            view = root
            let brand = NSTextField(labelWithString: "OpenEmu-NX"); brand.font = .systemFont(ofSize: 21, weight: .bold); brand.textColor = NXDesign.accent
            let tagline = NSTextField(labelWithString: "Your games. Together."); tagline.font = .systemFont(ofSize: 12); tagline.textColor = NXDesign.secondary
            let branding = NSStackView(views: [brand, tagline]); branding.orientation = .vertical; branding.alignment = .leading; branding.spacing = 6
            let settings = NXDesignButton(title: "Settings", target: NSApp.delegate, action: #selector(AppDelegate.showPreferencesWindow(_:)))
            settings.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
            let note = NSTextField(labelWithString: "Library stays on this Mac"); note.textColor = NXDesign.secondary; note.font = .systemFont(ofSize: 11)
            for child in [branding, scroll, settings, note] { child.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(child) }
            NSLayoutConstraint.activate([branding.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28), branding.topAnchor.constraint(equalTo: root.topAnchor, constant: 28), branding.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20), scroll.topAnchor.constraint(equalTo: branding.bottomAnchor, constant: 18), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), scroll.bottomAnchor.constraint(equalTo: settings.topAnchor, constant: -12), settings.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), settings.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24), settings.heightAnchor.constraint(equalToConstant: 38), settings.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -24), note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), note.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)])
        }
        sidebarView.registerForDraggedTypes([.fileURL, .game, Self.reorderType])
        sidebarView.setDraggingSourceOperationMask(.move, forLocal: true)
        sidebarView.indentationPerLevel = 12
        restoreExpansion()
        
        let menu = NSMenu()
        menu.delegate = self
        sidebarView.menu = menu
        menuNeedsUpdate(menu)
        
        tokens = [
            NotificationCenter.default.addObserver(forName: .OEDBSystemAvailabilityDidChange, object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }

                self.reloadDataAndPreserveSelection()
            },
            NotificationCenter.default.addObserver(forName: .libraryLocationDidChange, object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }

                self.reloadData()
            },
            NotificationCenter.default.addObserver(forName: .ROMImporterDidFinish, object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }

                self.reloadDataAndPreserveSelection()
            },
        ]
        
    }
    
    deinit {
        tokens.forEach { observer in
            NotificationCenter.default.removeObserver(observer)
        }
        tokens = []
        if let old = dbToken {
            NotificationCenter.default.removeObserver(old)
            dbToken = nil
        }
    }
    
    func reloadDataAndPreserveSelection() {
        let possibleItem = self.selectedSidebarItem
        let previousRow  = self.sidebarView.selectedRow
        
        reloadData()
        
        guard let previousItem = possibleItem, previousRow >= 0 else { return }
        
        var rowToSelect = previousRow
        let reloadedRowForPreviousItem = sidebarView.row(forItem: previousItem)
        
        if reloadedRowForPreviousItem == -1 {
            func isSelectable(i: Int) -> Bool {
                guard let item = sidebarView.item(atRow: i) else { return false }
                return outlineView(sidebarView, shouldSelectItem: item)
            }
            
            rowToSelect =
                // find a row before the previously selected one
                (0...rowToSelect).reversed().first(where: isSelectable) ??
                
                // find a row after the previously selected one
                (rowToSelect..<sidebarView.numberOfRows).first(where: isSelectable) ??
                
                // or nothing
                NSNotFound
            
        } else if reloadedRowForPreviousItem != previousRow {
            rowToSelect = reloadedRowForPreviousItem
        }
        
        guard rowToSelect != NSNotFound else { return }
        
        sidebarView.selectRowIndexes([rowToSelect], byExtendingSelection: false)
        outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification))
    }
    
    func reloadData() {
        guard let database = database else { return }
        
        if sidebarView.currentEditor() != nil {
            sidebarView.abortEditing()
        }
        
        let allSystems = OEDBSystem.enabledSystems(in: database.mainThreadContext)
        systems = allSystems.filter { system in
            let hasCores = !OECorePlugin.corePlugins(forSystemIdentifier: system.systemIdentifier).isEmpty
            let hasGames = !system.games.isEmpty
            return hasCores || hasGames
        }
        collections = database.collections
        rebuildGroups()
        sidebarView.reloadData()
        restoreExpansion()
    }
    
    // MARK: - Actions
    
    func selectCategory(_ category: LibraryController.Category) {
        if category == .games {
            if selectedSidebarItem is GameCollectionViewItemProtocol { return }
            let previous = (systems + collections).first { $0.sidebarID == lastGameSelectionID }
            if let item = previous ?? collections.first(where: { $0 is OEDBAllGamesCollection }) {
                selectItem(item)
            }
        } else if let item = destinations.first(where: { $0.category == category }) {
            selectItem(item)
        }
    }

    func selectItem(_ item: SidebarItem) {
        if sidebarView.row(forItem: item) < 0 {
            for group in groups {
                let children = groupChildren[group.key] ?? []
                if children.contains(where: { itemID($0) == itemID(item) }) { sidebarView.expandItem(group) }
                for child in children {
                    if let nested = child as? SidebarGroupItem,
                       (groupChildren[nested.key] ?? []).contains(where: { itemID($0) == itemID(item) }) {
                        sidebarView.expandItem(group); sidebarView.expandItem(nested)
                    }
                }
            }
        }
        let index = sidebarView.row(forItem: item)
        guard index > -1 else { return }
        
        if sidebarView.selectedRow != index {
            sidebarView.selectRowIndexes([index], byExtendingSelection: false)
        }
    }
    
    func startEditingItem(_ item: SidebarItem) {
        let index = sidebarView.row(forItem: item)
        guard index > -1 else { return }
        
        sidebarView.editColumn(0, row: index, with: nil, select: true)
    }
    
    @IBAction func endedEditingItem(_ sender: NSTextField) {
        let index = sidebarView.row(for: sender)
        
        guard let item = sidebarView.item(atRow: index) as? OEDBCollection,
              item.name != sender.stringValue
        else { return }
        
        if !sender.stringValue.isEmpty {
            item.name = sender.stringValue
            item.save()
        }
        
        reloadDataAndPreserveSelection()
    }
    
    func renameItem(at index: Int) {
        guard let item = sidebarView.item(atRow: index) as? SidebarItem else { return }
        
        selectItem(item)
        startEditingItem(item)
    }
    
    func removeItem(at index: Int) {
        guard let item = sidebarView.item(atRow: index) as? OEDBCollection,
              item.isEditableInSidebar,
              OEAlert.removeCollection(name: item.sidebarName).runModal() == .alertFirstButtonReturn else { return }
        
        item.delete()
        item.save()
        
        // keep selection on last object if the one we removed was last
        var index = index
        if sidebarView.selectedRowIndexes.first != index {
            index = sidebarView.selectedRowIndexes.first ?? index
        }
        else if index == sidebarView.numberOfRows - 1 {
            index -= 1
        }
        
        reloadData()
        sidebarView.selectRowIndexes([index], byExtendingSelection: false)
    }
    
    func addCollection() -> OEDBCollection {
        let newCollection = database!.addNewCollection(nil)
        
        reloadData()
        selectItem(newCollection)
        startEditingItem(newCollection)
        
        return newCollection
    }
    
    @IBAction func newCollection(_ sender: Any?) {
        _ = addCollection()
    }
    
    func newCollection(games: [OEDBGame]) {
        let newCollection = database!.addNewCollection(nil)
        
        newCollection.games = Set(games)
        if games.count == 1 {
            newCollection.name = games.first!.displayName
        }
        newCollection.save()
        
        reloadData()
        selectItem(newCollection)
        startEditingItem(newCollection)
    }
    
    func duplicateCollection(_ originalCollection: OEDBCollection) {
        let originalName = originalCollection.name
        let duplicateName = String.localizedStringWithFormat(NSLocalizedString("%@ copy", comment: "Duplicated collection name"), originalName)
        let duplicateCollection = database!.addNewCollection(duplicateName)
        duplicateCollection.games = originalCollection.games
        duplicateCollection.save()
        
        reloadDataAndPreserveSelection()
    }
    
    @objc func renameItem(for menuItem: NSMenuItem) {
        renameItem(at: menuItem.tag)
    }
    
    @objc func removeItem(for menuItem: NSMenuItem) {
        removeItem(at: menuItem.tag)
    }
    
    @objc func duplicateCollection(for menuItem: NSMenuItem) {
        guard let collection = menuItem.representedObject as? OEDBCollection else { return }
        duplicateCollection(collection)
    }
    
    @objc func toggleSystem(for menuItem: NSMenuItem) {
        let system = menuItem.representedObject as? OEDBSystem
        system?.toggleEnabledAndPresentError()
    }
    
    @objc func changeDefaultCore(_ sender: AnyObject?) {
        guard let data = sender?.representedObject as? [AnyHashable : Any],
              let systemIdentifier = data["system"] as? String,
              let coreIdentifier = data["core"] as? String else { return }
        
        let defaultCoreKey = "defaultCore.\(systemIdentifier)"
        UserDefaults.standard.set(coreIdentifier, forKey: defaultCoreKey)
    }
    
    @objc func editControls(_ sender: NSMenuItem) {
        guard let system = sender.representedObject as? OEDBSystem else { return }
        
        let userInfo = [
            PreferencesWindowController.userInfoPanelNameKey: "Controls",
            PreferencesWindowController.userInfoSystemIdentifierKey: system.systemIdentifier,
        ]
        
        NotificationCenter.default.post(Notification(name: PreferencesWindowController.openPaneNotificationName, userInfo: userInfo))
    }
    
    @IBAction func selectSystems(_ sender: Any?) {
        guard let v = sender as? NSView else { return }
        
        let selectLibraryController = AvailableLibrariesViewController()
        let po = NSPopover()
        po.behavior = .transient
        po.contentSize = NSSize(width: 200, height: 500)
        po.contentViewController = selectLibraryController
        selectLibraryController.transparentBackground = true
        po.show(relativeTo: v.frame, of: sidebarView, preferredEdge: .maxX)
    }
    
    @IBAction func showIssuesView(_ sender: NSButton) {
        presentAsSheet(gameScannerViewController)
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117,
           let index = sidebarView.selectedRowIndexes.first,
           let item = sidebarView.item(atRow: index) as? SidebarItem,
           item.isEditableInSidebar {
            
            removeItem(at: index)
        }
        else if event.keyCode == kVK_Return,
                let index = sidebarView.selectedRowIndexes.first,
                let item = sidebarView.item(atRow: index) as? SidebarItem,
                item.isEditableInSidebar {
            
            renameItem(at: index)
        }
        else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Delegate

extension SidebarController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { NXDesignSidebarRow() }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if let id = selectedSidebarItem?.sidebarID {
            lastSidebarSelection = id
            if selectedSidebarItem is GameCollectionViewItemProtocol { lastGameSelectionID = id }
        }
        NotificationCenter.default.post(name: .OESidebarSelectionDidChange, object: self, userInfo: nil)
    }
    
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { true }
    func outlineViewItemDidCollapse(_ notification: Notification) { rememberExpansion(notification, collapsed: true) }
    func outlineViewItemDidExpand(_ notification: Notification) { rememberExpansion(notification, collapsed: false) }
    
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        true
    }
}

// MARK: - DataSource

extension SidebarController: NSOutlineViewDataSource {
    
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? SidebarGroupItem { return groupChildren[group.key]![index] }
        return groups[index]
    }
    
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is SidebarGroupItem }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let group = item as? SidebarGroupItem else { return item == nil ? groups.count : 0 }
        return groupChildren[group.key]?.count ?? 0
    }
    
    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
        (item as? SidebarItem)?.sidebarName
    }
    
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarItem else { return nil }
        
        var view: NSTableCellView?
        
        if let group = item as? SidebarGroupItem {
            view = outlineView.makeView(withIdentifier: .headerView, owner: self) as? NSTableCellView
            
            if let button = (view as? SidebarHeaderView)?.button {
                button.isHidden = false
                switch group.autosaveName {
                case .sidebarConsolesItem:
                    button.title = ""
                    button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Organize Sidebar")
                    button.toolTip = "Organize consoles, favorites, and groups"
                    button.target = self
                    button.action = #selector(showSidebarOptions(_:))
                case .sidebarFavoritesItem, .sidebarSubgroupItem:
                    button.title = ""; button.image = nil; button.action = nil; button.isHidden = true
                case .sidebarCollectionsItem:
                    button.title = ""
                    button.image = NSImage(named: "sidebar_add")
                    button.action = #selector(newCollection(_:))
                }
            }
            
        } else {
            view = outlineView.makeView(withIdentifier: .itemView, owner: self) as? NSTableCellView
            view?.imageView?.image = NSImage(systemSymbolName: item is OEDBSystem ? "gamecontroller" : (item.sidebarName == "Homebrew" ? "leaf" : (item.sidebarName == "Save States" ? "externaldrive" : (item is NXMultiplayerSidebarItem ? "person.2" : "books.vertical"))), accessibilityDescription: nil)
            if item is OEDBSystem {
                view?.imageView?.image = item.sidebarIcon
                view?.imageView?.contentTintColor = nil
            } else {
                view?.imageView?.contentTintColor = NXDesign.foreground
            }
            view?.textField?.isSelectable = false
            view?.textField?.isEditable = item.isEditableInSidebar
        }
        
        view?.textField?.stringValue = item === libraryGroup ? "" : item.sidebarName
        view?.textField?.font = .systemFont(ofSize: item is SidebarGroupItem ? 12 : 14, weight: item is SidebarGroupItem ? .semibold : .regular)
        view?.textField?.textColor = item is SidebarGroupItem ? NXDesign.secondary : NXDesign.foreground
        view?.toolTip = item is SidebarGroupItem ? "Expand or collapse this section. Drag to reorder." : "Right-click for options. Drag to reorder."
        
        return view
    }
    
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        item is SidebarGroupItem && item as AnyObject !== libraryGroup
    }
    
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if item as AnyObject === libraryGroup { return 1 }
        return item is SidebarGroupItem ? 28 : 30
    }
    
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        // Ordinary expandable rows keep disclosure arrows visible instead of hover-only.
        false
    }
    
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !(item is SidebarGroupItem)
    }
    
    // MARK: - Drag & Drop
    
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        
        if info.draggingPasteboard.types?.contains(Self.reorderType) == true {
            return acceptSidebarMove(info, parent: item as? SidebarGroupItem, index: index)
        }
        guard let database else { return false }
        
        let pboard = info.draggingPasteboard
        
        var collection: OEDBCollection?
        if item is OEDBCollection {
            
            collection = item as? OEDBCollection
        }
        else if item as? SidebarGroupItem == collectionsGroup {
            
            // create a new collection with a single game
            var name: String?
            if pboard.types?.contains(.game) ?? false {
                
                let uris = pboard.pasteboardItems?.compactMap { $0.string(forType: .game) } ?? []
                let games = uris.compactMap { OEDBGame.object(withURI: URL(string: $0)!, in: database.mainThreadContext) }
                
                if games.count == 1 {
                    name = games.first?.displayName
                }
            }
            else {
                
                let games = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
                if games?.count == 1 {
                    name = games?.first?.deletingPathExtension().lastPathComponent.removingPercentEncoding
                }
            }
            collection = database.addNewCollection(name)
            reloadData()
            let index = outlineView.row(forItem: collection)
            if index != NSNotFound {
                outlineView.selectRowIndexes([index], byExtendingSelection: false)
                NotificationCenter.default.post(name: .OESidebarSelectionDidChange, object: self, userInfo: nil)
            }
        }
        
        if pboard.types?.contains(.game) ?? false {
            
            guard let collection = collection else { return true }
            
            // just add to collection
            let uris = pboard.pasteboardItems?.compactMap { $0.string(forType: .game) } ?? []
            let games = uris.compactMap { OEDBGame.object(withURI: URL(string: $0)!, in: database.mainThreadContext) }
            
            collection.games.formUnion(games)
            collection.save()
        }
        else {
            
            // import and add to collection
            if let files = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
                let collectionID = collection?.permanentID
                let importer = database.importer
                importer.importItems(at: files, intoCollectionWith: collectionID)
            }
        }
        
        return true
    }
    
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        
        if info.draggingPasteboard.types?.contains(Self.reorderType) == true {
            return canMoveSidebar(info, parent: item as? SidebarGroupItem, index: index) ? .move : []
        }
        guard let types = info.draggingPasteboard.types,
              types.contains(.game) || types.contains(.fileURL),
              item is SidebarItem else {
            return []
        }
        
        // Ignore anything that is between two rows
        if index != NSOutlineViewDropOnItemIndex {
            return []
        }
        
        // Allow drop on systems group, ignoring which system exactly is highlighted
        if item as? SidebarGroupItem == consolesGroup || item is OEDBSystem {
            
            // Disallow drop on systems for already imported games
            if types.contains(.game) {
                return []
            }
            
            // For new games, change drop target to the consoles header
            outlineView.setDropItem(consolesGroup, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        }
        
        // Allow drop on regular collections
        if type(of: item as! SidebarItem) === OEDBCollection.self {
            return .copy
        }
        
        // Allow drop on the collections header and on smart collections
        if item as? SidebarGroupItem == collectionsGroup || item is OEDBCollection || item is OEDBAllGamesCollection {
            
            // Find the first regular collection in the list
            let i = collections.firstIndex(where: { type(of: $0) === OEDBCollection.self }) ?? collections.count
            
            // Register as a drop just before that collection
            outlineView.setDropItem(collectionsGroup, dropChildIndex: i)
            return .copy
        }
        
        // Everything else is disabled
        return []
    }
}

// MARK: - NSMenuDelegate

extension SidebarController: NSMenuDelegate {
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        
        menu.removeAllItems()
        
        let index = sidebarView.clickedRow
        
        addOrganizationMenu(to: menu)
        guard index != -1, let item = sidebarView.item(atRow: index) as? SidebarItem,
              !(item is SidebarGroupItem) else { return }
        menu.addItem(.separator())
        
        var menuItem: NSMenuItem
        
        if let item = item as? OEDBSystem {
            let favorite = NSMenuItem(title: favoriteIDs.contains(itemID(item)) ? "Remove from Favorite Consoles" : "Add to Favorite Consoles", action: #selector(toggleFavorite(_:)), keyEquivalent: "")
            favorite.target = self; favorite.representedObject = item; menu.addItem(favorite)
            let assign = NSMenuItem(title: "Move to Custom Group…", action: #selector(assignCustomGroup(_:)), keyEquivalent: "")
            assign.target = self; assign.representedObject = item; menu.addItem(assign)
            menu.addItem(.separator())
            menuItem = NSMenuItem()
            menuItem.title = NSLocalizedString("Edit Game Controls…", comment: "")
            menuItem.action = #selector(editControls(_:))
            menuItem.representedObject = item
            menu.addItem(menuItem)
            
            let cores = OECorePlugin.corePlugins(forSystemIdentifier: item.systemIdentifier)
            if cores.count > 1 {
                
                let systemIdentifier = item.systemIdentifier
                let defaultCoreKey = "defaultCore.\(systemIdentifier)"
                let defaultCoreIdentifier = UserDefaults.standard.object(forKey: defaultCoreKey) as? String
                
                let coreItem = NSMenuItem()
                coreItem.title = NSLocalizedString("Default Core", comment: "Sidebar context menu item to pick default core for a system")
                let submenu = NSMenu()
                
                cores.forEach { core in
                    let coreName = core.displayName
                    let systemIdentifier = item.systemIdentifier
                    let coreIdentifier = core.bundleIdentifier
                    
                    let item = NSMenuItem()
                    item.title = coreName
                    item.action = #selector(changeDefaultCore(_:))
                    item.state = coreIdentifier == defaultCoreIdentifier ? .on : .off
                    item.representedObject = ["core": coreIdentifier,
                                              "system": systemIdentifier]
                    submenu.addItem(item)
                }
                coreItem.submenu = submenu
                menu.addItem(coreItem)
            }
            
            menuItem = NSMenuItem()
            menuItem.title = .localizedStringWithFormat(NSLocalizedString("Hide \"%@\"", comment: ""), item.name)
            menuItem.action = #selector(toggleSystem(for:))
            menuItem.representedObject = item
            menu.addItem(menuItem)
        }
        else if item is OEDBCollection || item is OEDBAllGamesCollection {
            
            if item.isEditableInSidebar {
                
                menuItem = NSMenuItem()
                menuItem.title = .localizedStringWithFormat(NSLocalizedString("Rename \"%@\"", comment: "Rename collection sidebar context menu item"), item.sidebarName)
                menuItem.action = #selector(renameItem(for:))
                menuItem.tag = index
                menu.addItem(menuItem)
                
                menuItem = NSMenuItem()
                menuItem.title = NSLocalizedString("Duplicate Collection", comment: "")
                menuItem.action = #selector(duplicateCollection(for:))
                menuItem.representedObject = item
                menu.addItem(menuItem)
                
                menuItem = NSMenuItem()
                menuItem.title = NSLocalizedString("Delete Collection", comment: "")
                menuItem.action = #selector(removeItem(for:))
                menuItem.tag = index
                menu.addItem(menuItem)
                
                menu.addItem(.separator())
            }
            
            menuItem = NSMenuItem()
            menuItem.title = NSLocalizedString("New Collection", comment: "")
            menuItem.action = #selector(newCollection(_:))
            menu.addItem(menuItem)
        }
    }
}

extension SidebarController {
    @objc private func showSidebarOptions(_ sender: NSButton) {
        let menu = NSMenu(); addOrganizationMenu(to: menu)
        menu.addItem(.separator())
        let libraries = NSMenuItem(title: "Choose Consoles…", action: #selector(showConsoleChooser(_:)), keyEquivalent: "")
        libraries.target = self; libraries.representedObject = sender; menu.addItem(libraries)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }
    @objc private func showConsoleChooser(_ sender: NSMenuItem) { selectSystems(sender.representedObject) }
    private func addOrganizationMenu(to menu: NSMenu) {
        let organize = NSMenuItem(title: "Organize Sidebar", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        for (title, value) in [("All Consoles", "flat"), ("Group by Vendor", "vendor"), ("Custom Groups", "custom")] {
            let item = NSMenuItem(title: title, action: #selector(changeGrouping(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = value; item.state = grouping == value ? .on : .off
            choices.addItem(item)
        }
        choices.addItem(.separator())
        for (title, expand) in [("Expand All Sections", true), ("Collapse All Sections", false)] {
            let item = NSMenuItem(title: title, action: #selector(setAllExpanded(_:)), keyEquivalent: "")
            item.target = self; item.tag = expand ? 1 : 0; choices.addItem(item)
        }
        organize.submenu = choices; menu.addItem(organize)
    }
    @objc private func changeGrouping(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        sidebarDefaults.set(mode, forKey: "NXSidebarGrouping")
        reloadDataAndPreserveSelection()
    }
    @objc private func setAllExpanded(_ sender: NSMenuItem) {
        if sender.tag == 1 { sidebarView.expandItem(nil, expandChildren: true) }
        else { sidebarView.collapseItem(nil, collapseChildren: true) }
    }
    @objc private func toggleFavorite(_ sender: NSMenuItem) {
        guard let system = sender.representedObject as? OEDBSystem else { return }
        let id = itemID(system); var ids = favoriteIDs
        if ids.contains(id) { ids.removeAll { $0 == id } } else { ids.append(id) }
        sidebarDefaults.set(ids, forKey: "NXSidebarFavorites")
        reloadDataAndPreserveSelection(); selectItem(system)
    }
    @objc private func assignCustomGroup(_ sender: NSMenuItem) {
        guard let system = sender.representedObject as? OEDBSystem else { return }
        var groups = sidebarDefaults.dictionary(forKey: "NXSidebarCustomGroups") as? [String: String] ?? [:]
        let alert = NSAlert(); alert.messageText = "Choose a console group"
        let existing = Array(Set(groups.values)).sorted().joined(separator: ", ")
        alert.informativeText = existing.isEmpty ? "Enter a name for your group. Consoles can be dragged between custom groups." : "Enter a new name or an existing group: " + existing
        let input = NSTextField(string: groups[itemID(system)] ?? ""); input.placeholderString = "Group name"
        input.frame = NSRect(x: 0, y: 0, width: 300, height: 24); alert.accessoryView = input
        alert.addButton(withTitle: "Move to Group"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = String(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !title.isEmpty else { return }
        groups[itemID(system)] = title
        sidebarDefaults.set(groups, forKey: "NXSidebarCustomGroups")
        sidebarDefaults.set("custom", forKey: "NXSidebarGrouping")
        sidebarDefaults.set(favoriteIDs.filter { $0 != itemID(system) }, forKey: "NXSidebarFavorites")
        reloadDataAndPreserveSelection(); selectItem(system)
    }
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let item = item as? SidebarItem, !(item is SidebarDestinationItem), !(item is OEDBAllGamesCollection), item !== libraryGroup else { return nil }
        let parent = (outlineView.parent(forItem: item) as? SidebarGroupItem)?.key ?? "root"
        let payload = ["id": itemID(item), "parent": parent]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return nil }
        let writer = NSPasteboardItem(); writer.setString(json, forType: Self.reorderType); return writer
    }
    private func sidebarMove(_ info: NSDraggingInfo) -> (SidebarItem, String)? {
        guard let source = info.draggingSource as? NSOutlineView, source === sidebarView,
              let json = info.draggingPasteboard.string(forType: Self.reorderType)?.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: json) as? [String: String],
              let id = values["id"], let parent = values["parent"] else { return nil }
        let candidates: [SidebarItem] = groups.map { $0 as SidebarItem } + extraGroups.values.map { $0 as SidebarItem } + systems + collections
        guard let item = candidates.first(where: { itemID($0) == id }) else { return nil }
        return (item, parent)
    }
    private func canMoveSidebar(_ info: NSDraggingInfo, parent: SidebarGroupItem?, index: Int) -> Bool {
        guard parent !== libraryGroup, let (item, oldParent) = sidebarMove(info) else { return false }
        if let group = item as? SidebarGroupItem {
            guard group !== libraryGroup else { return false }
            return index >= 0 && (groups.contains(group) ? parent == nil : parent === consolesGroup)
        }
        if item is OEDBSystem {
            guard let parent else { return false }
            if parent === favoritesGroup { return true }
            if parent === consolesGroup { return grouping == "flat" }
            return parent.autosaveName == .sidebarSubgroupItem && (grouping == "custom" || parent.key == oldParent)
        }
        return parent === collectionsGroup && index >= 0
    }
    private func acceptSidebarMove(_ info: NSDraggingInfo, parent: SidebarGroupItem?, index: Int) -> Bool {
        guard canMoveSidebar(info, parent: parent, index: index), let (item, oldParent) = sidebarMove(info) else { return false }
        let destination = parent?.key ?? "root"
        let siblings: [SidebarItem] = parent.map { groupChildren[$0.key] ?? [] } ?? groups
        var ids = siblings.map(itemID)
        var insertion = index < 0 ? ids.count : min(index, ids.count)
        if let old = ids.firstIndex(of: itemID(item)), old < insertion { insertion -= 1 }
        ids.removeAll { $0 == itemID(item) }; ids.insert(itemID(item), at: min(insertion, ids.count))
        let orderKey: String
        if parent == nil { orderKey = "NXSidebarSections" }
        else if parent === favoritesGroup { orderKey = "NXSidebarFavorites" }
        else if parent === collectionsGroup { orderKey = "NXSidebarCollections" }
        else if parent === consolesGroup { orderKey = item is SidebarGroupItem ? "NXSidebarGroups." + grouping : "NXSidebarSystems" }
        else { orderKey = "NXSidebarOrder." + destination }
        sidebarDefaults.set(ids, forKey: orderKey)
        if item is OEDBSystem, parent !== favoritesGroup {
            sidebarDefaults.set(favoriteIDs.filter { $0 != itemID(item) }, forKey: "NXSidebarFavorites")
            if grouping == "custom", let parent, parent.autosaveName == .sidebarSubgroupItem {
                var assignments = sidebarDefaults.dictionary(forKey: "NXSidebarCustomGroups") as? [String: String] ?? [:]
                assignments[itemID(item)] = parent.name
                sidebarDefaults.set(assignments, forKey: "NXSidebarCustomGroups")
            }
        }
        _ = oldParent
        reloadDataAndPreserveSelection()
        if !(item is SidebarGroupItem) { selectItem(item) }
        return true
    }
}

class SidebarGroupItem: NSObject, SidebarItem {
    
    enum AutosaveName: String {
        case sidebarConsolesItem, sidebarCollectionsItem, sidebarFavoritesItem, sidebarSubgroupItem
    }
    
    let name: String
    let autosaveName: AutosaveName
    let key: String
    
    init(name: String, autosaveName: AutosaveName, key: String? = nil) {
        self.name = name
        self.autosaveName = autosaveName
        self.key = key ?? autosaveName.rawValue
    }
    
    let sidebarIcon: NSImage? = nil
    lazy var sidebarName = name
    let sidebarID: String? = nil
    let isEditableInSidebar = false
    let hasSubCollections = false
}

extension Key {
    static let lastSidebarSelection: Key = "lastSidebarSelection"
}


final class NXDesignSidebarRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(srgbRed: 0.27, green: 0.21, blue: 0.33, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 10, yRadius: 10).fill()
    }
}

final class NXMultiplayerSidebarItem: NSObject, SidebarItem {
    let sidebarName = "Multiplayer Saves"
    let sidebarID: String? = "nx.multiplayerSaves"
    let sidebarIcon = NSImage(systemSymbolName: "person.2", accessibilityDescription: nil)
    let isEditableInSidebar = false
    let hasSubCollections = false
}
