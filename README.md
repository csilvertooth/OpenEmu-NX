![OpenEmu-NX — Classic games. Together.](docs/assets/openemu-nx-banner.svg?v=7da03d70)

<p align="center">
  <a href="https://github.com/csilvertooth/OpenEmu-NX/releases"><img alt="Testing release" src="https://img.shields.io/github/v/release/csilvertooth/OpenEmu-NX?include_prereleases&amp;style=flat-square&amp;color=9567ed" /></a>
  <img alt="Apple Silicon · macOS 14+ for netplay" src="https://img.shields.io/badge/netplay-Apple%20Silicon%20%C2%B7%20macOS%2014%2B-36aadd?style=flat-square" />
  <a href="docs/THIRD_PARTY.md"><img alt="Built on open-source projects" src="https://img.shields.io/badge/built%20on-open%20source-64748b?style=flat-square" /></a>
</p>

OpenEmu-NX is a Mac-first "netplay" like fork of [OpenEmu-Silicon](https://github.com/OpenEmu-Silicon/OpenEmu-Silicon), built on [OpenEmu](https://github.com/OpenEmu/OpenEmu). It keeps the imported game library and native Mac interface while adding shared play.

This is an early testing release. Network Play currently supports **two-player Super Mario Kart NTSC v1.0**, with matching game files verified by SHA-256. Hosts can optionally share the ROM with an admitted player who confirms ownership; spectators cannot download. Local emulation retains the upstream core architecture; Network Play uses a separate portable Snes9x runtime. Broader core support does not imply netplay support for those systems.

## Network Play

- Host public games or private rooms with readable invite codes.
- Match the host’s game against your imported library by SHA-256 before joining.
- Find public games across approved relays.
- Optional room passwords and spectator viewing.
- Rollback simulation with state-hash diagnostics.
- Direct-first invite connections with authenticated TURN fallback through Valve GameNetworkingSockets.
- Host multiplayer saves, then reconnect and resume together.
- Choose a public or custom STUN service and run Network Check for connection guidance.
- Optional player ROM transfers over the peer connection, verified before normal library import.

## Make your library your own

Apply **IPS, BPS and UPS** patches to a separate copy of a base game. SNES is the primary patching target; NES, Game Boy / Color, GBA, Genesis, Master System and Game Gear support is experimental. Original ROMs and saves stay separate.

Already have a patched ROM? Import it normally, then right-click **Use Base Game Artwork…** to choose a cover and mod name. See [ROM hacks](docs/rom-hacks.md) and [player transfers](docs/rom-transfer.md).

The current network helper requires an Apple Silicon Mac on macOS 14 or newer. ROMs and BIOS files are not included.

## Get started

See [testing and network play](docs/TESTING.md), [build instructions](docs/BUILDING.md), and [architecture](docs/ARCHITECTURE.md). Release packages, when published, will appear under [OpenEmu-NX Releases](https://github.com/csilvertooth/OpenEmu-NX/releases).

Starting with 0.1.4, the app checks this repository's signed update feed. Downloads and feed metadata are verified with the NX public key; installation asks for confirmation by default. Builds through 0.1.3 need a one-time manual installation. Core updates use their existing upstream channels. See [update publishing](docs/UPDATES.md).

## Data and preferences

OpenEmu-NX has its own data folder and app identity. Existing OpenEmu data can be copied without deleting the original, and custom library locations are preserved. Settings → Library provides a shortcut to the data folder. Core/library visibility controls determine which systems appear in the sidebar. See [data folders and fork configuration](docs/fork-data-configuration.md) for migration behavior and the settings a downstream fork should change.

## Project scope

This repository contains the app, runtime, core wrappers and vendored dependencies. The hosted lobby, relay directory backend, infrastructure and deployment tooling are intentionally not included yet. Client protocol handling remains in the runtime so it can connect to the configured services.

The initial public snapshot has a new Git history. Original attribution, license files and copyright headers remain; upstream history is available through the projects linked in [credits and dependencies](docs/THIRD_PARTY.md).

## Contribute

Use an issue to report the app version, macOS version, Mac model, game revision, and steps to reproduce. Remove passwords, invite codes for active private games, tokens, local paths and personal information from diagnostics before posting. Do not upload ROMs or BIOS files.

Preserve licenses and copyright headers, make focused changes, and test the behavior you change. Signing identities, credentials, release artifacts, local libraries and private infrastructure do not belong in commits. See [security](.github/SECURITY.md).

## Credits and licenses

OpenEmu-NX depends on extensive work by the OpenEmu, OpenEmu-Silicon, emulator-core and networking communities. [THIRD_PARTY.md](docs/THIRD_PARTY.md) identifies the major projects; [upstream credits](docs/UPSTREAM_CREDITS.md) preserve the inherited acknowledgments. The root [LICENSE](LICENSE) covers the frontend where applicable. Components retain their own licenses; there is no single license for the whole tree. Some cores have non-commercial restrictions.
