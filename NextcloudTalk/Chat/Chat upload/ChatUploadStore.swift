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
    private var eventsDirectory: URL { return self.directory.appendingPathComponent("events", isDirectory: true) }

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

    enum LoadResult {
        case found(ChatUploadState)
        /// There is no state with this id.
        case missing
        /// There is a file, but it cannot be read or decoded. Before the first unlock of the device the
        /// protection of the file is the reason, so this is no proof that the upload is gone.
        case unreadable
    }

    func loadResult(id: String) -> LoadResult {
        let url = self.stateURL(for: id)

        guard self.fileManager.fileExists(atPath: url.path) else { return .missing }

        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ChatUploadState.self, from: data)
        else { return .unreadable }

        return .found(state)
    }

    func load(id: String) -> ChatUploadState? {
        if case .found(let state) = self.loadResult(id: id) { return state }

        return nil
    }

    struct Report {
        /// The states that could be read.
        var states: [ChatUploadState] = []

        /// Files of states that could not be read.
        var unreadableURLs: [URL] = []

        var hasUnreadable: Bool { return !self.unreadableURLs.isEmpty }
    }

    func loadAllReport() -> Report {
        let urls = (try? self.fileManager.contentsOfDirectory(at: self.stateDirectory, includingPropertiesForKeys: nil)) ?? []
        var report = Report()

        for url in urls where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(ChatUploadState.self, from: data) {
                report.states.append(state)
            } else {
                report.unreadableURLs.append(url)
            }
        }

        return report
    }

    func loadAll() -> [ChatUploadState] {
        return self.loadAllReport().states
    }

    func removeState(id: String) {
        try? self.fileManager.removeItem(at: self.stateURL(for: id))
    }

    // MARK: - Transfer events

    /// The result of a transfer that came in while the states could not be read, i.e. before the first unlock of the
    /// device, to be handled when they can.
    struct TransferEvent: Codable, Equatable {
        var eventId = UUID().uuidString

        /// Id of the upload.
        var id: String

        /// What went wrong, `nil` when the server accepted the file.
        var failure: ChatFileUploadFailure?

        /// Seconds since 1970.
        var date: TimeInterval
    }

    /// Stores an event on disk, so it outlives the process: the system hands out the result of a transfer once, and
    /// the process may be gone again before the device is unlocked.
    ///
    /// The file has no protection (`.noFileProtection`) on purpose. The events come in before the first unlock, and
    /// a file of the class "until first user authentication" cannot be created then. The file holds the reference
    /// id of a message and the status codes of a request, no name, no content, no credentials.
    func saveEvent(_ event: TransferEvent) throws {
        try self.createDirectoryIfNeeded(self.eventsDirectory)

        let data = try JSONEncoder().encode(event)
        try data.write(to: self.eventURL(for: event), options: [.atomic, .noFileProtection])
    }

    /// The stored events, oldest first. A file that cannot be decoded is removed, nothing can be done with it.
    func loadEvents() -> [TransferEvent] {
        let urls = (try? self.fileManager.contentsOfDirectory(at: self.eventsDirectory, includingPropertiesForKeys: nil)) ?? []
        var events: [TransferEvent] = []

        for url in urls where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url), let event = try? JSONDecoder().decode(TransferEvent.self, from: data) {
                events.append(event)
            } else {
                try? self.fileManager.removeItem(at: url)
            }
        }

        return events.sorted { ($0.date, $0.eventId) < ($1.date, $1.eventId) }
    }

    func removeEvent(_ event: TransferEvent) {
        try? self.fileManager.removeItem(at: self.eventURL(for: event))
    }

    // MARK: - Files

    /// Copies the file into the store, which is the copy the upload is made from.
    ///
    /// - Returns: The name of the copy, to be stored in the state.
    func copyFile(at sourceURL: URL, id: String) throws -> String {
        try self.createDirectoryIfNeeded(self.filesDirectory)

        let localFileName = self.localFileName(forId: id, sourceURL: sourceURL)
        var destinationURL = self.filesDirectory.appendingPathComponent(localFileName)

        if self.fileManager.fileExists(atPath: destinationURL.path) {
            try self.fileManager.removeItem(at: destinationURL)
        }

        try self.fileManager.copyItem(at: sourceURL, to: destinationURL)

        // The copy keeps the date of the source. The age of the copy is what protects it from `removeOrphanedFiles`
        // while its state is not stored yet.
        try? self.fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destinationURL.path)

        // Neither needed in a backup nor worth the quota of the user
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? destinationURL.setResourceValues(values)

        return localFileName
    }

    /// Name `copyFile` gives the copy of a file.
    func localFileName(forId id: String, sourceURL: URL) -> String {
        let fileExtension = sourceURL.pathExtension
        return self.safeName(id) + (fileExtension.isEmpty ? "" : ".\(fileExtension)")
    }

    /// Where the copy of a file is going to be, before it exists.
    func plannedFileURL(forId id: String, sourceURL: URL) -> URL {
        return self.filesDirectory.appendingPathComponent(self.localFileName(forId: id, sourceURL: sourceURL))
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

    /// A state that cannot be read is dropped after this long, when the data is available. Waiting is for a state
    /// of a newer version of the app, which an older one has to leave alone for a while after a downgrade.
    static let unreadableStateRetention: TimeInterval = 7 * 24 * 60 * 60

    /// Files without a state, e.g. because the app died between copying the file and storing the state.
    ///
    /// Keeps the file of a state that cannot be read, which is found by the name (`localFileName` is made from
    /// the id, like the name of the state). Drops a state that cannot be read for `unreadableStateRetention`,
    /// so one broken file does not stop the cleaning for good. Only touches files that are older than
    /// `minimumAge`, because a file is copied before its state exists.
    ///
    /// - Parameter isProtectedDataAvailable: Whether the files protected until the first unlock can be read.
    func removeOrphanedFiles(isProtectedDataAvailable: Bool, minimumAge: TimeInterval = 6 * 60 * 60, now: Date = Date()) {
        guard isProtectedDataAvailable else { return }

        let report = self.loadAllReport()

        let knownNames = Set(report.states.map { $0.localFileName })
        var unreadableBaseNames = Set<String>()

        for url in report.unreadableURLs {
            unreadableBaseNames.insert(url.deletingPathExtension().lastPathComponent)

            if let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               now.timeIntervalSince(modified) > Self.unreadableStateRetention {
                NCLog.log("Removing the state \(url.lastPathComponent) of an upload, it cannot be read for long")
                try? self.fileManager.removeItem(at: url)
            }
        }

        let urls = (try? self.fileManager.contentsOfDirectory(at: self.filesDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []

        for url in urls where !knownNames.contains(url.lastPathComponent) && !unreadableBaseNames.contains(url.deletingPathExtension().lastPathComponent) {
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(modified) > minimumAge
            else { continue }

            try? self.fileManager.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    private func eventURL(for event: TransferEvent) -> URL {
        return self.eventsDirectory.appendingPathComponent(self.safeName(event.eventId)).appendingPathExtension("json")
    }

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
