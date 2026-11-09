import Foundation
import Darwin

// One store owns one cache. All disk access and decoding remain on the utility
// task; a pass is serialized so overlapping readers cannot mix generations.
final class SnapshotFileCache: @unchecked Sendable {
    private struct Stamp: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modified: timespec
        let changed: timespec
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size &&
            lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec &&
            lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
        init?(_ url: URL) {
            var info = stat()
            guard url.path.withCString({ fstatat(AT_FDCWD, $0, &info, 0) }) == 0 else { return nil }
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            modified = info.st_mtimespec; changed = info.st_ctimespec
        }
    }
    private struct Entry { let stamp: Stamp; let type: String; let value: Any? }
    private let lock = NSRecursiveLock()
    private var entries: [String: Entry] = [:]
    private var used: Set<String> = []
    private(set) var reads = 0
    private(set) var bytesRead = 0

    func withPass<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        used = []
        let result = body()
        entries = entries.filter { used.contains($0.key) }
        return result
    }

    func value<T>(_ url: URL, decode: (Data) -> T?) -> T? {
        lock.lock(); defer { lock.unlock() }
        let key = url.path, type = String(reflecting: T.self)
        used.insert(key)
        guard let before = Stamp(url) else { entries.removeValue(forKey: key); return nil }
        if let entry = entries[key], entry.stamp == before, entry.type == type {
            return entry.value as? T
        }
        guard let bytes = try? Data(contentsOf: url) else { entries.removeValue(forKey: key); return nil }
        reads += 1; bytesRead += bytes.count
        let value = decode(bytes)
        // Atomic replacements and in-place writes during a read are retried next pass.
        if Stamp(url) == before { entries[key] = Entry(stamp: before, type: type, value: value) }
        else { entries.removeValue(forKey: key) }
        return value
    }
}
