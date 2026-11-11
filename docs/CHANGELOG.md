# OpenEmu-NX changes

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
