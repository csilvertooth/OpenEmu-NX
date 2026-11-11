# 0.1.6 testing

- Redesigned Network Play with Host, Join, Relays and Settings tabs, centered navigation, fixed player fields, a scrollable host list and compact game status.
- Clearer Create Room, Start Game and Connect actions, with invite-code joining and player/room name placeholders.
- Host-approved ROM transfers before gameplay, progress feedback, SHA-256 verification and library artwork refresh.
- Collapsible sidebar sections, favorite consoles, vendor/custom grouping and drag ordering; corrected Nintendo grouping.
- Updated first-launch What’s New notes.

Validation: Release build and focused UI checks passed. Earlier two-Mac gameplay and pre-start transfer checks passed, with user-confirmed controls and audio. Drag reordering needs further hands-on testing because the UI automation could not perform the drag gesture. This release has not received a fresh full-game regression run.

Apple Silicon Mac required. SNES netplay is experimental; untested games and ROM hacks are marked in the app. Other emulator systems are not supported by the netplay runtime yet. ROMs and BIOS files are not included.

# OpenEmu-NX changes

## 0.1.5 testing

- Add safe IPS, BPS and UPS ROM patching, with SNES as the primary target and other cartridge systems marked experimental.
- Add base-game cover artwork and mod-name overlays, including a right-click option for already patched games.
- Fix helper-launch failures that prevented games from starting.
- Add public/custom STUN options and a wider Network Check with troubleshooting guidance and current-session route reporting.
- Add optional host-approved, player-only ROM downloads with ownership confirmation, SHA-256 verification and normal library import placement. Spectators cannot download.
- Show updated What's New notes once on the first launch of this version; refresh first-run setup notes and NX branding.

Validation: two Apple Silicon Macs completed 600 synchronized frames per test for direct play, Automatic relay fallback with direct candidates excluded by the test harness, and reconnection after a peer ROM download. Rejection checks covered disabled sharing and spectator downloads. This is not a fresh separate-ISP/hotspot test, nor a new subjective audio/controller test.

## 0.1.4 testing

- Enable GitHub-hosted app updates with NX-owned Ed25519 signatures for both the feed and installer.
- Check automatically and prompt before installing by default.
- Require valid signatures before extracting downloads; reject invalid or unsigned feeds.
- Builds through 0.1.3 require this update to be installed manually once.

## 0.1.3 testing

- Select a joining player's imported game by the host's SHA-256, with an explicit mismatch explanation.
- Use Automatic/direct-first transport for invite joins, with relay fallback.
- Add quick system visibility toggles in Cores and a larger available-libraries area.
- Give NX its own configurable data folder and preferences identity, with non-destructive legacy-data migration.
- Open the NX data folder from Library settings; start multiplayer-save browsing in the saved-sessions folder.

## 0.1.2 testing

- Make Network Play resizable and let game/relay tables expand with it.
- Keep Join Selected Room inside its tab and group it with Refresh.
- Preserve readable column headers at the minimum window size.

## Earlier NX testing work

- Integrate the portable Snes9x runtime, GameNetworkingSockets transport, rollback, state-hash diagnostics, spectator viewing, and multiplayer saves.
- Add library-based game selection, host passwords, private invites, public game discovery and a public relay directory client.
- Improve display pacing, audio continuity and controller/input scheduling through two-Mac LAN/hosted-relay testing.
- Introduce NX branding and icon, readable eight-character invites, connected-state controls and first-launch core-list refresh.

These changes build on the upstream projects credited in THIRD_PARTY.md. They do not imply every emulator core supports netplay, or that every network condition has been tested.
