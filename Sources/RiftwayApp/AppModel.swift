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
