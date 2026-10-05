//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Keeps the state of the uploads and the copies of their files on disk, so they outlive the process.
///
/// One JSON file per upload, written atomically. The state contains no credentials: the password is read
/// from the keychain whenever a request is built.
final class ChatUploadStore {

    let directory: URL

    private let fileManager = FileManager.default

    private var stateDirectory: URL { return self.directory.appendingPathComponent("state", isDirectory: true) }
    private var filesDirectory: URL { return self.directory.appendingPathComponent("files", isDirectory: true) }

    init(directory: URL) {
        self.directory = directory
    }

    /// `Application Support/ChatUploads`. Not the temporary directory, which the system clears at will.
    static func defaultDirectory() -> URL? {
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ChatUploads", isDirectory: true)
    }

    // MARK: - State

    func save(_ state: ChatUploadState) throws {
        try self.createDirectoryIfNeeded(self.stateDirectory)

        let data = try JSONEncoder().encode(state)
        try data.write(to: self.stateURL(for: state.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func load(id: String) -> ChatUploadState? {
        guard let data = try? Data(contentsOf: self.stateURL(for: id)) else { return nil }

        return try? JSONDecoder().decode(ChatUploadState.self, from: data)
    }

    func loadAll() -> [ChatUploadState] {
        let urls = (try? self.fileManager.contentsOfDirectory(at: self.stateDirectory, includingPropertiesForKeys: nil)) ?? []

        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }

            return try? JSONDecoder().decode(ChatUploadState.self, from: data)
        }
    }

    func removeState(id: String) {
        try? self.fileManager.removeItem(at: self.stateURL(for: id))
    }

    // MARK: - Files

    /// Copies the file into the store, which is the copy the upload is made from.
    ///
    /// - Returns: The name of the copy, to be stored in the state.
    func copyFile(at sourceURL: URL, id: String) throws -> String {
        try self.createDirectoryIfNeeded(self.filesDirectory)

        let fileExtension = sourceURL.pathExtension
        let localFileName = self.safeName(id) + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
        var destinationURL = self.filesDirectory.appendingPathComponent(localFileName)

        if self.fileManager.fileExists(atPath: destinationURL.path) {
            try self.fileManager.removeItem(at: destinationURL)
        }

        try self.fileManager.copyItem(at: sourceURL, to: destinationURL)

        // Neither needed in a backup nor worth the quota of the user
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? destinationURL.setResourceValues(values)

        return localFileName
    }

    func fileURL(for state: ChatUploadState) -> URL {
        return self.filesDirectory.appendingPathComponent(state.localFileName)
    }

    func fileExists(for state: ChatUploadState) -> Bool {
        return self.fileManager.fileExists(atPath: self.fileURL(for: state).path)
    }

    func removeFile(for state: ChatUploadState) {
        try? self.fileManager.removeItem(at: self.fileURL(for: state))
    }

    /// Removes state and copy of the file.
    func remove(_ state: ChatUploadState) {
        self.removeFile(for: state)
        self.removeState(id: state.id)
    }

    /// Files without a state, e.g. because the app died between copying the file and storing the state.
    func removeOrphanedFiles() {
        let knownNames = Set(self.loadAll().map { $0.localFileName })
        let urls = (try? self.fileManager.contentsOfDirectory(at: self.filesDirectory, includingPropertiesForKeys: nil)) ?? []

        for url in urls where !knownNames.contains(url.lastPathComponent) {
            try? self.fileManager.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    private func stateURL(for id: String) -> URL {
        return self.stateDirectory.appendingPathComponent(self.safeName(id)).appendingPathExtension("json")
    }

    /// The ids are reference ids, but they end up in file names, so make sure nothing odd gets through.
    private func safeName(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    private func createDirectoryIfNeeded(_ url: URL) throws {
        try self.fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
