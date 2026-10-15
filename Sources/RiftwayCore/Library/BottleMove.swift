import Darwin
import Foundation

/// Moves a bottle to another location (PRD-02 R2.3): on the same disk it is a
/// rename; to another disk it is copied (symlinks, permissions and extended
/// attributes as they are) into a hidden folder there, checked, renamed into
/// place, and only then removed from where it was. A cancelled or failed copy
/// leaves the bottle where it was and nothing on the other disk.
public enum BottleMove {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case running
        case disconnected(drive: String)
        case unsuitable(BottleLocations.Problem)
        case alreadyThere
        case exists(String)
        case notEnoughSpace(needed: Int64, free: Int64)
        case incomplete
        case cancelled

        public var description: String {
            switch self {
            case .running: "Close the game (and its launcher) before moving it"
            case .disconnected(let drive): "\(drive) is not connected"
            case .unsuitable(let problem): problem.description
            case .alreadyThere: "The game is already there"
            case .exists(let path): "\(path) already exists"
            case .notEnoughSpace(let needed, let free):
                "It needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)); "
                    + "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) are free there"
            case .incomplete: "The copy does not match the original; the game stays where it was"
            case .cancelled: "Cancelled; the game stays where it was"
            }
        }
    }

    /// The files of a bottle: what the copy writes and what its disk needs.
    public struct Size: Sendable, Equatable {
        public var files = 0
        public var bytes: Int64 = 0
        public var allocated: Int64 = 0
    }

    public static func size(of root: URL) -> Size {
        var size = Size()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else { return size }
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            size.files += 1
            size.bytes += Int64(values.fileSize ?? 0)
            size.allocated += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return size
    }

    /// Moves `entry`'s bottle into `location` (a `Riftway` folder, made if
    /// needed, or the home's `Bottles`) and returns its new root. The caller
    /// rebuilds its bridges, which name the bottle's path. `progress` gets the
    /// copied fraction; `isCancelled` stops a copy between two blocks.
    @discardableResult
    public static func move(_ entry: LibraryEntry, to location: URL, home: RiftwayHome,
                            progress: @escaping @Sendable (Double) -> Void = { _ in },
                            isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> URL {
        let fm = FileManager.default
        let source = entry.root.standardizedFileURL
        let location = location.standardizedFileURL
        guard location != source.deletingLastPathComponent() else { throw Failure.alreadyThere }
        guard !WineServer.isRunning(prefix: source.appendingPathComponent("prefix")) else { throw Failure.running }
        guard BottleLocations.isAvailable(location) else { throw Failure.disconnected(drive: BottleLocations.driveName(location)) }
        if location != home.bottles.standardizedFileURL {
            if let problem = BottleLocations.problem(for: location) { throw Failure.unsuitable(problem) }
            try home.addLocation(location, install: false)
        } else {
            try fm.createDirectory(at: location, withIntermediateDirectories: true)
        }
        let target = location.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        guard !fm.fileExists(atPath: target.path) else { throw Failure.exists(target.path) }

        if BottleLocations.sameVolume(source, location) {
            try fm.moveItem(at: source, to: target)
            progress(1)
            return target
        }
        let size = size(of: source)
        // "For important usage" counts purgeable space but is 0 on external
        // disks; the plain figure is right there.
        if let values = try? location.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) {
            let free = max(values.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values.volumeAvailableCapacity ?? 0))
            if free < size.allocated + 1_000_000_000 { throw Failure.notEnoughSpace(needed: size.allocated, free: free) }
        }
        let staging = location.appendingPathComponent(".\(source.lastPathComponent)-moving-\(UUID().uuidString)", isDirectory: true)
        do {
            try copy(source, to: staging, bytes: size.bytes, progress: progress, isCancelled: isCancelled)
            let copied = Self.size(of: staging)
            guard copied.files == size.files, copied.bytes == size.bytes else { throw Failure.incomplete }
            try fm.moveItem(at: staging, to: target)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        try fm.removeItem(at: source)
        progress(1)
        return target
    }

    private final class CopyState: @unchecked Sendable {
        let total: Int64
        let progress: @Sendable (Double) -> Void
        let isCancelled: @Sendable () -> Bool
        var done: Int64 = 0
        var current: Int64 = 0
        var cancelled = false
        var lastReport = 0.0

        init(total: Int64, progress: @escaping @Sendable (Double) -> Void, isCancelled: @escaping @Sendable () -> Bool) {
            self.total = max(total, 1)
            self.progress = progress
            self.isCancelled = isCancelled
        }

        func report() {
            let fraction = min(Double(done + current) / Double(total), 1)
            if fraction - lastReport >= 0.002 || fraction == 1 {
                lastReport = fraction
                progress(fraction)
            }
        }
    }

    /// `copyfile` of the whole tree, as it is (symlinks are not followed).
    static func copy(_ source: URL, to destination: URL, bytes: Int64,
                     progress: @escaping @Sendable (Double) -> Void, isCancelled: @escaping @Sendable () -> Bool) throws {
        let state = CopyState(total: bytes, progress: progress, isCancelled: isCancelled)
        let copier = copyfile_state_alloc()
        defer { copyfile_state_free(copier) }
        let callback: copyfile_callback_t = { what, stage, copier, _, _, context in
            guard let context else { return COPYFILE_CONTINUE }
            let state = Unmanaged<CopyState>.fromOpaque(context).takeUnretainedValue()
            if state.isCancelled() {
                state.cancelled = true
                return COPYFILE_QUIT
            }
            switch (what, stage) {
            case (COPYFILE_COPY_DATA, COPYFILE_PROGRESS):
                var copied: off_t = 0
                copyfile_state_get(copier, UInt32(COPYFILE_STATE_COPIED), &copied)
                state.current = Int64(copied)
                state.report()
            case (COPYFILE_RECURSE_FILE, COPYFILE_FINISH):
                state.done += state.current
                state.current = 0
            default: break
            }
            return COPYFILE_CONTINUE
        }
        copyfile_state_set(copier, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(copier, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(state).toOpaque())
        let status = withExtendedLifetime(state) {
            copyfile(source.path, destination.path, copier, copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW))
        }
        if state.cancelled { throw Failure.cancelled }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
