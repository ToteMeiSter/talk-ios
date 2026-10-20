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

    /// Describes a failed push proxy request with its HTTP status code and the domain and code of the error, e.g. to find out why a registration was rejected with a 400.
    /// The answer of the server and the description of the error (it can hold the URL) are not part of it, the log is exported by the user.
    public static func failureDescription(forTask task: URLSessionDataTask?, error: Error) -> String {
        let statusCode = (task?.response as? HTTPURLResponse)?.statusCode

        return "HTTP status: \(statusCode.map { String($0) } ?? "none"), error: \(NCLog.errorCode(error))"
    }

}
