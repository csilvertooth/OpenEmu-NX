# Network Check

Network Play → Settings offers Cloudflare public STUN, a custom STUN hostname and port, or the lobby's STUN configuration. Cloudflare is the default. STUN only discovers network mappings; it does not carry game or ROM data. Its operator sees the client's public network address. Settings apply on the next connection.

Check Network probes the configured lobby's health endpoint and sends a bounded UDP STUN Binding request. It validates the response transaction ID, message length, cookie and XOR-MAPPED-ADDRESS attribute. Invalid packets do not count as success. The probe retries twice and stops after five seconds; it does not modify rooms or interrupt gameplay.

A STUN response is **not proof of direct peer connectivity**. When a game is connected, the check reads the runtime's actual selected route and round-trip time. Before that, direct play is reported as unverified. Relay use does not by itself prove that direct play is impossible, particularly when Relay only was selected. Lobby-provided STUN is received during connection; choose an explicit provider for the standalone probe.

For problems, try another STUN endpoint, check outbound UDP policies and VPN restrictions, and investigate double NAT or ISP carrier-grade NAT. Ask the ISP about public IPv4 or IPv6 access when appropriate. Keep the firewall enabled and use Automatic for relay fallback.

This check does not classify NAT types, change router settings, or run a separate two-peer preflight session. Current paired verification uses the actual game connection. No network-check telemetry is uploaded.

Cloudflare endpoint documentation: https://developers.cloudflare.com/realtime/turn/

Focused verification: `bash Scripts/check-network-stun.sh`; add `--live` to probe Cloudflare from the current network.
