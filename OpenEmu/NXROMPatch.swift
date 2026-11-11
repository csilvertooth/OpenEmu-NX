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


import Foundation
import CryptoKit

/// Independent cartridge ROM patch decoder with bounded memory use.
enum NXROMPatch {
    struct Platform {
        let name: String
        let identifier: String
        let extensions: [String]
        var isSNES: Bool { identifier == "openemu.system.snes" }
        var displayName: String { name + (isSNES ? "" : " (Experimental)") }
    }
    static let platforms: [Platform] = [
        Platform(name: "Super Nintendo", identifier: "openemu.system.snes", extensions: ["sfc", "smc"]),
        Platform(name: "Nintendo NES", identifier: "openemu.system.nes", extensions: ["nes"]),
        Platform(name: "Game Boy / Game Boy Color", identifier: "openemu.system.gb", extensions: ["gb", "gbc", "sgb"]),
        Platform(name: "Game Boy Advance", identifier: "openemu.system.gba", extensions: ["gba"]),
        Platform(name: "Sega Genesis / Mega Drive", identifier: "openemu.system.sg", extensions: ["md", "bin", "gen"]),
        Platform(name: "Sega Master System", identifier: "openemu.system.sms", extensions: ["sms"]),
        Platform(name: "Sega Game Gear", identifier: "openemu.system.gg", extensions: ["gg"])
    ]
    static let limit = 32 * 1024 * 1024

    /// Conservative structural check, not a ROM authenticity or compatibility test.
    /// Bad checksums alone are common in hacks and must not trigger this warning.
    static func snesHeaderWarning(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        func plausible(_ offset: Int) -> Bool {
            guard offset >= 0, offset + 64 <= bytes.count else { return false }
            let title = bytes[offset..<offset + 21]
            let printable = title.filter { $0 >= 32 && $0 <= 126 }.count
            let map = bytes[offset + 21]
            let reset = Int(bytes[offset + 60]) | Int(bytes[offset + 61]) << 8
            return printable >= 18 && title.contains(where: { $0 > 32 && $0 < 127 })
                && [0x20, 0x21, 0x22, 0x23, 0x25, 0x30, 0x31, 0x32, 0x35].contains(Int(map))
                && reset >= 0x8000
        }
        let copierOffset = bytes.count % 32768 == 512 ? 512 : 0
        let locations = [0x7fc0, 0xffc0, 0x407fc0, 0x40ffc0]
        if locations.contains(where: { plausible($0 + copierOffset) }) { return nil }
        if locations.contains(where: { plausible($0 + (copierOffset == 0 ? 512 : 0)) }) {
            return "The SNES header appears 512 bytes away from its expected position. This can happen when a patch expects a headerless ROM but is applied to a ROM with a copier header, or vice versa. The game may freeze or fail to start. Reapply the original patch to the exact base ROM and header format specified by its author. This check is a warning, not proof that the ROM is invalid. OpenEmu-NX has not repaired or modified the ROM."
        }
        return nil
    }
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    static func fail(_ message: String) -> Failure { Failure(message: message) }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c >> 1) ^ ((c & 1) == 0 ? 0 : 0xedb88320) }
        return c
    }
    static func crc(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xffffffff
        for b in bytes { c = (c >> 8) ^ crcTable[Int((c ^ UInt32(b)) & 255)] }
        return c ^ 0xffffffff
    }
    static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard !data.isEmpty, data.count <= limit else { throw fail("File is empty or exceeds the 32 MB patch limit.") }
        return data
    }
    struct Result { let data: Data; let removedHeader: Bool; let format: String }
    static func apply(source: Data, patch: Data, stripIPSHeader: Bool = false, allowSNESHeader: Bool = true, cancelled: () -> Bool = { false }) throws -> Result {
        guard source.count <= limit, patch.count <= limit else { throw fail("File exceeds the 32 MB limit.") }
        let p = [UInt8](patch)
        if p.starts(with: Array("UPS1".utf8)) { return try applyUPS(source: source, patch: p, cancelled: cancelled) }
        let bps = p.starts(with: Array("BPS1".utf8))
        let ips = p.starts(with: Array("PATCH".utf8))
        guard bps || ips else { throw fail("Choose a valid IPS, BPS or UPS patch, not a ROM or archive.") }
        var src = [UInt8](source), removed = false
        func little(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(p[at + $1]) << ($1 * 8) } }
        if bps {
            guard p.count >= 19, crc(Array(p.dropLast(4))) == little(p.count - 4) else { throw fail("The BPS patch checksum is invalid. Download the patch again.") }
            let expected = little(p.count - 12)
            if allowSNESHeader, crc(src) != expected, src.count % 32768 == 512, crc(Array(src.dropFirst(512))) == expected {
                src.removeFirst(512); removed = true
            }
            guard crc(src) == expected else { throw fail("Base ROM checksum does not match. Select the region/revision required by this hack. The original is unchanged.") }
        } else if stripIPSHeader {
            guard allowSNESHeader else { throw fail("Copier-header removal is available only for SNES.") }
            guard src.count % 32768 == 512 else { throw fail("This ROM does not have the expected 512-byte copier-header size. Leave header removal off.") }
            src.removeFirst(512); removed = true
        }
        var at = bps ? 4 : 5
        let end = bps ? p.count - 12 : p.count
        func byte() throws -> UInt8 {
            guard at < end else { throw fail("Patch is truncated.") }
            defer { at += 1 }; return p[at]
        }
        func big(_ count: Int) throws -> Int {
            var value = 0
            for _ in 0..<count { value = (value << 8) | Int(try byte()) }
            return value
        }
        func number() throws -> Int {
            var value = 0, shift = 1
            for _ in 0..<5 {
                let b = Int(try byte())
                value += (b & 127) * shift
                if b & 128 != 0 { return value }
                shift <<= 7; value += shift
            }
            throw fail("BPS integer is too large.")
        }
        var out: [UInt8] = []
        if ips {
            out = src
            while true {
                if cancelled() { throw CancellationError() }
                let offset = try big(3)
                if offset == 0x454f46 { break }
                let size = try big(2)
                let count = size == 0 ? try big(2) : size
                guard count > 0, offset <= limit - count else { throw fail("IPS record is invalid or exceeds the output limit.") }
                let fill = size == 0 ? try byte() : 0
                if size != 0 && count > end - at { throw fail("IPS record is truncated.") }
                if out.count < offset + count { out += repeatElement(0, count: offset + count - out.count) }
                for i in 0..<count { out[offset + i] = size == 0 ? fill : try byte() }
            }
            if at != end {
                guard end - at == 3 else { throw fail("Unexpected data after the IPS footer.") }
                let size = try big(3)
                guard size > 0, size <= limit else { throw fail("Invalid IPS final size.") }
                if size < out.count { out.removeLast(out.count - size) }
                else { out += repeatElement(0, count: size - out.count) }
            }
        } else {
            let sourceSize = try number(), targetSize = try number(), metadataSize = try number()
            guard sourceSize == src.count else { throw fail("Base ROM size does not match this BPS patch.") }
            guard targetSize > 0, targetSize <= limit, metadataSize <= end - at else { throw fail("Invalid BPS sizes.") }
            at += metadataSize; out.reserveCapacity(targetSize)
            var sourceOffset = 0, targetOffset = 0
            while out.count < targetSize {
                if cancelled() { throw CancellationError() }
                let command = try number(), count = (command >> 2) + 1
                guard count <= targetSize - out.count else { throw fail("BPS command exceeds the target size.") }
                switch command & 3 {
                case 0:
                    guard out.count <= src.count - count else { throw fail("BPS source read is out of bounds.") }
                    out.append(contentsOf: src[out.count..<out.count + count])
                case 1:
                    guard count <= end - at else { throw fail("BPS literal is truncated.") }
                    out.append(contentsOf: p[at..<at + count]); at += count
                case 2:
                    let delta = try number(); sourceOffset += delta & 1 == 0 ? delta >> 1 : -(delta >> 1)
                    guard sourceOffset >= 0, sourceOffset <= src.count - count else { throw fail("BPS source copy is out of bounds.") }
                    out.append(contentsOf: src[sourceOffset..<sourceOffset + count]); sourceOffset += count
                default:
                    let delta = try number(); targetOffset += delta & 1 == 0 ? delta >> 1 : -(delta >> 1)
                    guard targetOffset >= 0, targetOffset < out.count else { throw fail("BPS target copy references unwritten data.") }
                    for i in 0..<count {
                        if i % 65536 == 0 && cancelled() { throw CancellationError() }
                        out.append(out[targetOffset]); targetOffset += 1
                    }
                }
            }
            guard at == end, crc(out) == little(p.count - 8) else { throw fail("Patched ROM checksum does not match. No game was added.") }
        }
        guard !out.isEmpty else { throw fail("Patch produced an empty ROM.") }
        if cancelled() { throw CancellationError() }
        return Result(data: Data(out), removedHeader: removed, format: bps ? "BPS" : "IPS")
    }

    // UPS applies XOR runs separated by relative offsets; all three CRCs are mandatory.
    // Import is forward-only: an already patched input is rejected rather than reverted.
    private static func applyUPS(source: Data, patch p: [UInt8], cancelled: () -> Bool) throws -> Result {
        guard p.count >= 18 else { throw fail("UPS patch is truncated.") }
        func little(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(p[at + $1]) << ($1 * 8) } }
        guard crc(Array(p.dropLast(4))) == little(p.count - 4) else { throw fail("UPS patch checksum is invalid.") }
        let src = [UInt8](source)
        guard crc(src) == little(p.count - 12) else { throw fail("Base ROM checksum does not match this UPS patch. Select the exact original ROM required by its author.") }
        var at = 4
        let end = p.count - 12
        func byte() throws -> UInt8 {
            guard at < end else { throw fail("UPS patch is truncated.") }
            defer { at += 1 }; return p[at]
        }
        func number() throws -> Int {
            var value = 0, shift = 1
            for _ in 0..<5 {
                let b = Int(try byte()); value += (b & 127) * shift
                if b & 128 != 0 { return value }
                shift <<= 7; value += shift
            }
            throw fail("UPS integer is too large.")
        }
        let sourceSize = try number(), targetSize = try number()
        guard sourceSize == src.count, targetSize > 0, targetSize <= limit else { throw fail("UPS ROM sizes are invalid or exceed 32 MB.") }
        let span = max(sourceSize, targetSize)
        var out = Array(src.prefix(targetSize))
        out += repeatElement(0, count: targetSize - out.count)
        var offset = 0
        while at < end {
            if cancelled() { throw CancellationError() }
            let skip = try number()
            guard offset <= span, skip <= span - offset else { throw fail("UPS offset is outside the ROM.") }
            offset += skip
            while true {
                let xor = try byte()
                if xor == 0 { offset += 1; break }
                guard offset < span else { throw fail("UPS run exceeds the ROM size.") }
                let value = (offset < src.count ? src[offset] : 0) ^ xor
                if offset < targetSize { out[offset] = value }
                offset += 1
                if offset & 65535 == 0, cancelled() { throw CancellationError() }
            }
        }
        guard crc(out) == little(p.count - 8) else { throw fail("UPS output checksum does not match. No ROM was created.") }
        return Result(data: Data(out), removedHeader: false, format: "UPS")
    }
}
