import Foundation

/// Whether a prefix's wineserver is running, whoever started it (Riftway, a
/// bridge opened by a website, a launcher). Wine keeps the server in
/// `/tmp/.wine-<uid>/server-<dev>-<inode>/` of the prefix folder, and the
/// server holds a write lock on the first byte of its `lock` file while it
/// lives (`server/request.c`). Testing the lock with F_GETLK neither takes it
/// nor talks to the server.
public enum WineServer {
    public static func directory(forPrefix prefix: URL) -> URL? {
        var info = stat()
        guard stat(prefix.path, &info) == 0 else { return nil }
        let name = "server-" + String(UInt64(UInt32(bitPattern: info.st_dev)), radix: 16) + "-" + String(UInt64(info.st_ino), radix: 16)
        return URL(fileURLWithPath: "/tmp/.wine-\(getuid())", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    public static func isRunning(prefix: URL) -> Bool {
        guard let lock = directory(forPrefix: prefix)?.appendingPathComponent("lock") else { return false }
        let fd = open(lock.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var query = flock()
        query.l_type = Int16(F_WRLCK)
        query.l_whence = Int16(SEEK_SET)
        query.l_start = 0
        query.l_len = 1
        guard fcntl(fd, F_GETLK, &query) != -1 else { return false }
        return query.l_type == Int16(F_WRLCK)
    }
}
