// Copyright (c) 2022, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Foundation
internal import os.log

extension NSXPCConnection {
    struct BrokerError: Error, LocalizedError {
        var errorDescription: String? { 
            NSLocalizedString("Failed to launch helper app", comment: "")
        }
        let failureReason: String?
    }
    
    static let helperIdentifierArgumentPrefix = "--org.openemu.broker.id="
    static let helperServiceNameArgumentPrefix = "--org.openemu.broker.name="
    private static var xpcTaskKey = 0
    
    static func makeConnection(serviceName name: String, executableURL url: URL) throws -> NSXPCConnection {
        let identifier = UUID().uuidString
        
        /// 1. Launch Helper App
        /// This results in the helper app establishing a connection to the broker and registering its
        /// `identifier`
        let task = Process()
        task.executableURL = url
        task.arguments = ["\(Self.helperIdentifierArgumentPrefix)\(identifier)", "\(Self.helperServiceNameArgumentPrefix)\(name)"]
        task.terminationHandler = { task in
            os_log(.error, log: .helper,
                   "Helper terminated unexpectedly. { id = %{public}@, reason = %ld, exit = %d }",
                   identifier,
                   task.terminationReason.rawValue,
                   task.terminationStatus)
        }
        task.standardError  = FileHandle.standardError
        task.standardOutput = FileHandle.standardOutput
        do {
            try task.run()
        } catch {
            throw BrokerError(failureReason: error.localizedDescription)
        }
        
        var success = false
        defer {
            // Terminate helper when broker connection fails
            if !success {
                os_log(.error, log: .helper,
                       "Terminating helper; failed to complete handshake. { id = %{public}@ }",
                       identifier)
                task.terminationHandler = nil
                task.terminate()
            }
        }
        
        // The broker declares ServiceType=User. A serviceName connection looks
        // in the host's per-process bundle namespace and can fail with error 3,
        // while the auxiliary helper has already started the user-scoped broker.
        // Connect in that shared scope and retry lookup while it starts.
        let deadline = DispatchTime.now() + .seconds(8)
        var endpoint: NSXPCListenerEndpoint?
        var lastFailure = "Timeout waiting for connection from helper app"
        while task.isRunning && DispatchTime.now() < deadline {
            let attempt = HelperBrokerAttempt()
            let cn = NSXPCConnection(machServiceName: name)
            cn.remoteObjectInterface = .init(with: OEXPCMatchMaking.self)
            cn.resume()
            let mm = cn.remoteObjectProxyWithErrorHandler { error in
                attempt.finish(endpoint: nil, failure: error.localizedDescription)
            } as? OEXPCMatchMaking
            if let mm {
                mm.retrieveListenerEndpoint(forIdentifier: identifier) { endpoint in
                    attempt.finish(endpoint: endpoint, failure: nil)
                }
            } else {
                attempt.finish(endpoint: nil, failure: "Broker proxy unavailable")
            }
            _ = attempt.ready.wait(timeout: deadline)
            let result = attempt.result
            cn.invalidate()
            if let value = result.0 { endpoint = value; break }
            if let failure = result.1 { lastFailure = failure }
            // Only connection lookup errors return immediately; a pending
            // handshake consumes the deadline and must not be duplicated.
            if DispatchTime.now() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        }
        guard let endpoint else { throw BrokerError(failureReason: lastFailure) }

        guard task.isRunning else {
            throw BrokerError(failureReason: NSLocalizedString("Helper unexpectedly terminated", comment: ""))
        }
        
        let newCn = NSXPCConnection(listenerEndpoint: endpoint)
        
        task.terminationHandler = { [weak newCn] task in
            os_log(.debug, log: .helper,
                   "Helper terminated. { id = %{public}@, exit = %d }.",
                   identifier,
                   task.terminationStatus)
            newCn?.invalidate()
        }
        
        objc_setAssociatedObject(newCn, &Self.xpcTaskKey, task, .OBJC_ASSOCIATION_RETAIN)
        
        success = true
        return newCn
    }
}

/// XPC callbacks can arrive after a timeout; protect the attempt's reply state.
private final class HelperBrokerAttempt: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var finished = false
    private var endpoint: NSXPCListenerEndpoint?
    private var failure: String?
    func finish(endpoint: NSXPCListenerEndpoint?, failure: String?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; self.endpoint = endpoint; self.failure = failure
        lock.unlock(); ready.signal()
    }
    var result: (NSXPCListenerEndpoint?, String?) {
        lock.lock(); defer { lock.unlock() }
        return (endpoint, failure)
    }
}
