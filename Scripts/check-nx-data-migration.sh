#!/bin/bash
# Copyright (c) 2026, OpenEmu Team. See LICENSE.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
printf 'import Foundation\nimport Darwin\n' > "$scratch/check.swift"
sed -n '/^\/\/ BEGIN NX_DATA_MIGRATION_FILES$/,/^\/\/ END NX_DATA_MIGRATION_FILES$/p' "$repo/OpenEmu/URL+OEAdditions.swift" >> "$scratch/check.swift"
cat >> "$scratch/check.swift" <<'SWIFT'
let fm = FileManager.default
let fixture = fm.temporaryDirectory.appendingPathComponent("nx-migration-check-" + UUID().uuidString)
defer { try? fm.removeItem(at: fixture) }
let old = fixture.appendingPathComponent("Old")
let next = fixture.appendingPathComponent("New")
try fm.createDirectory(at: old.appendingPathComponent("Game Library"), withIntermediateDirectories: true)
try Data("database fixture".utf8).write(to: old.appendingPathComponent("Game Library/Library.storedata"))
try fm.createDirectory(at: old.appendingPathComponent("Multiplayer Sessions/Autosaves"), withIntermediateDirectories: true)
try Data("old session".utf8).write(to: old.appendingPathComponent("Multiplayer Sessions/Autosaves/old.emuxsave"))
try Data("encrypted legacy credential fixture".utf8).write(to: old.appendingPathComponent(".oe_credentials.old"))
do {
    try NXDataMigrationFiles.copyLegacyData(from: old, to: next, legacyAppRunning: true)
    fatalError("A live legacy app must block the migration")
} catch {
    precondition(!fm.fileExists(atPath: next.path))
}
try fm.createDirectory(at: next.appendingPathComponent("Game Library"), withIntermediateDirectories: true)
try fm.createDirectory(at: old.appendingPathComponent("Bindings"), withIntermediateDirectories: true)
try Data("bindings fixture".utf8).write(to: old.appendingPathComponent("Bindings/controller.plist"))
try fm.createDirectory(at: next.appendingPathComponent("Bindings"), withIntermediateDirectories: true)
try fm.createDirectory(at: next.appendingPathComponent("Multiplayer Sessions"), withIntermediateDirectories: true)
let save = next.appendingPathComponent("Multiplayer Sessions/existing.emuxsave")
try Data("existing save".utf8).write(to: save)
try NXDataMigrationFiles.copyLegacyData(from: old, to: next, legacyAppRunning: false)
precondition((try? Data(contentsOf: old.appendingPathComponent("Game Library/Library.storedata"))) == (try? Data(contentsOf: next.appendingPathComponent("Game Library/Library.storedata"))))
precondition((try? String(contentsOf: next.appendingPathComponent("Bindings/controller.plist"), encoding: .utf8)) == "bindings fixture")
precondition((try? String(contentsOf: save, encoding: .utf8)) == "existing save")
precondition((try? String(contentsOf: next.appendingPathComponent("Multiplayer Sessions/Autosaves/old.emuxsave"), encoding: .utf8)) == "old session")
precondition(!fm.fileExists(atPath: next.appendingPathComponent(".oe_credentials.old").path))
try Data("changed original".utf8).write(to: old.appendingPathComponent("Game Library/Library.storedata"))
try NXDataMigrationFiles.copyLegacyData(from: old, to: next, legacyAppRunning: true)
precondition((try? String(contentsOf: next.appendingPathComponent("Game Library/Library.storedata"), encoding: .utf8)) == "database fixture")
let populated = fixture.appendingPathComponent("Populated")
try fm.createDirectory(at: populated.appendingPathComponent("Game Library"), withIntermediateDirectories: true)
try Data("owned database".utf8).write(to: populated.appendingPathComponent("Game Library/owned.storedata"))
try NXDataMigrationFiles.copyLegacyData(from: old, to: populated, legacyAppRunning: false)
precondition((try? String(contentsOf: populated.appendingPathComponent("Game Library/owned.storedata"), encoding: .utf8)) == "owned database")
precondition(!fm.fileExists(atPath: populated.appendingPathComponent("Game Library/Library.storedata").path))
let external = fixture.appendingPathComponent("External Library").path
let preserved = NXDataMigrationFiles.migratedPreferences(legacy: ["databasePath": external, "volume": 0.3], current: ["volume": 0.7], legacyRoot: old, destinationRoot: next)
precondition(preserved["databasePath"] as? String == external)
precondition(preserved["volume"] as? Double == 0.7)
let moved = NXDataMigrationFiles.migratedPreferences(legacy: ["databasePath": old.appendingPathComponent("Game Library").path], current: [:], legacyRoot: old, destinationRoot: next)
precondition(moved["databasePath"] as? String == next.appendingPathComponent("Game Library").path)
precondition(NXDataMigrationFiles.relocatedURL(fixture.appendingPathComponent("OldOther/file"), from: old, to: next) == nil)
let bad = fixture.appendingPathComponent("not-a-directory")
try Data().write(to: bad)
let failed = fixture.appendingPathComponent("Failed")
do {
    try NXDataMigrationFiles.copyLegacyData(from: bad, to: failed, legacyAppRunning: false)
    fatalError("Invalid source must fail")
} catch {
    precondition(!fm.fileExists(atPath: failed.appendingPathComponent(NXDataMigrationFiles.markerName).path))
}
print("PASS: live-app protection, copy preservation, retry safety, credential exclusion, custom library paths, preference precedence, failed-copy marker")
SWIFT
swift "$scratch/check.swift"

# Check the actual shared SDK resolver from a nested helper bundle. This does not
# create any Application Support data or alter a preference domain.
outer="$scratch/Fixture.app"
inner="$outer/Contents/Helpers/FixtureHelper.app"
mkdir -p "$inner/Contents/MacOS"
cat > "$outer/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.fixture.Host</string><key>CFBundlePackageType</key><string>APPL</string><key>OEApplicationSupportFolder</key><string>FixtureFork</string></dict></plist>
PLIST
cat > "$inner/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.fixture.Helper</string><key>CFBundleExecutable</key><string>check</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
cat > "$scratch/main.m" <<'OBJC'
#import <Foundation/Foundation.h>
#import "NSUserDefaults+OpenEmuSDK.h"
int main(void) {
    @autoreleasepool {
        NSCAssert([OEApplicationSupportFolderName() isEqualToString:@"FixtureFork"], @"Helper must use the host's configured folder");
        NSCAssert([OEApplicationPreferencesDomain() isEqualToString:@"test.fixture.Host"], @"Helper must use the host's preference domain");
        NSCAssert([OEApplicationSupportDirectoryURL().lastPathComponent isEqualToString:@"FixtureFork"], @"Configured support path missing");
        puts("PASS: nested helper resolves host folder and preference identity");
    }
    return 0;
}
OBJC
clang -fobjc-arc -framework Foundation -I "$repo/OpenEmu-SDK/OpenEmuBase" "$repo/OpenEmu-SDK/OpenEmuBase/NSUserDefaults+OpenEmuSDK.m" "$scratch/main.m" -o "$inner/Contents/MacOS/check"
"$inner/Contents/MacOS/check"
