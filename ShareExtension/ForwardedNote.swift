//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import UIKit

/// The first line of a forwarded message: "Forwarded from <author>". The server has no field for the author of
/// the original message, so the note is part of the text (or the caption of a file). The clients tell it from
/// the rest by its wording and draw it small, bold and italic. The wording is the same as in the Android client.
@objc(NCForwardedNote) public final class ForwardedNote: NSObject {

    private static let key = "Forwarded from %@"
    private static let placeholder = "%@"

    /// The note in the language of the app
    static func note(author: String) -> String {
        return String(format: NSLocalizedString("Forwarded from %@", comment: "The first line of a forwarded message, %@ is the author of the original message"), author)
    }

    /// The name of the author of `message` for the note
    static func author(of message: NCChatMessage) -> String {
        return message.actorDisplayName.isEmpty ? NSLocalizedString("Guest", comment: "") : message.actorDisplayName
    }

    /// `text` with the note as first line. A text that is blank is left alone: there is nothing to forward.
    static func text(_ text: String, author: String) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }

        return text
    }

    /// The caption of a forwarded file: the note, and the original caption below it if there is one
    static func caption(_ caption: String?, author: String) -> String {
        return caption ?? ""
    }

    /// The note with `%@` for the name, in the language of the app and in English and Russian: a forward keeps
    /// the language of its sender.
    static func templates(appBundle: Bundle = Bundle(for: ForwardedNote.self)) -> [String] {
        var result = [appBundle.localizedString(forKey: key, value: nil, table: nil)]

        for language in ["en", "ru"] {
            guard let path = appBundle.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) else { continue }
            result.append(bundle.localizedString(forKey: key, value: nil, table: nil))
        }

        return result.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    /// The range of the first line of `text` when it is a note, i.e. fits one of `templates`. Other text: nil.
    static func noteRange(in text: String, templates: [String]) -> NSRange? {
        let firstLine = text.components(separatedBy: "\n")[0]

        let isNote = templates.contains { template in
            guard let at = template.range(of: placeholder) else { return false }

            let prefix = String(template[..<at.lowerBound])
            let suffix = String(template[at.upperBound...])

            return firstLine.utf16.count > prefix.utf16.count + suffix.utf16.count && firstLine.hasPrefix(prefix) && firstLine.hasSuffix(suffix)
        }

        return nil
    }

    /// The font of the note: two steps smaller than the text of a message (body, footnote), bold and italic
    static var noteFont: UIFont {
        let base = UIFont.preferredFont(forTextStyle: .footnote)
        let descriptor = base.fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) ?? base.fontDescriptor

        return UIFont(descriptor: descriptor, size: 0)
    }

    private static let appTemplates = templates()

    /// Draws the first line of `text` as a note if it is one. Other text is not touched.
    @objc(styleNoteIn:) public static func styleNote(in text: NSMutableAttributedString) -> NSMutableAttributedString {
        if let range = noteRange(in: text.string, templates: appTemplates) {
            text.addAttribute(.font, value: noteFont, range: range)
        }

        return text
    }
}
