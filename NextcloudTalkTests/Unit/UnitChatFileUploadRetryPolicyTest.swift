//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitChatFileUploadRetryPolicyTest: XCTestCase {

    func testNetworkErrorsAreRetried() {
        let codes = [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
                     NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
                     NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed, NSURLErrorBackgroundSessionWasDisconnected]

        for code in codes {
            XCTAssertEqual(ChatFileUploadRetryPolicy.classify(urlErrorCode: code), .network, "code \(code)")
        }
    }

    func testBrokenTlsHandshakeIsANetworkError() {
        XCTAssertEqual(ChatFileUploadRetryPolicy.classify(urlErrorCode: NSURLErrorSecureConnectionFailed), .network)
    }

    func testCertificateAndCancelErrorsAreNotRetried() {
        for code in -1206 ... -1201 {
            XCTAssertEqual(ChatFileUploadRetryPolicy.classify(urlErrorCode: code), .permanent, "code \(code)")
        }

        XCTAssertEqual(ChatFileUploadRetryPolicy.classify(urlErrorCode: NSURLErrorCancelled), .permanent)
        XCTAssertEqual(ChatFileUploadRetryPolicy.classify(urlErrorCode: NSURLErrorFileDoesNotExist), .permanent)
    }

    func testCancellationReasons() {
        XCTAssertEqual(ChatFileUploadRetryPolicy.cancellation(forReason: 0), .userForceQuit)
        XCTAssertEqual(ChatFileUploadRetryPolicy.cancellation(forReason: 1), .system)
        XCTAssertEqual(ChatFileUploadRetryPolicy.cancellation(forReason: 2), .system)
        XCTAssertEqual(ChatFileUploadRetryPolicy.cancellation(forReason: nil), .unknown)
        XCTAssertEqual(ChatFileUploadRetryPolicy.cancellation(forReason: 42), .unknown)
    }

    func testCancellationReasonIsReadFromTheError() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: [NSURLErrorBackgroundTaskCancelledReasonKey: 1])
        let failure = ChatFileUploadFailure(error: error)

        XCTAssertEqual(failure.urlErrorCode, NSURLErrorCancelled)
        XCTAssertEqual(failure.backgroundCancelReason, 1)
        XCTAssertNil(ChatFileUploadFailure(error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)).backgroundCancelReason)
    }

    func testCallerCanLimitTheWaitForTheNetwork() {
        let failure = ChatFileUploadFailure(urlErrorCode: NSURLErrorNotConnectedToInternet)

        XCTAssertEqual(ChatFileUploadRetryPolicy.decision(for: failure, serverErrorCount: 0, failureCount: 1, networkWait: 31, maxNetworkWait: 30), .fail)
        XCTAssertNotEqual(ChatFileUploadRetryPolicy.decision(for: failure, serverErrorCount: 0, failureCount: 1, networkWait: 31), .fail)
    }

    func testHttpStatusCodes() {
        for code in [500, 502, 503, 504, 599, 408, 429] {
            XCTAssertEqual(ChatFileUploadRetryPolicy.classify(httpStatusCode: code), .server, "code \(code)")
        }

        for code in [400, 401, 403, 404, 409, 413, 422, 423, 507] {
            XCTAssertEqual(ChatFileUploadRetryPolicy.classify(httpStatusCode: code), .permanent, "code \(code)")
        }
    }

    func testErrorCodeOfUploadLibrary() {
        XCTAssertEqual(ChatFileUploadRetryPolicy.classify(errorCode: -1009), .network)
        XCTAssertEqual(ChatFileUploadRetryPolicy.classify(errorCode: 503), .server)
        XCTAssertEqual(ChatFileUploadRetryPolicy.classify(errorCode: 507), .permanent)
        XCTAssertEqual(ChatFileUploadRetryPolicy.classify(errorCode: 0), .permanent)
    }

    func testFailureFromErrors() {
        let urlError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        XCTAssertEqual(ChatFileUploadFailure(error: urlError), ChatFileUploadFailure(urlErrorCode: NSURLErrorNetworkConnectionLost))
        XCTAssertEqual(ChatFileUploadRetryPolicy.classify(error: urlError), .network)

        // A wrapped error is found as well
        let wrapped = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: urlError])
        XCTAssertEqual(ChatFileUploadFailure(error: wrapped).urlErrorCode, NSURLErrorNetworkConnectionLost)

        // Some errors carry an HTTP status in the URL error domain
        let httpLike = NSError(domain: NSURLErrorDomain, code: 503)
        XCTAssertEqual(ChatFileUploadFailure(error: httpLike), ChatFileUploadFailure(httpStatusCode: 503))

        let posixReset = NSError(domain: NSPOSIXErrorDomain, code: 54)
        XCTAssertEqual(ChatFileUploadRetryPolicy.classify(error: posixReset), .network)

        let unknown = NSError(domain: "unknown", code: 5)
        XCTAssertEqual(ChatFileUploadRetryPolicy.classify(error: unknown), .permanent)
    }

    func testDelaySchedule() {
        let delays = (1 ... 8).map { ChatFileUploadRetryPolicy.delay(forFailureCount: $0) }
        XCTAssertEqual(delays, [2, 4, 8, 16, 32, 60, 60, 60])

        XCTAssertEqual(ChatFileUploadRetryPolicy.delay(forFailureCount: 0), 2)
        XCTAssertEqual(ChatFileUploadRetryPolicy.delay(forFailureCount: 1000), 60)
    }

    func testRetryAfterOnlyMakesTheDelayLonger() {
        XCTAssertEqual(ChatFileUploadRetryPolicy.delay(forFailureCount: 1, retryAfter: 30), 30)
        XCTAssertEqual(ChatFileUploadRetryPolicy.delay(forFailureCount: 6, retryAfter: 5), 60)
        XCTAssertEqual(ChatFileUploadRetryPolicy.delay(forFailureCount: 1, retryAfter: 100_000), ChatFileUploadRetryPolicy.maxRetryAfter)
    }

    func testRetryAfterHeader() {
        XCTAssertEqual(ChatFileUploadRetryPolicy.retryAfter(fromHeaderValue: "120"), 120)
        XCTAssertNil(ChatFileUploadRetryPolicy.retryAfter(fromHeaderValue: nil))
        XCTAssertNil(ChatFileUploadRetryPolicy.retryAfter(fromHeaderValue: "soon"))

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let later = now.addingTimeInterval(90)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        let seconds = ChatFileUploadRetryPolicy.retryAfter(fromHeaderValue: formatter.string(from: later), now: now)
        XCTAssertEqual(seconds ?? -1, 90, accuracy: 1)
    }

    func testNetworkErrorsDoNotUseUpAttempts() {
        let failure = ChatFileUploadFailure(urlErrorCode: NSURLErrorNotConnectedToInternet)

        // Even with a high count of server errors and failures
        XCTAssertEqual(ChatFileUploadRetryPolicy.decision(for: failure, serverErrorCount: 10, failureCount: 3), .retry(after: 8))
    }

    func testNetworkWaitHasACeiling() {
        let failure = ChatFileUploadFailure(urlErrorCode: NSURLErrorTimedOut)

        XCTAssertEqual(ChatFileUploadRetryPolicy.decision(for: failure, serverErrorCount: 0, failureCount: 20, networkWait: 60), .retry(after: 60))
        XCTAssertEqual(ChatFileUploadRetryPolicy.decision(for: failure, serverErrorCount: 0, failureCount: 20, networkWait: ChatFileUploadRetryPolicy.maxNetworkWait + 1), .fail)
    }

    func testServerErrorsAreLimited() {
        let failure = ChatFileUploadFailure(httpStatusCode: 503)

        for count in 1 ..< ChatFileUploadRetryPolicy.maxServerErrors {
            XCTAssertEqual(ChatFileUploadRetryPolicy.decision(for: failure, serverErrorCount: count, failureCount: count), .retry(after: ChatFileUploadRetryPolicy.delay(forFailureCount: count)))
        }

        XCTAssertEqual(ChatFileUploadRetryPolicy.decision(for: failure, serverErrorCount: ChatFileUploadRetryPolicy.maxServerErrors, failureCount: 4), .fail)
        XCTAssertEqual(ChatFileUploadRetryPolicy.maxServerErrors, 4)
    }

    func testTooManyRequestsHonoursRetryAfter() {
        let failure = ChatFileUploadFailure(httpStatusCode: 429, retryAfter: 45)

        XCTAssertEqual(ChatFileUploadRetryPolicy.decision(for: failure, serverErrorCount: 1, failureCount: 1), .retry(after: 45))
    }

    func testPermanentErrorsFailAtOnce() {
        XCTAssertEqual(ChatFileUploadRetryPolicy.decision(for: ChatFileUploadFailure(httpStatusCode: 507), serverErrorCount: 1, failureCount: 1), .fail)
        XCTAssertEqual(ChatFileUploadRetryPolicy.decision(for: ChatFileUploadFailure(httpStatusCode: 403), serverErrorCount: 1, failureCount: 1), .fail)
        XCTAssertEqual(ChatFileUploadRetryPolicy.decision(for: ChatFileUploadFailure(urlErrorCode: -1202), serverErrorCount: 1, failureCount: 1), .fail)
        XCTAssertEqual(ChatFileUploadRetryPolicy.decision(for: ChatFileUploadFailure(), serverErrorCount: 1, failureCount: 1), .fail)
    }

    func testUnknownAttachmentFolderIsAnErrorThatIsNotRetried() {
        let code = ChatFileUploadRetryPolicy.attachmentFolderUnknownCode

        // 0 is "the folder is there", so it must not be the code of an error. It is an URL error as the
        // uploader hands codes below 100 to the policy as such.
        XCTAssertNotEqual(code, 0)
        XCTAssertLessThan(code, 100)

        let failure = ChatFileUploadFailure(urlErrorCode: code)

        XCTAssertEqual(ChatFileUploadRetryPolicy.classify(failure), .permanent)
        XCTAssertEqual(ChatFileUploadRetryPolicy.classify(errorCode: code), .permanent)
        XCTAssertEqual(ChatFileUploadRetryPolicy.decision(for: failure, serverErrorCount: 0, failureCount: 1), .fail)
    }

    func testAlreadyAnnounced() {
        let notFound = ChatFileUploadFailure(httpStatusCode: 404)

        // The file of the draft folder is gone, which is only fine when an earlier request might have moved it
        XCTAssertTrue(ChatFileUploadRetryPolicy.isAlreadyAnnounced(notFound, viaDraftFolder: true, earlierAttemptMayHaveSucceeded: true))
        XCTAssertFalse(ChatFileUploadRetryPolicy.isAlreadyAnnounced(notFound, viaDraftFolder: true, earlierAttemptMayHaveSucceeded: false))
        XCTAssertFalse(ChatFileUploadRetryPolicy.isAlreadyAnnounced(notFound, viaDraftFolder: false, earlierAttemptMayHaveSucceeded: true))
        XCTAssertFalse(ChatFileUploadRetryPolicy.isAlreadyAnnounced(ChatFileUploadFailure(httpStatusCode: 500), viaDraftFolder: true, earlierAttemptMayHaveSucceeded: true))
    }
}
