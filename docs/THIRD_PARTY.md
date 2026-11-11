# Credits and third-party projects

OpenEmu-NX is a fork, not a replacement claim of authorship for its dependencies. Original copyright notices and license files remain alongside the code.

| Project | Role | License source |
|---|---|---|
| [OpenEmu](https://github.com/OpenEmu/OpenEmu) | Original frontend, library, plugin and controller architecture | Root LICENSE and source headers |
| [OpenEmu-Silicon](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon) | Immediate upstream Mac/Apple Silicon frontend | Preserved source headers and upstream history |
| [OpenEmuARM64](https://github.com/bazley82/OpenEmuARM64) | Earlier ARM64 integration in the upstream lineage | Upstream repository |
| [Snes9x](https://github.com/snes9xgit/snes9x) | Portable deterministic SNES runtime and local SNES core | SNES9x/src/LICENSE |
| [Valve GameNetworkingSockets](https://github.com/ValveSoftware/GameNetworkingSockets) | Network transport and ICE integration | Upstream LICENSE; pinned commit in Runtime/Netplay/CMakeLists.txt |
| [OpenSSL](https://github.com/openssl/openssl) | Cryptographic dependency of the network transport | Upstream LICENSE.txt |
| [Protocol Buffers](https://github.com/protocolbuffers/protobuf) | Transport protocol serialization dependency | Upstream LICENSE |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | App/core update framework | Upstream LICENSE |
| [OpenEmu emulator core repositories](https://github.com/OpenEmu) | Core wrappers and local emulation backends | License files under each core directory |

The networking build reuses public Valve/OpenSSL/Protobuf components. No code from another private application is required or included.

The full inherited core, art and contributor acknowledgments are in [UPSTREAM_CREDITS.md](UPSTREAM_CREDITS.md). Additional dependencies include OpenEmuKit/SDK, shader tools, XADMaster, SQLite, FFmpeg and the dependencies vendored by each core. Their individual license and notice files are authoritative. Preserve them when redistributing.

The frontend and all bundled components are not covered by one uniform license. Some emulator components have GPL obligations or non-commercial restrictions. No ROMs or BIOS files are supplied by this project. Review the exact components and their licenses before redistributing a modified package.
