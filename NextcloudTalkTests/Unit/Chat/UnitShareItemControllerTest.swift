//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

/// Files handed to the share item controller end up as share items only when a local copy exists.
final class UnitShareItemControllerTest: XCTestCase {

    private var sourceDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        self.sourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: self.sourceDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.sourceDirectory)

        try super.tearDownWithError()
    }

    func testAddItemWithURLKeepsALocalCopy() throws {
        let sourceURL = self.sourceDirectory.appendingPathComponent("Document.txt")
        try Data("content".utf8).write(to: sourceURL)

        let shareItemController = ShareItemController()
        shareItemController.addItem(with: sourceURL)

        let item = try XCTUnwrap(shareItemController.shareItems.first)

        XCTAssertEqual(shareItemController.shareItems.count, 1)
        XCTAssertEqual(try String(contentsOfFile: item.filePath, encoding: .utf8), "content")
    }

    func testAddItemWithMissingFileAddsNoItem() {
        let sourceURL = self.sourceDirectory.appendingPathComponent("Missing.txt")

        let shareItemController = ShareItemController()
        shareItemController.addItem(with: sourceURL)

        XCTAssertTrue(shareItemController.shareItems.isEmpty)
    }

    func testAddItemWithMissingFileReportsTheFileNameToTheDelegate() {
        let delegate = FailureRecordingDelegate()
        let shareItemController = ShareItemController()
        shareItemController.delegate = delegate

        shareItemController.addItem(with: self.sourceDirectory.appendingPathComponent("Missing.txt"))
        shareItemController.addItem(with: self.sourceDirectory.appendingPathComponent("AlsoMissing.txt"))

        XCTAssertTrue(shareItemController.shareItems.isEmpty)
        XCTAssertEqual(delegate.failedFileNames, ["Missing.txt", "AlsoMissing.txt"])
        XCTAssertEqual(delegate.changedCount, 0)
    }

    func testAddItemWithExistingFileReportsNoFailure() throws {
        let sourceURL = self.sourceDirectory.appendingPathComponent("Document.txt")
        try Data("content".utf8).write(to: sourceURL)

        let delegate = FailureRecordingDelegate()
        let shareItemController = ShareItemController()
        shareItemController.delegate = delegate

        shareItemController.addItem(with: sourceURL)

        XCTAssertEqual(shareItemController.shareItems.count, 1)
        XCTAssertTrue(delegate.failedFileNames.isEmpty)
        XCTAssertEqual(delegate.changedCount, 1)
    }

    func testUpdateItemWithMissingFileReportsTheItemAndKeepsTheFile() throws {
        let sourceURL = self.sourceDirectory.appendingPathComponent("Document.txt")
        try Data("content".utf8).write(to: sourceURL)

        let shareItemController = ShareItemController()
        shareItemController.addItem(with: sourceURL)
        let item = try XCTUnwrap(shareItemController.shareItems.first)

        let delegate = FailureRecordingDelegate()
        shareItemController.delegate = delegate

        shareItemController.update(item, with: self.sourceDirectory.appendingPathComponent("Edited.txt"))

        XCTAssertEqual(delegate.failedFileNames, ["Document.txt"])
        XCTAssertEqual(shareItemController.shareItems.count, 1)
        XCTAssertEqual(try String(contentsOfFile: item.filePath, encoding: .utf8), "content")
    }
}

private final class FailureRecordingDelegate: NSObject, ShareItemControllerDelegate {

    var failedFileNames: [String] = []
    var changedCount = 0

    func shareItemControllerItemsChanged(_ shareItemController: ShareItemController) {
        self.changedCount += 1
    }

    func shareItemController(_ shareItemController: ShareItemController, didFailToPrepareFileNamed fileName: String) {
        self.failedFileNames.append(fileName)
    }
}
