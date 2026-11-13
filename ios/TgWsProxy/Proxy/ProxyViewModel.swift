import Foundation
import Network
import os
import SwiftUI

@MainActor
final class ProxyViewModel: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case stopping
        case running
        case failed(String)
    }

    @Published private(set) var restoring = false
    @Published private(set) var refreshingDomains = false
    @Published private(set) var state: State = .stopped
    @Published private(set) var stats = ProxyStats.empty
    @Published private(set) var traffic: [TrafficSample] = []
    @Published private(set) var cloudflareDomains: [String] = []
    @Published var configuration: ProxyConfiguration {
        didSet { if !configurationLoadFailed { persistConfiguration() } }
    }

    private var lastSample: (up: Double, down: Double, at: Date)?
    private static let trafficWindow = 40

    private var configurationLoadFailed = false
    private var restored = false
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var startAttempt = 0
    private let engine: ProxyEngine
    private let defaults: UserDefaults
    private static let settingsKey = "proxy.configuration.v1"
    private static let maxReconnectAttempts = 3

    private var reconnectEnabled: Bool {
        defaults.object(forKey: "app.reconnect") as? Bool ?? true
    }

    init(defaults: UserDefaults = .standard, engine: ProxyEngine? = nil) {
        self.defaults = defaults
        self.engine = engine ?? ProxyEngineFactory.make()
        if let data = defaults.data(forKey: Self.settingsKey) {
            do {
                var value = try JSONDecoder().decode(ProxyConfiguration.self, from: data)
                value.normalize()
                configuration = value
            } catch {
                configuration = ProxyConfiguration()
                configurationLoadFailed = true
                state = .failed("Не удалось прочитать настройки. Восстановите их или явно сгенерируйте новый secret.")
                NSLog("Proxy configuration: %@", error.localizedDescription)
            }
        } else {
            configuration = ProxyConfiguration()
        }
        if !configurationLoadFailed { persistConfiguration() }
        reloadCloudflareDomains()
    }

    var isTransitioning: Bool { refreshingDomains || restoring || state == .starting || state == .stopping }
    var configurationLocked: Bool { isRunning || isTransitioning }

    func restore() async {
        guard !restored, state == .stopped else { return }
        restored = true
        restoring = true
        defer { restoring = false }
        do {
            if let active = try await engine.restore(), state == .stopped {
                configuration = active
                cloudflareDomains = active.cachedCloudflareDomains
                didStart()
            }
        } catch {
            NSLog("Restore VPN: %@", String(describing: error))
        }
    }

    var isRunning: Bool {
        state == .running
    }

    var statusTitle: String {
        switch state {
        case .stopped: "Не подключено".tgLoc
        case .starting: "Запуск…".tgLoc
        case .stopping: "Остановка…".tgLoc
        case .running: "Прокси работает".tgLoc
        case .failed: "Ошибка запуска".tgLoc
        }
    }

    var statusDetail: String {
        switch state {
        case .stopped:
            "Локальный MTProto".tgLoc + " · \(configuration.bindAddress):\(configuration.port)"
        case .starting:
            "Поднимаем Rust-ядро и WebSocket-пул".tgLoc
        case .stopping:
            "Закрываем соединения".tgLoc
        case .running:
            "Telegram → localhost → WSS → Telegram DC".tgLoc
        case .failed(let message):
            message
        }
    }

    var modeTitle: String { engine.mode.title }

    var diagnosticsContext: String {
        let c = configuration
        let s = stats
        return """
        Состояние: \(isRunning ? "запущен" : "остановлен")
        Режим: \(modeTitle)
        Адрес: \(c.bindAddress):\(c.port)
        Размер пула: \(c.poolSize)
        Cloudflare: \(c.cloudflareEnabled ? "вкл" : "выкл") \(c.cloudflareDomain)
        DC override: \(c.dcAddresses.isEmpty ? "—" : c.dcAddresses)
        Статистика: всего \(s.total), активных \(s.active), ws \(s.webSockets), \
        ↑\(s.uploaded) ↓\(s.downloaded), ошибок \(s.errors)
        Fronting: \(s.fronting), CF pool: \(s.cloudflarePool), masked: \(s.masked)
        """
    }

    var backgroundWarning: String? {
        guard !engine.runsInBackground else { return nil }
        guard !BackgroundKeeper.shared.isAuthorizedForBackground else { return nil }
        return "Без доступа к геопозиции в режиме «Всегда» прокси остановится, как только вы свернёте приложение.".tgLoc
    }

    func toggle() {
        if isRunning || state == .starting { stop() }
        else if state != .stopping { start() }
    }

    func start(isRetry: Bool = false) {
        guard !refreshingDomains, !restoring, !isRunning, state != .stopping, startTask == nil,
              state != .starting || isRetry else { return }
        guard !configurationLoadFailed else { return }
        var normalized = configuration
        normalized.normalize()
        if let error = normalized.validationError { didFail(error); return }
        configuration = normalized
        if !isRetry { startAttempt = 0 }
        reconnectTask?.cancel()
        state = .starting

        let configuration = configuration
        startTask = Task {
            let result = await engine.start(configuration)
            guard !Task.isCancelled else { return }
            startTask = nil

            if result == 0 {
                startAttempt = 0
                didStart()
            } else {
                handleStartFailure(result)
            }
        }
    }

    func stop() {
        Task { await stopAndWait() }
    }

    func stopAndWait(notify: Bool = true) async {
        if let stopTask { await stopTask.value; return }
        guard state != .stopped else { return }
        let wasRunning = isRunning
        state = .stopping
        reconnectTask?.cancel()
        reconnectTask = nil
        statsTask?.cancel()
        statsTask = nil
        let pendingStart = startTask
        pendingStart?.cancel()
        startAttempt = 0
        let task = Task {
            await pendingStart?.value
            await engine.stop()
            startTask = nil
            BackgroundKeeper.shared.deactivate()
            stats = .empty
            traffic = []
            lastSample = nil
            state = .stopped
            if notify, wasRunning {
                NotificationManager.post(title: "TG WS Proxy", body: "Прокси остановлен")
            }
        }
        stopTask = task
        await task.value
        stopTask = nil
    }

    func applyConfiguration(
        _ newConfiguration: ProxyConfiguration,
        start requestedStart: Bool?
    ) async {
        let shouldResume = requestedStart ?? isRunning
        if state != .stopped {
            await stopAndWait(notify: false)
        }
        configuration = newConfiguration
        if shouldResume {
            start()
        }
    }

    private func handleStartFailure(_ result: Int32) {
        let message = NativeProxyError.startFailed(result).localizedDescription
        if reconnectEnabled, startAttempt < Self.maxReconnectAttempts {
            startAttempt += 1
            state = .starting
            reconnectTask?.cancel()
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.reconnectTask = nil
                self?.start(isRetry: true)
            }
        } else {
            didFail(message)
        }
    }

    func telegramURL() -> URL? {
        let secret = configuration.telegramSecret
        var components = URLComponents()
        components.scheme = "tg"
        components.host = "proxy"
        components.queryItems = [
            URLQueryItem(name: "server", value: configuration.bindAddress),
            URLQueryItem(name: "port", value: String(configuration.port)),
            URLQueryItem(name: "secret", value: secret)
        ]
        return components.url
    }

    func regenerateSecret() {
        guard !configurationLocked else { return }
        configurationLoadFailed = false
        configuration.secret = ProxyConfiguration.makeSecret()
    }

    func reloadCloudflareDomains() {
        cloudflareDomains = NativeProxy.cloudflareDomains()
    }

    func refreshCloudflareDomains() async -> Bool {
        guard !configurationLocked else { return false }
        refreshingDomains = true
        defer { refreshingDomains = false }
        let refreshed = await NativeProxy.refreshCloudflareDomains()
        reloadCloudflareDomains()
        if refreshed { configuration.cachedCloudflareDomains = cloudflareDomains }
        return refreshed
    }

    private func didStart() {
        state = .running
        if !engine.runsInBackground {
            BackgroundKeeper.shared.activate()
        }
        lastSample = nil
        traffic = []
        Haptics.notify(.success)
        NotificationManager.post(title: "TG WS Proxy", body: "Прокси запущен")
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if let s = await self.engine.stats(), !Task.isCancelled {
                    self.stats = s
                    self.recordTraffic(s)
                }
                guard !Task.isCancelled else { return }

                if tick % 15 == 0, let domains = await self.engine.cloudflareDomains(), !Task.isCancelled {
                    self.cloudflareDomains = domains
                    if self.configuration.cloudflareDomain.isEmpty, self.configuration.cachedCloudflareDomains != domains {
                        self.configuration.cachedCloudflareDomains = domains
                    }
                }
                tick += 1
                if tick % 5 == 0, self.isRunning, !(await self.isListening()) {
                    await self.stopAndWait(notify: false)
                    self.handleStartFailure(-6)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func isListening() async -> Bool {
        let host = configuration.bindAddress
        guard let value = UInt16(exactly: configuration.port),
              let port = NWEndpoint.Port(rawValue: value) else { return false }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            let finished = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ alive: Bool) {
                let first = finished.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: alive)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish(false) }
        }
    }

    private func recordTraffic(_ s: ProxyStats) {
        let now = Date()
        if let last = lastSample {
            let dt = max(now.timeIntervalSince(last.at), 0.001)
            let up = max((s.uploadedBytes - last.up) / dt, 0)
            let down = max((s.downloadedBytes - last.down) / dt, 0)
            traffic.append(TrafficSample(time: now, up: up, down: down))
            if traffic.count > Self.trafficWindow {
                traffic.removeFirst(traffic.count - Self.trafficWindow)
            }
        }
        lastSample = (s.uploadedBytes, s.downloadedBytes, now)
    }

    private func didFail(_ message: String) {
        state = .failed(message)
        Haptics.notify(.error)
        NotificationManager.post(title: "TG WS Proxy", body: "Ошибка: \(message)")
    }

    private func persistConfiguration() {
        do {
            let data = try JSONEncoder().encode(configuration)
            defaults.set(data, forKey: Self.settingsKey)
        } catch {
            NSLog("Save proxy configuration: %@", error.localizedDescription)
        }
    }
}

struct TrafficSample: Identifiable {
    let id = UUID()
    let time: Date
    let up: Double
    let down: Double
}

struct ProxyStats: Sendable {
    var uploaded: String
    var downloaded: String
    var active: String
    var webSockets: String
    var total: String
    var tcpFallback: String
    var cloudflare: String
    var errors: String
    var pool: String
    var fronting: String
    var cloudflarePool: String
    var masked: String
    var uploadedBytes: Double
    var downloadedBytes: Double

    static let empty = ProxyStats(raw: "")

    init(rawValue: String) { self = ProxyStats(raw: rawValue) }

    private init(raw: String) {
        uploaded = Self.value(after: "up=", in: raw, fallback: "0 B")
        downloaded = Self.value(after: "down=", in: raw, fallback: "0 B")
        active = Self.value(after: "active=", in: raw, fallback: "0")
        webSockets = Self.value(after: "ws=", in: raw, fallback: "0")
        total = Self.value(after: "total=", in: raw, fallback: "0")
        tcpFallback = Self.value(after: "tcp_fb=", in: raw, fallback: "0")
        cloudflare = Self.value(after: "cf=", in: raw, fallback: "0")
        errors = Self.value(after: "err=", in: raw, fallback: "0")
        fronting = Self.value(after: "front=", in: raw, fallback: "0")
        cloudflarePool = Self.value(after: "cf_pool=", in: raw, fallback: "n/a")
        masked = Self.value(after: "masked=", in: raw, fallback: "0")
        pool = Self.value(after: "pool=", in: raw, fallback: "0/0")
        uploadedBytes = Double(Self.value(after: "up_bytes=", in: raw, fallback: ""))
            ?? Self.bytes(from: Self.value(after: "up=", in: raw, fallback: "0B"))
        downloadedBytes = Double(Self.value(after: "down_bytes=", in: raw, fallback: ""))
            ?? Self.bytes(from: Self.value(after: "down=", in: raw, fallback: "0B"))
    }

    private static func bytes(from s: String) -> Double {
        let multipliers: [(String, Double)] = [
            ("TB", 1099511627776), ("GB", 1073741824),
            ("MB", 1048576), ("KB", 1024), ("B", 1)
        ]
        for (suffix, mult) in multipliers where s.hasSuffix(suffix) {
            return (Double(s.dropLast(suffix.count)) ?? 0) * mult
        }
        return Double(s) ?? 0
    }

    private static func value(after key: String, in source: String, fallback: String) -> String {
        source.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix(key) }
            .map { String($0.dropFirst(key.count)) } ?? fallback
    }
}
