//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitLegacyUploadDrainTest: TestBaseRealm {

    private func job() -> ChatBackgroundUploadJob {
        var metadata = ChatFileUploadMetadata()
        metadata.isVoiceMessage = true
        metadata.replyTo = 42
        metadata.threadId = 7
        metadata.silent = true
        return ChatBackgroundUploadJob(id: "job", sessionIdentifier: "session", index: 0,
                                       accountId: "account", roomToken: "room", roomName: "Room",
                                       fileName: "voice.m4a", draftPath: "Talk/voice.m4a",
                                       serverURL: "https://example.invalid/voice.m4a", referenceId: "voice-reference",
                                       metadata: metadata, allowUpdate: false, createdAt: Date())
    }

    func testPendingVoiceKeepsItsTypeAndLocalFile() throws {
        let job = self.job()
        let localURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voice.m4a")
        let upload = ChatBackgroundUpload(job: job, fileURL: localURL, isFailed: false)
        let room = self.addRoom(withToken: "room")
        let message = upload.temporaryMessage(in: room, for: NCDatabaseManager.sharedInstance().activeAccount())
        XCTAssertTrue(message.isVoiceMessage)
        XCTAssertEqual(message.referenceId, "voice-reference")
        XCTAssertEqual(message.threadId, 7)
        XCTAssertTrue(message.isSilent)
        XCTAssertEqual(message.file()?.fileStatus?.fileLocalPath, localURL.path)
    }

    func testLegacySessionKeepsItsIdentifier() {
        XCTAssertEqual(LegacyChatBackgroundUploader.sessionIdentifier, "\(Bundle.main.bundleIdentifier ?? "com.nextcloud.Talk").chat-upload")
        XCTAssertFalse(LegacyChatBackgroundUploader.sessionIdentifier.contains(".chatUpload."))
    }

    func testVoiceAttachmentDestinationSurvivesRelaunch() throws {
        var job = self.job()
        job.attachmentServerPath = "Talk/voice.m4a"
        job.uploaded = true
        job.postStarted = true
        let restored = try JSONDecoder().decode(ChatBackgroundUploadJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(restored.attachmentServerPath, "Talk/voice.m4a")
        XCTAssertTrue(restored.metadata.isVoiceMessage)
        XCTAssertEqual(restored.metadata.replyTo, 42)
        XCTAssertTrue(restored.metadata.silent)
        XCTAssertEqual(restored.referenceId, "voice-reference")
        XCTAssertTrue(restored.uploaded)
        XCTAssertTrue(restored.postStarted)
    }

    func testUpstreamJobWithoutAttachmentDestinationStillDecodes() throws {
        let data = try JSONEncoder().encode(self.job())
        let restored = try JSONDecoder().decode(ChatBackgroundUploadJob.self, from: data)
        XCTAssertNil(restored.attachmentServerPath)
        XCTAssertEqual(restored.draftPath, "Talk/voice.m4a")
    }
}
