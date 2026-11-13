import Foundation

enum ProxyMode {
    case loopback
    case tunnel

    var title: String {
        switch self {
        case .loopback: "Локальный режим".tgLoc
        case .tunnel: "VPN-туннель".tgLoc
        }
    }
}

@MainActor
protocol ProxyEngine: AnyObject {
    var mode: ProxyMode { get }
    var runsInBackground: Bool { get }

    func start(_ configuration: ProxyConfiguration) async -> Int32
    func stop() async
    func restore() async throws -> ProxyConfiguration?
    func cloudflareDomains() async -> [String]?
    func stats() async -> ProxyStats?
}

extension ProxyEngine {
    func restore() async throws -> ProxyConfiguration? { nil }
    func cloudflareDomains() async -> [String]? { NativeProxy.cloudflareDomains() }
}

final class LoopbackEngine: ProxyEngine {
    let mode: ProxyMode = .loopback
    let runsInBackground = false

    func start(_ configuration: ProxyConfiguration) async -> Int32 {
        await Task.detached(priority: .userInitiated) {
            NativeProxy.start(configuration: configuration)
        }.value
    }

    func stop() async {
        await Task.detached(priority: .userInitiated) {
            NativeProxy.stop()
        }.value
    }

    func stats() async -> ProxyStats? {
        let raw = await Task.detached(priority: .utility) {
            NativeProxy.stats()
        }.value
        return ProxyStats(rawValue: raw)
    }

}

@MainActor
enum ProxyEngineFactory {
    static func make() -> ProxyEngine {
#if TGWS_TUNNEL_AVAILABLE
        return TunnelEngine()
#else
        return LoopbackEngine()
#endif
    }
}
