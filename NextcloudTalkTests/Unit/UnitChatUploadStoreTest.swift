//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

final class UnitChatUploadStoreTest: XCTestCase {

    private var directory: URL!
    private var store: ChatUploadStore!

    override func setUpWithError() throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("UnitChatUploadStoreTest-\(UUID().uuidString)", isDirectory: true)
        self.store = ChatUploadStore(directory: self.directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.directory)
    }

    private func makeState(id: String, localFileName: String = "file.txt") -> ChatUploadState {
        return ChatUploadState(id: id,
                               accountId: "account-1",
                               roomToken: "token1",
                               fileName: "file.txt",
                               localFileName: localFileName,
                               destinationKind: .attachmentFolder,
                               serverPath: "/Talk/file.txt",
                               serverURL: "https://cloud.example.com/remote.php/dav/files/user/Talk/file.txt",
                               createdAt: 1_700_000_000)
    }

    func testSaveAndLoad() throws {
        var state = makeState(id: "abc")
        state.metadata.caption = "Caption"

        try store.save(state)

        XCTAssertEqual(store.load(id: "abc"), state)
        XCTAssertNil(store.load(id: "unknown"))
    }

    func testSaveOverwrites() throws {
        var state = makeState(id: "abc")
        try store.save(state)

        state.step = .uploaded
        state.fileUploaded = true
        try store.save(state)

        XCTAssertEqual(store.load(id: "abc")?.step, .uploaded)
        XCTAssertEqual(store.loadAll().count, 1)
    }

    func testLoadAllAndRemove() throws {
        try store.save(makeState(id: "one"))
        try store.save(makeState(id: "two"))

        XCTAssertEqual(Set(store.loadAll().map { $0.id }), ["one", "two"])

        store.removeState(id: "one")

        XCTAssertEqual(store.loadAll().map { $0.id }, ["two"])
    }

    func testLoadAllWithoutDirectory() {
        XCTAssertEqual(store.loadAll(), [])
    }

    func testBrokenFileIsIgnored() throws {
        try store.save(makeState(id: "good"))

        let brokenURL = directory.appendingPathComponent("state").appendingPathComponent("broken.json")
        try Data("not json".utf8).write(to: brokenURL)

        XCTAssertEqual(store.loadAll().map { $0.id }, ["good"])
        XCTAssertNil(store.load(id: "broken"))
    }

    func testIdsCannotEscapeTheDirectory() throws {
        try store.save(makeState(id: "../../evil"))

        XCTAssertEqual(store.loadAll().count, 1)
        XCTAssertEqual(store.load(id: "../../evil")?.id, "../../evil")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("evil.json").path))
    }

    func testCopyFile() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString).txt")
        try Data("content".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let localFileName = try store.copyFile(at: sourceURL, id: "abc")
        let state = makeState(id: "abc", localFileName: localFileName)

        XCTAssertEqual(localFileName, "abc.txt")
        XCTAssertTrue(store.fileExists(for: state))
        XCTAssertEqual(try Data(contentsOf: store.fileURL(for: state)), Data("content".utf8))

        // The copy is independent of the source
        try FileManager.default.removeItem(at: sourceURL)
        XCTAssertTrue(store.fileExists(for: state))

        try store.save(state)
        store.remove(state)

        XCTAssertFalse(store.fileExists(for: state))
        XCTAssertNil(store.load(id: "abc"))
    }

    func testOrphanedFilesAreRemoved() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString).txt")
        try Data("content".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let keptName = try store.copyFile(at: sourceURL, id: "kept")
        let orphanName = try store.copyFile(at: sourceURL, id: "orphan")
        try store.save(makeState(id: "kept", localFileName: keptName))

        // A copy that was just made may be the one of a state that is stored right now
        store.removeOrphanedFiles(isProtectedDataAvailable: true)
        XCTAssertTrue(store.fileExists(for: makeState(id: "orphan", localFileName: orphanName)))

        let later = Date().addingTimeInterval(24 * 60 * 60)
        store.removeOrphanedFiles(isProtectedDataAvailable: true, now: later)

        XCTAssertTrue(store.fileExists(for: makeState(id: "kept", localFileName: keptName)))
        XCTAssertFalse(store.fileExists(for: makeState(id: "orphan", localFileName: orphanName)))
    }

    func testOrphanedFilesAreKeptWhenAStateCannotBeRead() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString).txt")
        try Data("content".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let name = try store.copyFile(at: sourceURL, id: "unreadable")
        try store.save(makeState(id: "good"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("state/unreadable.json"))

        store.removeOrphanedFiles(isProtectedDataAvailable: true, now: Date().addingTimeInterval(24 * 60 * 60))

        XCTAssertTrue(store.fileExists(for: makeState(id: "unreadable", localFileName: name)))
    }

    func testAnUnreadableStateDoesNotStopTheCleaning() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString).txt")
        try Data("content".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let keptName = try store.copyFile(at: sourceURL, id: "unreadable")
        let orphanName = try store.copyFile(at: sourceURL, id: "orphan")
        try store.save(makeState(id: "good"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("state/unreadable.json"))

        store.removeOrphanedFiles(isProtectedDataAvailable: true, now: Date().addingTimeInterval(24 * 60 * 60))

        XCTAssertTrue(store.fileExists(for: makeState(id: "unreadable", localFileName: keptName)))
        XCTAssertFalse(store.fileExists(for: makeState(id: "orphan", localFileName: orphanName)))
    }

    func testAnUnreadableStateIsDroppedWhenItIsOldEnough() throws {
        let stateURL = directory.appendingPathComponent("state/broken.json")
        try store.save(makeState(id: "good"))
        try Data("not json".utf8).write(to: stateURL)

        store.removeOrphanedFiles(isProtectedDataAvailable: true, now: Date().addingTimeInterval(ChatUploadStore.unreadableStateRetention - 60))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))

        // Not before the first unlock: the state might be fine then
        store.removeOrphanedFiles(isProtectedDataAvailable: false, now: Date().addingTimeInterval(ChatUploadStore.unreadableStateRetention + 60))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))

        store.removeOrphanedFiles(isProtectedDataAvailable: true, now: Date().addingTimeInterval(ChatUploadStore.unreadableStateRetention + 60))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertNotNil(store.load(id: "good"))
        XCTAssertFalse(store.loadAllReport().hasUnreadable)
    }

    func testTheCopyOfAFileIsNewEvenWhenTheSourceIsOld() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString).txt")
        try Data("content".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let old = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: sourceURL.path)

        let name = try store.copyFile(at: sourceURL, id: "new")
        let copyURL = store.fileURL(for: makeState(id: "new", localFileName: name))
        let modified = try XCTUnwrap(try copyURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)

        XCTAssertLessThan(abs(modified.timeIntervalSinceNow), 60)

        // Which is what keeps the copy of a file whose state is not stored yet
        store.removeOrphanedFiles(isProtectedDataAvailable: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyURL.path))
    }

    func testOrphanedFilesAreKeptBeforeTheFirstUnlock() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString).txt")
        try Data("content".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let name = try store.copyFile(at: sourceURL, id: "orphan")

        store.removeOrphanedFiles(isProtectedDataAvailable: false, now: Date().addingTimeInterval(24 * 60 * 60))

        XCTAssertTrue(store.fileExists(for: makeState(id: "orphan", localFileName: name)))
    }

    func testLoadResultTellsMissingFromUnreadable() throws {
        try store.save(makeState(id: "good"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("state/broken.json"))

        guard case .found = store.loadResult(id: "good") else { return XCTFail("good") }
        guard case .unreadable = store.loadResult(id: "broken") else { return XCTFail("broken") }
        guard case .missing = store.loadResult(id: "nothing") else { return XCTFail("nothing") }
        XCTAssertTrue(store.loadAllReport().hasUnreadable)
    }
}
