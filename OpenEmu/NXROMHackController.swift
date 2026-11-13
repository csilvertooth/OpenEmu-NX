// Copyright (c) 2021, OpenEmu Team
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
import CryptoKit
import UniformTypeIdentifiers

/// Owns a single native patch-import window. Never edits a source ROM or save.
@MainActor
final class NXROMHackController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static func warnAboutSNESHeader(_ data: Data, name: String) {
        guard let warning = NXROMPatch.snesHeaderWarning(data) else { return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Possible ROM header mismatch"
            alert.informativeText = "\(name)\n\n\(warning)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    static let shared = NXROMHackController()
    private struct Base { let name: String; let url: URL; var artworkURL: URL? = nil }
    private var bases: [Base] = [], visible: [Base] = []
    private var patchURL: URL?
    private var working = false
    private var matchGeneration = UUID()
    private let platformPicker = NSPopUpButton()
    private var platform: NXROMPatch.Platform { NXROMPatch.platforms[max(0, platformPicker.indexOfSelectedItem)] }
    private let search = NSSearchField(), table = NSTableView()
    private let patchLabel = NSTextField(labelWithString: "Choose an IPS, BPS or UPS patch")
    private let nameField = NSTextField()
    private let stripHeader = NSButton(checkboxWithTitle: "Remove copier header before patching (advanced)", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "IPS cannot verify the base ROM. Check the patch author’s required region, revision and header settings. BPS and UPS verify checksums automatically.")
    private var controls: [NSControl] = []
    private var cancellation: Cancellation?
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    func installMenu() {
        guard let file = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { $0.title == "File" }) else { return }
        let item = NSMenuItem(title: "Add ROM Hack…", action: #selector(showImporter), keyEquivalent: "")
        item.target = self; file.addItem(item)
    }
    @objc func showImporter() { show(patch: nil) }
    func show(patch: URL?) {
        if window == nil { buildWindow() }
        if !working {
            reloadBases()
            if let patch { setPatch(patch) }
        }
        if let window { NXDesign.apply(to: window) }
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        controls.append(button); return button
    }
    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Add ROM Hack"; window.minSize = NSSize(width: 680, height: 600)
        window.isReleasedWhenClosed = false; self.window = window
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)])
        stack.addArrangedSubview(NSTextField(labelWithString: "Create a separate game. Your original ROM and saves stay unchanged."))
        platformPicker.addItems(withTitles: NXROMPatch.platforms.map(\.displayName))
        platformPicker.target = self; platformPicker.action = #selector(changePlatform)
        controls.append(platformPicker)
        stack.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "System"), platformPicker]))
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "Other systems are experimental. Use the exact base ROM required by the patch. Genesis accepts raw MD/BIN/GEN files; interleaved SMD is not supported."))
        let patchRow = NSStackView(views: [button("Choose Patch…", #selector(choosePatch)), patchLabel]); stack.addArrangedSubview(patchRow)
        search.placeholderString = "Search the selected system’s library"; search.delegate = self; controls.append(search); stack.addArrangedSubview(search)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("game")); column.title = "Base game from your library"; column.width = 650
        table.addTableColumn(column); table.delegate = self; table.dataSource = self; table.rowHeight = 28
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        stack.addArrangedSubview(scroll); scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        stack.addArrangedSubview(button("Locate Uncompressed Base ROM…", #selector(locateBase)))
        nameField.placeholderString = "Name for the new ROM hack"; controls.append(nameField); stack.addArrangedSubview(nameField)
        stripHeader.toolTip = "SNES IPS patches only. Enable only when the patch author requires a headerless ROM. Removes 512 bytes from the working copy; your original is unchanged. BPS handles verified SNES header matching automatically."
        stripHeader.isHidden = true
        controls.append(stripHeader); stack.addArrangedSubview(stripHeader)
        stack.addArrangedSubview(status)
        let actions = NSStackView(views: [button("Add ROM Hack", #selector(createHack)), NSButton(title: "Cancel", target: self, action: #selector(cancel))]); stack.addArrangedSubview(actions)
        for view in [search, scroll, nameField, status] as [NSView] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        window.center()
    }
    @objc private func changePlatform() {
        guard !working else { return }
        matchGeneration = UUID(); search.stringValue = ""; table.deselectAll(nil)
        stripHeader.state = .off; stripHeader.isHidden = !(platform.isSNES && patchURL?.pathExtension.lowercased() == "ips")
        reloadBases()
        if let patchURL { setPatch(patchURL) }
    }
    private func reloadBases() {
        guard let db = OELibraryDatabase.default else { return }
        let request = OEDBRom.fetchRequest()
        request.predicate = NSPredicate(format: "game.system.systemIdentifier == %@", platform.identifier)
        bases = ((try? db.mainThreadContext.fetch(request)) as? [OEDBRom] ?? []).compactMap { rom in
            guard let url = rom.url, platform.extensions.contains(url.pathExtension.lowercased()), rom.archiveFileIndex == nil else { return nil }
            return Base(name: rom.game?.displayName ?? url.lastPathComponent, url: url, artworkURL: rom.game?.boxImage?.imageURL)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        filter()
    }
    private func filter() {
        visible = bases.filter { search.stringValue.isEmpty || $0.name.localizedCaseInsensitiveContains(search.stringValue) }
        table.reloadData()
        if visible.count == 1 { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }
    func controlTextDidChange(_ obj: Notification) { if obj.object as? NSSearchField === search { filter() } }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView(); let text = NSTextField(labelWithString: visible[row].name)
        text.translatesAutoresizingMaskIntoConstraints = false; text.lineBreakMode = .byTruncatingMiddle; cell.addSubview(text); cell.textField = text
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        cell.toolTip = visible[row].url.path; return cell
    }
    @objc private func choosePatch() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = ["ips", "bps", "ups"].compactMap { UTType(filenameExtension: $0) }; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { setPatch(url) }
    }
    private func setPatch(_ url: URL) {
        patchURL = url; patchLabel.stringValue = url.lastPathComponent
        nameField.stringValue = url.deletingPathExtension().lastPathComponent
        stripHeader.state = .off; stripHeader.isEnabled = platform.isSNES && url.pathExtension.lowercased() == "ips"
        stripHeader.isHidden = !stripHeader.isEnabled
        let generation = UUID(); matchGeneration = generation
        guard ["bps", "ups"].contains(url.pathExtension.lowercased()) else {
            status.stringValue = "IPS does not verify the base ROM. Select the exact region/revision and header settings required by the patch author."
            return
        }
        let candidates = bases
        let isSNES = platform.isSNES
        status.stringValue = "Looking for a verified base in the selected system’s library…"
        DispatchQueue.global(qos: .utility).async {
            do {
                let patch = try NXROMPatch.read(url)
                var matches: [URL] = []
                for candidate in candidates {
                    if let source = try? NXROMPatch.read(candidate.url),
                       (try? NXROMPatch.apply(source: source, patch: patch, allowSNESHeader: isSNES)) != nil { matches.append(candidate.url) }
                }
                DispatchQueue.main.async {
                    guard self.matchGeneration == generation, !self.working else { return }
                    if matches.count == 1, let match = matches.first {
                        self.search.stringValue = ""; self.filter()
                        if let row = self.visible.firstIndex(where: { $0.url == match }) {
                            self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                            self.table.scrollRowToVisible(row)
                        }
                        self.status.stringValue = "Matching base ROM found. Source and output checksums verified."
                    } else {
                        self.status.stringValue = matches.isEmpty ? "No verified matching base found. Select or locate the ROM required by the patch; checksums will be enforced." : "Multiple matching bases found. Select the copy you want to use."
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if self.matchGeneration == generation && !self.working { self.status.stringValue = error.localizedDescription }
                }
            }
        }
    }
    @objc private func locateBase() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = platform.extensions.compactMap { UTType(filenameExtension: $0) }; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            search.stringValue = ""; bases.append(Base(name: url.lastPathComponent, url: url)); filter()
            table.selectRowIndexes(IndexSet(integer: visible.count - 1), byExtendingSelection: false)
        }
    }
    @objc private func cancel() {
        if working { cancellation?.cancel(); status.stringValue = "Canceling…" }
        else { window?.close() }
    }
    @objc private func createHack() {
        guard !working, let patchURL, visible.indices.contains(table.selectedRow), let db = OELibraryDatabase.default else {
            status.stringValue = "Choose a patch and select its base game first."; return
        }
        let title = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 160 else { status.stringValue = "Enter a name (up to 160 characters)."; return }
        let selectedPlatform = platform
        guard let system = OEDBSystem.system(for: selectedPlatform.identifier, in: db.mainThreadContext), db.romsFolderURL != nil else { return }
        let sourceURL = visible[table.selectedRow].url
        let artworkURL = visible[table.selectedRow].artworkURL
        let root = db.romsFolderURL(for: system).appendingPathComponent("ROM Hacks", isDirectory: true)
        let removeHeader = selectedPlatform.isSNES && stripHeader.state == .on
        let outputExtension = selectedPlatform.isSNES ? "sfc" : sourceURL.pathExtension.lowercased()
        let token = Cancellation(); cancellation = token; working = true
        controls.forEach { $0.isEnabled = false }; table.isEnabled = false
        status.stringValue = "Checking the patch and creating a separate ROM…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let source = try NXROMPatch.read(sourceURL), patch = try NXROMPatch.read(patchURL)
                let result = try NXROMPatch.apply(source: source, patch: patch, stripIPSHeader: removeHeader, allowSNESHeader: selectedPlatform.isSNES, cancelled: { token.isCancelled })
                if selectedPlatform.isSNES { Self.warnAboutSNESHeader(result.data, name: title) }
                guard result.data != source else { throw NXROMPatch.fail("This patch makes no changes to the selected ROM.") }
                let id = UUID().uuidString
                let folder = root.appendingPathComponent(id, isDirectory: true)
                let romURL = folder.appendingPathComponent("Hack-\(id).\(outputExtension)")
                let fm = FileManager.default
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                do {
                    try result.data.write(to: romURL, options: .atomic)
                    try patch.write(to: folder.appendingPathComponent("patch.\(result.format.lowercased())"), options: .atomic)
                    let manifest: [String: Any] = ["schemaVersion": 1, "systemIdentifier": selectedPlatform.identifier, "experimental": !selectedPlatform.isSNES, "title": title, "baseSHA256": NXROMPatch.sha(source), "patchSHA256": NXROMPatch.sha(patch), "outputSHA256": NXROMPatch.sha(result.data), "format": result.format, "removedCopierHeader": result.removedHeader, "sourceVerified": result.format != "IPS", "engineVersion": 1]
                    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
                    if token.isCancelled { throw CancellationError() }
                } catch { try? fm.removeItem(at: folder); throw error }
                let md5 = Insecure.MD5.hash(data: result.data).map { String(format: "%02x", $0) }.joined()
                DispatchQueue.main.async { self.finish(platform: selectedPlatform, artworkURL: artworkURL, folder: folder, romURL: romURL, title: title, md5: md5, size: result.data.count, token: token, verified: result.format != "IPS") }
            } catch {
                DispatchQueue.main.async { self.complete(error is CancellationError ? "Canceled. Original ROM and saves are unchanged." : error.localizedDescription) }
            }
        }
    }
    private func finish(platform: NXROMPatch.Platform, artworkURL: URL?, folder: URL, romURL: URL, title: String, md5: String, size: Int, token: Cancellation, verified: Bool) {
        guard !token.isCancelled, let db = OELibraryDatabase.default, let system = OEDBSystem.system(for: platform.identifier, in: db.mainThreadContext) else {
            try? FileManager.default.removeItem(at: folder); complete("Canceled. No game was added."); return
        }
        let context = db.mainThreadContext
        let game = OEDBGame.createObject(in: context)
        let rom = OEDBRom.createObject(in: context)
        game.name = title + " [ROM Hack]"; game.system = system; game.importDate = Date()
        rom.url = romURL; rom.fileName = romURL.lastPathComponent; rom.md5 = md5; rom.fileSize = NSNumber(value: size); rom.game = game
        let baseCover = artworkURL.flatMap { NSImage(contentsOf: $0) }
        game.setBoxImage(image: NXHackArtwork.make(base: baseCover, title: title, system: platform.name))
        do {
            try context.save()
            var writeError: Error?
            let writer = db.writerContext
            writer.performAndWait {
                do { try writer.save() } catch { writeError = error }
            }
            if let writeError {
                // The child save has propagated. Keep the files and entry for retry;
                // never leave a persisted library entry pointing to deleted output.
                complete("The ROM hack was created, but the library could not be written to disk: \(writeError.localizedDescription). Keep the app open and check the library volume.")
                return
            }
            complete("Added \(title) to your \(platform.name) library with separate saves. " + (verified ? "Patch checksums verified." : "IPS base ROM is unverified; check gameplay before relying on this hack."))
        } catch {
            context.delete(rom); context.delete(game)
            try? FileManager.default.removeItem(at: folder)
            complete("Could not save the library entry: \(error.localizedDescription)")
        }
    }
    private func complete(_ message: String) {
        working = false; cancellation = nil; controls.forEach { $0.isEnabled = true }; table.isEnabled = true
        stripHeader.isEnabled = platform.isSNES && patchURL?.pathExtension.lowercased() == "ips"
        status.stringValue = message
    }
}

/// Creates a separate cover image; never changes or shares the base artwork record.
enum NXHackArtwork {
    static func make(base: NSImage?, title: String, system: String) -> NSImage {
        let width: CGFloat = 600
        let ratio = base.map { $0.size.height / max(1, $0.size.width) } ?? 1.35
        let size = NSSize(width: width, height: width * min(2, max(0.65, ratio)))
        return NSImage(size: size, flipped: false) { bounds in
            if let base {
                base.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
            } else {
                NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.08, blue: 0.30, alpha: 1), ending: NSColor(calibratedRed: 0.025, green: 0.10, blue: 0.19, alpha: 1))!.draw(in: bounds, angle: -60)
                let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
                (system as NSString).draw(in: NSRect(x: 36, y: size.height * 0.50, width: width - 72, height: 100), withAttributes: [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.85), .paragraphStyle: paragraph])
            }
            let height = min(112, max(78, size.height * 0.17))
            let band = NSRect(x: 0, y: 0, width: width, height: height)
            NSColor(calibratedWhite: 0.025, alpha: 0.94).setFill(); band.fill()
            let accent = NSGradient(starting: NSColor(calibratedRed: 0.72, green: 0.24, blue: 1, alpha: 1), ending: NSColor(calibratedRed: 0.10, green: 0.75, blue: 1, alpha: 1))!
            accent.draw(in: NSRect(x: 0, y: height - 4, width: width, height: 4), angle: 0)
            let badge = NSRect(x: 18, y: (height - 26) / 2, width: 60, height: 26)
            NSColor(calibratedRed: 0.42, green: 0.21, blue: 0.73, alpha: 1).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
            ("MOD" as NSString).draw(in: badge.insetBy(dx: 9, dy: 4), withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: NSColor.white])
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            let textRect = NSRect(x: 94, y: 15, width: width - 112, height: height - 30)
            (title as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [.font: NSFont.systemFont(ofSize: 23, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
            return true
        }
    }
}

/// Explicit artwork-only association for prepatched ROMs; no ROM identity is inferred.
@MainActor
@objc(NXBaseArtworkChooser)
final class NXBaseArtworkChooser: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    @objc static func chooseArtwork(for game: OEDBGame) { NXBaseArtworkChooser().run(for: game) }
    private var games: [OEDBGame] = [], visible: [OEDBGame] = []
    private let search = NSSearchField(), name = NSTextField(), table = NSTableView()
    private let preview = NSImageView()
    private var applyButton: NSButton?
    private func update() {
        applyButton?.isEnabled = visible.indices.contains(table.selectedRow)
            && !name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.stringValue.count <= 160
        if visible.indices.contains(table.selectedRow),
           let url = visible[table.selectedRow].boxImage?.imageURL,
           let base = NSImage(contentsOf: url) {
            preview.image = NXHackArtwork.make(base: base, title: name.stringValue, system: "")
        } else { preview.image = nil }
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === search {
            visible = games.filter { search.stringValue.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search.stringValue) }
            table.deselectAll(nil); table.reloadData()
        }
        update()
    }
    func tableViewSelectionDidChange(_ notification: Notification) { update() }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView(), label = NSTextField(labelWithString: visible[row].displayName)
        label.translatesAutoresizingMaskIntoConstraints = false; label.lineBreakMode = .byTruncatingTail
        cell.addSubview(label); cell.textField = label
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func run(for target: OEDBGame) {
        guard let db = OELibraryDatabase.default else { return }
        let request = NSFetchRequest<OEDBGame>(entityName: "Game")
        request.predicate = NSPredicate(format: "boxImage != nil")
        do { games = try db.mainThreadContext.fetch(request).filter { $0 != target && $0.boxImage?.isLocalImageAvailable == true } }
        catch { NSAlert(error: error).runModal(); return }
        games.sort {
            let a = $0.system == target.system, b = $1.system == target.system
            return a != b ? a : $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        visible = games
        let alert = NSAlert(); alert.messageText = "Use Base Game Artwork"
        alert.informativeText = "Choose a cover for \(target.displayName) and enter the mod name. Only this game’s artwork changes; its ROM, title and saves stay unchanged."
        applyButton = alert.addButton(withTitle: "Apply Artwork"); alert.addButton(withTitle: "Cancel")
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 620, height: 440)
        search.placeholderString = "Search games with artwork"; search.delegate = self
        stack.addArrangedSubview(search)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("base")); column.title = "Base game"; column.width = 360
        table.addTableColumn(column); table.dataSource = self; table.delegate = self; table.rowHeight = 30
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        preview.imageScaling = .scaleProportionallyUpOrDown
        let row = NSStackView(views: [scroll, preview]); row.orientation = .horizontal; row.spacing = 12
        stack.addArrangedSubview(row)
        preview.widthAnchor.constraint(equalToConstant: 200).isActive = true
        row.heightAnchor.constraint(equalToConstant: 300).isActive = true
        stack.addArrangedSubview(NSTextField(labelWithString: "Mod name (up to 160 characters)"))
        name.stringValue = target.displayName.replacingOccurrences(of: " [ROM Hack]", with: "")
        name.delegate = self; stack.addArrangedSubview(name)
        if games.isEmpty { stack.addArrangedSubview(NSTextField(labelWithString: "Add artwork to a base game first, then try again.")) }
        for view in [search, row, name] as [NSView] { view.widthAnchor.constraint(equalToConstant: 620).isActive = true }
        alert.accessoryView = stack; update()
        guard alert.runModal() == .alertFirstButtonReturn,
              !target.isDeleted, visible.indices.contains(table.selectedRow),
              let url = visible[table.selectedRow].boxImage?.imageURL,
              let base = NSImage(contentsOf: url) else { return }
        let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 160 else { return }
        target.setBoxImage(image: NXHackArtwork.make(base: base, title: title, system: ""))
        do {
            try db.mainThreadContext.save()
            var failure: Error?
            db.writerContext.performAndWait { do { try db.writerContext.save() } catch { failure = error } }
            if let failure { throw failure }
        } catch { NSAlert(error: error).runModal() }
    }
}
