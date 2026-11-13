#if TGWS_TUNNEL_AVAILABLE
import Foundation
import NetworkExtension

enum TunnelControllerError: Error {
    case unavailable
    case connectionFailed
    case timedOut
}

private final class TunnelReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: String?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

@MainActor
final class TunnelController {
    static let shared = TunnelController()
    private var manager: NETunnelProviderManager?

    private var providerBundleID: String {
        (Bundle.main.bundleIdentifier ?? "com.delewer.tgwsproxy") + ".tunnel"
    }

    var isConnected: Bool { manager?.connection.status == .connected }

    @discardableResult
    func prepare() async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let mgr = managers.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleID
        } ?? NETunnelProviderManager()
        manager = mgr
        return mgr
    }

    func restore() async throws -> ProxyConfiguration? {
        let mgr = try await prepare()
        for _ in 0..<40 where mgr.connection.status == .connecting || mgr.connection.status == .reasserting {
            try await Task.sleep(for: .milliseconds(200))
        }
        guard isConnected else { return nil }
        if let raw = await sendMessage("configuration"), let data = raw.data(using: .utf8) {
            return try JSONDecoder().decode(ProxyConfiguration.self, from: data)
        }
        guard let proto = mgr.protocolConfiguration as? NETunnelProviderProtocol,
              let data = proto.providerConfiguration?["configuration"] as? Data else {
            throw TunnelControllerError.unavailable
        }
        return try JSONDecoder().decode(ProxyConfiguration.self, from: data)
    }

    func start(_ configuration: ProxyConfiguration) async throws {
        if let active = try await restore() {
            guard active == configuration else { throw TunnelControllerError.connectionFailed }
            return
        }
        let mgr = try await prepare()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleID
        proto.serverAddress = "127.0.0.1"
        proto.providerConfiguration = ["configuration": try JSONEncoder().encode(configuration)]
        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "TG WS Proxy"
        mgr.isEnabled = true
        try await mgr.saveToPreferences()
        try await mgr.loadFromPreferences()
        guard let session = mgr.connection as? NETunnelProviderSession else {
            throw TunnelControllerError.unavailable
        }
        try session.startTunnel()
        for _ in 0..<40 {
            try Task.checkCancellation()
            switch session.status {
            case .connected: return
            case .invalid, .disconnecting: throw TunnelControllerError.connectionFailed
            case .disconnected, .connecting, .reasserting:
                try await Task.sleep(for: .milliseconds(200))
            @unknown default: throw TunnelControllerError.connectionFailed
            }
        }
        throw TunnelControllerError.timedOut
    }

    func stop() async {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        session.stopTunnel()
        // A stop must finish before another engine binds the same local port.
        for _ in 0..<40 {
            if session.status == .disconnected || session.status == .invalid { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        NSLog("VPN did not stop within 8 seconds")
    }

    func sendMessage(_ command: String) async -> String? {
        guard isConnected, let session = manager?.connection as? NETunnelProviderSession,
              let data = command.data(using: .utf8) else { return nil }
        return await withCheckedContinuation { continuation in
            let reply = TunnelReply(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { reply.finish(nil) }
            do {
                try session.sendProviderMessage(data) { response in
                    reply.finish(response.flatMap { String(data: $0, encoding: .utf8) })
                }
            } catch {
                reply.finish(nil)
            }
        }
    }
}
#endif
