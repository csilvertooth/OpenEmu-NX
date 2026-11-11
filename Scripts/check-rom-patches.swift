// Copyright (c) 2026, OpenEmu Team. See LICENSE.
import Foundation
func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws { if try !value() { fatalError(name) } }
func rejects(_ patch: Data, source: Data = Data("abcdef".utf8)) { do { _ = try NXROMPatch.apply(source: source, patch: patch); fatalError("accepted invalid patch") } catch {} }
let source = Data("abcdef".utf8)
let ips = Data(Array("PATCH".utf8) + [0,0,1,0,2,88,89] + Array("EOF".utf8))
try check(NXROMPatch.apply(source: source, patch: ips).data == Data("aXYdef".utf8), "IPS literal")
let rle = Data(Array("PATCH".utf8) + [0,0,5,0,0,0,3,90] + Array("EOF".utf8) + [0,0,7])
try check(NXROMPatch.apply(source: source, patch: rle).data == Data("abcdeZZ".utf8), "IPS RLE, expansion, resize")
rejects(Data(ips.dropLast()))
rejects(ips + Data([1]))
let bps0 = Data([66, 80, 83, 49, 134, 136, 128, 132, 133, 88, 89, 143, 132, 239, 57, 142, 75, 222, 9, 149, 189, 0, 202, 226, 183])
let bps1 = Data([66, 80, 83, 49, 134, 132, 128, 134, 136, 134, 141, 239, 57, 142, 75, 45, 53, 188, 190, 137, 121, 181, 33])
try check(NXROMPatch.apply(source: source, patch: bps0).data == Data("abXYXYXY".utf8), "BPS source read, literal, overlapping target copy")
try check(NXROMPatch.apply(source: source, patch: bps1).data == Data("efab".utf8), "BPS signed source copy")
rejects(bps0, source: Data("wrong!".utf8))
var corrupt = bps0; corrupt[10] ^= 1; rejects(corrupt)
do { _ = try NXROMPatch.apply(source: source, patch: ips, cancelled: { true }); fatalError("cancellation ignored") } catch is CancellationError {} 
try check(source == Data("abcdef".utf8), "source preserved")
for length in 0..<bps0.count { rejects(Data(bps0.prefix(length))) }
for _ in 0..<500 { rejects(Data((0..<Int.random(in: 0...100)).map { _ in UInt8.random(in: 0...255) })) }
let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let original = root.appendingPathComponent("original.sfc"), save = root.appendingPathComponent("original.sav")
try source.write(to: original); try Data("save fixture".utf8).write(to: save)
let patched = try NXROMPatch.apply(source: NXROMPatch.read(original), patch: ips)
try patched.data.write(to: root.appendingPathComponent("hack.sfc"), options: .atomic)
try check(Data(contentsOf: original) == source, "original file preserved")
try check(Data(contentsOf: save) == Data("save fixture".utf8), "save file preserved")
print("PASS: IPS/BPS operations, checksums, malformed input, cancellation, original ROM and save preservation")

let headerPatch = Data([66, 80, 83, 49, 0, 127, 128, 1, 127, 128, 128, 124, 126, 134, 129, 90, 166, 252, 31, 1, 70, 78, 8, 102, 66, 205, 248, 251])
let headerSource = Data(repeating: 17, count: 512) + Data(repeating: 0, count: 32768)
let headerResult = try NXROMPatch.apply(source: headerSource, patch: headerPatch)
try check(headerResult.removedHeader && headerResult.data == Data(repeating: 0, count: 32768) + Data([90]), "verified BPS copier-header normalization")
rejects(Data([66, 80, 83, 49, 134, 129, 128, 131, 128, 239, 57, 142, 75, 131, 22, 220, 140, 71, 241, 204, 132]))
try check(NXROMPatch.crc(Array("123456789".utf8)) == 0xcbf43926, "standard CRC32 vector")
print("PASS: verified SNES header removal, invalid BPS target reference, standard CRC32 vector")

// Header warnings: standard/headered ROMs and stale hack checksums are accepted.
func headerFixture(size: Int, offset: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: size)
    let title = Array("SUPER MARIO KART     ".utf8)
    bytes.replaceSubrange(offset..<offset + 21, with: title)
    bytes[offset + 21] = 0x31
    bytes[offset + 61] = 0x80
    return Data(bytes)
}
precondition(NXROMPatch.snesHeaderWarning(headerFixture(size: 1048576, offset: 0xffc0)) == nil)
precondition(NXROMPatch.snesHeaderWarning(headerFixture(size: 1049088, offset: 0x101c0)) == nil)
precondition(NXROMPatch.snesHeaderWarning(headerFixture(size: 1048576, offset: 0x101c0)) != nil)
precondition(NXROMPatch.snesHeaderWarning(headerFixture(size: 1049088, offset: 0xffc0)) != nil)
precondition(NXROMPatch.snesHeaderWarning(Data(repeating: 0, count: 32)) == nil)
print("PASS: SNES header mismatch warnings")

func upsNumber(_ input: Int) -> [UInt8] {
    var n = input, out: [UInt8] = []
    while true {
        let byte = UInt8(n & 127); n >>= 7
        if n == 0 { out.append(byte | 128); return out }
        out.append(byte); n -= 1
    }
}
func upsFixture(_ input: Data, _ output: Data, records: [UInt8]) -> Data {
    var p = Array("UPS1".utf8) + upsNumber(input.count) + upsNumber(output.count) + records
    func appendCRC(_ crc: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { p.append(UInt8(truncatingIfNeeded: crc >> shift)) } }
    appendCRC(NXROMPatch.crc(Array(input))); appendCRC(NXROMPatch.crc(Array(output)))
    appendCRC(NXROMPatch.crc(p)); return Data(p)
}
let upsTarget = Data("aXYdef".utf8)
let ups = upsFixture(source, upsTarget, records: [0x81, 98 ^ 88, 99 ^ 89, 0])
try check(NXROMPatch.apply(source: source, patch: ups).data == upsTarget, "UPS XOR run")
let grown = source + Data([90])
try check(NXROMPatch.apply(source: source, patch: upsFixture(source, grown, records: [0x86,90,0])).data == grown, "UPS expansion")
let shrunk = Data(source.prefix(3))
try check(NXROMPatch.apply(source: source, patch: upsFixture(source, shrunk, records: [0x83,100,101,102,0])).data == shrunk, "UPS truncation")
rejects(ups, source: upsTarget)
rejects(upsFixture(source, Data("wrong!".utf8), records: [0x81,98 ^ 88,99 ^ 89,0]))
rejects(upsFixture(source, upsTarget, records: [0xff,1,0]))
rejects(upsFixture(source, upsTarget, records: [0x81,1]))
for length in 0..<ups.count { rejects(Data(ups.prefix(length))) }
var corruptUPS = ups; corruptUPS[7] ^= 1; rejects(corruptUPS)
do { _ = try NXROMPatch.apply(source: source, patch: ups, cancelled: { true }); fatalError("UPS cancellation ignored") } catch is CancellationError {}
do { _ = try NXROMPatch.apply(source: headerSource, patch: headerPatch, allowSNESHeader: false); fatalError("non-SNES header modified") } catch {}
for platform in NXROMPatch.platforms {
    for ext in platform.extensions {
        let original = root.appendingPathComponent("original.\(ext)")
        let save = root.appendingPathComponent("original-\(ext).sav")
        try source.write(to: original); try Data("untouched".utf8).write(to: save)
        let output = try NXROMPatch.apply(source: NXROMPatch.read(original), patch: ups, allowSNESHeader: platform.isSNES)
        let variant = root.appendingPathComponent("Hack-\(UUID().uuidString).\(ext)")
        try output.data.write(to: variant)
        try check(Data(contentsOf: original) == source && Data(contentsOf: save) == Data("untouched".utf8), "platform original/save preservation")
    }
}
print("PASS: UPS checksums, XOR, resize, bounds, cancellation; platform save preservation; SNES-only normalization")
