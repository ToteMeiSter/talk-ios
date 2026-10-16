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
        let finished = expectation(description: "Download of A handled")

        baseController.setupVoiceMessagePlayer(with: fileStatusOfA, selection: selectionOfA) { didStart in
            XCTAssertFalse(didStart)
            finished.fulfill()
        }

        wait(for: [finished], timeout: 5)
        XCTAssertTrue(baseController.voiceMessagesPlayer === playerOfB)
    }

    func testVoiceMessagePlayerOfCurrentSelectionIsStarted() throws {
        let previousPlayer = try AVAudioPlayer(data: silentWavData())
        baseController.voiceMessagesPlayer = previousPlayer
        addTeardownBlock { [baseController] in baseController?.stopVoiceMessagePlayer() }

        let selection = baseController.selectVoiceMessage()
        let fileStatus = try makeVoiceMessageFileStatus(fileId: "1")
        let finished = expectation(description: "Player handled")

        baseController.setupVoiceMessagePlayer(with: fileStatus, selection: selection) { didStart in
            XCTAssertTrue(didStart)
            finished.fulfill()
        }

        wait(for: [finished], timeout: 5)
        XCTAssertNotNil(baseController.voiceMessagesPlayer)
        XCTAssertFalse(baseController.voiceMessagesPlayer === previousPlayer)
    }

    func testTapOnVoiceMessageWithLocalFilePlaysItWithoutDownload() throws {
        addTeardownBlock { [baseController] in baseController?.stopVoiceMessagePlayer() }

        let fileStatus = try makeVoiceMessageFileStatus(fileId: "1")
        let fileLocalPath = try XCTUnwrap(fileStatus.fileLocalPath)
        let fileParameters = """
        {
            "file": {
                "type": "file",
                "id": "1",
                "name": "\(fileStatus.fileName)",
                "path": "\(fileStatus.filePath)",
                "mimetype": "audio/wav",
                "fileId": "1",
                "fileName": "\(fileStatus.fileName)",
                "filePath": "\(fileStatus.filePath)",
                "fileLocalPath": "\(fileLocalPath)"
            }
        }
        """
        testMessage.messageParametersJSONString = fileParameters
        testMessage.message = "{file}"
        testMessage.messageType = "voice-message"
        XCTAssertNotNil(testMessage.file()?.fileStatus)

        let previousPlayer = try AVAudioPlayer(data: silentWavData())
        baseController.voiceMessagesPlayer = previousPlayer

        baseController.cellWants(toPlayAudioFile: testMessage)

        // The local file is played directly, no download is requested
        XCTAssertNil(baseController.pendingVoiceMessageDownload)

        // The player is built off the main thread and set on the main thread. Waiting for an expectation fulfilled
        // on the main queue lets the main queue run, so wait like that until the player replaces the previous one
        let deadline = Date().addingTimeInterval(5)
        while baseController.voiceMessagesPlayer === previousPlayer, Date() < deadline {
            let mainQueueRan = expectation(description: "Main queue ran")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { mainQueueRan.fulfill() }
            wait(for: [mainQueueRan], timeout: 1)
        }

        XCTAssertNotNil(baseController.voiceMessagesPlayer)
        XCTAssertFalse(baseController.voiceMessagesPlayer === previousPlayer)
        XCTAssertNil(baseController.pendingVoiceMessageDownload)
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

    func testVoiceMessagePlayerCanBeBuiltOffMainThread() throws {
        let fileStatus = try makeVoiceMessageFileStatus(fileId: "1")
        let fileLocalPath = try XCTUnwrap(fileStatus.fileLocalPath)
        let built = expectation(description: "Player built")

        DispatchQueue.global(qos: .userInitiated).async {
            let player = BaseChatViewController.makeVoiceMessagePlayer(atPath: fileLocalPath)

            XCTAssertFalse(Thread.isMainThread)
            XCTAssertNotNil(player)
            built.fulfill()
        }

        wait(for: [built], timeout: 5)
    }

    func testVoiceMessagePlayerBuiltForOutdatedSelectionIsDiscarded() throws {
        // The player of A is built off the main thread, while B is tapped
        let playerOfB = try AVAudioPlayer(data: silentWavData())
        baseController.voiceMessagesPlayer = playerOfB

        let selectionOfA = baseController.selectVoiceMessage()
        let fileStatusOfA = try makeVoiceMessageFileStatus(fileId: "1")
        let finished = expectation(description: "Player of A handled")

        // The selection of A is still current here, so this passes the first check and continues asynchronously
        baseController.setupVoiceMessagePlayer(with: fileStatusOfA, selection: selectionOfA) { didStart in
            XCTAssertFalse(didStart)
            finished.fulfill()
        }
        baseController.selectVoiceMessage()

        wait(for: [finished], timeout: 5)
        XCTAssertTrue(baseController.voiceMessagesPlayer === playerOfB)
    }

    func testVoiceMessagePlayerOfLatestSelectionReplacesPlayer() throws {
        let previousPlayer = try AVAudioPlayer(data: silentWavData())
        baseController.voiceMessagesPlayer = previousPlayer
        addTeardownBlock { [baseController] in baseController?.stopVoiceMessagePlayer() }

        let selection = baseController.selectVoiceMessage()
        let newPlayer = try AVAudioPlayer(data: silentWavData())
        let fileStatus = try makeVoiceMessageFileStatus(fileId: "1")

        XCTAssertTrue(baseController.startVoiceMessagePlayer(newPlayer, with: fileStatus, selection: selection))
        XCTAssertTrue(baseController.voiceMessagesPlayer === newPlayer)
    }

}
