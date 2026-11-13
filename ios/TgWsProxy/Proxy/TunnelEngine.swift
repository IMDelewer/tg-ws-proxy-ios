#if TGWS_TUNNEL_AVAILABLE
import Foundation

@MainActor
final class TunnelEngine: ProxyEngine {
    var mode: ProxyMode { usingFallback ? .loopback : .tunnel }
    var runsInBackground: Bool { !usingFallback }

    private let controller = TunnelController.shared
    private let fallback = LoopbackEngine()
    private var usingFallback = false

    func restore() async throws -> ProxyConfiguration? {
        try await controller.restore()
    }

    func start(_ configuration: ProxyConfiguration) async -> Int32 {
        do {
            try await controller.start(configuration)
            usingFallback = false
            return 0
        } catch {
            NSLog("VPN start: %@", String(describing: error))
            await controller.stop()
            guard !Task.isCancelled else { return -5 }
            usingFallback = true
            return await fallback.start(configuration)
        }
    }

    func stop() async {
        if usingFallback { await fallback.stop() }
        else { await controller.stop() }
        usingFallback = false
    }

    func stats() async -> ProxyStats? {
        if usingFallback { return await fallback.stats() }
        guard let raw = await controller.sendMessage("stats"), !raw.isEmpty else { return nil }
        return ProxyStats(rawValue: raw)
    }

    func cloudflareDomains() async -> [String]? {
        if usingFallback { return NativeProxy.cloudflareDomains() }
        guard let raw = await controller.sendMessage("domains") else { return nil }
        return raw.split(separator: "\n").map(String.init)
    }
}
#endif
