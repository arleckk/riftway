import Foundation

/// Removing Riftway (PRD-06 R8): everything goes to the Trash, nothing is
/// deleted. Bottles hold the games and their saves, so they go only when the
/// player says so; without them, the runtimes and downloads still go, and
/// the bottles (with their saved launch links) wait for a reinstall.
public struct Uninstaller: Sendable {
    public var home: RiftwayHome
    public var app: URL?

    public init(home: RiftwayHome = .standard, app: URL? = Updater.appBundle) {
        self.home = home
        self.app = app
    }

    /// What goes to the Trash, in order: bridges first (unregistered), then
    /// Riftway's data, then the app.
    public func items(includingBottles: Bool) -> [URL] {
        let fm = FileManager.default
        var items: [URL] = []
        if fm.fileExists(atPath: home.bridges.path) { items.append(home.bridges) }
        if includingBottles {
            if fm.fileExists(atPath: home.root.path) { items.append(home.root) }
        } else {
            for folder in ["Runtimes", "Updates"] {
                let url = home.root.appendingPathComponent(folder, isDirectory: true)
                if fm.fileExists(atPath: url.path) { items.append(url) }
            }
        }
        if let app, fm.fileExists(atPath: app.path) { items.append(app) }
        return items
    }

    /// Stops every bottle, unregisters the bridges and moves `items` to the
    /// Trash. Returns what could not be moved.
    @discardableResult
    public func run(includingBottles: Bool) -> [URL] {
        let library = Library(home: home)
        for entry in library.entries() { try? entry.setup?.killAll() }
        let fm = FileManager.default
        if let bridges = try? fm.contentsOfDirectory(at: home.bridges, includingPropertiesForKeys: nil) {
            for bridge in bridges where bridge.pathExtension == "app" { try? ShimBundle.unregister(bridge) }
        }
        var failed: [URL] = []
        for item in items(includingBottles: includingBottles) {
            var trashed: NSURL?
            do {
                try fm.trashItem(at: item, resultingItemURL: &trashed)
                // LaunchServices re-indexes a bundle in the Trash too.
                if item.pathExtension == "app", let trashed = trashed as URL? { try? ShimBundle.unregister(trashed) }
                if item == home.bridges, let trashed = trashed as URL?,
                   let moved = try? fm.contentsOfDirectory(at: trashed, includingPropertiesForKeys: nil) {
                    for bridge in moved where bridge.pathExtension == "app" { try? ShimBundle.unregister(bridge) }
                }
            } catch {
                failed.append(item)
            }
        }
        Log().write("uninstall: moved Riftway to the Trash" + (includingBottles ? " with its bottles" : ", bottles kept"))
        return failed
    }
}
