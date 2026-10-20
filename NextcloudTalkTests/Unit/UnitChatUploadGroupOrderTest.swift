//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

/// The files of a group are posted in the order the user chose them in, not in the order their transfers end in.
final class UnitChatUploadGroupOrderTest: XCTestCase {

    private let now: TimeInterval = 1_700_000_000

    private func makeState(group: String = "group", index: Int, step: ChatUploadState.Step, room: String = "token1", createdAt: TimeInterval? = nil) throws -> ChatUploadState {
        let reference = try XCTUnwrap(FileUploadReference(uploadId: group, index: index))
        var state = ChatUploadState(id: reference.referenceId,
                                    accountId: "account-1",
                                    roomToken: room,
                                    fileName: "file-\(index).jpg",
                                    localFileName: "file-\(index).jpg",
                                    createdAt: createdAt ?? now)
        state.step = step
        state.fileUploaded = step == .uploaded || step == .announced
        return state
    }

    private func isWaiting(_ state: ChatUploadState, among states: [ChatUploadState]) -> Bool {
        return state.isWaitingForEarlierFiles(among: states, now: now + 60)
    }

    func testFileThatEndedFirstWaitsForEarlierFileStillOnItsWay() throws {
        let first = try makeState(index: 0, step: .uploading)
        let second = try makeState(index: 1, step: .uploaded)

        XCTAssertTrue(isWaiting(second, among: [first, second]))
        XCTAssertFalse(isWaiting(first, among: [first, second]))
    }

    func testFileWaitsWhileEarlierFileIsNotPostedYet() throws {
        let first = try makeState(index: 0, step: .uploaded)
        let second = try makeState(index: 1, step: .uploaded)

        XCTAssertTrue(isWaiting(second, among: [first, second]))
    }

    func testFileWaitsForEarlierFileWhoseAnnouncementWasCutOffByTheDeathOfTheProcess() throws {
        var first = try makeState(index: 0, step: .uploaded)
        first.announceInFlight = true
        first.recoverAfterRelaunch()
        let second = try makeState(index: 1, step: .uploaded)

        XCTAssertEqual(first.step, .uploaded)
        XCTAssertTrue(isWaiting(second, among: [first, second]))
    }

    func testFileDoesNotWaitForPostedEarlierFile() throws {
        let first = try makeState(index: 0, step: .announced)
        let second = try makeState(index: 1, step: .uploaded)

        XCTAssertFalse(isWaiting(second, among: [first, second]))
    }

    func testFileDoesNotWaitForeverForEarlierFileThatGaveUp() throws {
        let first = try makeState(index: 0, step: .failed)
        let second = try makeState(index: 1, step: .uploaded)
        let third = try makeState(index: 2, step: .uploaded)

        XCTAssertFalse(isWaiting(second, among: [first, second, third]))
        // The ones after the file that is free to go still keep the order among themselves
        XCTAssertTrue(isWaiting(third, among: [first, second, third]))
    }

    func testFileDoesNotWaitForEarlierFileThatIsGone() throws {
        let second = try makeState(index: 1, step: .uploaded)

        XCTAssertFalse(isWaiting(second, among: [second]))
    }

    func testFileDoesNotWaitForEarlierFileOlderThanTheLimit() throws {
        let first = try makeState(index: 0, step: .uploading, createdAt: now - ChatUploadState.maxAge - 1)
        let second = try makeState(index: 1, step: .uploaded, createdAt: now - ChatUploadState.maxAge - 1)

        XCTAssertFalse(isWaiting(second, among: [first, second]))
    }

    func testFileDoesNotWaitForLaterFiles() throws {
        let first = try makeState(index: 0, step: .uploaded)
        let second = try makeState(index: 1, step: .uploading)

        XCTAssertFalse(isWaiting(first, among: [first, second]))
    }

    func testFileDoesNotWaitForOtherGroupsOrOtherConversations() throws {
        let otherGroup = try makeState(group: "other", index: 0, step: .uploading)
        let otherRoom = try makeState(index: 0, step: .uploading, room: "token2")
        let second = try makeState(index: 1, step: .uploaded)

        XCTAssertFalse(isWaiting(second, among: [otherGroup, otherRoom, second]))
    }

    func testFileOfNoGroupNeverWaits() {
        let single = ChatUploadState(id: "temp-1758012345.678", accountId: "account-1", roomToken: "token1", fileName: "a.jpg", localFileName: "a.jpg", createdAt: now)
        var other = single
        other.id = "temp-1758012346.000"
        other.step = .uploading

        XCTAssertFalse(isWaiting(single, among: [single, other]))
    }

    func testFollowsOnlyLaterFilesOfTheSameGroup() throws {
        let first = try makeState(index: 0, step: .failed)
        let second = try makeState(index: 1, step: .uploaded)
        let otherGroup = try makeState(group: "other", index: 1, step: .uploaded)

        XCTAssertTrue(second.follows(first))
        XCTAssertFalse(first.follows(second))
        XCTAssertFalse(first.follows(first))
        XCTAssertFalse(otherGroup.follows(first))
    }
}
