# Testing Network Play

Install the same OpenEmu-NX build on both Macs. Each player imports their own matching game into their local library. The current preview targets Super Mario Kart NTSC v1.0.

1. Open Network Play and select the desired relay.
2. The host chooses a library game and creates a room. Public rooms appear in Browse Games; private rooms require the host's invite.
3. The other player joins the public room or enters its invite code. The app selects an exact SHA-256 match from the imported library. If no match is found, it asks you to choose and verify a library game; mismatched files cannot join. Both Macs must use the host's relay when joining by invite. Invite joins use Automatic connectivity, preferring direct play with relay fallback.
4. When both players are present, the host starts the game and the guest connects. A running connection is shown as Connected.
5. Use Leave Room to finish. The host's confirmed multiplayer progress is saved automatically; export a separate copy when needed.

Room passwords are separate from invite codes. Spectators use the host's spectator/password settings and do not consume player slots. A ROM hash mismatch is not fixed by renaming a file; use the same game revision.

Test LAN and separate-network play independently. A same-network connection through a hosted relay verifies relay transport, but does not reproduce every NAT or mobile-network condition. Listen for audio gaps and check controller responsiveness; automated state hashes alone cannot prove those user-facing qualities.

Do not share ROMs, BIOS files, passwords, active private invites, tokens or unredacted diagnostics in issues.

## Library and data settings

In Settings → Cores, use Show to enable or hide the supported systems in the library sidebar. Settings → Library provides the larger system list and an Open OpenEmu-NX Folder action. Hiding a system does not delete its imported games.

Resume Multiplayer Game opens the multiplayer-save folder inside the configured application data folder. Existing OpenEmu data is copied during migration; custom library locations remain supported. Fork maintainers can configure the application data folder as described in [Fork data configuration](fork-data-configuration.md). Verify a clean first launch and an existing-library migration separately before distributing a build.
