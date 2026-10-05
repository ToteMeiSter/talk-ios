//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import UIKit

extension Notification.Name {
    /// Posted when the upload of a file gave up. The user info has the `referenceId` of the temporary message.
    static let NCChatUploadDidFail = Notification.Name(rawValue: "NCChatUploadDidFailNotification")
}

/// Sends files into conversations in a way that survives the app being suspended or terminated.
///
/// The file is transferred by a background `URLSession`, which the system carries on while the app is
/// suspended, and relaunches the app for when the transfer is over. Posting the file into the
/// conversation is an ordinary request and needs a running app: it happens right after the transfer ended
/// when the system gave us time for it, otherwise at the next launch or when the app becomes active.
///
/// What happens next with every upload is decided by `ChatUploadState`, which is stored on disk by
/// `ChatUploadStore`. The key of an upload is the reference id of its temporary message.
///
/// Everything in here runs on the main thread: the delegate queue of the session is the main queue.
final class ChatBackgroundUploader: NSObject, URLSessionDelegate, URLSessionTaskDelegate {

    static let shared = ChatBackgroundUploader()

    /// The identifier must be the same on every launch, the system matches its transfers with it.
    static var sessionIdentifier: String {
        return "\(Bundle.main.bundleIdentifier ?? "com.nextcloud.Talk").chat-upload"
    }

    /// How long a transfer that has no task after a launch gets to show up, before it is declared interrupted.
    private static let orphanCheckDelay: TimeInterval = 8

    let store: ChatUploadStore

    private var backgroundCompletionHandler: (() -> Void)?
    private var didReceiveAllBackgroundEvents = false

    /// Ids of uploads that have a transfer in the session.
    private var transferringIds = Set<String>()

    /// Ids of uploads that have a request to announce running.
    private var announcingIds = Set<String>()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = ChatUploadState.maxAge

        return URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue.main)
    }()

    override init() {
        let directory = ChatUploadStore.defaultDirectory() ?? FileManager.default.temporaryDirectory.appendingPathComponent("ChatUploads", isDirectory: true)
        self.store = ChatUploadStore(directory: directory)

        super.init()
    }

    // MARK: - Lifecycle

    /// Reconnects with the session of an earlier launch and carries on with what is left. To be called
    /// on every launch, before the first upload is started.
    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(self.applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)

        // Creating the session is what makes the system deliver the events of transfers that ended while
        // there was no process.
        self.session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                self?.reconnect(with: tasks)
            }
        }
    }

    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    func handleEventsForBackgroundSession(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else {
            completionHandler()
            return
        }

        self.backgroundCompletionHandler = completionHandler

        // Recreates the session if the app was launched for this. The events might have been delivered
        // before this was called, in which case there is nothing to wait for.
        _ = self.session
        self.callBackgroundCompletionHandlerIfIdle()
    }

    @objc private func applicationDidBecomeActive() {
        self.announcePendingUploads()
    }

    private func reconnect(with tasks: [URLSessionTask]) {
        for task in tasks {
            if let id = task.taskDescription, task.state == .running || task.state == .suspended {
                self.transferringIds.insert(id)
            }
        }

        self.store.removeOrphanedFiles()

        for var state in self.store.loadAll() {
            state.recoverAfterRelaunch()
            try? self.store.save(state)

            switch state.step {
            case .uploading:
                if state.destination == nil {
                    // The app went away while it was waiting for the server to tell where to upload to
                    self.interrupt(state, reason: "destination not resolved")
                } else if !self.transferringIds.contains(state.id) {
                    // Events of finished transfers arrive right after the session was created. What is
                    // still without a transfer after that was cancelled, e.g. because the user terminated the app.
                    let id = state.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.orphanCheckDelay) { [weak self] in
                        self?.interruptIfWithoutTransfer(id: id)
                    }
                }
            case .uploaded:
                self.announce(id: state.id)
            case .failed:
                // The process might have died before the message was updated
                self.markMessageAsFailed(referenceId: state.id)
            case .announced:
                self.store.remove(state)
            }
        }

        self.callBackgroundCompletionHandlerIfIdle()
    }

    private func interruptIfWithoutTransfer(id: String) {
        guard let state = self.store.load(id: id), state.step == .uploading, !self.transferringIds.contains(id) else { return }

        self.interrupt(state, reason: "transfer was cancelled")
    }

    private func interrupt(_ state: ChatUploadState, reason: String) {
        var state = state
        state.fail(reason: reason)
        self.persist(state)
        self.markMessageAsFailed(referenceId: state.id)
        NCLog.log("Upload of \(state.fileName) was interrupted: \(reason)")
    }

    /// Posts the files that are on the server but not in the conversation.
    private func announcePendingUploads() {
        for state in self.store.loadAll() where state.step == .uploaded {
            self.announce(id: state.id)
        }
    }

    // MARK: - Starting

    /// Takes over the upload of a file, which has a temporary message in the chat already.
    ///
    /// The file is copied, so the caller may delete it, and the destination is determined while the user
    /// is looking at the app. A failure marks the temporary message as failed.
    @MainActor
    func enqueue(_ upload: ChatFileUpload) async {
        guard let referenceId = upload.referenceId else {
            NCLog.log("Upload of \(upload.fileName) has no reference id")
            return
        }

        let localFileName: String

        do {
            localFileName = try self.store.copyFile(at: URL(fileURLWithPath: upload.localPath), id: referenceId)
        } catch {
            NCLog.log("Could not copy \(upload.fileName) for the upload. Error: \(error.localizedDescription)")
            self.markMessageAsFailed(referenceId: referenceId)
            return
        }

        var state = ChatUploadState(id: referenceId,
                                    accountId: upload.account.accountId,
                                    roomToken: upload.room.token,
                                    fileName: upload.fileName,
                                    localFileName: localFileName,
                                    createdAt: Date().timeIntervalSince1970)
        state.allowUpdate = upload.allowUpdate
        state.metadata = ChatUploadState.Metadata(upload.metadata)

        guard self.persist(state) else {
            self.store.remove(state)
            self.markMessageAsFailed(referenceId: referenceId)
            return
        }

        await self.resolveDestinationAndTransfer(id: referenceId, room: upload.room, account: upload.account)
    }

    /// The user wants to send a failed upload again.
    ///
    /// - Returns: `false` when there is nothing stored for the message, which is the case for messages
    ///            sent before uploads were stored. The caller sends those the usual way.
    @MainActor
    func retry(referenceId: String) -> Bool {
        guard var state = self.store.load(id: referenceId) else { return false }

        guard self.store.fileExists(for: state) || state.fileUploaded else {
            return false
        }

        let action = state.prepareRetry(now: Date().timeIntervalSince1970)

        guard self.persist(state) else { return false }

        switch action {
        case .announce:
            self.announce(id: referenceId)
        case .startTransfer:
            if state.destination != nil {
                self.startTransfer(state, after: 0)
            } else if let account = NCDatabaseManager.sharedInstance().talkAccount(forAccountId: state.accountId),
                      let room = NCDatabaseManager.sharedInstance().room(withToken: state.roomToken, forAccountId: state.accountId) {
                Task { @MainActor in
                    await self.resolveDestinationAndTransfer(id: referenceId, room: room, account: account)
                }
            } else {
                self.interrupt(state, reason: "room or account is gone")
            }
        default:
            break
        }

        return true
    }

    /// The user deleted the message of an upload that failed.
    func discard(referenceId: String) {
        guard let state = self.store.load(id: referenceId) else { return }

        // The state goes first, so the cancellation below finds nothing to carry on with
        self.store.remove(state)

        self.session.getAllTasks { tasks in
            for task in tasks where task.taskDescription == referenceId {
                task.cancel()
            }
        }

        self.transferringIds.remove(referenceId)
    }

    @MainActor
    private func resolveDestinationAndTransfer(id: String, room: NCRoom, account: TalkAccount) async {
        guard let state = self.store.load(id: id) else { return }

        // Keeps the app running while it waits for the server to answer
        let bgTask = BGTaskHelper.startBackgroundTask(withName: "ChatUploadResolveDestination")
        defer { bgTask.stopBackgroundTask() }

        let destination: ChatFileUploadDestination

        do {
            destination = try await ChatFileUploader.resolveDestinationWithRetries(in: room, account: account, fileName: state.fileName, allowUpdate: state.allowUpdate)
        } catch {
            NCLog.log("Could not determine where to upload \(state.fileName) to. Error: \(error.localizedDescription)")

            if let current = self.store.load(id: id) {
                self.interrupt(current, reason: "no destination")
            }

            return
        }

        // The user might have deleted the message in the meantime
        guard var current = self.store.load(id: id), current.step == .uploading else { return }

        current.setDestination(destination)

        guard self.persist(current) else {
            self.interrupt(current, reason: "state could not be stored")
            return
        }

        self.startTransfer(current, after: 0)
    }

    private func startTransfer(_ state: ChatUploadState, after delay: TimeInterval) {
        guard !self.transferringIds.contains(state.id) else { return }

        guard self.store.fileExists(for: state) else {
            self.interrupt(state, reason: "local file is missing")
            return
        }

        guard let request = self.makeRequest(for: state) else {
            self.interrupt(state, reason: "request could not be built")
            return
        }

        let task = self.session.uploadTask(with: request, fromFile: self.store.fileURL(for: state))
        task.taskDescription = state.id

        if delay > 0 {
            // Honoured by the system even when the app is suspended
            task.earliestBeginDate = Date().addingTimeInterval(delay)
        }

        self.transferringIds.insert(state.id)
        task.resume()
    }

    private func makeRequest(for state: ChatUploadState) -> URLRequest? {
        guard let serverURL = state.serverURL,
              let url = Self.url(from: serverURL),
              let account = NCDatabaseManager.sharedInstance().talkAccount(forAccountId: state.accountId),
              let authHeader = NCAPIController.sharedInstance().authHeader(forAccount: account)
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue(NCAppBranding.userAgent(), forHTTPHeaderField: "User-Agent")

        return request
    }

    /// File names can contain everything, so the path part needs to be encoded.
    ///
    /// The strings are built from raw names, so they are never encoded already.
    static func url(from string: String) -> URL? {
        return string.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap { URL(string: $0) }
    }

    // MARK: - URLSession delegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }

        self.transferringIds.remove(id)

        let response = task.response as? HTTPURLResponse
        let retryAfter = ChatFileUploadRetryPolicy.retryAfter(fromHeaderValue: response?.value(forHTTPHeaderField: "Retry-After"))
        var failure: ChatFileUploadFailure?

        if let error {
            failure = ChatFileUploadFailure(error: error)
            failure?.retryAfter = retryAfter
        } else if let response {
            // A background session reports an answer of the server like 503 without an error
            if !(200 ..< 300).contains(response.statusCode) {
                failure = ChatFileUploadFailure(httpStatusCode: response.statusCode, retryAfter: retryAfter)
            }
        } else {
            failure = ChatFileUploadFailure(urlErrorCode: NSURLErrorBadServerResponse)
        }

        self.transferFinished(id: id, failure: failure)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        self.didReceiveAllBackgroundEvents = true
        self.callBackgroundCompletionHandlerIfIdle()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        self.handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        self.handle(challenge, completionHandler: completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge, completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // The pinning check, the same as everywhere else in the app
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust,
           CCCertificate.sharedManager().checkTrustedChallenge(challenge) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: - Steps

    private func transferFinished(id: String, failure: ChatFileUploadFailure?) {
        guard var state = self.store.load(id: id) else {
            // Discarded in the meantime
            return
        }

        let action = state.transferFinished(failure: failure, now: Date().timeIntervalSince1970)
        self.persist(state)

        if let failure {
            NCLog.log("Transfer of \(state.fileName) failed, http \(failure.httpStatusCode ?? 0), url error \(failure.urlErrorCode ?? 0). Next: \(action)")
        }

        switch action {
        case .startTransfer(let delay):
            self.startTransfer(state, after: delay)
        case .announce:
            self.announce(id: id)
        case .failed:
            self.markMessageAsFailed(referenceId: id)
        case .finished, .none:
            break
        }
    }

    /// Posts the uploaded file into the conversation, exactly once.
    ///
    /// The state is stored before the request is sent and after it ended, so whatever happens in between,
    /// the next try knows whether the file might have been posted already.
    private func announce(id: String, after delay: TimeInterval = 0) {
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.announce(id: id)
            }
            return
        }

        guard !self.announcingIds.contains(id),
              var state = self.store.load(id: id),
              state.step == .uploaded,
              let destination = state.destination
        else { return }

        guard let account = NCDatabaseManager.sharedInstance().talkAccount(forAccountId: state.accountId) else {
            self.interrupt(state, reason: "account is gone")
            return
        }

        // Stored before the request is sent: a state found with the request in flight means it might have got through
        guard state.beginAnnounce(), self.persist(state) else { return }

        self.announcingIds.insert(id)

        // Gives the request time to end when the app is going to the background, or was woken for the transfer
        let bgTask = BGTaskHelper.startBackgroundTask(withName: "ChatUploadAnnounce") { [weak self] _ in
            NCLog.log("ExpirationHandler called - announcing an upload")
            self?.callBackgroundCompletionHandler()
        }

        let metadata = state.metadata.uploadMetadata
        let announcedState = state

        Task { @MainActor in
            var failure: ChatFileUploadFailure?

            do {
                try await ChatFileUploader.announce(inRoom: announcedState.roomToken,
                                                    account: account,
                                                    fileName: announcedState.fileName,
                                                    referenceId: announcedState.id,
                                                    metadata: metadata,
                                                    allowUpdate: announcedState.allowUpdate,
                                                    at: destination)
            } catch {
                failure = ChatFileUploader.failure(for: error)
                NCLog.log("Announcing \(announcedState.fileName) failed. Error: \(error.localizedDescription)")
            }

            self.announcingIds.remove(id)
            self.announceFinished(id: id, failure: failure)

            bgTask.stopBackgroundTask()
            self.callBackgroundCompletionHandlerIfIdle()
        }
    }

    private func announceFinished(id: String, failure: ChatFileUploadFailure?) {
        guard var state = self.store.load(id: id) else { return }

        let action = state.announceFinished(failure: failure, now: Date().timeIntervalSince1970)
        self.persist(state)

        switch action {
        case .finished:
            NCLog.log("Uploaded and shared \(state.fileName)")
            self.store.remove(state)
        case .announce(let delay):
            self.announce(id: id, after: delay)
        case .failed:
            self.markMessageAsFailed(referenceId: id)
        case .startTransfer, .none:
            break
        }
    }

    // MARK: - Results

    @discardableResult
    private func persist(_ state: ChatUploadState) -> Bool {
        do {
            try self.store.save(state)
            return true
        } catch {
            NCLog.log("Could not store the state of the upload of \(state.fileName). Error: \(error.localizedDescription)")
            return false
        }
    }

    /// Shows the temporary message as not sent, so the user can send it again or delete it.
    private func markMessageAsFailed(referenceId: String) {
        RLMRealm.writeTransaction { _ in
            if let managedTemporaryMessage = NCChatMessage.objects(where: "referenceId = %@ AND isTemporary = true", referenceId).firstObject() as? NCChatMessage {
                managedTemporaryMessage.sendingFailed = true
                managedTemporaryMessage.isOfflineMessage = false
            }
        }

        // An open chat holds its own copy of the message
        NotificationCenter.default.post(name: .NCChatUploadDidFail, object: self, userInfo: ["referenceId": referenceId])
    }

    // MARK: - Background events

    /// The system wants to hear when we are done with the events of the background session, which includes
    /// posting the files that arrived. Telling it earlier lets it suspend the app before that is done.
    private func callBackgroundCompletionHandlerIfIdle() {
        guard self.didReceiveAllBackgroundEvents, self.announcingIds.isEmpty else { return }

        self.callBackgroundCompletionHandler()
    }

    private func callBackgroundCompletionHandler() {
        guard let handler = self.backgroundCompletionHandler else { return }

        self.backgroundCompletionHandler = nil
        self.didReceiveAllBackgroundEvents = false
        handler()
    }
}
