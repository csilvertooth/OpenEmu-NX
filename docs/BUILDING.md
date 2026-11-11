# Building OpenEmu-NX

The application is an Xcode workspace with flattened emulator-core sources. Network Play additionally builds the portable Snes9x runtime and links a pinned GameNetworkingSockets build. Hosted service implementations are not needed to compile the client and are not included in this snapshot.

The development environment used Xcode 26.5, CMake, an Apple Silicon Mac and the macOS SDK. The frontend deployment target is macOS 12; Network Play requires macOS 14. Use your own Developer ID identity and notarization credentials when distributing a build. Never add them to this repository.

## Local placeholder files

The project refers to local credential implementations. Create harmless placeholders from the checked-in templates:

```sh
cp OpenEmu/ScreenScraperDevCredentials.template.swift OpenEmu/ScreenScraperDevCredentials.swift
cp OpenEmu/CheatWorksSecrets.template.swift OpenEmu/CheatWorksSecrets.swift
```

The generated files stay ignored. Third-party services that require developer credentials will be unavailable until you configure your own credentials privately.

## Networking dependencies

Set these Xcode build settings (or exported environment variables for a command-line build):

- `EMU_GNS_ROOT`: checkout of `https://github.com/ValveSoftware/GameNetworkingSockets` at **d534c19aa760df3fb75fd20db13ba1932b8a5463**.
- `EMU_GNS_ARCHIVE`: its arm64 static `libGameNetworkingSockets_s.a`.
- `EMU_DEPS_ROOT`: matching arm64 static OpenSSL and Protocol Buffers install prefix, containing `include/`, `lib/libcrypto.a`, `lib/libprotobuf.a`, and `bin/protoc`.

The tested dependency combination was OpenSSL **3.5.4** and Protocol Buffers **3.21.12**. These are compatibility details for reproducing the current binary, not a promise that old dependency versions are indefinitely safe. Review upstream security updates and retest after changing them.

The default local paths are `Dependencies/GameNetworkingSockets`, its `build/src/libGameNetworkingSockets_s.a`, and `Dependencies/macos14.0`. `Dependencies/` is ignored. No other application's checkout is required.

Build OpenSSL and Protocol Buffers from their public upstream sources into the same prefix for arm64/macOS 14. Build GameNetworkingSockets with that prefix and these options:

```sh
cmake -S "$EMU_GNS_ROOT" -B "$EMU_GNS_ROOT/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_PREFIX_PATH="$EMU_DEPS_ROOT" \
  -DBUILD_STATIC_LIB=ON -DBUILD_SHARED_LIB=OFF \
  -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TOOLS=OFF \
  -DENABLE_ICE=ON -DUSE_STEAMWEBRTC=OFF \
  -DOPENSSL_USE_STATIC_LIBS=ON -DOPENSSL_ROOT_DIR="$EMU_DEPS_ROOT" \
  -DProtobuf_INCLUDE_DIR="$EMU_DEPS_ROOT/include" \
  -DProtobuf_LIBRARY="$EMU_DEPS_ROOT/lib/libprotobuf.a" \
  -DProtobuf_PROTOC_EXECUTABLE="$EMU_DEPS_ROOT/bin/protoc"
cmake --build "$EMU_GNS_ROOT/build" --config Release
```

Initialize the pinned checkout's required upstream submodules according to its build instructions. Do not substitute an unrelated static archive: the runtime checks the checkout commit, and the archive must be built from that same checkout with compatible dependency versions.

## Build the app

```sh
xcodebuild -workspace OpenEmu-metal.xcworkspace -scheme OpenEmu \
  -configuration Debug -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  EMU_GNS_ROOT="$EMU_GNS_ROOT" \
  EMU_GNS_ARCHIVE="$EMU_GNS_ARCHIVE" \
  EMU_DEPS_ROOT="$EMU_DEPS_ROOT" build
```

An unsigned local build is not a distribution artifact. App signing/notarization and hosted deployment automation are deliberately outside this public snapshot. The existing project may require local Xcode package resolution for its public framework dependencies.

The main app scheme does not rebuild every emulator core. Core plugin builds and installation are separate; inspect `Scripts/core.sh` before using it because installing a core can stop an open app. Do not overwrite a user's running game during testing.

## Validation limits

The private development checkout has built and run the matching client/runtime. The sanitized public export and these fresh-machine dependency setup instructions have not yet been independently built from an empty machine. Report missing public build inputs rather than copying private credentials or deployment files into the tree.
