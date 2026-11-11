# Player ROM transfers (testing)

The host may enable **Allow Player 2 to download this ROM** before starting a game. This is off by default and applies when the host starts the helper; changing it during an active game is disabled.

When no library file matches the host's SHA-256, a player may request a download instead of selecting a local game. They must confirm they own the game and are authorized to receive a copy. Spectators never receive this option and the helper rejects spectator credentials.

The host must start the room to establish the peer connection. The receiving player uses Automatic ICE: direct when possible, TURN otherwise. ROM bytes never pass through the lobby API or directory. Only an admitted player's session key can request the host's current ROM, before gameplay begins. Each membership may download once; leaving and rejoining is required after an interrupted transfer.

Transfers use one bounded 16 KiB chunk request at a time, an overall three-minute deadline, a size limit of 8,000,512 bytes, and full SHA-256 verification before writing. The recipient cannot request a different host file or choose a path on the host. The destination name is selected locally. Existing files are never overwritten.

The recipient stages the verified ROM temporarily, then uses the regular library importer. With Copy files to Game Library enabled, the normal system ROM folder and collision rules apply. With that option disabled, the user chooses the permanent file location before the transfer. Temporary staging is removed afterward. There is no separate Received ROMs library folder.

The transfer helper disconnects without leaving the room. The player can then connect to the game using the newly imported, verified ROM. ROM compatibility checks still apply; transfers do not expand the current netplay runtime's supported games.
