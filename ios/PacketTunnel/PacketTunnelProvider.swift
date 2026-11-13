import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var activeConfiguration: ProxyConfiguration?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let configuration: ProxyConfiguration
        do {
            configuration = try loadConfiguration()
            if let message = configuration.validationError {
                throw NSError(domain: "TgWsProxy", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        } catch {
            completionHandler(error)
            return
        }
        activeConfiguration = configuration
        DispatchQueue.global(qos: .userInitiated).async {
            let code = NativeProxy.start(configuration: configuration)
            guard code == 0 else {
                completionHandler(
                    NSError(
                        domain: "TgWsProxy",
                        code: Int(code),
                        userInfo: [NSLocalizedDescriptionKey: "StartProxy failed (\(code))"]
                    )
                )
                return
            }

            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
            let ipv4 = NEIPv4Settings(addresses: ["10.7.0.2"], subnetMasks: ["255.255.255.255"])
            ipv4.includedRoutes = []
            ipv4.excludedRoutes = [NEIPv4Route.default()]
            settings.ipv4Settings = ipv4
            settings.mtu = 1500

            self.setTunnelNetworkSettings(settings) { error in
                if error != nil {
                    NativeProxy.stop()
                }
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            NativeProxy.stop()
            completionHandler()
        }
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        guard let command = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        let response: String
        switch command {
        case "stats":  response = NativeProxy.stats()
        case "secret": response = NativeProxy.secretWithPrefix() ?? ""
        case "domains": response = NativeProxy.cloudflareDomains().joined(separator: "\n")
        case "configuration":
            guard var configuration = activeConfiguration else { completionHandler?(nil); return }
            if configuration.cloudflareDomain.isEmpty {
                configuration.cachedCloudflareDomains = NativeProxy.cloudflareDomains()
            }
            completionHandler?(try? JSONEncoder().encode(configuration))
            return
        default:       response = ""
        }
        completionHandler?(response.data(using: .utf8))
    }

    private func loadConfiguration() throws -> ProxyConfiguration {
        guard
            let proto = protocolConfiguration as? NETunnelProviderProtocol,
            let raw = proto.providerConfiguration?["configuration"] as? Data
        else {
            throw NSError(domain: "TgWsProxy", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Missing proxy configuration"])
        }
        return try JSONDecoder().decode(ProxyConfiguration.self, from: raw)
    }
}
