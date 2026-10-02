import Foundation

/// Watches a bead store for changes and reports them after a debounce.
///
/// FSEvents rather than kqueue: it coalesces at directory level and survives
/// the atomic rename `bd` uses to rewrite JSONL, which a file-descriptor watch
/// would lose track of entirely.
///
/// The callback firing is not itself a reason to re-analyse — the store gates
/// on the engine's data hash, so an incidental `touch` costs nothing.
public final class FileWatchService: @unchecked Sendable {
    /// Debounce window, matching bv's `BV_DEBOUNCE_MS` default.
    public var debounce: TimeInterval = 0.2

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.qjam.vbx.filewatch")
    /// Confined to `queue`; rebuilt by each `start` so it picks up `debounce`.
    private var debouncer: Debouncer?
    private var onChange: (@Sendable () -> Void)?

    /// Test hook: called on the watch queue with the time each FSEvents batch
    /// reached the debounce, before it is scheduled. A test compares the gaps
    /// between these to the window rather than trusting its own sleeps.
    var onSignalForTesting: (@Sendable (DispatchTime) -> Void)?
    private var watchedPaths: [String] = []

    public init() {}

    deinit { stopStream() }

    /// True while a stream is running.
    public var isWatching: Bool { stream != nil }

    public var paths: [String] { watchedPaths }

    /// Starts watching the directory containing `source`.
    ///
    /// The *directory* is watched rather than the file because an atomic
    /// rename replaces the inode, and a file-level watch would silently go
    /// deaf after the first write.
    public func start(watching source: String, onChange: @escaping @Sendable () -> Void) {
        let directory = URL(fileURLWithPath: source)
            .deletingLastPathComponent()
            .path
        start(directories: [directory], onChange: onChange)
    }

    /// Starts one stream over every directory in `directories`, recursively.
    ///
    /// One stream rather than one per directory, so a burst that touches two
    /// members at once — a `br` run in each, a checkout — still collapses into
    /// a single notification through the one debouncer.
    public func start(directories: [String], onChange: @escaping @Sendable () -> Void) {
        stop()

        let directories = directories.filter { !$0.isEmpty }
        guard !directories.isEmpty else { return }

        self.onChange = onChange
        self.watchedPaths = directories
        let debouncer = Debouncer(
            window: debounce, scheduler: QueueDebounceScheduler(queue: queue)
        ) { [weak self] in
            self?.onChange?()
        }
        queue.sync { self.debouncer = debouncer }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let service = Unmanaged<FileWatchService>.fromOpaque(info)
                .takeUnretainedValue()
            service.scheduleNotification()
        }

        let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            directories as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce / 2,  // FSEvents' own latency; the debounce below does the rest
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        )
        guard let created else { return }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    public func stop() {
        stopStream()
        queue.sync { debouncer?.cancel(); debouncer = nil }
        onChange = nil
        watchedPaths = []
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Collapses a burst of events into a single notification. `bd` rewriting a
    /// store produces several events in quick succession; reloading once at the
    /// end is both correct and much cheaper. See ``Debouncer``.
    private func scheduleNotification() {
        queue.async { [weak self] in
            guard let self, let debouncer = self.debouncer else { return }
            self.onSignalForTesting?(.now())
            debouncer.signal()
        }
    }
}
