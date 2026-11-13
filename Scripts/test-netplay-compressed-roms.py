#!/usr/bin/env python3
# Tests the production preparation actor with XADMaster; no copyrighted ROM fixtures.
from pathlib import Path
import zipfile,subprocess,shutil,tempfile,atexit
r=Path(__file__).resolve().parents[1];w=Path(tempfile.mkdtemp(prefix='nx-compressed-rom-tests-'));atexit.register(shutil.rmtree,w)
f=w/'fixtures';f.mkdir(exist_ok=True)
raw=bytes(range(256))*4096;(f/'raw.sfc').write_bytes(raw)
for name,payload in [('normal.zip',raw),('changed.zip',raw+b'new')]:
 with zipfile.ZipFile(f/name,'w',zipfile.ZIP_DEFLATED) as z:
  z.writestr('readme.txt','not a ROM');z.writestr('../../escaped.sfc',payload)
(f/'broken.zip').write_bytes(b'invalid zip')
with zipfile.ZipFile(f/'oversize.zip','w',zipfile.ZIP_DEFLATED) as z:z.writestr('big.sfc',b'0'*(64*1024*1024+1))
s=(r/'OpenEmu/ArchiveHelper.swift').read_text();actor=s[s.index('actor NetworkROMPreparation'):]
(w/'Preparation.swift').write_text('import Foundation\nimport XADMaster\n'+actor)
(w/'Main.swift').write_text('''import Foundation
@main struct Test {
 static func main() async throws {
  let root = URL(fileURLWithPath: CommandLine.arguments[1]); let cache = root.appendingPathComponent("cache")
  let p = NetworkROMPreparation()
  let raw = try await p.prepare(source: root.appendingPathComponent("raw.sfc"), index: nil, retainedRoot: nil)
  let zipped = try await p.prepare(source: root.appendingPathComponent("normal.zip"), index: 1, retainedRoot: cache)
  assert(raw.sha256 == zipped.sha256 && raw.url != zipped.url)
  assert(zipped.url.path.hasPrefix(cache.path) && zipped.url.lastPathComponent == "game.sfc")
  let stamp = try zipped.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  let again = try await p.prepare(source: root.appendingPathComponent("normal.zip"), index: 1, retainedRoot: cache)
  assert(try again.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == stamp)
  try Data("corrupt".utf8).write(to: zipped.url)
  let repaired = try await p.prepare(source: root.appendingPathComponent("normal.zip"), index: 1, retainedRoot: cache)
  assert(repaired.sha256 == raw.sha256)
  let changed = try await p.prepare(source: root.appendingPathComponent("changed.zip"), index: 1, retainedRoot: cache)
  assert(changed.sha256 != raw.sha256 && changed.url != repaired.url)
  for (name,index) in [("broken.zip",0),("normal.zip",-1),("normal.zip",99),("oversize.zip",0)] {
   do { _ = try await p.prepare(source: root.appendingPathComponent(name), index: index, retainedRoot: cache); fatalError("accepted invalid archive") } catch { }
  }
  let temporary = try await p.prepare(source: root.appendingPathComponent("normal.zip"), index: 1, retainedRoot: nil)
  assert(!temporary.url.path.hasPrefix(cache.path) && temporary.sha256 == raw.sha256)
  print("PASS extracted/raw hash equality; exact archive entry; safe destination; cache reuse and corruption recovery; changed content; invalid, damaged and oversized rejection; temporary mode")
  if CommandLine.arguments.count > 2 {
   let game = URL(fileURLWithPath: CommandLine.arguments[2])
   let real = try await p.prepare(source: game, index: 0, retainedRoot: cache)
   print("REAL_ROM=" + real.url.path)
  }
 }
}
'''.replace('assert(try again.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == stamp)','let againStamp = try again.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate\n  assert(againStamp == stamp)'))
subprocess.run(['clang','-c','-fmodules','-fobjc-arc','-F'+str(r/'OpenEmu'),str(r/'OpenEmu/XADArchive+OE.m'),'-o',str(w/'bridge.o')],check=True)
subprocess.run(['swiftc','-parse-as-library','-F'+str(r/'OpenEmu'),'-framework','XADMaster','-import-objc-header',str(r/'OpenEmu/XADArchive+OE.h'),str(w/'Preparation.swift'),str(r/'OpenEmu/FileManager+Hashing.swift'),str(w/'Main.swift'),str(w/'bridge.o'),'-Xlinker','-rpath','-Xlinker',str(r/'OpenEmu'),'-o',str(w/'tests')],check=True)
subprocess.run([str(w/'tests'),str(f)],check=True)
