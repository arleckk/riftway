import AppKit
import Observation
import RiftwayCore

/// Update checks against the signed release feed (PRD-06 R5, R6, R9): at
/// most once a day when automatic checks are on, or from the menu. Profiles
/// install silently; a new app or runtime is offered in a sheet.
@MainActor @Observable
final class UpdateModel {
    enum Phase: Equatable {
        case idle
        case checking
        /// Something to offer: the app, runtimes, or both.
        case available
        case installing(String)
        case upToDate
        case failed(String)
    }

    var phase: Phase = .idle
    var showsSheet = false
    private(set) var manifest: ReleaseManifest?
    let feedURL = Updater.configuredFeedURL
    private let log = Log()
    static let automaticKey = "automaticUpdateChecks"

    /// Checks run only when a release location is configured; the player can
    /// turn automatic checks off (the only connections Riftway makes, R9).
    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.automaticKey) }
    }

    var updater: Updater? { feedURL.map { Updater(feedURL: $0) } }

    var newApp: ReleaseManifest.AppRelease? {
        guard let app = manifest?.app, VersionNumber.isNewer(app.version, than: Riftway.version),
              VersionNumber.macOS(meets: app.minimumMacOS) else { return nil }
        return app
    }

    var newRuntimes: [ReleaseManifest.RuntimeRelease] {
        guard let manifest, let updater else { return [] }
        return updater.newRuntimes(in: manifest)
    }

    var lastCheck: Date? { updater?.state.lastCheck }

    func checkIfDue() {
        guard automatic, let updater, updater.isCheckDue else { return }
        check(manual: false)
    }

    func check(manual: Bool) {
        guard let updater else {
            if manual { phase = .failed("Esta versión de Riftway no tiene configurado dónde buscar actualizaciones."); showsSheet = true }
            return
        }
        guard phase != .checking else { return }
        phase = .checking
        if manual { showsSheet = true }
        Task {
            do {
                let manifest = try await updater.check()
                self.manifest = manifest
                let count = try await Task.detached { try updater.install(profiles: manifest.profiles) }.value
                log.write("update: feed of \(manifest.generated), \(count) profiles" + (manifest.app.map { ", app \($0.version)" } ?? ""))
                if newApp != nil || !newRuntimes.isEmpty {
                    phase = .available
                    showsSheet = true
                } else {
                    phase = .upToDate
                }
            } catch Updater.Failure.download(_, status: 404) {
                // The feed's address has no release yet.
                log.write("update: no release published yet")
                phase = .failed("Todavía no hay versiones publicadas.")
            } catch {
                log.write("update: check failed: \(error)")
                phase = .failed("\(error)")
            }
        }
    }

    /// Downloads and checks the new app, then quits so its helper swaps the
    /// bundle and reopens it. Nothing changes if any step fails.
    func installApp(_ release: ReleaseManifest.AppRelease) {
        guard let updater, let current = Updater.appBundle else {
            phase = .failed("Riftway no está corriendo desde su app (Riftway.app); actualízalo compilando desde el código.")
            return
        }
        phase = .installing("Descargando Riftway \(release.version)…")
        Task {
            do {
                let staged = try await updater.stage(app: release, replacing: current)
                try Updater.launchApply(staged: staged, target: current)
                log.write("update: Riftway \(release.version) staged; quitting to install it")
                NSApp.terminate(nil)
            } catch {
                phase = .failed("\(error)")
            }
        }
    }

    func installRuntime(_ release: ReleaseManifest.RuntimeRelease, then done: @escaping () -> Void) {
        guard let updater else { return }
        phase = .installing("Descargando el runtime \(release.version) (\(release.download.size / 1_000_000) MB)…")
        Task {
            do {
                _ = try await updater.install(runtime: release)
                log.write("update: runtime \(release.version) installed")
                done()
                phase = newApp != nil || !newRuntimes.isEmpty ? .available : .upToDate
            } catch {
                phase = .failed("\(error)")
            }
        }
    }
}
