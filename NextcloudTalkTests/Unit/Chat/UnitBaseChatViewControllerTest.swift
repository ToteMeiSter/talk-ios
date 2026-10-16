//
// SPDX-FileCopyrightText: 2024 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AVFoundation
import XCTest
@testable import NextcloudTalk

final class UnitBaseChatViewControllerTest: TestBaseRealm {

    var baseController: BaseChatViewController!
    var testMessage: NCChatMessage!

    let fileMessageParameters = """
{
    "actor": {
        "type": "user",
        "id": "admin",
        "name": "admin"
    },
    "file": {
        "type": "file",
        "id": "9",
        "name": "photo-1517603250781-c4eac1449a80.jpeg",
        "size": 444676,
        "path": "Media/photo-1517603250781-c4eac1449a80.jpeg",
        "link": "https://nextcloud-mm.local/index.php/f/9",
        "etag": "60fb4ececc370787b1cdc5623ff4a189",
        "permissions": 27,
        "mimetype": "image/jpeg",
        "preview-available": "yes",
        "width": 1491,
        "height": 837
    }
}
"""

    override func setUpWithError() throws {
        try super.setUpWithError()

        let activeAccount = NCDatabaseManager.sharedInstance().activeAccount()
        baseController = BaseChatViewController(forRoom: NCRoom(), withAccount: activeAccount)!
        testMessage = NCChatMessage(dictionary: [:], andAccountId: activeAccount.accountId)
    }

    func testSystemMessageCellHeight() throws {
        testMessage.message = "System Message"
        testMessage.systemMessage = "test_system_message"
        XCTAssertEqual(baseController.getCellHeight(for: testMessage, with: 300), 35.0)
    }

    func testCellHeight() throws {
        // Normal chat message
        testMessage.message = "test"
        testMessage.messageId = 1
        XCTAssertEqual(baseController.getCellHeight(for: testMessage, with: 300), 101.0)

        // Multiline chat message
        testMessage.message = "test\nasd\nasd"
        testMessage.messageId = 2
        XCTAssertEqual(baseController.getCellHeight(for: testMessage, with: 300), 141.0)

        // Normal chat message with reaction
        testMessage.message = "test"
        testMessage.messageId = 3
        testMessage.setOrUpdateTemporaryReaction("👍", state: .added)
        XCTAssertEqual(baseController.getCellHeight(for: testMessage, with: 300), 141.0)
    }

    func testGroupedCellHeight() throws {
        // Grouped chat message
        testMessage.message = "test"
        testMessage.isGroupMessage = true
        testMessage.messageId = 1
        XCTAssertEqual(baseController.getCellHeight(for: testMessage, with: 300), 71.0)

        // Grouped chat message with reaction
        testMessage.messageId = 2
        testMessage.setOrUpdateTemporaryReaction("👍", state: .added)
        XCTAssertEqual(baseController.getCellHeight(for: testMessage, with: 300), 111.0)
    }

    func testGroupedCellWithQuoteHeight() throws {
        // Add an existing message to the database
        let existingMessage = NCChatMessage()
        existingMessage.messageId = 1
        existingMessage.internalId = "internal-1"
        existingMessage.message = "existing"

        try? realm.transaction {
            realm.add(existingMessage)
        }

        // Chat message with a quote
        testMessage.message = "test"
        testMessage.parentId = "internal-1"
        testMessage.isGroupMessage = true
        XCTAssertEqual(baseController.getCellHeight(for: testMessage, with: 300), 171.0)
    }

    func testCellWithUrlHeight() throws {
        // Chat message with URL preview
        testMessage.message = "test - https://nextcloud.com"
        testMessage.messageId = 1

        updateCapabilities { cap in
            cap.referenceApiSupported = true
        }

        XCTAssertEqual(baseController.getCellHeight(for: testMessage, with: 300), 206.0)

        // Test URL with grouped message
        testMessage.isGroupMessage = true
        testMessage.messageId = 2
        XCTAssertEqual(baseController.getCellHeight(for: testMessage, with: 300), 176.0)
    }

    func testCellWithPollHeight() throws {
        testMessage.messageParametersJSONString = """
{
    "actor": {
        "type": "user",
        "id": "admin",
        "name": "admin"
    },
    "object": {
        "type": "talk-poll",
        "id": "1",
        "name": "Test"
    }
}
"""

        testMessage.message = "{object}"
        XCTAssertEqual(baseController.getCellHeight(for: testMessage, with: 300), 119.0)
    }

    func testCellWithGeolocationHeight() {
        testMessage.messageParametersJSONString = """
{
  "actor": {
    "type": "user",
    "id": "admin",
    "name": "admin"
  },
  "object": {
    "name": "Geteilter Ort",
    "longitude": "6.764340827050928",
    "latitude": "53.20406320313201",
    "type": "geo-location",
    "id": "geo:53.20406320313201,6.764340827050928",
    "icon-url": "https://nextcloud-mm.local/ocs/v2.php/apps/spreed/api/v1/room/2yjsf6i6/avatar?v=02234d2d"
  }
}
"""

        testMessage.message = "{object}"
        XCTAssertEqual(baseController.getCellHeight(for: testMessage, with: 300), 231.0)
    }

    func testCellWithFileHeight() {
        // Test without file caption
        testMessage.messageParametersJSONString = fileMessageParameters
        testMessage.message = "{file}"
        XCTAssertEqual(baseController.getCellHeight(for: testMessage, with: 300), 221.0)
    }

    func testCellWithFileCaptionHeight() {
        testMessage.messageParametersJSONString = fileMessageParameters
        testMessage.message = "File caption..."
        XCTAssertEqual(baseController.getCellHeight(for: testMessage, with: 300), 241.0)
    }

    func testCellWithFileCaptionUrlHeight() {
        updateCapabilities { cap in
            cap.referenceApiSupported = true
        }

        testMessage.messageParametersJSONString = fileMessageParameters
        testMessage.message = "File caption... https://nextcloud.com"
        XCTAssertEqual(baseController.getCellHeight(for: testMessage, with: 300), 366.0)
    }

    func testCellWithFileAndQuoteHeight() {
        testMessage.messageParametersJSONString = fileMessageParameters
        testMessage.message = "File caption..."

        // Add an existing message to the database
        let existingMessage = NCChatMessage()
        existingMessage.messageId = 1
        existingMessage.internalId = "internal-1"
        existingMessage.message = "existing"

        try? realm.transaction {
            realm.add(existingMessage)
        }

        testMessage.parentId = "internal-1"
        XCTAssertEqual(baseController.getCellHeight(for: testMessage, with: 300), 311.0)
    }

    func testCellWithVoiceMessageHeight() {
        testMessage.message = "abc"
        testMessage.messageType = "voice-message"
        XCTAssertEqual(baseController.getCellHeight(for: testMessage, with: 300), 133.0)
    }

    func testCellWithQuoteHeight() throws {
        // Add an existing message to the database
        let existingMessage = NCChatMessage()
        existingMessage.messageId = 1
        existingMessage.internalId = "internal-1"
        existingMessage.message = "existing"

        try? realm.transaction {
            realm.add(existingMessage)
        }

        // Chat message with a quote
        testMessage.message = "test"
        testMessage.parentId = "internal-1"
        XCTAssertEqual(baseController.getCellHeight(for: testMessage, with: 300), 171.0)
    }

    func testMarkTemporaryMessageAsFailed() throws {
        let temporaryMessage = NCChatMessage()
        temporaryMessage.internalId = "temp-1"
        temporaryMessage.referenceId = "reference-1"
        temporaryMessage.messageType = "voice-message"
        temporaryMessage.isTemporary = true

        // A message received from the server with the same reference id
        let receivedMessage = NCChatMessage()
        receivedMessage.messageId = 1
        receivedMessage.internalId = "internal-1"
        receivedMessage.referenceId = "reference-1"

        try? realm.transaction {
            realm.add(temporaryMessage)
            realm.add(receivedMessage)
        }

        baseController.markTemporaryMessageAsFailed(referenceId: "reference-1")

        XCTAssertTrue(temporaryMessage.sendingFailed)
        XCTAssertFalse(temporaryMessage.isOfflineMessage)
        XCTAssertFalse(receivedMessage.sendingFailed)
    }

    func testMarkTemporaryMessageAsFailedIgnoresReceivedMessage() throws {
        let receivedMessage = NCChatMessage()
        receivedMessage.messageId = 1
        receivedMessage.internalId = "internal-1"
        receivedMessage.referenceId = "reference-1"

        try? realm.transaction {
            realm.add(receivedMessage)
        }

        baseController.markTemporaryMessageAsFailed(referenceId: "reference-1")

        XCTAssertFalse(receivedMessage.sendingFailed)
    }

    func testPrepareVoiceMessageForResendAssignsNewTimestamp() throws {
        let message = NCChatMessage()
        message.sendingFailed = true
        message.isOfflineMessage = true
        message.timestamp = Int(Date().timeIntervalSince1970) - (60 * 60 * 13)

        let before = Int(Date().timeIntervalSince1970)
        baseController.prepareVoiceMessageForResend(message)

        XCTAssertFalse(message.sendingFailed)
        XCTAssertFalse(message.isOfflineMessage)
        XCTAssertGreaterThanOrEqual(message.timestamp, before)
    }

    // MARK: - Voice message playback

    /// One second of silence as 16 bit mono WAV, which AVAudioPlayer can load without any audio hardware
    private func silentWavData() -> Data {
        let sampleRate: UInt32 = 8000
        let dataSize = sampleRate * 2

        func bytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
            withUnsafeBytes(of: value.littleEndian) { Array($0) }
        }

        var data = Data("RIFF".utf8)
        data.append(contentsOf: bytes(36 + dataSize))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(contentsOf: bytes(UInt32(16)))
        data.append(contentsOf: bytes(UInt16(1)))
        data.append(contentsOf: bytes(UInt16(1)))
        data.append(contentsOf: bytes(sampleRate))
        data.append(contentsOf: bytes(sampleRate * 2))
        data.append(contentsOf: bytes(UInt16(2)))
        data.append(contentsOf: bytes(UInt16(16)))
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: bytes(dataSize))
        data.append(Data(count: Int(dataSize)))

        return data
    }

    private func makeVoiceMessageFileStatus(fileId: String) throws -> NCChatFileStatus {
        let fileName = "voice-\(fileId)-\(UUID().uuidString).wav"
        let fileUrl = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try silentWavData().write(to: fileUrl)
        addTeardownBlock { try? FileManager.default.removeItem(at: fileUrl) }

        return NCChatFileStatus(fileId: fileId, fileName: fileName, filePath: "Talk/\(fileName)", fileLocalPath: fileUrl.path)
    }

    func testVoiceMessageSelectionOutdatedByLaterTap() {
        let first = baseController.selectVoiceMessage()
        XCTAssertTrue(baseController.shouldStartVoiceMessage(selection: first))

        let second = baseController.selectVoiceMessage()
        XCTAssertFalse(baseController.shouldStartVoiceMessage(selection: first))
        XCTAssertTrue(baseController.shouldStartVoiceMessage(selection: second))
    }

    func testFinishedDownloadOfOutdatedVoiceMessageKeepsPlayer() throws {
        // B was tapped last and is playing, while the download of A (tapped earlier) finishes now
        let playerOfB = try AVAudioPlayer(data: silentWavData())
        baseController.voiceMessagesPlayer = playerOfB

        let selectionOfA = baseController.selectVoiceMessage()
        baseController.selectVoiceMessage()

        let fileStatusOfA = try makeVoiceMessageFileStatus(fileId: "1")
        baseController.setupVoiceMessagePlayer(with: fileStatusOfA, selection: selectionOfA)

        XCTAssertTrue(baseController.voiceMessagesPlayer === playerOfB)
    }

    func testTapOnVoiceMessageWaitingForItsDownloadIsPending() {
        let downloading = NCChatFileStatus(fileId: "1", fileName: "", filePath: "")
        baseController.pendingVoiceMessageDownload = (fileId: "1", selection: 1)

        XCTAssertTrue(baseController.isVoiceMessageDownloadPending(forFileId: "1", downloadStatus: downloading))
    }

    func testTapOnOtherVoiceMessageWhileDownloadingIsNotPending() {
        let downloading = NCChatFileStatus(fileId: "1", fileName: "", filePath: "")
        baseController.pendingVoiceMessageDownload = (fileId: "2", selection: 1)

        XCTAssertFalse(baseController.isVoiceMessageDownloadPending(forFileId: "1", downloadStatus: downloading))
    }

    func testTapIsNotPendingWithoutDownloadStatus() {
        baseController.pendingVoiceMessageDownload = (fileId: "1", selection: 1)

        XCTAssertFalse(baseController.isVoiceMessageDownloadPending(forFileId: "1", downloadStatus: nil))
    }

    func testTapIsNotSwallowedByForeignDownloadAfterOwnDownloadEnded() {
        // Tap on A, its download ends (success, failure or cancellation all call finishVoiceMessageDownload).
        // Afterwards the same file is downloaded again for another reason, e.g. the transcription.
        let selection = baseController.selectVoiceMessage()
        baseController.pendingVoiceMessageDownload = (fileId: "1", selection: selection)
        XCTAssertTrue(baseController.isVoiceMessageDownloadPending(forFileId: "1", downloadStatus: NCChatFileStatus(fileId: "1", fileName: "", filePath: "")))

        baseController.finishVoiceMessageDownload(selection: selection)

        let foreignDownload = NCChatFileStatus(fileId: "1", fileName: "", filePath: "")
        XCTAssertFalse(baseController.isVoiceMessageDownloadPending(forFileId: "1", downloadStatus: foreignDownload))
    }

    func testEndOfOutdatedVoiceMessageDownloadKeepsNewerPendingDownload() {
        // Tap on A, tap on B, tap on A again: the first A download is outdated and must not clear the third tap
        let first = baseController.selectVoiceMessage()
        baseController.selectVoiceMessage()
        let third = baseController.selectVoiceMessage()
        baseController.pendingVoiceMessageDownload = (fileId: "1", selection: third)

        baseController.finishVoiceMessageDownload(selection: first)

        XCTAssertTrue(baseController.isVoiceMessageDownloadPending(forFileId: "1", downloadStatus: NCChatFileStatus(fileId: "1", fileName: "", filePath: "")))
    }

}
