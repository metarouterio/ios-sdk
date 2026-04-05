import Foundation

/// Handles reading, writing, and deleting the queue snapshot file on disk.
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

    private let baseDirectory: URL
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

    /// Write a snapshot to disk, fully overwriting any existing file.
    /// If the snapshot contains no events, any existing file is deleted instead.
    /// Creates the directory if it does not exist.
    /// Uses atomic write to prevent partial-file corruption.
    public func write(_ snapshot: QueueSnapshot) throws {
        guard !snapshot.events.isEmpty else {
            delete()
            return
        }

        let fm = FileManager.default

        if !fm.fileExists(atPath: baseDirectory.path) {
            try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }

        var dir = baseDirectory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try dir.setResourceValues(resourceValues)

        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: filePath, options: .atomic)

        Logger.log("Queue snapshot written to disk: \(snapshot.events.count) events, \(data.count) bytes")
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
            let snapshot = try JSONDecoder().decode(QueueSnapshot.self, from: data)
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
}
