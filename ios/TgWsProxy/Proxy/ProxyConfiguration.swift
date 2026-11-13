import Foundation
import Security

struct ProxyConfiguration: Codable, Equatable, Sendable {
    static let allowedPoolSizes = Array(0...16)
    var bindAddress = "127.0.0.1"
    var port = 1443
    var secret = ProxyConfiguration.makeSecret()
    var dcAddresses = ""
    var poolSize = 4
    var cloudflareEnabled = true
    var cloudflareDomain = ""
    var verboseLogging = false
    var bufferSizeKB = 256
    var workerDomains = ""
    var fakeTLSDomain = ""
    var disableSecure = false
    var forceTestDC = false
    var proxyProtocol = false
    var cachedCloudflareDomains: [String] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case bindAddress, port, secret, dcAddresses, poolSize, cloudflareEnabled
        case cloudflareDomain, verboseLogging, bufferSizeKB, workerDomains
        case fakeTLSDomain, disableSecure, forceTestDC, proxyProtocol, cachedCloudflareDomains
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Missing fields from older versions keep their defaults. A stored secret
        // is required so a damaged configuration never silently changes identity.
        secret = try c.decode(String.self, forKey: .secret)
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? bindAddress
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? port
        dcAddresses = try c.decodeIfPresent(String.self, forKey: .dcAddresses) ?? dcAddresses
        poolSize = try c.decodeIfPresent(Int.self, forKey: .poolSize) ?? poolSize
        cloudflareEnabled = try c.decodeIfPresent(Bool.self, forKey: .cloudflareEnabled) ?? cloudflareEnabled
        cloudflareDomain = try c.decodeIfPresent(String.self, forKey: .cloudflareDomain) ?? cloudflareDomain
        verboseLogging = try c.decodeIfPresent(Bool.self, forKey: .verboseLogging) ?? verboseLogging
        bufferSizeKB = try c.decodeIfPresent(Int.self, forKey: .bufferSizeKB) ?? bufferSizeKB
        workerDomains = try c.decodeIfPresent(String.self, forKey: .workerDomains) ?? workerDomains
        fakeTLSDomain = try c.decodeIfPresent(String.self, forKey: .fakeTLSDomain) ?? fakeTLSDomain
        disableSecure = try c.decodeIfPresent(Bool.self, forKey: .disableSecure) ?? disableSecure
        forceTestDC = try c.decodeIfPresent(Bool.self, forKey: .forceTestDC) ?? forceTestDC
        proxyProtocol = try c.decodeIfPresent(Bool.self, forKey: .proxyProtocol) ?? proxyProtocol
        cachedCloudflareDomains = try c.decodeIfPresent([String].self, forKey: .cachedCloudflareDomains) ?? cachedCloudflareDomains
    }

    var telegramSecret: String {
        let domain = fakeTLSDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if domain.isEmpty { return "dd" + secret }
        return "ee" + secret + domain.utf8.map { String(format: "%02x", $0) }.joined()
    }

    var validationError: String? {
        guard (1...65535).contains(port) else { return "Порт должен быть от 1 до 65535." }
        guard !bindAddress.isEmpty, !bindAddress.contains("\0") else { return "Укажите адрес прокси." }
        guard secret.count == 32, secret.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
        }) else { return "Некорректный secret. Сгенерируйте новый в настройках." }
        for domain in Self.domains(in: cloudflareDomain) + Self.domains(in: workerDomains)
            + (fakeTLSDomain.isEmpty ? [] : [fakeTLSDomain]) {
            guard Self.isValidDomain(domain) else { return "Некорректный домен: \(domain)" }
        }
        guard !dcAddresses.contains("\0") else { return "Некорректный адрес DC." }
        return nil
    }

    static func domains(in text: String) -> [String] {
        text.split { $0.isWhitespace || $0 == "," || $0 == ";" }.map(String.init)
    }

    private static func isValidDomain(_ domain: String) -> Bool {
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return domain.utf8.count <= 253 && labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45 }
        }
    }

    mutating func normalize() {
        poolSize = min(max(poolSize, 0), 16)
        bufferSizeKB = min(max(bufferSizeKB, 4), 4096)
        fakeTLSDomain = fakeTLSDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func makeSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            return UUID().uuidString
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
                .prefix(32)
                .description
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
