//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Security
import WebRTC

/// Verifies the certificate of a TURNS server against the iOS system trust store.
///
/// WebRTC checks the certificate of a TURNS server against its own built-in list of root certificates. That list
/// does not contain ISRG Root X1/X2, so a TURNS server with a Let's Encrypt certificate is rejected.
///
/// WebRTC calls the verifier only when its own check failed, and passes only the certificate of the server (the leaf),
/// without the intermediate certificates and without the type of the error. A returned `true` clears the error.
/// The host name is still checked by WebRTC itself.
///
/// The leaf is evaluated for the host names of the `turns:` ICE servers of the peer connection with the system trust
/// store as the only source of trust. The built-in Let's Encrypt intermediates are only a hint to build the path:
/// they are never trust anchors, and the anchors are never changed. If the system does not trust the chain, the
/// result is `false`, as it was without this verifier.
final class NCTurnCertificateVerifier: NSObject, RTCSSLCertificateVerifier {

    private struct CacheKey: Hashable {
        let derCertificate: Data
        let host: String
    }

    private struct CacheEntry {
        let isTrusted: Bool
        let expiresAt: Date?
    }

    private static let negativeCacheLifetime: TimeInterval = 60
    private static let maxCacheEntries = 64

    /// Used only to build the certification path, see `NCTurnIntermediateCertificates`
    private static let intermediateCertificates: [SecCertificate] = NCTurnIntermediateCertificates.all.compactMap {
        guard let data = Data(base64Encoded: $0.base64) else { return nil }
        return SecCertificateCreateWithData(nil, data as CFData)
    }

    let hosts: [String]

    private let verifyDate: Date?
    private let isNetworkFetchAllowed: Bool
    private let lock = NSLock()
    private var cache: [CacheKey: CacheEntry] = [:]

    /// - Parameters:
    ///   - hosts: Host names (or IP addresses) of the TURNS servers. Without hosts nothing is trusted.
    ///   - verifyDate: Date to evaluate the chain at. `nil` means now. For tests.
    ///   - allowsNetworkFetch: Allows a second evaluation with fetching of missing intermediates (AIA). For tests.
    init(hosts: [String], verifyDate: Date? = nil, allowsNetworkFetch: Bool = true) {
        self.hosts = hosts
        self.verifyDate = verifyDate
        self.isNetworkFetchAllowed = allowsNetworkFetch

        super.init()
    }

    /// Returns `nil` if the ICE servers do not contain a `turns:` URL
    convenience init?(iceServers: [RTCIceServer]) {
        let hosts = NCTurnCertificateVerifier.turnsHosts(from: iceServers.flatMap { $0.urlStrings })

        guard !hosts.isEmpty else { return nil }

        self.init(hosts: hosts)
    }

    /// Extracts the unique host names of all `turns:` URLs, for example `turns:host:443?transport=tcp`,
    /// `turns:[2001:db8::1]:443` or `turns:host`. URLs with other schemes and malformed URLs are skipped.
    static func turnsHosts(from urlStrings: [String]) -> [String] {
        var hosts: [String] = []

        for urlString in urlStrings {
            let trimmed = urlString.trimmingCharacters(in: .whitespaces)

            guard trimmed.lowercased().hasPrefix("turns:") else { continue }

            var rest = String(trimmed.dropFirst("turns:".count))

            if rest.hasPrefix("//") {
                rest = String(rest.dropFirst(2))
            }

            if let queryIndex = rest.firstIndex(of: "?") {
                rest = String(rest[..<queryIndex])
            }

            var host: String

            if rest.hasPrefix("[") {
                // IPv6 literal, the port (if any) follows the closing bracket
                guard let closingIndex = rest.firstIndex(of: "]") else { continue }
                host = String(rest[rest.index(after: rest.startIndex)..<closingIndex])
            } else if let portIndex = rest.firstIndex(of: ":") {
                host = String(rest[..<portIndex])
            } else {
                host = rest
            }

            host = host.lowercased()

            if !host.isEmpty, !hosts.contains(host) {
                hosts.append(host)
            }
        }

        return hosts
    }

    // MARK: - RTCSSLCertificateVerifier

    func verify(_ derCertificate: Data) -> Bool {
        guard !hosts.isEmpty, let certificate = SecCertificateCreateWithData(nil, derCertificate as CFData) else {
            return false
        }

        for host in hosts where isTrusted(certificate, derCertificate: derCertificate, host: host) {
            return true
        }

        NCLog.log("NCTurnCertificateVerifier: Certificate of the TURNS server is not trusted by the system (\(hosts.count) host(s))")

        return false
    }

    // MARK: - Private

    private func isTrusted(_ certificate: SecCertificate, derCertificate: Data, host: String) -> Bool {
        let key = CacheKey(derCertificate: derCertificate, host: host)

        if let cached = cachedResult(for: key) {
            return cached
        }

        // First without the network, as WebRTC calls us synchronously on its network thread. A second evaluation
        // with the network (AIA) is only a reserve for a rotation of the Let's Encrypt intermediates.
        var result = evaluate(certificate, host: host, networkFetchAllowed: false)

        if !result, isNetworkFetchAllowed {
            result = evaluate(certificate, host: host, networkFetchAllowed: true)
        }

        store(result, for: key)

        return result
    }

    private func evaluate(_ certificate: SecCertificate, host: String, networkFetchAllowed: Bool) -> Bool {
        let policy = SecPolicyCreateSSL(true, host as CFString)
        var createdTrust: SecTrust?

        let certificates = [certificate] + NCTurnCertificateVerifier.intermediateCertificates

        guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &createdTrust) == errSecSuccess, let trust = createdTrust else {
            return false
        }

        // No anchors are set: only the system trust store is used
        if let verifyDate {
            _ = SecTrustSetVerifyDate(trust, verifyDate as CFDate)
        }

        _ = SecTrustSetNetworkFetchAllowed(trust, networkFetchAllowed)

        return SecTrustEvaluateWithError(trust, nil)
    }

    private func cachedResult(for key: CacheKey) -> Bool? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = cache[key] else { return nil }

        if let expiresAt = entry.expiresAt, expiresAt < Date() {
            cache[key] = nil
            return nil
        }

        return entry.isTrusted
    }

    private func store(_ isTrusted: Bool, for key: CacheKey) {
        lock.lock()
        defer { lock.unlock() }

        if cache.count >= NCTurnCertificateVerifier.maxCacheEntries {
            cache.removeAll()
        }

        let expiresAt = isTrusted ? nil : Date().addingTimeInterval(NCTurnCertificateVerifier.negativeCacheLifetime)
        cache[key] = CacheEntry(isTrusted: isTrusted, expiresAt: expiresAt)
    }
}
