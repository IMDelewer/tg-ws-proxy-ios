import Foundation

// Host-side substitutes for device services; the model/configuration/engine
// protocol are compiled directly from the application sources by the runner.
extension String { var tgLoc: String { self } }
enum Feedback { case success, error }
enum Haptics { static func notify(_ feedback: Feedback) {} }
enum NotificationManager { static func post(title: String, body: String) {} }
@MainActor
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()
    var isAuthorizedForBackground = true
    func activate() {}
    func deactivate() {}
}
enum NativeProxyError: LocalizedError {
    case startFailed(Int32)
}
enum NativeProxy {
    static func start(configuration: ProxyConfiguration) -> Int32 { 0 }
    static func stop() {}
    static func stats() -> String { "" }
    static func cloudflareDomains() -> [String] { [] }
    static func refreshCloudflareDomains() async -> Bool { false }
}

#if TGWS_TUNNEL_AVAILABLE
@MainActor
final class TunnelController {
    static let shared = TunnelController()
    var failStart = false
    var replies: [String?] = []
    func restore() async throws -> ProxyConfiguration? { nil }
    func start(_ configuration: ProxyConfiguration) async throws {
        if failStart { throw NSError(domain: "test", code: 1) }
    }
    func stop() async {}
    func sendMessage(_ command: String) async -> String? { replies.removeFirst() }
}
#endif

@MainActor
final class TestEngine: ProxyEngine {
    let mode: ProxyMode = .loopback
    let runsInBackground = false
    var starts = 0
    var stops = 0
    var results: [Int32] = [0]
    var slowStart = false
    func start(_ configuration: ProxyConfiguration) async -> Int32 {
        starts += 1
        if slowStart {
            // Native startup cannot be cancelled halfway through its bind.
            await Task.detached { try? await Task.sleep(for: .milliseconds(80)) }.value
        }
        return results.removeFirst()
    }
    func stop() async { stops += 1 }
    func stats() async -> ProxyStats? { .empty }
}

@MainActor
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

@MainActor
func runRegressions() async throws {
    let suite = "tgws.regressions." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let key = "proxy.configuration.v1"
    let first = ProxyViewModel(defaults: defaults, engine: TestEngine())
    expect(defaults.data(forKey: key) != nil, "Initial config must be persisted")
    first.configuration.cachedCloudflareDomains = ["alpha.co.uk", "beta.co.uk", "gamma.co.uk"]
    let second = ProxyViewModel(defaults: defaults, engine: TestEngine())
    expect(first.configuration.secret == second.configuration.secret, "Secret changed on relaunch")

    expect(second.configuration.cachedCloudflareDomains == first.configuration.cachedCloudflareDomains, "Worker list lost on relaunch")

    let old = Data("{\"secret\":\"0123456789abcdef0123456789abcdef\",\"port\":1443,\"poolSize\":6}".utf8)
    defaults.set(old, forKey: key)
    let migrated = ProxyViewModel(defaults: defaults, engine: TestEngine())
    expect(migrated.configuration.secret == "0123456789abcdef0123456789abcdef", "Migration lost secret")
    expect(migrated.configuration.bufferSizeKB == 256, "Migration must default new fields")
    expect(!migrated.configuration.disableSecure, "Migration must preserve WSS default")
    var config = migrated.configuration
    config.fakeTLSDomain = "example.com"
    expect(config.telegramSecret == "ee0123456789abcdef0123456789abcdef6578616d706c652e636f6d", "Invalid ee secret")
    config.port = 65536
    expect(config.validationError != nil, "Out-of-range port accepted")
    config.port = -1
    expect(config.validationError != nil, "Negative port accepted")
    config.port = 1443
    config.poolSize = 0
    config.normalize()
    expect(config.poolSize == 0, "Pool-off setting was clamped away")

    defaults.set(Data("broken".utf8), forKey: key)
    let brokenEngine = TestEngine()
    let broken = ProxyViewModel(defaults: defaults, engine: brokenEngine)
    broken.configuration.port = 2443
    broken.start()
    expect(brokenEngine.starts == 0, "Damaged settings must block startup")
    expect(defaults.data(forKey: key) == Data("broken".utf8), "Damaged config was silently overwritten")

    defaults.set(old, forKey: key)
    let engine = TestEngine()
    engine.slowStart = true
    let model = ProxyViewModel(defaults: defaults, engine: engine)
    model.start()
    try await Task.sleep(for: .milliseconds(10))
    await model.stopAndWait(notify: false)
    expect(model.state == .stopped && engine.stops == 1, "Late start escaped stop")

    let retryEngine = TestEngine()
    retryEngine.results = [-3, 0]
    let retry = ProxyViewModel(defaults: defaults, engine: retryEngine)
    retry.start()
    for _ in 0..<90 {
        if retry.isRunning { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    expect(retryEngine.starts == 2 && retry.isRunning, "Retry was blocked by starting state")
    await retry.stopAndWait(notify: false)

    let stats = ProxyStats(rawValue: "cf_pool=7/8 pool=1/2 up=1.0MB down=2.0MB up_bytes=1048593 down_bytes=2097199")
    expect(stats.pool == "1/2" && stats.cloudflarePool == "7/8", "Stats keys collided")
    expect(stats.uploadedBytes == 1048593 && stats.downloadedBytes == 2097199, "Traffic uses rounded values")
#if TGWS_TUNNEL_AVAILABLE
    let tunnel = TunnelEngine()
    let result = await tunnel.start(ProxyConfiguration())
    expect(result == 0 && tunnel.runsInBackground, "VPN did not start")
    TunnelController.shared.replies = [nil, "up_bytes=42 down_bytes=84"]
    let unavailable = await tunnel.stats()
    expect(unavailable == nil && tunnel.mode == .tunnel, "Transient stats failure switched engines")
    let recovered = await tunnel.stats()
    expect(recovered?.uploadedBytes == 42, "VPN statistics did not recover")
    await tunnel.stop()
    TunnelController.shared.failStart = true
    let fallbackResult = await tunnel.start(ProxyConfiguration())
    expect(fallbackResult == 0 && tunnel.mode == .loopback && !tunnel.runsInBackground,
           "Fallback must request local background keeping")
    await tunnel.stop()
#endif
    print("Swift regression tests passed")
}

Task { @MainActor in
    do {
        try await runRegressions()
        exit(0)
    } catch {
        fputs("Swift regression failure: \(error)\n", stderr)
        exit(1)
    }
}
dispatchMain()
