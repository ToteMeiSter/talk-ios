//
// SPDX-FileCopyrightText: 2024 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

@objcMembers public class NCPushProxySessionManager: NCBaseSessionManager {

    public static let shared = NCPushProxySessionManager()

    init() {
        let configuration = URLSessionConfiguration.default
        super.init(configuration: configuration, responseSerializer: AFHTTPResponseSerializer(), requestSerializer: AFHTTPRequestSerializer())

        self.userAgent += " (Strict VoIP)"
        self.updateUserAgent()

        // As we can run max. 30s in the background, we need to lower the default timeout from 60s to something < 30s.
        // Otherwise our app can be killed when trying to register while in the background
        self.requestSerializer.timeoutInterval = 25
    }

    /// Describes a failed push proxy request with its HTTP status code, the domain and code of the error and the masked answer of the server,
    /// e.g. to find out why a registration was rejected with a 400. The description of the error is not part of it, it can hold the URL.
    public static func failureDescription(forTask task: URLSessionDataTask?, error: Error) -> String {
        let statusCode = (task?.response as? HTTPURLResponse)?.statusCode
        var description = "HTTP status: \(statusCode.map { String($0) } ?? "none")"

        if let data = (error as NSError).userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey] as? Data,
           let body = loggableBody(from: data) {
            description += ", body: \(body)"
        }

        return "\(description), error: \(NCLog.errorCode(error))"
    }

    private static let maxBodyLength = 500
    private static let reasonKeys = ["message", "error", "reason", "status", "code"]

    // The answer of the push proxy is not documented and the log is exported by the user, so the answer is masked before it is written:
    // a JSON answer only keeps the fields of a reason, URLs, accounts (user@server) and long token-like strings (push token, push token hash,
    // device identifier, signature, public key) are replaced.
    private static let maskingRules: [(NSRegularExpression, String)] = [
        ("https?://\\S+", "<url>"),
        ("[^\\s@]+@[^\\s@]+", "<account>"),
        ("[A-Za-z0-9+/=_:-]{40,}|(?=[A-Za-z0-9+/=_:-]*\\d)[A-Za-z0-9+/=_:-]{20,}", "<redacted>")
    ].compactMap { rule in
        (try? NSRegularExpression(pattern: rule.0)).map { ($0, rule.1) }
    }

    static func loggableBody(from data: Data) -> String? {
        // The input is cut before it is masked, so a token that crosses the limit is never left half readable
        let raw = data.prefix(4096)
        guard var body = String(data: raw, encoding: .utf8) else { return nil }

        if let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            body = reasonKeys.compactMap { key -> String? in
                guard let value = json[key] as? String ?? (json[key] as? NSNumber)?.stringValue else { return nil }
                return "\(key)=\(value)"
            }.joined(separator: ", ")
        }

        for (regex, replacement) in maskingRules {
            body = regex.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: replacement)
        }

        body = body.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return body.isEmpty ? nil : String(body.prefix(maxBodyLength))
    }

}
