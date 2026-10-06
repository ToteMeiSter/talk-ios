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
///
/// The evaluation without network runs first, for all hosts. The evaluation with network (fetching of missing
/// intermediates via AIA) is a reserve for a rotation of the Let's Encrypt intermediates and for CAs without built-in
/// intermediates. WebRTC calls `verify` synchronously on its shared network thread, so the online evaluation runs
/// only if the offline one failed for all hosts, and at most once per minute per verifier, whatever the certificate is.
final class NCTurnCertificateVerifier: NSObject, RTCSSLCertificateVerifier {

    private struct CacheKey: Hashable {
        let derCertificate: Data
        let host: String
    }

    private struct CacheEntry {
        let isTrusted: Bool
        let expiresAt: Date
    }

    private static let positiveCacheLifetime: TimeInterval = 60 * 60
    private static let negativeCacheLifetime: TimeInterval = 60
    private static let onlineEvaluationInterval: TimeInterval = 60
    private static let maxCacheEntries = 64

    /// Used only to build the certification path, see `NCTurnIntermediateCertificates`
    private static let intermediateCertificates: [SecCertificate] = NCTurnIntermediateCertificates.all.compactMap {
        guard let data = Data(base64Encoded: $0.base64) else { return nil }
        return SecCertificateCreateWithData(nil, data as CFData)
    }

    let hosts: [String]

    private let verifyDate: Date?
    private let isNetworkFetchAllowed: Bool
    private let testAnchors: [SecCertificate]?
    private let testAdditionalCertificates: [SecCertificate]
    private let lock = NSLock()
    private var cache: [CacheKey: CacheEntry] = [:]
    private var lastOnlineEvaluation: Date?

    /// Number of started online evaluations. For tests.
    private(set) var onlineEvaluationCount = 0

    /// - Parameters:
    ///   - hosts: Host names (or IP addresses) of the TURNS servers. Without hosts nothing is trusted.
    ///   - verifyDate: Date to evaluate the chain at. `nil` means now. Only for tests.
    ///   - allowsNetworkFetch: Allows the rate-limited online evaluation. Only for tests.
    ///   - anchors: Replaces the system trust store with these anchors. Only for tests, never set it in production code.
    ///   - additionalCertificates: Untrusted certificates for building the path, like the intermediates. Only for tests.
    init(hosts: [String], verifyDate: Date? = nil, allowsNetworkFetch: Bool = true, anchors: [SecCertificate]? = nil, additionalCertificates: [SecCertificate] = []) {
        self.hosts = hosts
        self.verifyDate = verifyDate
        self.isNetworkFetchAllowed = allowsNetworkFetch
        self.testAnchors = anchors
        self.testAdditionalCertificates = additionalCertificates

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

        var uncachedHosts: [String] = []

        for host in hosts {
            switch cachedResult(for: CacheKey(derCertificate: derCertificate, host: host)) {
            case .some(true): return true
            case .none: uncachedHosts.append(host)
            case .some(false): break
            }
        }

        // All hosts have a cached refusal, nothing new to log
        guard !uncachedHosts.isEmpty else { return false }

        // Offline evaluation for all hosts first
        for host in uncachedHosts where evaluate(certificate, host: host, networkFetchAllowed: false) {
            store(true, for: CacheKey(derCertificate: derCertificate, host: host))
            return true
        }

        // Online evaluation only if the offline one failed for all hosts, and rate limited
        if reserveOnlineEvaluation() {
            for host in uncachedHosts where evaluate(certificate, host: host, networkFetchAllowed: true) {
                store(true, for: CacheKey(derCertificate: derCertificate, host: host))
                return true
            }
        }

        for host in uncachedHosts {
            store(false, for: CacheKey(derCertificate: derCertificate, host: host))
        }

        NCLog.log("NCTurnCertificateVerifier: Certificate of the TURNS server is not trusted by the system (\(hosts.count) host(s))")

        return false
    }

    // MARK: - Private

    private func evaluate(_ certificate: SecCertificate, host: String, networkFetchAllowed: Bool) -> Bool {
        let policy = SecPolicyCreateSSL(true, host as CFString)
        var createdTrust: SecTrust?

        let certificates = [certificate] + testAdditionalCertificates + NCTurnCertificateVerifier.intermediateCertificates

        guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &createdTrust) == errSecSuccess, let trust = createdTrust else {
            return false
        }

        // Without test anchors no anchors are set: only the system trust store is used
        if let testAnchors {
            _ = SecTrustSetAnchorCertificates(trust, testAnchors as CFArray)
            _ = SecTrustSetAnchorCertificatesOnly(trust, true)
        }

        if let verifyDate {
            _ = SecTrustSetVerifyDate(trust, verifyDate as CFDate)
        }

        _ = SecTrustSetNetworkFetchAllowed(trust, networkFetchAllowed)

        return SecTrustEvaluateWithError(trust, nil)
    }

    /// Allows an online evaluation at most once per `onlineEvaluationInterval`, whatever the certificate is
    private func reserveOnlineEvaluation() -> Bool {
        guard isNetworkFetchAllowed else { return false }

        lock.lock()
        defer { lock.unlock() }

        let now = Date()

        if let lastOnlineEvaluation, now.timeIntervalSince(lastOnlineEvaluation) < NCTurnCertificateVerifier.onlineEvaluationInterval {
            return false
        }

        lastOnlineEvaluation = now
        onlineEvaluationCount += 1

        return true
    }

    private func cachedResult(for key: CacheKey) -> Bool? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = cache[key] else { return nil }

        if entry.expiresAt < Date() {
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

        let lifetime = isTrusted ? NCTurnCertificateVerifier.positiveCacheLifetime : NCTurnCertificateVerifier.negativeCacheLifetime
        cache[key] = CacheEntry(isTrusted: isTrusted, expiresAt: Date().addingTimeInterval(lifetime))
    }
}
