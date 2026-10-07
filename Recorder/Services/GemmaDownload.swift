import Foundation

/// Gemma's 3.6 GB download (BetterSummaries) as a background URLSession: iOS transfers the files while Feder is in the
/// background, suspended or not running at all, and only over Wi-Fi (`allowsExpensiveNetworkAccess` and
/// `allowsConstrainedNetworkAccess` off: no cellular, no personal hotspot, no Low Data Mode); elsewhere a task simply
/// waits until there is Wi-Fi. The foreground download it replaces (one default session per file, the idle timer off)
/// failed when the phone locked or the user switched apps for long, which made "keep Feder open" for minutes the price.
///
/// One task per missing file (`taskDescription` = its name), each moved into the model directory when it finishes, so
/// a complete file is never fetched again. The session is recreated with the same identifier at every launch, which
/// reattaches the delegate to tasks still running; a task the user's force-quit cancelled comes back as an error with
/// resume data and continues from there. When iOS wakes the app for finished transfers, AppDelegate hands over the
/// completion handler (`handleBackgroundEvents`), called once the session has delivered its events.
/// UserDefaults `wantedKey` remembers that the user asked for it, so a launch picks the download up again.
nonisolated final class GemmaDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = GemmaDownload()
    static let sessionIdentifier = "de.cofinpro.recorder.gemma"
    /// Set by `start`, cleared when the files are complete or the download is cancelled.
    static let wantedKey = "gemmaDownloadWanted"

    enum Event: Sendable {
        case progress(Int64)          // bytes on disk or received so far, of the variant's `downloadBytes`
        case finished
        case failed(String)
    }

    private let variant = LocalLanguageModel.Variant.e2b
    private let lock = NSLock()
    private var session: URLSession?
    private var onEvent: (@Sendable (Event) -> Void)?
    private var backgroundCompletion: (@Sendable () -> Void)?
    /// The running task per file name; a callback of any other task for that file is stale and ignored.
    private var inFlight: [String: Int] = [:]
    /// Bytes received per file in flight, and of the files already in place.
    private var received: [String: Int64] = [:]
    private var completedBytes: Int64 = 0
    private var reported: Int64 = 0
    /// Resume data of a task that stopped with an error (force-quit, a dropped connection), per file.
    private var resumeData: [String: Data] = [:]
    /// Automatic retries per file in this process, so a file that keeps failing ends as `.failed`.
    private var retries: [String: Int] = [:]

    static var isWanted: Bool { UserDefaults.standard.bool(forKey: wantedKey) }

    /// Where events go (BetterSummaries; on the main actor there).
    func setHandler(_ handler: @escaping @Sendable (Event) -> Void) {
        lock.withLock { onEvent = handler }
    }

    /// Starts the missing files, or picks up the tasks that are still running (a launch while `isWanted`).
    func start() {
        UserDefaults.standard.set(true, forKey: Self.wantedKey)
        let directory = BetterSummaries.modelDirectory(variant)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var models = directory.deletingLastPathComponent().deletingLastPathComponent()   // …/Models: no iCloud backup
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? models.setResourceValues(values)

        let session = backgroundSession()
        session.getAllTasks { [self] tasks in
            let missing = variant.files.filter { !isInPlace($0) }
            let (events, toResume): ([Event], [URLSessionDownloadTask]) = lock.withLock {
                completedBytes = variant.files.filter { isInPlace($0) }.reduce(0) { $0 + size(of: $1) }
                for task in tasks where task.state == .running || task.state == .suspended {
                    guard let name = task.taskDescription, missing.contains(name) else { task.cancel(); continue }
                    inFlight[name] = task.taskIdentifier
                    received[name] = task.countOfBytesReceived
                }
                var created: [URLSessionDownloadTask] = []
                for name in missing where inFlight[name] == nil {
                    created.append(makeTask(name, in: session))
                }
                let suspended = tasks.compactMap { $0 as? URLSessionDownloadTask }.filter { $0.state == .suspended }
                return (missing.isEmpty ? [.finished] : [.progress(total())], created + suspended)
            }
            toResume.forEach { $0.resume() }
            if missing.isEmpty { UserDefaults.standard.set(false, forKey: Self.wantedKey) }
            events.forEach(emit)
        }
    }

    /// Stops every transfer (Delete, or the files were removed).
    func cancel() {
        UserDefaults.standard.set(false, forKey: Self.wantedKey)
        lock.withLock {
            inFlight = [:]
            received = [:]
            resumeData = [:]
        }
        guard let session = lock.withLock({ session }) else { return }
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    /// AppDelegate: iOS launched or woke the app for this session's events. The session is recreated (if this launch
    /// has none yet) so they are delivered; `completion` runs after the last one.
    func handleBackgroundEvents(_ completion: @escaping @Sendable () -> Void) {
        lock.withLock { backgroundCompletion = completion }
        _ = backgroundSession()
    }

    // MARK: Session

    private func backgroundSession() -> URLSession {
        lock.withLock {
            if let session { return session }
            let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
            configuration.allowsCellularAccess = false
            configuration.allowsExpensiveNetworkAccess = false
            configuration.allowsConstrainedNetworkAccess = false
            configuration.isDiscretionary = false          // the user asked for it: as soon as there is Wi-Fi
            configuration.sessionSendsLaunchEvents = true
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let created = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            session = created
            return created
        }
    }

    /// A task for `name` (from its resume data when there is some). Called with the lock held; not resumed yet.
    private func makeTask(_ name: String, in session: URLSession) -> URLSessionDownloadTask {
        let task: URLSessionDownloadTask
        if let data = resumeData.removeValue(forKey: name) {
            task = session.downloadTask(withResumeData: data)
        } else {
            let url = URL(string: "https://huggingface.co/\(variant.repository)/resolve/\(variant.revision)/\(name)")!
            task = session.downloadTask(with: url)
        }
        task.taskDescription = name
        inFlight[name] = task.taskIdentifier
        received[name] = 0
        return task
    }

    private func target(_ name: String) -> URL { BetterSummaries.modelDirectory(variant).appending(path: name) }

    private func isInPlace(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: target(name).path(percentEncoded: false))
    }

    private func size(of name: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: target(name).path(percentEncoded: false))[.size] as? Int64) ?? 0
    }

    /// Called with the lock held.
    private func total() -> Int64 { completedBytes + received.values.reduce(0, +) }

    private func emit(_ event: Event) {
        lock.withLock { onEvent }?(event)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // Every chunk arrives here: report only every 0.25 % (about 9 MB), not a main-actor hop per chunk.
        let bytes: Int64? = lock.withLock {
            guard let name = downloadTask.taskDescription, inFlight[name] == downloadTask.taskIdentifier else { return nil }
            received[name] = totalBytesWritten
            let now = total()
            guard now - reported >= variant.downloadBytes / 400 else { return nil }
            reported = now
            return now
        }
        if let bytes { emit(.progress(bytes)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let name = downloadTask.taskDescription,
              lock.withLock({ inFlight[name] == downloadTask.taskIdentifier }) else { return }
        guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            lock.withLock { inFlight[name] = nil; received[name] = nil }
            emit(.failed(String(localized: "The download server answered with error \(code). Try again later.")))
            return
        }
        // The file at `location` is deleted when this returns: into place now.
        do {
            let target = target(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
        } catch {
            lock.withLock { inFlight[name] = nil; received[name] = nil }
            emit(.failed(error.localizedDescription))
            return
        }
        let done: Bool = lock.withLock {
            inFlight[name] = nil
            received[name] = nil
            completedBytes += size(of: name)
            return variant.files.allSatisfy(isInPlace)
        }
        if done {
            UserDefaults.standard.set(false, forKey: Self.wantedKey)
            emit(.finished)
        } else {
            emit(.progress(lock.withLock { total() }))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, let name = task.taskDescription else { return }
        enum Outcome { case ignore, retry(URLSessionDownloadTask), fail }
        let outcome: Outcome = lock.withLock {
            // A stale task (another one runs for this file) or one we cancelled: nothing to do.
            guard inFlight[name] == task.taskIdentifier || inFlight[name] == nil, Self.isWanted else { return .ignore }
            inFlight[name] = nil
            received[name] = nil
            guard let data = (error as? URLError)?.downloadTaskResumeData, retries[name, default: 0] < 3 else { return .fail }
            retries[name, default: 0] += 1
            resumeData[name] = data
            return .retry(makeTask(name, in: session))
        }
        switch outcome {
        case .ignore: break
        case .retry(let task): task.resume()       // force-quit or a dropped connection: on from where it stopped
        case .fail: emit(.failed(error.localizedDescription))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { backgroundCompletion = nil }
            return backgroundCompletion
        }
        DispatchQueue.main.async { completion?() }    // UIKit wants it on the main thread
    }
}
