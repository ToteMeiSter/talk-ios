//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// What went wrong with one request of an upload, reduced to the facts the retry policy needs.
struct ChatFileUploadFailure: Codable, Equatable {

    /// HTTP status code of the answer of the server, if there was one.
    var httpStatusCode: Int?

    /// Code of the `NSURLErrorDomain` error, if the request failed on its way.
    var urlErrorCode: Int?

    /// Seconds the server asked us to wait, if it did.
    var retryAfter: TimeInterval?

    /// Why the system cancelled a background transfer (`NSURLErrorBackgroundTaskCancelledReasonKey`), if it did.
    var backgroundCancelReason: Int?

    init(httpStatusCode: Int? = nil, urlErrorCode: Int? = nil, retryAfter: TimeInterval? = nil, backgroundCancelReason: Int? = nil) {
        self.httpStatusCode = httpStatusCode
        self.urlErrorCode = urlErrorCode
        self.retryAfter = retryAfter
        self.backgroundCancelReason = backgroundCancelReason
    }

    /// Looks through the error (and the errors it wraps) for an HTTP status code or an URL error code.
    init(error: Error) {
        var httpStatusCode = ChatFileUploadRetryPolicy.httpStatusCode(of: error)
        var urlErrorCode = ChatFileUploadRetryPolicy.urlErrorCode(of: error)

        // Some of our own errors carry an HTTP status code in an NSURLErrorDomain error
        if httpStatusCode == nil, let code = urlErrorCode, code >= 100 {
            httpStatusCode = code
            urlErrorCode = nil
        }

        self.init(httpStatusCode: httpStatusCode,
                  urlErrorCode: urlErrorCode,
                  backgroundCancelReason: ChatFileUploadRetryPolicy.backgroundCancelReason(of: error))
    }
}

/// Decides what happens with an upload after a request failed.
///
/// Network problems never use up attempts, the upload goes on once the network is back. Only errors
/// answered by the server (5xx except 507, 408, 429) count against `maxServerErrors`. Everything else
/// (other 4xx, a full quota, certificate problems, cancelling) fails at once.
///
/// This type only knows about numbers and errors, so it can be used and tested without any networking.
enum ChatFileUploadRetryPolicy {

    /// Errors answered by the server one upload may hit before it is given up.
    static let maxServerErrors = 4

    /// How long a running process waits for the network to come back before it reports the upload as not sent.
    static let maxNetworkWait: TimeInterval = 15 * 60

    /// Longest pause between two attempts.
    static let maxDelay: TimeInterval = 60

    /// Longest pause we accept when the server sends a `Retry-After` header.
    static let maxRetryAfter: TimeInterval = 10 * 60

    private static let firstDelay: TimeInterval = 2

    /// The key AFNetworking stores the response under in the user info of its errors.
    private static let afNetworkingResponseKey = "com.alamofire.serialization.response.error.response"

    enum Kind: Equatable {
        /// No connection or a connection that broke. Retried without using up attempts.
        case network
        /// The server answered with an error that may go away. Retried a limited number of times.
        case server
        /// Waiting does not help.
        case permanent
    }

    enum Decision: Equatable {
        case retry(after: TimeInterval)
        case fail
    }

    // MARK: - Classification

    static func classify(_ failure: ChatFileUploadFailure) -> Kind {
        if let statusCode = failure.httpStatusCode {
            return self.classify(httpStatusCode: statusCode)
        }

        if let urlErrorCode = failure.urlErrorCode {
            return self.classify(urlErrorCode: urlErrorCode)
        }

        return .permanent
    }

    static func classify(error: Error) -> Kind {
        return self.classify(ChatFileUploadFailure(error: error))
    }

    /// Classifies the code an upload library reports: negative values are `NSURLErrorDomain` codes,
    /// values from 100 on are HTTP status codes.
    static func classify(errorCode: Int) -> Kind {
        if errorCode >= 100 {
            return self.classify(httpStatusCode: errorCode)
        }

        return self.classify(urlErrorCode: errorCode)
    }

    static func classify(httpStatusCode: Int) -> Kind {
        switch httpStatusCode {
        case 507:
            // The quota of the user is exhausted
            return .permanent
        case 408, 429:
            return .server
        case 500...599:
            return .server
        default:
            return .permanent
        }
    }

    static func classify(urlErrorCode: Int) -> Kind {
        switch urlErrorCode {
        case NSURLErrorTimedOut,                          // -1001
             NSURLErrorCannotFindHost,                    // -1003
             NSURLErrorCannotConnectToHost,               // -1004
             NSURLErrorNetworkConnectionLost,             // -1005
             NSURLErrorDNSLookupFailed,                   // -1006
             NSURLErrorNotConnectedToInternet,            // -1009
             NSURLErrorInternationalRoamingOff,           // -1018
             NSURLErrorCallIsActive,                      // -1019
             NSURLErrorDataNotAllowed,                    // -1020
             NSURLErrorBackgroundSessionInUseByAnotherProcess,   // -996
             NSURLErrorBackgroundSessionWasDisconnected,  // -997
             NSURLErrorSecureConnectionFailed:            // -1200
            // A TLS handshake that breaks when the network changes or a portal interferes. The errors about
            // the certificate itself (-1201 to -1206) are not in this list and stay permanent.
            return .network
        case NSURLErrorBadServerResponse,                 // -1011
             NSURLErrorCannotParseResponse,               // -1017
             NSURLErrorResourceUnavailable:               // -1008
            return .server
        default:
            // Includes -999 (cancelled), -1201 to -1206 (certificate problems) and
            // local problems like a missing file
            return .permanent
        }
    }

    // MARK: - Schedule

    /// Pause before the next attempt: 2, 4, 8, 16, 32 and then 60 seconds. A `Retry-After` of the server
    /// can make it longer, never shorter.
    ///
    /// - Parameter failureCount: Number of failures in a row so far, including the one being decided on.
    static func delay(forFailureCount failureCount: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        let exponent = min(max(failureCount - 1, 0), 10)
        let backoff = min(self.firstDelay * pow(2, Double(exponent)), self.maxDelay)

        guard let retryAfter, retryAfter > 0 else { return backoff }

        return max(backoff, min(retryAfter, self.maxRetryAfter))
    }

    /// - Parameters:
    ///   - serverErrorCount: Errors answered by the server so far, including the one being decided on.
    ///   - failureCount: Failures in a row so far, including the one being decided on. Only used for the pause.
    ///   - networkWait: How long the upload has been waiting for the network. `nil` for no limit.
    ///   - maxNetworkWait: How long the caller is willing to wait for the network.
    static func decision(for failure: ChatFileUploadFailure,
                         serverErrorCount: Int,
                         failureCount: Int,
                         networkWait: TimeInterval? = nil,
                         maxNetworkWait: TimeInterval = ChatFileUploadRetryPolicy.maxNetworkWait) -> Decision {
        let delay = self.delay(forFailureCount: failureCount, retryAfter: failure.retryAfter)

        switch self.classify(failure) {
        case .network:
            if let networkWait, networkWait > maxNetworkWait { return .fail }
            return .retry(after: delay)
        case .server:
            return serverErrorCount < self.maxServerErrors ? .retry(after: delay) : .fail
        case .permanent:
            return .fail
        }
    }

    // MARK: - Cancelled background transfers

    /// What a cancelled background transfer means.
    enum Cancellation: Equatable {
        /// The user terminated the app: iOS cancels all its background transfers, and they do not come back.
        case userForceQuit
        /// The system stopped the transfer, e.g. because background updates are off (Low Power Mode) or it ran
        /// short of resources. Sending again once the app is in front works.
        case system
        /// No reason given.
        case unknown
    }

    /// - Parameter reason: Value of `NSURLErrorBackgroundTaskCancelledReasonKey`:
    ///   0 `NSURLErrorCancelledReasonUserForceQuitApplication`, 1 `…BackgroundUpdatesDisabled`,
    ///   2 `…InsufficientSystemResources`.
    static func cancellation(forReason reason: Int?) -> Cancellation {
        switch reason {
        case 0: return .userForceQuit
        case 1, 2: return .system
        default: return .unknown
        }
    }

    static func backgroundCancelReason(of error: Error) -> Int? {
        for link in self.chain(of: error) {
            guard let value = link.nsError?.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] else { continue }

            if let number = value as? NSNumber { return number.intValue }
        }

        return nil
    }

    /// The beginning of the body an error response had, to be logged.
    static func responseBody(of error: Error, maxLength: Int = 300) -> String? {
        for link in self.chain(of: error) {
            guard let data = link.nsError?.userInfo["com.alamofire.serialization.response.error.data"] as? Data,
                  let body = String(data: data, encoding: .utf8)
            else { continue }

            return String(body.prefix(maxLength))
        }

        return nil
    }

    // MARK: - Duplicates

    /// Whether a refused announce means the file was announced by an earlier attempt already.
    ///
    /// The attachment endpoint moves the file out of the draft folder, so a second request for the same
    /// path answers 404 (`postAttachmentToRoom` in spreed, `getFileNode` throws `NotFoundException`).
    /// That is only a success when an earlier attempt may have got through, i.e. it ended without an
    /// answer. A 404 of the first attempt means the file is really gone.
    ///
    /// The files sharing API answers 403 "Path is already shared with this conversation" for the second
    /// share of a path, which `NCAPIController.shareFileOrFolder` already counts as success.
    static func isAlreadyAnnounced(_ failure: ChatFileUploadFailure, viaDraftFolder: Bool, earlierAttemptMayHaveSucceeded: Bool) -> Bool {
        return viaDraftFolder && earlierAttemptMayHaveSucceeded && failure.httpStatusCode == 404
    }

    // MARK: - Extracting facts from errors

    static func httpStatusCode(of error: Error) -> Int? {
        for link in self.chain(of: error) {
            if let statusCode = link.httpStatusCode { return statusCode }
        }

        return nil
    }

    static func urlErrorCode(of error: Error) -> Int? {
        for link in self.chain(of: error) {
            guard let nsError = link.nsError else { continue }

            if nsError.domain == NSURLErrorDomain {
                return nsError.code
            }

            if nsError.domain == NSPOSIXErrorDomain {
                switch nsError.code {
                case 32, 50, 51, 54, 57, 60, 61:
                    // EPIPE, ENETDOWN, ENETUNREACH, ECONNRESET, ENOTCONN, ETIMEDOUT, ECONNREFUSED
                    return NSURLErrorNetworkConnectionLost
                default:
                    continue
                }
            }
        }

        return nil
    }

    /// Value of a `Retry-After` header: a number of seconds, or a date.
    static func retryAfter(fromHeaderValue value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }

        if let seconds = TimeInterval(value) {
            return seconds >= 0 ? seconds : nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        guard let date = formatter.date(from: value) else { return nil }

        return max(date.timeIntervalSince(now), 0)
    }

    private struct ChainLink {
        var nsError: NSError?
        var httpStatusCode: Int?
    }

    /// The error itself and the errors it wraps, outermost first.
    private static func chain(of error: Error) -> [ChainLink] {
        var result: [ChainLink] = []
        var current: Error? = error

        while let error = current, result.count < 6 {
            // Has to be checked on the Error itself, converting an OcsError to an NSError loses the OcsError
            if let ocsError = error as? OcsError {
                let statusCode = ocsError.responseStatusCode
                result.append(ChainLink(nsError: nil, httpStatusCode: statusCode > 0 ? statusCode : nil))
                current = ocsError.underlyingError
                continue
            }

            let nsError = error as NSError
            let response = nsError.userInfo[self.afNetworkingResponseKey] as? HTTPURLResponse
            result.append(ChainLink(nsError: nsError, httpStatusCode: response?.statusCode))
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }

        return result
    }
}
