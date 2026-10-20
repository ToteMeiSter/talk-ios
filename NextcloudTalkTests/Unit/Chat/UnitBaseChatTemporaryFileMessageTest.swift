//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

/// The temporary message of a file sent from the chat, and which way a new upload goes.
final class UnitBaseChatTemporaryFileMessageTest: TestBaseRealm {

    private var baseController: BaseChatViewController!

    override func setUpWithError() throws {
        try super.setUpWithError()

        let activeAccount = NCDatabaseManager.sharedInstance().activeAccount()
        baseController = BaseChatViewController(forRoom: NCRoom(), withAccount: activeAccount)!
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "ncBackgroundUploadEnabled")
        super.tearDown()
    }

    private func fileMessage(caption: String? = nil,
                             referenceId: String? = nil,
                             filePathForReferenceId: ((String) -> String)? = nil) throws -> NCChatMessage {
        return try XCTUnwrap(baseController.createTemporaryMessage(message: "IMG_0001.jpg",
                                                                   replyTo: nil,
                                                                   messageParameters: "/tmp/IMG_0001.jpg",
                                                                   silently: false,
                                                                   isVoiceMessage: false,
                                                                   isFileMessage: true,
                                                                   caption: caption,
                                                                   referenceId: referenceId,
                                                                   filePathForReferenceId: filePathForReferenceId))
    }

    // MARK: - createTemporaryMessage(isFileMessage:)

    func testAFileMessageWithoutCaptionShowsThePlaceholder() throws {
        XCTAssertEqual(try self.fileMessage().message, "{file}")
        XCTAssertEqual(try self.fileMessage(caption: "  \n ").message, "{file}")
    }

    func testAFileMessageShowsTheTrimmedCaption() throws {
        XCTAssertEqual(try self.fileMessage(caption: "  Look at this \n").message, "Look at this")
    }

    func testAFileMessageIsATemporaryCommentAboutAFile() throws {
        let message = try self.fileMessage()
        let file = try XCTUnwrap(message.file())

        XCTAssertTrue(message.isTemporary)
        XCTAssertNotEqual(message.messageType, kMessageTypeVoiceMessage)
        XCTAssertEqual(file.name, "IMG_0001.jpg")
        XCTAssertEqual(file.fileStatus?.fileName, "IMG_0001.jpg")
    }

    func testAFileMessagePointsToTheLocalFile() throws {
        XCTAssertEqual(try self.fileMessage().file()?.fileStatus?.fileLocalPath, "/tmp/IMG_0001.jpg")
    }

    func testAFileMessagePointsToTheCopyOfTheUpload() throws {
        let message = try self.fileMessage(filePathForReferenceId: { "/store/\($0).jpg" })
        let referenceId = try XCTUnwrap(message.referenceId)

        XCTAssertEqual(message.file()?.fileStatus?.fileLocalPath, "/store/\(referenceId).jpg")
        XCTAssertEqual(message.file()?.fileStatus?.filePath, "/tmp/IMG_0001.jpg")
    }

    func testAFileMessageKeepsTheReferenceIdOfItsUpload() throws {
        let uploadReferenceId = String(repeating: "a", count: 60) + "-001"

        XCTAssertEqual(try self.fileMessage(referenceId: uploadReferenceId).referenceId, uploadReferenceId)
    }

    func testTwoMessagesNeverShareAReferenceId() throws {
        // The reference id is the key of a stored upload, it must differ even within a millisecond
        let referenceIds = Set(try (0..<20).compactMap { _ in try self.fileMessage().referenceId })

        XCTAssertEqual(referenceIds.count, 20)
    }

    func testAVoiceMessageIsNotAFileMessage() throws {
        let message = try XCTUnwrap(baseController.createTemporaryMessage(message: "Talk recording.mp3",
                                                                          replyTo: nil,
                                                                          messageParameters: "/tmp/Talk recording.mp3",
                                                                          silently: false,
                                                                          isVoiceMessage: true))

        XCTAssertEqual(message.messageType, kMessageTypeVoiceMessage)
        XCTAssertEqual(message.message, "Talk recording.mp3")
    }

    // MARK: - The way of a new upload

    func testANewUploadGoesInTheBackgroundOnlyWithTheSwitchOn() {
        XCTAssertTrue(BaseChatViewController.sendsInBackground(referenceId: "ref", backgroundUploadEnabled: true))
        XCTAssertFalse(BaseChatViewController.sendsInBackground(referenceId: "ref", backgroundUploadEnabled: false))
    }

    func testAnUploadWithoutTemporaryMessageStaysInTheApp() {
        XCTAssertFalse(BaseChatViewController.sendsInBackground(referenceId: nil, backgroundUploadEnabled: true))
        XCTAssertFalse(BaseChatViewController.sendsInBackground(referenceId: nil, backgroundUploadEnabled: false))
    }

    func testTheSwitchIsOffByDefault() {
        UserDefaults.standard.removeObject(forKey: "ncBackgroundUploadEnabled")
        XCTAssertFalse(NCUserDefaults.backgroundUploadEnabled())

        NCUserDefaults.setBackgroundUploadEnabled(true)
        XCTAssertTrue(NCUserDefaults.backgroundUploadEnabled())

        NCUserDefaults.setBackgroundUploadEnabled(false)
        XCTAssertFalse(NCUserDefaults.backgroundUploadEnabled())
    }
}
