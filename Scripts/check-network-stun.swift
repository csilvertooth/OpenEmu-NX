// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
@main struct Check {
 static func main() async {
 let tx = Array(UInt8(0)...UInt8(11))
 let header: [UInt8] = [1,1,0,12,0x21,0x12,0xa4,0x42] + tx
 let good = Data(header + [0,32,0,8,0,1,0x21,0x13,1,2,3,4])
 precondition(NXSTUNProbe.validResponse(good, transaction: tx))
 precondition(!NXSTUNProbe.validResponse(good, transaction: Array(repeating: 0, count: 12)))
 for n in 0..<good.count { precondition(!NXSTUNProbe.validResponse(good.prefix(n), transaction: tx)) }
 var bad = good; bad[23] = 255
 precondition(!NXSTUNProbe.validResponse(bad, transaction: tx))
 var error = good; error[1] = 0x11
 precondition(!NXSTUNProbe.validResponse(error, transaction: tx))
 precondition(NXSTUNProbe.server("stun.cloudflare.com:3478") != nil)
 for s in ["https://bad:3478", "host:0", "host:65536", "host:3478\n", "host"] { precondition(NXSTUNProbe.server(s) == nil) }
 print("PASS: response validation, truncation, transaction mismatch, malformed attributes, invalid servers")
 if CommandLine.arguments.contains("--live") {
 let ok = await NXSTUNProbe.check("stun.cloudflare.com:3478")
 print("Live Cloudflare STUN UDP:", ok ? "reachable" : "unreachable")
 }
 }
}
