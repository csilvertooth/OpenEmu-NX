# Architecture

The OpenEmu-derived native frontend owns the imported game library, preferences, controller configuration and Network Play interface. Local games continue to use the upstream core-plugin architecture.

Network Play launches a separate helper with a portable Snes9x runtime. Peers validate game and runtime identities before a session. Rollback keeps local input responsive while remote inputs arrive; periodic state hashes expose divergence. Rendering, audio buffering and networking are separate from the deterministic emulation step. Spectators receive a viewing stream rather than controlling the game.

The central Lambda lobby provides room discovery, membership, invite resolution, relay registration and signaling. The native app refreshes public games and approved relays on demand. Once joined, authenticated WebSocket notifications prompt the app to retrieve the current room state; periodic heartbeats preserve membership and recover from interrupted notifications. Relay servers carry TURN traffic, not room catalogs or invite resolution. Private rooms use invite codes and may require a password. Game traffic uses GameNetworkingSockets/ICE: direct connectivity where possible and authenticated TURN when needed. TURN credentials are granted for room access; they are not a secret bundled in the app.

A host's multiplayer save contains the session data needed to restore a shared game. Both players must still have compatible local game files and runtimes. A spectator is not a player slot.

The server implementations and deployment configuration are withheld from this public snapshot pending separate review. No hosting account credentials or server administration keys are required to build the client.
