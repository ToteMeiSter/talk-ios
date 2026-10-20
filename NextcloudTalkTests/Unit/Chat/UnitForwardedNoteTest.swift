//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
@testable import NextcloudTalk

/// The "Forwarded from <author>" line of a forwarded message: how it is written and how it is recognized.
final class UnitForwardedNoteTest: TestBaseRealm {

    private func message(_ text: String, author: String, parameters: String? = nil) -> NCChatMessage {
        let message = NCChatMessage()
        message.actorDisplayName = author
        message.message = text
        message.messageParametersJSONString = parameters
        return message
    }

    private func range(of text: String) -> NSRange? {
        return ForwardedNote.noteRange(in: text, templates: ForwardedNote.templates())
    }

    // MARK: - Writing the note

    func testTextOfAForeignMessageStartsWithTheNoteOfItsAuthor() {
        let forwarded = ForwardedNote.text("Hello", author: "Alice")

        XCTAssertEqual(forwarded, "Forwarded from Alice\nHello")
    }

    func testTextOfOwnMessageIsMarkedWithOwnName() {
        let own = message("Hello", author: "Bob")

        XCTAssertEqual(ForwardedNote.text(own.parsedMessage().string, author: ForwardedNote.author(of: own)), "Forwarded from Bob\nHello")
    }

    func testMentionInForeignTextIsForwardedAsTheChatShowsIt() {
        let parameters = """
        {"mention-user1": {"type": "user", "id": "carol", "name": "Carol Jones"}}
        """
        let foreign = message("Hi {mention-user1}", author: "Alice", parameters: parameters)

        let forwarded = ForwardedNote.text(foreign.parsedMessage().string, author: ForwardedNote.author(of: foreign))

        XCTAssertEqual(forwarded, "Forwarded from Alice\nHi @Carol Jones")
        XCTAssertFalse(forwarded.contains("{mention-user1}"))
    }

    func testBlankTextGetsNoNote() {
        XCTAssertEqual(ForwardedNote.text("  \n", author: "Alice"), "  \n")
    }

    func testAuthorWithoutNameIsAGuest() {
        XCTAssertEqual(ForwardedNote.author(of: message("Hi", author: "")), "Guest")
    }

    func testNameWithAFormatSpecifierIsKept() {
        XCTAssertEqual(ForwardedNote.note(author: "50% %@ %d"), "Forwarded from 50% %@ %d")
    }

    // MARK: - Recognizing the note

    func testFirstLineOfTheNoteInEnglishAndRussianIsRecognized() {
        XCTAssertEqual(range(of: "Forwarded from Alice\nHello"), NSRange(location: 0, length: 20))
        XCTAssertEqual(ForwardedNote.noteRange(in: "Переслано от Алиса\nПривет", templates: ["Переслано от %@"]), NSRange(location: 0, length: 18))
        XCTAssertEqual(range(of: "Forwarded from Alice"), NSRange(location: 0, length: 20), "A note alone")
    }

    func testTextWithoutTheNoteIsNotRecognized() {
        XCTAssertNil(range(of: "Hello"))
        XCTAssertNil(range(of: "Hello\nForwarded from Alice"), "Only the first line is the note")
        XCTAssertNil(range(of: "Forwarded from"), "A note has a name")
        XCTAssertNil(range(of: "Forwarded from \nHello"), "A note has a name")
        XCTAssertNil(range(of: "Weitergeleitet von Alice\nHello"), "Other languages are plain text")
        XCTAssertNil(range(of: ""))
    }

    func testStyleMakesOnlyTheNoteSmallBoldAndItalic() throws {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let text = NSMutableAttributedString(string: "Forwarded from Alice\nHello", attributes: [.font: body])

        let styled = ForwardedNote.styleNote(in: text)

        let noteFont = try XCTUnwrap(styled.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(noteFont.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertTrue(noteFont.fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertLessThan(noteFont.pointSize, body.pointSize)
        XCTAssertEqual(styled.attribute(.font, at: 21, effectiveRange: nil) as? UIFont, body, "The body keeps its font")
        XCTAssertEqual(styled.string, "Forwarded from Alice\nHello", "The text is not changed")
    }

    func testStyleLeavesTextWithoutTheNoteAlone() {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let text = NSMutableAttributedString(string: "Hello\nForwarded from Alice", attributes: [.font: body])

        let styled = ForwardedNote.styleNote(in: text)

        var range = NSRange()
        XCTAssertEqual(styled.attribute(.font, at: 0, effectiveRange: &range) as? UIFont, body)
        XCTAssertEqual(range, NSRange(location: 0, length: styled.length))
    }

    func testChatShowsTheNoteOfAForwardedMessageSmall() throws {
        let forwarded = message("Forwarded from Alice\nHello", author: "Bob")

        let shown = try XCTUnwrap(forwarded.parsedMarkdownForChatWithForwardedNote())

        let noteFont = try XCTUnwrap(shown.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let bodyFont = try XCTUnwrap(shown.attribute(.font, at: 21, effectiveRange: nil) as? UIFont)
        XCTAssertLessThan(noteFont.pointSize, bodyFont.pointSize)
    }
}
