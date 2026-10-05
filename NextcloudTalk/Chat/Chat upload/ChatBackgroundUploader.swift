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

    /// Ids of uploads that are waiting for the server to tell where to upload to.
    private var resolvingIds = Set<String>()

    /// Ids of uploads that have a request to announce running.
    private var announcingIds = Set<String>()

    /// Ids of uploads that have an announcement planned for later. There is at most one chain per upload.
    private var scheduledAnnounceIds = Set<String>()

    /// A transfer the system stopped was started again since the app became active. Keeps the cancellations
    /// of a system that stops transfers over and over from becoming a loop.
    private var didRestartSuspendedTransfer = false

    /// The tasks of the session are known, see `start()`.
    private var didCollectTasks = false

    /// The states were prepared for the new process, see `recoverStoredStates()`.
    private var didRecoverStates = false

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
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(self.applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(self.applicationDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(self.protectedDataDidBecomeAvailable), name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)

        // Has to happen before the session delivers anything: an announcement that is in flight in THIS process
        // must not look like one that was cut off by the death of the last process
        self.recoverStoredStates()

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
        // Whatever the system wanted to hear is over once the user is back, and a flag from earlier events
        // must not make the next background launch end at once
        self.didReceiveAllBackgroundEvents = false
        self.didRestartSuspendedTransfer = false
        self.callBackgroundCompletionHandler()

        self.announcePendingUploads()
        self.restartUploadsFromForeground()
    }

    @objc private func applicationDidEnterBackground() {
        if self.backgroundCompletionHandler == nil {
            self.didReceiveAllBackgroundEvents = false
        }
    }

    @objc private func protectedDataDidBecomeAvailable() {
        self.recoverStoredStates()
        self.processStoredStates()
    }

    private func reconnect(with tasks: [URLSessionTask]) {
        for task in tasks {
            if let id = task.taskDescription, task.state == .running || task.state == .suspended {
                self.transferringIds.insert(id)
            }
        }

        self.didCollectTasks = true
        self.processStoredStates()

        // The app is in front already, so the tasks are at hand and `applicationDidBecomeActive` came too early for them
        if UIApplication.shared.applicationState != .background, UIApplication.shared.isProtectedDataAvailable {
            self.restart(from: tasks)
        }
    }

    /// Prepares the stored states for a new process. Needs the states to be readable, and does nothing before that
    /// and after the first time.
    ///
    /// Everything that looks at the stored states or starts work from them calls this first, because the order of
    /// `didBecomeActive` and `protectedDataDidBecomeAvailable` after a launch before the first unlock is not defined.
    /// Else an announcement started in between would be taken for one of the dead process, or the other way round.
    /// Note that `isProtectedDataAvailable` is `false` whenever the screen is locked, not only before the first unlock,
    /// so a process of this launch can have announcements in flight when this finally runs: those are skipped here,
    /// and `ChatUploadState.beginAnnounce` covers the other order.
    /// The call is idempotent and cheap, which is why it is called from every entry and the notification is not waited for.
    private func recoverStoredStates() {
        guard !self.didRecoverStates, UIApplication.shared.isProtectedDataAvailable else { return }

        self.didRecoverStates = true

        for var state in self.store.loadAll() where !self.announcingIds.contains(state.id) {
            state.recoverAfterRelaunch()
            try? self.store.save(state)
        }

    }

    /// Handles the results of transfers that came in before the states were readable, maybe in an earlier process.
    ///
    /// Waits for the tasks of the session to be known: the result of a failure starts the transfer again, and
    /// `startTransfer` only leaves out a transfer that is running already when it knows the tasks. Else an event that
    /// was handled before the process died would start a second chain of attempts. Called before any other work on
    /// the states.
    private func handleStoredEvents() {
        guard self.didCollectTasks, UIApplication.shared.isProtectedDataAvailable else { return }

        for event in self.store.loadEvents() {
            self.transferFinished(id: event.id, failure: event.failure)
            self.store.removeEvent(event)
        }
    }

    /// Carries on with the states found on disk. Waits for the data to be available (not locked), before the first
    /// unlock the states cannot be read, which does not mean they are gone.
    private func processStoredStates() {
        guard self.didCollectTasks, UIApplication.shared.isProtectedDataAvailable else { return }

        self.recoverStoredStates()
        self.handleStoredEvents()

        let now = Date().timeIntervalSince1970
        let report = self.store.loadAllReport()

        if !report.hasUnreadable {
            // A transfer that ended between asking the session for its tasks and now left its id behind
            let uploadingIds = Set(report.states.filter { $0.step == .uploading }.map { $0.id })
            self.transferringIds = self.transferringIds.filter { uploadingIds.contains($0) }
        }

        self.store.removeOrphanedFiles(isProtectedDataAvailable: true)

        for state in report.states {
            switch state.step {
            case .uploading:
                self.checkUploading(state)
            case .uploaded:
                self.announce(id: state.id)
            case .failed:
                if self.isObsolete(state, now: now) {
                    NCLog.log("Removing the failed upload of \(state.fileName), it is obsolete")
                    self.store.remove(state)
                } else {
                    // The process might have died before the message was updated
                    self.markMessageAsFailed(referenceId: state.id)
                }
            case .announced:
                // The file is not needed anymore. The state stays for a while, see `isAnnounced`.
                self.store.removeFile(for: state)

                if state.isAnnouncedRetentionOver(now: now) {
                    // Without the mark nothing tells "Resend" that the file is posted already, so the message of the
                    // upload that was not replaced by the one of the server goes with it
                    self.removeTemporaryMessage(referenceId: state.id)
                    self.store.removeState(id: state.id)
                }
            }
        }

        self.callBackgroundCompletionHandlerIfIdle()
    }

    private func checkUploading(_ state: ChatUploadState) {
        if state.destination == nil {
            // Nothing to do for a destination that is asked for right now
            guard !self.resolvingIds.contains(state.id) else { return }

            // The app went away while it was waiting for the server to tell where to upload to
            self.interrupt(state, reason: "destination not resolved")
        } else if !self.transferringIds.contains(state.id), !state.suspendedBySystem, !self.resolvingIds.contains(state.id) {
            // Events of finished transfers arrive right after the session was created. What is
            // still without a transfer after that was cancelled, e.g. because the user terminated the app.
            // A transfer the system stopped is started again when the app is in front.
            let id = state.id
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.orphanCheckDelay) { [weak self] in
                self?.interruptIfWithoutTransfer(id: id)
            }
        }
    }

    /// A failed upload nobody can ask to send again anymore, or nobody did for long.
    private func isObsolete(_ state: ChatUploadState, now: TimeInterval) -> Bool {
        if now - state.createdAt > ChatUploadState.failedRetention { return true }

        let database = NCDatabaseManager.sharedInstance()

        guard database.talkAccount(forAccountId: state.accountId) != nil,
              database.room(withToken: state.roomToken, forAccountId: state.accountId) != nil
        else { return true }

        return NCChatMessage.objects(where: "referenceId = %@ AND isTemporary = true", state.id).firstObject() == nil
    }

    /// Whether the file was posted. The temporary message of such an upload that is still shown is stale.
    func isAnnounced(referenceId: String) -> Bool {
        return self.store.load(id: referenceId)?.step == .announced
    }

    /// Sends the transfers again that are better sent from the foreground.
    ///
    /// The system treats a transfer that was created in the background as discretionary and may hold it back
    /// for hours, so what did not send a byte yet is cancelled and created again now. The cancellation that
    /// comes back is known to the state and not a failure. A transfer the system stopped is started again.
    private func restartUploadsFromForeground() {
        guard self.didCollectTasks, UIApplication.shared.isProtectedDataAvailable else { return }

        self.session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                self?.restart(from: tasks)
            }
        }
    }

    private func restart(from tasks: [URLSessionTask]) {
        self.recoverStoredStates()
        self.handleStoredEvents()

        for state in self.store.loadAll() where state.step == .uploading {
            let task = tasks.first { $0.taskDescription == state.id && ($0.state == .running || $0.state == .suspended) }

            if let task {
                guard state.startedInBackground, task.countOfBytesSent == 0 else { continue }

                var restarting = state
                restarting.prepareRestartFromForeground()

                if self.persist(restarting) {
                    task.cancel()
                }
            } else if state.suspendedBySystem, state.destination != nil,
                      !self.transferringIds.contains(state.id), !self.resolvingIds.contains(state.id) {
                self.restartStopped(state)
            }
        }
    }

    /// Sends a transfer again that the system stopped, which can be long ago.
    private func restartStopped(_ state: ChatUploadState) {
        if state.isExpired(now: Date().timeIntervalSince1970) {
            self.interrupt(state, reason: "expired")
        } else if state.destinationKind == .attachmentFolder {
            // The name was free when it was chosen, see `retry`
            self.resolveAgain(state)
        } else {
            // The pause the server asked for, e.g. with `Retry-After`, is not over because the app was away
            self.startTransfer(state, after: state.remainingPause(now: Date().timeIntervalSince1970))
        }
    }

    /// Asks the server where to upload to again, and sends the file there.
    private func resolveAgain(_ state: ChatUploadState) {
        let id = state.id

        guard let account = NCDatabaseManager.sharedInstance().talkAccount(forAccountId: state.accountId),
              let room = NCDatabaseManager.sharedInstance().room(withToken: state.roomToken, forAccountId: state.accountId)
        else {
            self.interrupt(state, reason: "room or account is gone")
            return
        }

        // Claimed here, so nothing mistakes the upload for one without a transfer until the task runs
        self.resolvingIds.insert(id)

        Task { @MainActor in
            self.resolvingIds.remove(id)
            await self.resolveDestinationAndTransfer(id: id, room: room, account: account)
        }
    }

    private func interruptIfWithoutTransfer(id: String) {
        guard let state = self.store.load(id: id), state.step == .uploading,
              !self.transferringIds.contains(id), !self.resolvingIds.contains(id)
        else { return }

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
        self.recoverStoredStates()

        for state in self.store.loadAll() where state.step == .uploaded {
            self.announce(id: state.id)
        }
    }

    // MARK: - Starting

    /// Takes over the upload of a file, which has a temporary message in the chat already.
    ///
    /// Returns when the upload is done or failed. Use `stage` and `begin` separately when the file must be
    /// safe, so the caller can delete it, before the network is involved.
    @MainActor
    func enqueue(_ upload: ChatFileUpload) async {
        guard self.stage(upload), let referenceId = upload.referenceId else { return }

        await self.begin(referenceId: referenceId, room: upload.room, account: upload.account)
    }

    /// Copies the file into the store and stores the state, which makes the upload survive the app being killed.
    /// A failure marks the temporary message as failed.
    ///
    /// - Returns: Whether the upload is stored.
    @MainActor
    func stage(_ upload: ChatFileUpload) -> Bool {
        guard let referenceId = upload.referenceId else {
            NCLog.log("Upload of \(upload.fileName) has no reference id")
            return false
        }

        let localFileName: String

        do {
            localFileName = try self.store.copyFile(at: URL(fileURLWithPath: upload.localPath), id: referenceId)
        } catch {
            NCLog.log("Could not copy \(upload.fileName) for the upload. Error: \(error.localizedDescription)")
            self.markMessageAsFailed(referenceId: referenceId)
            return false
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
            return false
        }

        return true
    }

    /// Determines where to upload the staged file to, while the user is looking at the app, and starts
    /// the transfer. A failure marks the temporary message as failed.
    @MainActor
    func begin(referenceId: String, room: NCRoom, account: TalkAccount) async {
        await self.resolveDestinationAndTransfer(id: referenceId, room: room, account: account)
    }

    /// The user wants to send a failed upload again.
    ///
    /// - Returns: `false` when there is nothing stored for the message, which is the case for messages
    ///            sent before uploads were stored. The caller sends those the usual way.
    @MainActor
    func retry(referenceId: String) -> Bool {
        guard var state = self.store.load(id: referenceId) else { return false }

        // Posted already: nothing to send, the message of the server is the one to show
        if state.step == .announced { return true }

        guard self.store.fileExists(for: state) || state.fileUploaded else {
            return false
        }

        let action = state.prepareRetry(now: Date().timeIntervalSince1970)

        guard self.persist(state) else { return false }

        switch action {
        case .announce:
            self.announce(id: referenceId)
        case .startTransfer:
            // The name of a file in the attachment folder was free when it was chosen, which can be long ago now
            if state.destination != nil, state.destinationKind != .attachmentFolder {
                self.startTransfer(state, after: 0)
            } else {
                self.resolveAgain(state)
            }
        default:
            // Still going, nothing to do. A file that is waiting to be posted might have been left alone by
            // an expired message, so ask for it.
            if state.step == .uploaded {
                self.announce(id: referenceId)
            }
        }

        return true
    }

    /// The user deleted the message of an upload that failed.
    func discard(referenceId: String?) {
        guard let referenceId, let state = self.store.load(id: referenceId) else { return }

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

        self.resolvingIds.insert(id)
        defer { self.resolvingIds.remove(id) }

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

        // The pause the server asked for is not over because the destination was asked for again
        self.startTransfer(current, after: current.remainingPause(now: Date().timeIntervalSince1970))
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

        // A transfer created while the app is in the background is a discretionary one for the system
        var state = state
        state.transferStarted(inBackground: UIApplication.shared.applicationState == .background)
        self.persist(state)

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
        var state: ChatUploadState

        switch self.store.loadResult(id: id) {
        case .found(let found):
            state = found
        case .missing:
            // Discarded in the meantime
            return
        case .unreadable:
            self.keepResultOfUnreadableState(id: id, failure: failure)
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
        case .recreateAttachmentFolder:
            self.recreateAttachmentFolderAndTransfer(state)
        case .suspended:
            self.transferSuspended(state)
        case .failed:
            self.markMessageAsFailed(referenceId: id)
        case .finished, .none:
            break
        }
    }

    /// A result for a state that cannot be read.
    private func keepResultOfUnreadableState(id: String, failure: ChatFileUploadFailure?) {
        // A state that cannot be read with the data available is broken, there is nothing to carry on with
        guard !UIApplication.shared.isProtectedDataAvailable else {
            NCLog.log("The state of the upload \(id) is broken, its result is dropped")
            return
        }

        // Before the first unlock of the device. The result is kept on disk and handled when the data is
        // available, which can be in another process.
        NCLog.log("The state of the upload \(id) cannot be read yet, its result is handled later")

        do {
            try self.store.saveEvent(ChatUploadStore.TransferEvent(id: id, failure: failure, date: Date().timeIntervalSince1970))
        } catch {
            NCLog.log("Could not store the result of the upload \(id). Error: \(error.localizedDescription)")
        }
    }

    /// Started again when the app comes to the front. When it is in front already, once: a system
    /// that stops every transfer would else make a loop.
    private func transferSuspended(_ state: ChatUploadState) {
        NCLog.log("The system stopped the transfer of \(state.fileName)")

        if UIApplication.shared.applicationState == .active, !self.didRestartSuspendedTransfer {
            self.didRestartSuspendedTransfer = true
            self.restartUploadsFromForeground()
        }
    }

    /// The server did not find the attachment folder. Creates it and sends the file again.
    private func recreateAttachmentFolderAndTransfer(_ state: ChatUploadState) {
        guard let account = NCDatabaseManager.sharedInstance().talkAccount(forAccountId: state.accountId) else {
            self.interrupt(state, reason: "account is gone")
            return
        }

        let id = state.id
        let bgTask = BGTaskHelper.startBackgroundTask(withName: "ChatUploadAttachmentFolder")

        // Nothing mistakes the upload for one without a transfer while the folder is created
        self.resolvingIds.insert(id)

        Task { @MainActor in
            defer {
                self.resolvingIds.remove(id)
                bgTask.stopBackgroundTask()
            }

            do {
                try await ChatFileUploader.ensureAttachmentFolder(for: account)
            } catch {
                NCLog.log("Could not create the attachment folder for \(state.fileName). Error: \(error.localizedDescription)")

                if let current = self.store.load(id: id), current.step == .uploading {
                    self.interrupt(current, reason: "attachment folder")
                }

                return
            }

            // The user might have deleted the message in the meantime
            guard let current = self.store.load(id: id), current.step == .uploading else { return }

            self.startTransfer(current, after: 0)
        }
    }

    /// Posts the uploaded file into the conversation, exactly once.
    ///
    /// The state is stored before the request is sent and after it ended, so whatever happens in between,
    /// the next try knows whether the file might have been posted already.
    private func announce(id: String, after delay: TimeInterval = 0) {
        if delay > 0 {
            // One chain per upload: a second one would use up the attempts twice as fast
            guard self.scheduledAnnounceIds.insert(id).inserted else { return }

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                // An announcement that was started in the meantime took over from this one
                guard let self, self.scheduledAnnounceIds.remove(id) != nil else { return }

                self.announce(id: id)
            }
            return
        }

        self.scheduledAnnounceIds.remove(id)

        self.recoverStoredStates()

        guard !self.announcingIds.contains(id),
              var state = self.store.load(id: id),
              state.step == .uploaded,
              let destination = state.destination
        else { return }

        // The chain of a process that is gone is not there anymore. Do not ask before the pause of the server is over.
        let pause = state.remainingPause(now: Date().timeIntervalSince1970)

        if pause > 0 {
            self.announce(id: id, after: pause)
            return
        }

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
                NCLog.log("Announcing \(announcedState.fileName) failed. Error: \(error.localizedDescription). Answer: \(ChatFileUploadRetryPolicy.responseBody(of: error) ?? "none")")
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
            // The state stays for a while, see `isAnnounced`
            self.store.removeFile(for: state)
        case .announce(let delay):
            self.announce(id: id, after: delay)
        case .failed:
            self.markMessageAsFailed(referenceId: id)
        case .startTransfer, .recreateAttachmentFolder, .suspended, .none:
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

    private func removeTemporaryMessage(referenceId: String) {
        RLMRealm.writeTransaction { realm in
            if let managedTemporaryMessage = NCChatMessage.objects(where: "referenceId = %@ AND isTemporary = true", referenceId).firstObject() {
                realm.delete(managedTemporaryMessage)
            }
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
