import Foundation

/// Handles reading, writing, and deleting the single event disk store.
/// All operations are actor-isolated for thread safety.
///
/// Storage location:
/// - Production: Application Support/metarouter/disk-queue/queue.v1.json
/// - Tests: injected temp directory
///
/// The directory is marked isExcludedFromBackup = true to prevent iCloud backup.
/// Writes use atomic file replacement to avoid partial-write corruption.
public actor DiskStorage {
    private static let directoryName = "metarouter/disk-queue"
    private static let fileName = "queue.v1.json"

    private static let jsonEncoder = JSONEncoder()
    private static let jsonDecoder = JSONDecoder()

    nonisolated public let baseDirectory: URL
    private let filePath: URL

    /// Initialize with an explicit base directory (for testing).
    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        self.filePath = baseDirectory.appendingPathComponent(Self.fileName)
    }

    /// Initialize with the platform-default Application Support directory.
    public init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent(Self.directoryName)
        self.baseDirectory = dir
        self.filePath = dir.appendingPathComponent(Self.fileName)
    }

    /// Cheap file-existence check. Does not parse the file contents.
    /// Used on boot to initialize the `hasDiskData` flag without a full read.
    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: filePath.path)
    }

    /// Write a snapshot to disk, fully overwriting any existing file.
    /// If the snapshot contains no events, any existing file is deleted instead.
    /// Creates the directory if it does not exist.
    /// Uses atomic write to prevent partial-file corruption.
    public func write(_ snapshot: QueueSnapshot) throws {
        guard !snapshot.events.isEmpty else {
            delete()
            return
        }

        try ensureDirectory()
        let data = try Self.jsonEncoder.encode(snapshot)
        try data.write(to: filePath, options: .atomic)
        Logger.log("Queue snapshot written to disk: \(snapshot.events.count) events, \(data.count) bytes")
    }

    /// Append events to the existing on-disk store, merging with prior contents.
    /// Enforces `maxEvents` cap by dropping the oldest events first. Atomic write.
    /// Used by: capacity overflow, background flush, offline push-back, threshold flush, requeue-at-cap.
    /// Returns the final on-disk event count.
    @discardableResult
    public func append(_ events: [EnrichedEventPayload], maxEvents: Int) throws -> Int {
        guard !events.isEmpty else {
            let existing = read()?.events.count ?? 0
            return existing
        }

        let existing = read()?.events ?? []
        var combined = existing + events
        if maxEvents > 0 && combined.count > maxEvents {
            let dropCount = combined.count - maxEvents
            combined = Array(combined.dropFirst(dropCount))
            Logger.warn("Disk store cap reached — dropped \(dropCount) oldest events")
        }

        try ensureDirectory()
        let snapshot = QueueSnapshot(events: combined)
        let data = try Self.jsonEncoder.encode(snapshot)
        try data.write(to: filePath, options: .atomic)
        Logger.log("Disk store append: +\(events.count) events, \(combined.count) total on disk")
        return combined.count
    }

    /// Read the snapshot from disk. Returns nil if no file exists.
    /// Corrupt or unparseable files are deleted, logged as a warning, and return nil.
    public func read() -> QueueSnapshot? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: filePath.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: filePath)
            let snapshot = try Self.jsonDecoder.decode(QueueSnapshot.self, from: data)
            Logger.log("Queue snapshot read from disk: \(snapshot.events.count) events, \(data.count) bytes")
            return snapshot
        } catch {
            Logger.warn("Queue snapshot file is corrupt or unparseable: \(error). Deleting file.")
            delete()
            return nil
        }
    }

    /// Delete the snapshot file if it exists.
    public func delete() {
        try? FileManager.default.removeItem(at: filePath)
        Logger.log("Queue snapshot deleted from disk")
    }

    private func ensureDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: baseDirectory.path) {
            try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }
        var dir = baseDirectory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try dir.setResourceValues(resourceValues)
    }
}
