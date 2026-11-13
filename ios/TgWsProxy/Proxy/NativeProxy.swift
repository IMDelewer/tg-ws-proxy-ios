import Foundation

enum NativeProxyError: LocalizedError {
    case startFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .startFailed(let code):
            switch code {
            case -1:
                return "Прокси уже запущен."
            case -2:
                return "Некорректный порт или secret."
            case -3:
                return "Порт занят. Закройте другой прокси или смените порт в настройках."
            case -4:
                return "Нет доступа к кэшу приложения."
            default:
                return "Rust-ядро не запустилось (код \(code))"
            }
        }
    }
}

enum NativeProxy {
    static func start(configuration: ProxyConfiguration) -> Int32 {
        guard configuration.validationError == nil else { return -2 }
        SetPoolSize(Int32(min(max(configuration.poolSize, 0), 16)))
        SetBufferSizeKb(Int32(min(max(configuration.bufferSizeKB, 4), 4096)))
        SetDisableSecure(configuration.disableSecure ? 1 : 0)
        SetForceTestDc(configuration.forceTestDC ? 1 : 0)
        SetProxyProtocol(configuration.proxyProtocol ? 1 : 0)
        configuration.workerDomains.withCString { SetCfWorkerDomains($0) }
        configuration.fakeTLSDomain.withCString { SetFakeTlsDomain($0) }
        guard prepareCache() else { return -4 }
        configuration.cachedCloudflareDomains.joined(separator: "\n").withCString { SetCfProxyDomains($0) }
        configuration.cloudflareDomain.withCString {
            SetCfProxyConfig(configuration.cloudflareEnabled ? 1 : 0, 1, $0)
        }

        let result = configuration.bindAddress.withCString { host in
            configuration.dcAddresses.withCString { addresses in
                configuration.secret.withCString { secret in
                    StartProxy(
                        host,
                        Int32(configuration.port),
                        addresses,
                        secret,
                        configuration.verboseLogging ? 1 : 0
                    )
                }
            }
        }

        return result
    }

    @discardableResult
    static func prepareCache() -> Bool {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }
        let directory = base.appendingPathComponent("TgWsProxy", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Keep the list previously stored by older releases.
            if let old = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("cfproxy-domains-cache.txt") {
                let destination = directory.appendingPathComponent(old.lastPathComponent)
                if FileManager.default.fileExists(atPath: old.path),
                   !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.copyItem(at: old, to: destination)
                }
            }
            directory.path.withCString { SetCfProxyCacheDir($0) }
            return true
        } catch {
            NSLog("CF storage: %@", error.localizedDescription)
            return false
        }
    }

    static func stop() {
        _ = StopProxy()
    }

    static func stats() -> String {
        guard let pointer = GetStats() else { return "" }
        defer { FreeString(pointer) }
        return String(cString: pointer)
    }

    static func secretWithPrefix() -> String? {
        guard let pointer = GetSecretWithPrefix() else { return nil }
        defer { FreeString(pointer) }
        return String(cString: pointer)
    }

    static func cloudflareDomains() -> [String] {
        guard prepareCache() else { return [] }
        guard let pointer = GetCfProxyDomains() else { return [] }
        defer { FreeString(pointer) }
        return String(cString: pointer)
            .split(separator: "\n")
            .map(String.init)
    }

    static func refreshCloudflareDomains() async -> Bool {
        await Task.detached(priority: .utility) {
            guard prepareCache() else { return false }
            "".withCString { SetCfProxyConfig(1, 1, $0) }
            return RefreshCfProxyDomains() == 1
        }.value
    }
}
