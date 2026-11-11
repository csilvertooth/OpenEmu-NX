# Testing Network Play

Install the same OpenEmu-NX build on both Macs. Each player imports their own matching game into their local library. This beta allows experimental SNES games and ROM hacks; consult the compatibility indicator for validation status.

1. Open Network Play. Set your player name on Host Game or Join Game. The host may choose a fallback relay; direct play is tried first.
2. The host chooses a library game and creates a room. Public rooms appear on Join Game after Refresh Games; private rooms require the host's invite.
3. The other player joins the public room or enters its invite code. The app selects an exact SHA-256 match from the imported library. If no match is found, it asks you to choose and verify a library game; mismatched files cannot join. The central lobby resolves the invite and supplies the room’s connection information. Invite joins use Automatic connectivity, preferring direct play with relay fallback.
4. When both players are present, the host starts the game and the guest connects. A running connection is shown as Connected.
5. Use Leave Room to finish. The host's confirmed multiplayer progress is saved automatically; export a separate copy when needed.

Room passwords are separate from invite codes. Spectators use the host's spectator/password settings and do not consume player slots. A ROM hash mismatch is not fixed by renaming a file; use the same game revision.

Test LAN and separate-network play independently. A same-network connection through a hosted relay verifies relay transport, but does not reproduce every NAT or mobile-network condition. Listen for audio gaps and check controller responsiveness; automated state hashes alone cannot prove those user-facing qualities.

Do not share ROMs, BIOS files, passwords, active private invites, tokens or unredacted diagnostics in issues.

## Library and data settings

In Settings → Cores, use Show to enable or hide the supported systems in the library sidebar. Settings → Library provides the larger system list and an Open OpenEmu-NX Folder action. Hiding a system does not delete its imported games.

Resume Multiplayer Game opens the multiplayer-save folder inside the configured application data folder. Existing OpenEmu data is copied during migration; custom library locations remain supported. Fork maintainers can configure the application data folder as described in [Fork data configuration](fork-data-configuration.md). Verify a clean first launch and an existing-library migration separately before distributing a build.

The default lobby is **https://lobby.azimuthsystems.net**. Beta 2 migrates the previous default automatically; custom servers remain unchanged.

## Relay registration

Open Network Play → Relays and use the registration action to submit a relay name, region, hostname and operator contact. Registration is reviewed before listing; submitting a form does not automatically publish a relay. Do not put TURN secrets or server credentials in the form. The operator completes private service configuration after review.

Use Refresh Relays to retrieve the current approved list. Registered does not guarantee that a relay is reachable from every network; Network Check and a real connection determine connectivity.
