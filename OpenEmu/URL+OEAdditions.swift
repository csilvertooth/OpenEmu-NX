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
import Darwin
import OpenEmuBase

extension URL {
    static let userGuideBIOSFiles = URL(string: "https://github.com/OpenEmu/OpenEmu/wiki/User-guide:-BIOS-files")!
    static let userGuideCDBasedGames = URL(string: "https://github.com/OpenEmu/OpenEmu/wiki/User-guide:-CD-based-games")!
    static let userGuideWiimotePairing = URL(string: "https://github.com/OpenEmu/OpenEmu/wiki/User-guide:-Wiimote-and-Wii-U-Pro-pairing")!
    static let pugsyMAMECheats = URL(string: "https://www.mamecheat.co.uk/mame_downloads.htm")!
}

extension URL {
    
    /// The configured host app's data folder, shared with its nested helpers.
    static var oeApplicationSupportDirectory: URL { OEApplicationSupportDirectoryURL() }

}

extension URL {
    
    var isDirectory: Bool {
        
        guard let resourceValues = try? resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else {
            return false
        }
        
        return resourceValues.isDirectory! && !resourceValues.isPackage!
    }
    
    var fileSize: Int {
        
        guard let resourceValues = try? resourceValues(forKeys: [.fileSizeKey]) else {
            return 0
        }
        
        return resourceValues.fileSize!
    }
    
    func url(relativeTo url: URL) -> URL? {
        
        let selfAbsoluteString = standardized.absoluteString
        let urlAbsoluteString = url.standardized.absoluteString
        
        let range = (selfAbsoluteString as NSString).range(of: urlAbsoluteString)
        
        if range.location != NSNotFound && range.location == 0 {
            return URL(string: (selfAbsoluteString as NSString).substring(from: range.length))
        } else {
            return standardized
        }
    }
    
    var hasImageSuffix: Bool {
        let urlSuffix = pathExtension.lowercased()
        return NSImage.imageTypes.contains(urlSuffix)
    }
    
    func isSubpath(of url: URL) -> Bool {
        
        let parentPathComponents = url.standardized.pathComponents
        let ownPathComponents = standardized.pathComponents
        
        let ownPathCount = ownPathComponents.count
        
        for i in 0..<parentPathComponents.count {
            if i >= ownPathCount || parentPathComponents[i] != ownPathComponents[i] {
                return false
            }
        }
        
        return true
    }
    
    func uniqueURL(_ block: (Int) -> URL) -> URL {
        
        var result = self
        var triesCount = 1
        
        while (try? result.checkResourceIsReachable()) == true {
            triesCount += 1
            result = block(triesCount)
        }
        
        return result
    }
    
    static func validFilename(from fileName: String) -> String {
        let illegalFileNameCharacters = CharacterSet(charactersIn: "/\\?%*|\":<>")
        return fileName.deleting(illegalFileNameCharacters)
    }
}

// BEGIN NX_DATA_MIGRATION_FILES
/// Filesystem-only operations, parameterized so migrations can be checked in a
/// temporary fixture without opening a user's library or changing preferences.
enum NXDataMigrationFiles {
    static let markerName = ".nx-data-migration-v1"

    static func copyLegacyData(from source: URL, to destination: URL, legacyAppRunning: Bool) throws {
        let fm = FileManager.default
        let marker = destination.appendingPathComponent(markerName)
        guard source.standardizedFileURL != destination.standardizedFileURL,
              !fm.fileExists(atPath: marker.path) else { return }
        if fm.fileExists(atPath: source.path), legacyAppRunning {
            throw NSError(domain: "NXDataMigration", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Quit the previous OpenEmu or OpenEmu-NX build before copying its library. This prevents copying a database while it is being written."])
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: source.path) {
            let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            for child in children {
                let target = destination.appendingPathComponent(child.lastPathComponent)
                // Existing NX data wins. Never combine two library databases or
                // merge partially copied core bundles into an existing bundle.
                var replacesEmptyDirectory = false
                if fm.fileExists(atPath: target.path) {
                    if child.lastPathComponent == "Multiplayer Sessions" {
                        try copyMissingSessionFiles(from: child, to: target)
                        continue
                    }
                    let info = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if info.isDirectory == true && info.isSymbolicLink != true {
                        replacesEmptyDirectory = try fm.contentsOfDirectory(atPath: target.path).isEmpty
                    }
                    guard replacesEmptyDirectory else { continue }
                }
                let staging = destination.appendingPathComponent(".nx-copy-" + UUID().uuidString)
                do {
                    try fm.copyItem(at: child, to: staging)
                    // rmdir refuses to remove a directory that gained contents
                    // while copying, unlike recursive removeItem.
                    if replacesEmptyDirectory, rmdir(target.path) != 0 {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "The destination folder changed during migration. Try again after closing other applications."])
                    }
                    if !fm.fileExists(atPath: target.path) { try fm.moveItem(at: staging, to: target) }
                    else { try fm.removeItem(at: staging) }
                } catch {
                    try? fm.removeItem(at: staging)
                    throw error
                }
            }
        }
        try Data("1\n".utf8).write(to: marker, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }

    private static func copyMissingSessionFiles(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let sourceInfo = try source.resourceValues(forKeys: keys)
        let destinationInfo = try destination.resourceValues(forKeys: keys)
        guard sourceInfo.isDirectory == true, destinationInfo.isDirectory == true,
              sourceInfo.isSymbolicLink != true, destinationInfo.isSymbolicLink != true else { return }
        for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
            let target = destination.appendingPathComponent(child.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                try copyMissingSessionFiles(from: child, to: target)
                continue
            }
            let staging = destination.appendingPathComponent(".nx-copy-" + UUID().uuidString)
            do {
                try fm.copyItem(at: child, to: staging)
                if !fm.fileExists(atPath: target.path) { try fm.moveItem(at: staging, to: target) }
                else { try fm.removeItem(at: staging) }
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
        }
    }

    static func relocatedURL(_ url: URL, from legacyRoot: URL, to destinationRoot: URL) -> URL? {
        let source = legacyRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == source || path.hasPrefix(source + "/") else { return nil }
        let suffix = String(path.dropFirst(source.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return suffix.isEmpty ? destinationRoot : destinationRoot.appendingPathComponent(suffix)
    }

    static func migratedPreferences(legacy: [String: Any], current: [String: Any], legacyRoot: URL, destinationRoot: URL) -> [String: Any] {
        var result = legacy.merging(current) { _, currentValue in currentValue }
        for key in ["databasePath", "defaultDatabasePath"] {
            guard let path = result[key] as? String,
                  let relocated = relocatedURL(URL(fileURLWithPath: (path as NSString).expandingTildeInPath), from: legacyRoot, to: destinationRoot) else { continue }
            result[key] = (relocated.path as NSString).abbreviatingWithTildeInPath
        }
        for key in ["saveStateFolder", "screenshotFolder"] {
            guard let path = result[key] as? String, let url = URL(string: path), url.isFileURL,
                  let relocated = relocatedURL(url, from: legacyRoot, to: destinationRoot) else { continue }
            result[key] = relocated.absoluteString
        }
        return result
    }
}
// END NX_DATA_MIGRATION_FILES

/// macOS owns the live preference domain. The data folder also contains a
/// private, readable snapshot for backup; credentials remain in their own store.
enum NXDataMigration {
    private static var preferenceObserver: NSObjectProtocol?
    private static var pendingSnapshot: DispatchWorkItem?

    static var legacyRoot: URL? {
        guard let name = OEHostApplicationBundle().object(forInfoDictionaryKey: "OELegacyApplicationSupportFolder") as? String,
              !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(name, isDirectory: true)
    }

    static func relocatedOwnedURL(_ url: URL, libraryRoot: URL) -> URL {
        guard libraryRoot.isSubpath(of: URL.oeApplicationSupportDirectory),
              let source = legacyRoot,
              let relocated = NXDataMigrationFiles.relocatedURL(url, from: source, to: URL.oeApplicationSupportDirectory),
              (try? relocated.checkResourceIsReachable()) == true else { return url }
        return relocated
    }

    static func prepare() throws {
        let fm = FileManager.default
        let destination = URL.oeApplicationSupportDirectory
        let defaults = UserDefaults.standard
        let domain = OEApplicationPreferencesDomain()
        let host = OEHostApplicationBundle()
        let legacyDomain = host.object(forInfoDictionaryKey: "OELegacyPreferencesDomain") as? String
        if let source = legacyRoot {
            let running = legacyDomain.map { name in
                NSWorkspace.shared.runningApplications.contains {
                    guard $0.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
                    if $0.bundleIdentifier == name || $0.bundleIdentifier == name + ".debug" { return true }
                    // Also detect an old game helper whose host has already quit.
                    var bundleURL = $0.bundleURL
                    for _ in 0..<12 {
                        guard let url = bundleURL, url.path.count > 1 else { break }
                        let identifier = Bundle(url: url)?.bundleIdentifier
                        if identifier == name || identifier == name + ".debug" { return true }
                        bundleURL = url.deletingLastPathComponent()
                    }
                    return false
                }
            } ?? false
            try NXDataMigrationFiles.copyLegacyData(from: source, to: destination, legacyAppRunning: running)
            let migrationKey = "NXPreferencesMigratedV1"
            if !defaults.bool(forKey: migrationKey), let legacyDomain {
                let debugDomain = domain.hasSuffix(".debug") ? legacyDomain + ".debug" : legacyDomain
                let old = defaults.persistentDomain(forName: debugDomain) ?? defaults.persistentDomain(forName: legacyDomain) ?? [:]
                let current = defaults.persistentDomain(forName: domain) ?? [:]
                var migrated = NXDataMigrationFiles.migratedPreferences(legacy: old, current: current, legacyRoot: source, destinationRoot: destination)
                migrated[migrationKey] = true
                defaults.setPersistentDomain(migrated, forName: domain)
            }
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        for folder in ["Bindings", "Cores", "Game Library", "Save States", "Screenshots", "BIOS", "Multiplayer Sessions/Autosaves", "Logs"] {
            try fm.createDirectory(at: destination.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    static func observePreferences() {
        guard preferenceObserver == nil else { return }
        preferenceObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { _ in
            pendingSnapshot?.cancel()
            let work = DispatchWorkItem { writePreferencesSnapshot() }
            pendingSnapshot = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        writePreferencesSnapshot()
    }

    static func writePreferencesSnapshot() {
        let domain = OEApplicationPreferencesDomain()
        let values = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        let publicSettings = values.filter { key, _ in
            let name = key.lowercased()
            return !["password", "secret", "token", "credential", "apikey", "api_key", "accesskey", "access_key", "privatekey", "private_key"].contains(where: name.contains)
        }
        let name = domain.hasSuffix(".debug") ? "Preferences-Debug.plist" : "Preferences.plist"
        let url = URL.oeApplicationSupportDirectory.appendingPathComponent(name)
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: publicSettings, format: .xml, options: 0)
            // Atomic replacement first, then restrict the new inode.
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("Could not update the preferences backup in the application data folder: %@", error.localizedDescription)
        }
    }
}
