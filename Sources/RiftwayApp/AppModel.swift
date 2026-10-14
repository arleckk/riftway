import AppKit
import Observation
import RiftwayCore

/// A file the user opened, waiting to be shown in the analysis sheet.
struct PendingFile: Identifiable {
    let id = UUID()
    let url: URL
    var report: InstallerReport?
    /// The game's profile, found from the installer.
    var profile: GameProfile?
}

@MainActor @Observable
final class AppModel {
    /// Files opened from Finder, the Dock or a drop, shown one at a time.
    private(set) var queue: [PendingFile] = []
    /// The first-launch offer to open Windows files with Riftway. It waits until
    /// the files the app was opened with have been reviewed: one sheet at a time.
    private var offersAssociation = false
    var showsAssociationOffer: Bool {
        get { offersAssociation && queue.isEmpty }
        set { if !newValue { offersAssociation = false } }
    }

    private let log = Log()
    let profiles = ProfileStore.standard()
    static let associationOfferedKey = "didOfferFileAssociation"

    var current: PendingFile? { queue.first }
    var remaining: Int { max(0, queue.count - 1) }

    // MARK: Launchers

    /// A sidebar section to show (the File menu and the empty library ask for Launchers).
    var requestedSection: SidebarItem?
    /// Each launcher downloading now, and how far (0…1).
    private(set) var launcherProgress: [String: Double] = [:]
    /// Why the last download was refused or failed, by launcher.
    private(set) var launcherProblem: [String: String] = [:]
    private var launcherTasks: [String: Task<Void, Never>] = [:]

    /// Downloads the launcher's Windows installer and, once its publisher's
    /// signature checks out, shows it in the analysis sheet like any other.
    func getLauncher(_ launcher: StoreLauncher) {
        guard launcherTasks[launcher.id] == nil else { return }
        launcherProblem[launcher.id] = nil
        launcherProgress[launcher.id] = 0
        launcherTasks[launcher.id] = Task {
            do {
                let file = try await StoreLauncherDownload.run(launcher) { [weak self] fraction in
                    Task { @MainActor in
                        if self?.launcherProgress[launcher.id] != nil { self?.launcherProgress[launcher.id] = fraction }
                    }
                }
                log.write("app: downloaded \(launcher.name)'s installer")
                finishLauncher(launcher.id)
                open([file])
            } catch is CancellationError {
                finishLauncher(launcher.id)
            } catch let error as URLError where error.code == .cancelled {
                finishLauncher(launcher.id)
            } catch {
                finishLauncher(launcher.id)
                launcherProblem[launcher.id] = (error as? StoreLauncherDownload.Failure)?.description ?? error.localizedDescription
            }
        }
    }

    func cancelLauncher(_ launcher: StoreLauncher) {
        launcherTasks[launcher.id]?.cancel()
    }

    private func finishLauncher(_ id: String) {
        launcherTasks[id] = nil
        launcherProgress[id] = nil
    }

    func start() {
        if !UserDefaults.standard.bool(forKey: Self.associationOfferedKey), !FileAssociation.isRiftwayDefaultForAll {
            offersAssociation = true
        }
    }

    func open(_ urls: [URL]) {
        for url in urls where !queue.contains(where: { $0.url == url }) {
            let file = PendingFile(url: url)
            queue.append(file)
            analyze(file.id, url)
        }
    }

    func dismissCurrent() {
        guard !queue.isEmpty else { return }
        queue.removeFirst()
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FileAssociation.types
        panel.allowsMultipleSelection = true
        panel.message = "Elige un instalador o programa de Windows"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    func associationOfferAnswered(accept: Bool) {
        UserDefaults.standard.set(true, forKey: Self.associationOfferedKey)
        offersAssociation = false
        if accept { Task { await FileAssociation.makeRiftwayDefault() } }
    }

    private func analyze(_ id: UUID, _ url: URL) {
        Task {
            let profiles = profiles
            let (report, profile) = await Task.detached(priority: .userInitiated) {
                let report = InstallerAnalyzer.analyze(url)
                return (report, profiles.match(ProfileQuery(report: report, hash: profiles.usesHashes)))
            }.value
            log.write("app: analyzed \(url.lastPathComponent): \(report.kind)" + (profile.map { ", profile \($0.id)" } ?? ""))
            guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
            queue[index].report = report
            queue[index].profile = profile
        }
    }
}
