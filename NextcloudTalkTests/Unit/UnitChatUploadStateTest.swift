//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitChatUploadStateTest: XCTestCase {

    private let now: TimeInterval = 1_700_000_000

    private func makeState(kind: ChatUploadState.DestinationKind = .draftFolder) -> ChatUploadState {
        return ChatUploadState(id: "ref-1",
                               accountId: "account-1",
                               roomToken: "token1",
                               fileName: "photo.jpg",
                               localFileName: "ref-1.jpg",
                               destinationKind: kind,
                               draftPath: kind == .draftFolder ? "Talk/room/Draft/abc.jpg" : nil,
                               serverPath: "/Talk/room/Draft/abc.jpg",
                               serverURL: "https://cloud.example.com/remote.php/dav/files/user/Talk/room/Draft/abc.jpg",
                               createdAt: now)
    }

    // MARK: - Transfer

    func testSuccessfulTransferMovesToAnnounce() {
        var state = makeState()

        XCTAssertEqual(state.transferFinished(failure: nil, now: now), .announce(after: 0))
        XCTAssertEqual(state.step, .uploaded)
        XCTAssertTrue(state.fileUploaded)
    }

    func testNetworkErrorsRetryForeverWithoutCounting() {
        var state = makeState()
        let failure = ChatFileUploadFailure(urlErrorCode: NSURLErrorNetworkConnectionLost)

        for _ in 0 ..< 50 {
            guard case .startTransfer = state.transferFinished(failure: failure, now: now + 60) else {
                return XCTFail("Network errors need to be retried")
            }
        }

        XCTAssertEqual(state.serverErrorCount, 0)
        XCTAssertEqual(state.step, .uploading)
    }

    func testServerErrorsGiveUpAfterTheLimit() {
        var state = makeState()
        let failure = ChatFileUploadFailure(httpStatusCode: 503)

        for _ in 1 ..< ChatFileUploadRetryPolicy.maxServerErrors {
            guard case .startTransfer = state.transferFinished(failure: failure, now: now) else {
                return XCTFail("Server errors need to be retried at first")
            }
        }

        XCTAssertEqual(state.transferFinished(failure: failure, now: now), .failed)
        XCTAssertEqual(state.step, .failed)
        XCTAssertFalse(state.fileUploaded)
    }

    func testPermanentErrorFailsAtOnce() {
        var state = makeState()

        XCTAssertEqual(state.transferFinished(failure: ChatFileUploadFailure(httpStatusCode: 507), now: now), .failed)
        XCTAssertEqual(state.step, .failed)

        // The cancellation by the system
        var cancelled = makeState()
        XCTAssertEqual(cancelled.transferFinished(failure: ChatFileUploadFailure(urlErrorCode: NSURLErrorCancelled), now: now), .failed)
    }

    func testUploadsExpire() {
        var state = makeState()
        let failure = ChatFileUploadFailure(urlErrorCode: NSURLErrorNotConnectedToInternet)

        XCTAssertEqual(state.transferFinished(failure: failure, now: now + ChatUploadState.maxAge + 1), .failed)
        XCTAssertEqual(state.failureReason, "expired")
    }

    func testPausesGrowAndResetAfterSuccess() {
        var state = makeState()
        let failure = ChatFileUploadFailure(urlErrorCode: NSURLErrorTimedOut)

        XCTAssertEqual(state.transferFinished(failure: failure, now: now), .startTransfer(after: 2))
        XCTAssertEqual(state.transferFinished(failure: failure, now: now), .startTransfer(after: 4))
        XCTAssertEqual(state.transferFinished(failure: nil, now: now), .announce(after: 0))
        XCTAssertEqual(state.failureCount, 0)
    }

    func testEventsOfOtherStepsAreIgnored() {
        var state = makeState()
        _ = state.transferFinished(failure: nil, now: now)

        // A second delivery of the same event
        XCTAssertEqual(state.transferFinished(failure: nil, now: now), .none)
        XCTAssertEqual(state.transferFinished(failure: ChatFileUploadFailure(httpStatusCode: 500), now: now), .none)
        XCTAssertEqual(state.step, .uploaded)
    }

    // MARK: - Announce

    private func uploadedState(kind: ChatUploadState.DestinationKind = .draftFolder) -> ChatUploadState {
        var state = makeState(kind: kind)
        _ = state.transferFinished(failure: nil, now: now)
        return state
    }

    func testAnnounceSucceeds() {
        var state = uploadedState()

        XCTAssertTrue(state.beginAnnounce())
        XCTAssertTrue(state.announceInFlight)
        XCTAssertEqual(state.announceFinished(failure: nil, now: now), .finished)
        XCTAssertEqual(state.step, .announced)
        XCTAssertFalse(state.announceInFlight)
    }

    func testNothingToAnnounceBeforeTheUpload() {
        var state = makeState()

        XCTAssertFalse(state.beginAnnounce())
    }

    func testAnnounceIsNotStartedTwiceAfterItFinished() {
        var state = uploadedState()

        XCTAssertTrue(state.beginAnnounce())
        _ = state.announceFinished(failure: nil, now: now)

        XCTAssertFalse(state.beginAnnounce())
        XCTAssertEqual(state.announceFinished(failure: nil, now: now), .none)
    }

    func testRepeatedAnnounceAfterLostAnswerFindsTheFileMovedAndCountsAsDone() {
        var state = uploadedState()

        XCTAssertTrue(state.beginAnnounce())
        XCTAssertEqual(state.announceFinished(failure: ChatFileUploadFailure(urlErrorCode: NSURLErrorNetworkConnectionLost), now: now), .announce(after: 2))
        XCTAssertTrue(state.announceMayHaveSucceeded)

        // The file is gone from the draft folder, because the first request moved it
        XCTAssertTrue(state.beginAnnounce())
        XCTAssertEqual(state.announceFinished(failure: ChatFileUploadFailure(httpStatusCode: 404), now: now), .finished)
        XCTAssertEqual(state.step, .announced)
    }

    func testNotFoundOfTheFirstAnnounceIsAFailure() {
        var state = uploadedState()

        XCTAssertTrue(state.beginAnnounce())
        XCTAssertEqual(state.announceFinished(failure: ChatFileUploadFailure(httpStatusCode: 404), now: now), .failed)
        XCTAssertEqual(state.step, .failed)
        // The file is on the server, a retry must not upload it again
        XCTAssertTrue(state.fileUploaded)
    }

    func testAnnounceAfterTheProcessDiedDuringTheRequest() {
        var state = uploadedState()
        XCTAssertTrue(state.beginAnnounce())

        // Stored with announceInFlight, read back after a relaunch
        state.recoverAfterRelaunch()

        XCTAssertFalse(state.announceInFlight)
        XCTAssertTrue(state.announceMayHaveSucceeded)

        XCTAssertTrue(state.beginAnnounce())
        XCTAssertEqual(state.announceFinished(failure: ChatFileUploadFailure(httpStatusCode: 404), now: now), .finished)
    }

    func testDefiniteRefusalDoesNotMakeLaterNotFoundASuccess() {
        var state = uploadedState()

        XCTAssertTrue(state.beginAnnounce())
        // The conversation does not allow us to chat, definite answer
        XCTAssertEqual(state.announceFinished(failure: ChatFileUploadFailure(httpStatusCode: 403), now: now), .failed)
        XCTAssertFalse(state.announceMayHaveSucceeded)
    }

    func testAnnounceServerErrorsAreLimited() {
        var state = uploadedState()
        let failure = ChatFileUploadFailure(httpStatusCode: 500)

        for _ in 1 ..< ChatFileUploadRetryPolicy.maxServerErrors {
            XCTAssertTrue(state.beginAnnounce())
            guard case .announce = state.announceFinished(failure: failure, now: now) else {
                return XCTFail("Needs to retry")
            }
        }

        XCTAssertTrue(state.beginAnnounce())
        XCTAssertEqual(state.announceFinished(failure: failure, now: now), .failed)
        XCTAssertEqual(state.step, .failed)
        XCTAssertTrue(state.fileUploaded)
    }

    func testAttachmentFolderNeverTreatsNotFoundAsDone() {
        var state = uploadedState(kind: .attachmentFolder)

        XCTAssertTrue(state.beginAnnounce())
        _ = state.announceFinished(failure: ChatFileUploadFailure(urlErrorCode: NSURLErrorTimedOut), now: now)

        XCTAssertTrue(state.beginAnnounce())
        XCTAssertEqual(state.announceFinished(failure: ChatFileUploadFailure(httpStatusCode: 404), now: now), .failed)
    }

    // MARK: - Attachment folder

    func testMissingAttachmentFolderIsCreatedOnce() {
        for status in [404, 409] {
            var state = makeState(kind: .attachmentFolder)
            let failure = ChatFileUploadFailure(httpStatusCode: status)

            XCTAssertEqual(state.transferFinished(failure: failure, now: now), .recreateAttachmentFolder, "status \(status)")
            XCTAssertTrue(state.attachmentFolderRecreated)

            // Still missing after it was created: the failure is the one of any other
            XCTAssertEqual(state.transferFinished(failure: failure, now: now), .failed, "status \(status)")
        }
    }

    func testDraftFolderDoesNotCreateTheAttachmentFolder() {
        var state = makeState(kind: .draftFolder)

        XCTAssertEqual(state.transferFinished(failure: ChatFileUploadFailure(httpStatusCode: 409), now: now), .failed)
    }

    func testRetryByTheUserMayCreateTheFolderAgain() {
        var state = makeState(kind: .attachmentFolder)
        _ = state.transferFinished(failure: ChatFileUploadFailure(httpStatusCode: 404), now: now)
        _ = state.transferFinished(failure: ChatFileUploadFailure(httpStatusCode: 404), now: now)

        XCTAssertEqual(state.prepareRetry(now: now), .startTransfer(after: 0))
        XCTAssertEqual(state.transferFinished(failure: ChatFileUploadFailure(httpStatusCode: 404), now: now), .recreateAttachmentFolder)
    }

    // MARK: - Cancelled by the system

    private func cancellation(reason: Int?) -> ChatFileUploadFailure {
        return ChatFileUploadFailure(urlErrorCode: NSURLErrorCancelled, backgroundCancelReason: reason)
    }

    func testCancelByUserForceQuitFails() {
        var state = makeState()

        XCTAssertEqual(state.transferFinished(failure: cancellation(reason: 0), now: now), .failed)
        XCTAssertEqual(state.step, .failed)
    }

    func testCancelByTheSystemWaitsForTheApp() {
        for reason in [1, 2] {
            var state = makeState()

            XCTAssertEqual(state.transferFinished(failure: cancellation(reason: reason), now: now), .suspended)
            XCTAssertEqual(state.step, .uploading)
            XCTAssertTrue(state.suspendedBySystem)

            state.transferStarted(inBackground: false)
            XCTAssertFalse(state.suspendedBySystem)
        }
    }

    func testCancelWithoutReasonFails() {
        var state = makeState()

        XCTAssertEqual(state.transferFinished(failure: cancellation(reason: nil), now: now), .failed)
    }

    func testCancelByTheAppItselfStartsAgain() {
        var state = makeState()
        state.transferStarted(inBackground: true)
        XCTAssertTrue(state.startedInBackground)

        state.prepareRestartFromForeground()

        XCTAssertEqual(state.transferFinished(failure: cancellation(reason: 0), now: now), .startTransfer(after: 0))
        XCTAssertEqual(state.step, .uploading)
        XCTAssertFalse(state.expectedCancel)
        XCTAssertFalse(state.startedInBackground)

        // The planned cancellation is used up: the next one is not the app's own
        XCTAssertEqual(state.transferFinished(failure: cancellation(reason: 0), now: now), .failed)
    }

    func testPlannedCancelIsForgottenWhenAnotherResultCameFirst() {
        var state = makeState()
        state.prepareRestartFromForeground()

        _ = state.transferFinished(failure: ChatFileUploadFailure(httpStatusCode: 503), now: now)

        XCTAssertFalse(state.expectedCancel)
    }

    func testExpiryIsTheSameForRestartAndFailures() {
        let state = makeState()

        XCTAssertFalse(state.isExpired(now: now + ChatUploadState.maxAge))
        XCTAssertTrue(state.isExpired(now: now + ChatUploadState.maxAge + 1))
    }

    func testBeginAnnounceOnTopOfARequestInFlightRemembersItMayHaveSucceeded() {
        var state = uploadedState(kind: .draftFolder)
        XCTAssertTrue(state.beginAnnounce())
        XCTAssertFalse(state.announceMayHaveSucceeded)

        // The state of the request that never ended is read again (no `recoverAfterRelaunch` in between)
        XCTAssertTrue(state.beginAnnounce())
        XCTAssertTrue(state.announceMayHaveSucceeded)

        // A 404 of the draft folder then means that the file was moved already
        XCTAssertEqual(state.announceFinished(failure: ChatFileUploadFailure(httpStatusCode: 404), now: now), .finished)
    }

    func testNotFoundIsNoSuccessWithoutAnEarlierRequest() {
        var state = uploadedState(kind: .draftFolder)
        XCTAssertTrue(state.beginAnnounce())

        XCTAssertNotEqual(state.announceFinished(failure: ChatFileUploadFailure(httpStatusCode: 404), now: now), .finished)
        XCTAssertNotEqual(state.step, .announced)
    }

    // MARK: - Pause of the server

    func testRetryAfterIsKeptAsEarliestBegin() {
        var state = makeState()
        let failure = ChatFileUploadFailure(httpStatusCode: 429, retryAfter: 600)

        XCTAssertEqual(state.transferFinished(failure: failure, now: now), .startTransfer(after: 600))
        XCTAssertEqual(state.earliestBeginAt, now + 600)
        XCTAssertEqual(state.remainingPause(now: now + 60), 540)
        XCTAssertEqual(state.remainingPause(now: now + 601), 0)
    }

    func testRemainingPauseIsCappedWhenTheClockWasSetBack() {
        var state = makeState()
        _ = state.transferFinished(failure: ChatFileUploadFailure(httpStatusCode: 429, retryAfter: 600), now: now)

        // The clock jumped back by a day
        XCTAssertEqual(state.remainingPause(now: now - 24 * 60 * 60), ChatFileUploadRetryPolicy.maxRetryAfter)

        state.earliestBeginAt = now + 10_000
        XCTAssertEqual(state.remainingPause(now: now), ChatFileUploadRetryPolicy.maxRetryAfter)
    }

    func testRestartFromForegroundKeepsTheRestOfThePause() {
        var state = makeState()
        _ = state.transferFinished(failure: ChatFileUploadFailure(httpStatusCode: 429, retryAfter: 600), now: now)
        state.transferStarted(inBackground: true)
        state.prepareRestartFromForeground()

        // The user opens the app a minute later and the task is cancelled by the app
        let action = state.transferFinished(failure: ChatFileUploadFailure(urlErrorCode: NSURLErrorCancelled), now: now + 60)

        XCTAssertEqual(action, .startTransfer(after: 540))
        // No attempt was made, so nothing was used up
        XCTAssertEqual(state.serverErrorCount, 1)
    }

    func testRestartFromForegroundAfterThePauseStartsAtOnce() {
        var state = makeState()
        _ = state.transferFinished(failure: ChatFileUploadFailure(httpStatusCode: 503), now: now)
        state.prepareRestartFromForeground()

        XCTAssertEqual(state.transferFinished(failure: ChatFileUploadFailure(urlErrorCode: NSURLErrorCancelled), now: now + 3600), .startTransfer(after: 0))
    }

    func testRestartWithoutAKnownPauseUsesTheBackoffOfOldStates() {
        var state = makeState()
        state.failureCount = 2
        state.prepareRestartFromForeground()

        XCTAssertNil(state.earliestBeginAt)
        XCTAssertEqual(state.transferFinished(failure: ChatFileUploadFailure(urlErrorCode: NSURLErrorCancelled), now: now), .startTransfer(after: ChatFileUploadRetryPolicy.delay(forFailureCount: 2)))
    }

    func testEarliestBeginIsClearedByResultAndByRetry() {
        var state = makeState()
        _ = state.transferFinished(failure: ChatFileUploadFailure(httpStatusCode: 429, retryAfter: 60), now: now)
        XCTAssertNotNil(state.earliestBeginAt)

        _ = state.transferFinished(failure: nil, now: now + 60)
        XCTAssertNil(state.earliestBeginAt)

        XCTAssertTrue(state.beginAnnounce())
        _ = state.announceFinished(failure: ChatFileUploadFailure(httpStatusCode: 503, retryAfter: 30), now: now + 61)
        XCTAssertEqual(state.earliestBeginAt, now + 91)

        state.fail(reason: "test")
        _ = state.prepareRetry(now: now + 100)
        XCTAssertNil(state.earliestBeginAt)
    }

    func testStateWithoutEarliestBeginIsReadable() throws {
        var state = makeState()
        _ = state.transferFinished(failure: ChatFileUploadFailure(httpStatusCode: 429, retryAfter: 60), now: now)

        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(ChatUploadState.self, from: data).earliestBeginAt, now + 60)

        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "earliestBeginAt")
        let old = try JSONDecoder().decode(ChatUploadState.self, from: JSONSerialization.data(withJSONObject: json))

        XCTAssertNil(old.earliestBeginAt)
        XCTAssertEqual(old.remainingPause(now: now), 0)
    }

    // MARK: - Posted uploads

    func testPostedUploadKeepsAMarkWithTheTime() {
        var state = uploadedState(kind: .draftFolder)

        XCTAssertTrue(state.beginAnnounce())
        XCTAssertEqual(state.announceFinished(failure: nil, now: now), .finished)
        XCTAssertEqual(state.step, .announced)
        XCTAssertEqual(state.announcedAt, now)
    }

    func testAPostedUploadCannotBeSentAgain() {
        var state = uploadedState(kind: .draftFolder)
        _ = state.beginAnnounce()
        _ = state.announceFinished(failure: nil, now: now)

        XCTAssertEqual(state.prepareRetry(now: now), .none)
        state.fail(reason: "late")
        XCTAssertEqual(state.step, .announced)
    }

    func testPostedMarkOutlivesTheTimeAMessageCanBeResent() {
        var state = uploadedState(kind: .draftFolder)
        state.step = .announced
        state.announcedAt = now

        // A voice message is resent from the recording, which stays: the mark must outlive the 48 hours of old
        XCTAssertFalse(state.isAnnouncedRetentionOver(now: now + 3 * 24 * 60 * 60))
        XCTAssertFalse(state.isAnnouncedRetentionOver(now: now + ChatUploadState.failedRetention))
        XCTAssertTrue(state.isAnnouncedRetentionOver(now: now + ChatUploadState.failedRetention + 1))
        XCTAssertGreaterThanOrEqual(ChatUploadState.announcedRetention, ChatUploadState.failedRetention)
    }

    func testPostedMarkWithoutTimeIsOver() {
        var state = uploadedState(kind: .draftFolder)
        state.step = .announced

        XCTAssertTrue(state.isAnnouncedRetentionOver(now: now))
    }

    // MARK: - Retry by the user

    func testRetryAfterFailedTransferUploadsAgain() {
        var state = makeState()
        _ = state.transferFinished(failure: ChatFileUploadFailure(httpStatusCode: 403), now: now)

        XCTAssertEqual(state.prepareRetry(now: now + 100), .startTransfer(after: 0))
        XCTAssertEqual(state.step, .uploading)
        XCTAssertEqual(state.createdAt, now + 100)
        XCTAssertEqual(state.serverErrorCount, 0)
    }

    func testRetryAfterFailedAnnounceOnlyAnnounces() {
        var state = uploadedState()
        _ = state.beginAnnounce()
        _ = state.announceFinished(failure: ChatFileUploadFailure(httpStatusCode: 403), now: now)

        XCTAssertEqual(state.prepareRetry(now: now), .announce(after: 0))
        XCTAssertEqual(state.step, .uploaded)
        XCTAssertTrue(state.beginAnnounce())
    }

    func testRetryOnlyFromFailed() {
        var state = makeState()
        XCTAssertEqual(state.prepareRetry(now: now), .none)
    }

    func testFailedStateIsKeptWhenFailingTwice() {
        var announced = uploadedState()
        _ = announced.beginAnnounce()
        _ = announced.announceFinished(failure: nil, now: now)
        announced.fail(reason: "late")
        XCTAssertEqual(announced.step, .announced)
    }

    // MARK: - Destination

    func testDestinationIsStoredAndRestored() {
        var state = makeState()
        state.destinationKind = nil
        state.draftPath = nil
        state.serverPath = nil
        state.serverURL = nil
        XCTAssertNil(state.destination)

        state.setDestination(.draftFolder(draftPath: "Talk/Draft/a.jpg", serverPath: "/Talk/Draft/a.jpg", serverURL: "https://cloud.example.com/a.jpg"))
        XCTAssertTrue(state.isDraftFolder)
        XCTAssertEqual(state.destination?.serverURL, "https://cloud.example.com/a.jpg")

        guard case .draftFolder(let draftPath, _, _)? = state.destination else { return XCTFail("Expected the draft folder") }
        XCTAssertEqual(draftPath, "Talk/Draft/a.jpg")

        state.setDestination(.attachmentFolder(serverPath: "/Talk/b.jpg", serverURL: "https://cloud.example.com/b.jpg"))
        XCTAssertFalse(state.isDraftFolder)
        XCTAssertNil(state.draftPath)
        XCTAssertEqual(state.destination?.serverPath, "/Talk/b.jpg")
    }

    // MARK: - Serialization

    func testStateSurvivesEncodingAndDecoding() throws {
        var state = makeState()
        state.metadata.caption = "Hello"
        state.metadata.replyTo = 42
        state.metadata.threadId = 7
        state.metadata.silent = true
        state.metadata.isVoiceMessage = true
        state.allowUpdate = true
        _ = state.transferFinished(failure: nil, now: now)
        _ = state.beginAnnounce()

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ChatUploadState.self, from: data)

        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.metadata.uploadMetadata.asDictionary()["caption"] as? String, "Hello")
        XCTAssertEqual(decoded.metadata.uploadMetadata.asDictionary()["replyTo"] as? Int, 42)
    }

    func testStateWithoutTheNewerKeysCanBeRead() throws {
        // What the first version wrote, before the keys for the folder, the system and the posted time existed
        let json = """
        {"id": "ref-1", "accountId": "account-1", "roomToken": "token1", "fileName": "photo.jpg",
         "localFileName": "ref-1.jpg", "createdAt": 1700000000, "step": "uploaded", "fileUploaded": true,
         "metadata": {"caption": "Hi"}}
        """

        let state = try JSONDecoder().decode(ChatUploadState.self, from: Data(json.utf8))

        XCTAssertEqual(state.id, "ref-1")
        XCTAssertEqual(state.step, .uploaded)
        XCTAssertTrue(state.fileUploaded)
        XCTAssertEqual(state.metadata.caption, "Hi")
        XCTAssertFalse(state.metadata.silent)
        XCTAssertFalse(state.attachmentFolderRecreated)
        XCTAssertFalse(state.startedInBackground)
        XCTAssertFalse(state.suspendedBySystem)
        XCTAssertNil(state.announcedAt)
        XCTAssertEqual(state.failureCount, 0)
    }

    func testStateWithoutTheBasicKeysIsRefused() {
        let json = "{\"id\": \"ref-1\"}"

        XCTAssertThrowsError(try JSONDecoder().decode(ChatUploadState.self, from: Data(json.utf8)))
    }

    func testStateNeverContainsCredentials() throws {
        let data = try JSONEncoder().encode(makeState())
        let json = String(data: data, encoding: .utf8) ?? ""

        XCTAssertFalse(json.lowercased().contains("password"))
        XCTAssertFalse(json.lowercased().contains("authorization"))
    }
}
