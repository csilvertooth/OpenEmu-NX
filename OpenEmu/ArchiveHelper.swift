// Copyright (c) 2022, OpenEmu Team
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

import Foundation
import CryptoKit
import OpenEmuKit // Crypto.SHA1

enum ArchiveHelper {
    
    @available(macOS 10.15, *)
    private static func hashPath(_ path: String) -> String {
        return Insecure.SHA1.hash(data: Data(path.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }
    
    static func temporaryDirectoryForDecompressionOfFile(at url: URL, withHash fileHash: String? = nil) -> URL {
        var finalHash: String
        if #available(macOS 10.15, *) {
            finalHash = hashPath(url.path)
        } else {
            finalHash = Crypto.SHA1.digest(string: url.path)
        }
        
        if let fileHash = fileHash {
            finalHash += "_\(fileHash)"
        }
        
        let folder = Bundle.main.bundleIdentifier ?? "OpenEmu"
        
        let fm = FileManager.default
        let folderURL = fm.temporaryDirectory.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(finalHash, isDirectory: true)
        
        do {
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            DLog("Couldn't create temp directory \(folderURL.path), \(error)")
            return fm.temporaryDirectory
        }
        
        return folderURL
    }
    
    /// Decompresses a file in an archive to a temporary directory.
    /// - Parameter url: A file URL specifying the archive file to decompress.
    /// - Parameter index: The entry index of the file to be extracted.
    /// - Parameter hash: A `String` which uniquely describes the file to be extracted, e.g. its cryptographic hash.
    /// - Parameter didDecompress: Upon return, contains `true` if the file was extracted successfully,
    /// or `false` if the archive was invalid or if the file has been extracted before.
    /// - Returns: A file URL pointing to the extracted file.
    static func decompressFileInArchive(at url: URL, atIndex index: Int = 0, withHash hash: String? = nil, didDecompress: UnsafeMutablePointer<ObjCBool>? = nil) -> URL? {
        
        didDecompress?.pointee = false
        
        let entryIndex = Int32(index)
        
        // we check for known compression types for the ROM at the path
        // if we detect one, we decompress it and store it in the temporary directory at a known location
        
        guard let archive = XADArchive.oe_archiveForFile(at: url),
              archive.numberOfEntries() > entryIndex
        else { return nil }
        
        // XADMaster identifies some legit Mega Drive as LZMA archives
        let formatName = archive.formatName()
        if formatName == "MacBinary" ||
            formatName == "LZMA_Alone" ||
            formatName == "ISO 9660" ||
            formatName == "NDS"
        {
            return nil
        }
        
        if !archive.entryHasSize(entryIndex) ||
            archive.uncompressedSize(ofEntry: entryIndex) == 0 ||
            archive.entryIsEncrypted(entryIndex) ||
            archive.entryIsDirectory(entryIndex) ||
            archive.entryIsArchive(entryIndex)
        {
            return nil
        }
        
        let folder = temporaryDirectoryForDecompressionOfFile(at: url, withHash: hash)
        var tmpURL = folder.appendingPathComponent(archive.name(ofEntry: entryIndex))
        if tmpURL.pathExtension.count == 0,
           url.pathExtension.count > 0
        {
            // we need an extension
            tmpURL = tmpURL.appendingPathComponent(url.pathExtension)
        }
        
        let fm = FileManager.default
        if fm.fileExists(atPath: tmpURL.path),
           !tmpURL.isDirectory
        {
            DLog("Found existing decompressed ROM for path \(url.path)")
            return tmpURL
        }
        
        let success = archive.oe_extractEntry(entryIndex, as: tmpURL.path, deferDirectories: false, dataFork: true, resourceFork: false)
        
        if !success {
            try? fm.removeItem(at: folder)
            return nil
        }
        
        didDecompress?.pointee = true
        return tmpURL
    }
    
    /// Decompresses an archive to the given directory.
    /// - Parameter url: A file URL specifying the archive file to decompress.
    /// - Parameter directory: A file URL specifying the directory to which the archive’s content should be extracted.
    /// - Returns: The file name of the first entry in the archive.
    @discardableResult
    static func decompressFileInArchive(at url: URL, toDirectory directory: URL) -> String? {
        let archive = XADArchive.oe_archiveForFile(at: url)
        
        let fileName = archive?.name(ofEntry: 0)
        archive?.extract(to: directory.path)
        
        return fileName
    }
}


/// Serial preparation keeps extraction off the UI thread and prevents duplicate writes.
/// Archive paths are never used as destination paths. Only the library's selected entry is read.
actor NetworkROMPreparation {
    static let shared = NetworkROMPreparation()
    private let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("NX-Netplay-ROMs-" + UUID().uuidString, isDirectory: true)

    struct Prepared: Sendable {
        let url: URL
        let sha256: String
    }

    func prepare(source: URL, index: Int?, retainedRoot: URL?) throws -> Prepared {
        let fm = FileManager.default
        func error(_ message: String) -> NSError {
            NSError(domain: "NetworkROMPreparation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        func hash(_ url: URL) throws -> String { try fm.hashFile(at: url, hashFunction: .sha256) }
        try Task.checkCancellation()
        guard let index else {
            guard !["zip", "7z", "rar", "gz"].contains(source.pathExtension.lowercased()) else {
                throw error("The archive has no selected library ROM. Import it into your library again before using netplay.")
            }
            return Prepared(url: source, sha256: try hash(source))
        }
        guard index >= 0, index <= Int(Int32.max),
              let archive = XADArchive.oe_archiveForFile(at: source),
              index < Int(archive.numberOfEntries()) else {
            throw error("The selected ROM could not be found in its archive. Import the archive again.")
        }
        let entry = Int32(index)
        // Current network runtime is SNES. Bound extraction before allocating disk space.
        let maximumSize: Int64 = 64 * 1024 * 1024
        guard archive.entryHasSize(entry), archive.uncompressedSize(ofEntry: entry) > 0,
              archive.uncompressedSize(ofEntry: entry) <= maximumSize,
              !archive.entryIsEncrypted(entry), !archive.entryIsDirectory(entry),
              !archive.entryIsLink(entry), !archive.entryIsArchive(entry) else {
            throw error("Netplay needs an unencrypted ROM entry no larger than 64 MB; folders, links and nested archives are not supported.")
        }
        // Content addressing invalidates the cache even if an archive changes without changing its date.
        let archiveHash = try hash(source)
        let folder = (retainedRoot ?? temporaryRoot).appendingPathComponent(archiveHash + "-" + String(index), isDirectory: true)
        let suffix = URL(fileURLWithPath: archive.name(ofEntry: entry)).pathExtension.lowercased()
        let safeSuffix = suffix.isEmpty || suffix.count > 8 || !suffix.allSatisfy({ $0.isLetter || $0.isNumber }) ? "rom" : suffix
        let output = folder.appendingPathComponent("game." + safeSuffix)
        let checksum = folder.appendingPathComponent("sha256.txt")
        if let expected = try? String(contentsOf: checksum, encoding: .utf8),
           let actual = try? hash(output), actual == expected {
            return Prepared(url: output, sha256: actual)
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let partial = folder.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? fm.removeItem(at: partial) }
        guard archive.oe_extractEntry(entry, as: partial.path, deferDirectories: false, dataFork: true, resourceFork: false),
              let size = (try? fm.attributesOfItem(atPath: partial.path)[.size]) as? NSNumber,
              size.int64Value == archive.uncompressedSize(ofEntry: entry), size.int64Value <= maximumSize else {
            throw error("Could not decompress this ROM. The archive may be damaged or incomplete.")
        }
        try Task.checkCancellation()
        guard try hash(source) == archiveHash else { throw error("The archive changed during extraction. Try again.") }
        let sha = try hash(partial)
        if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
        try fm.moveItem(at: partial, to: output)
        try sha.write(to: checksum, atomically: true, encoding: .utf8)
        return Prepared(url: output, sha256: sha)
    }
}
