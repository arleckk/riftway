import AppKit
import RiftwayCore

let usage = """
riftway — route URLs from macOS into Windows programs running in Wine

  riftway bottles
      List CrossOver bottles and the URL protocols registered in each.
  riftway resolve <url> (--bottle NAME | --prefix DIR --wine PATH)
      Show the command a URL would start (the URL itself is redacted).
  riftway open <url> (--bottle NAME | --prefix DIR --wine PATH) [--dry-run]
      Hand a URL to the program that registered its scheme in the bottle.
  riftway make-shim (--runtime DIR --at DIR | --bottle NAME | --prefix DIR --wine PATH) [--name NAME]
                    [--app-dpi DPI:A.exe;B.exe] [--mouselook EXE]... [--env K=V]...
                    [--scheme S]... [--arg A]... [--icon FILE] [--output DIR]
                    [--register] [--default] [--dry-run] [--wine-log]
      Build the app macOS opens for the bottle's URL schemes (all registered
      ones unless --scheme is given), in ~/Applications/Riftway by default.
      --register adds it to LaunchServices, --default makes it the handler.
  riftway remove-shim <app>
      Unregister a shim and move it to the Trash.
  riftway bottle-create --runtime DIR --at DIR [--name NAME]
      Create a bottle on a Riftway runtime (wineboot, no Z: drive, settings).
  riftway bottle-isolate --runtime DIR --at DIR
      Remove the Z: drive and map R: to the runtime's shared data.
  riftway bottle-fonts --runtime DIR --at DIR
      Link Windows UI fonts to the Mac's CJK fonts in an existing bottle.
  riftway bottle-wine --runtime DIR --at DIR [--timeout S] [--debug CHANNELS] -- ARGS...
      Run the runtime's wine in a bottle's environment (wine ARGS…), wait for it.
  riftway inspect <file.exe|file.msi>...
      Analyze Windows installers and programs without running them.

Library (~/Library/Application Support/Riftway, or $RIFTWAY_HOME):
  riftway runtime-install <runtime folder>
      Install an assembled runtime (work/runtime/artifacts/<version>) for new bottles.
  riftway runtimes
      List installed runtimes, newest first.
  riftway install <installer> [--name NAME] [--installer-arg A]... [--no-bridge] [--default]
      New bottle, run the installer (its wizard shows), discover what it left,
      add the game to the library and build its bridge app.
  riftway library
      List the games and what Play starts.
  riftway play <game> [--wait]
      Start the game's primary program (or open its web page).
  riftway rediscover <game> [--bridge]
      Look for programs and URL protocols a launcher installed since.
  riftway bridge <game> [--default]
      Rebuild the game's bridge app (schemes and Play).
  riftway adopt <bottle folder> --baseline-from <fresh bottle> [--name NAME] [--runtime-version V]
                [--app-dpi DPI:A.exe;B.exe] [--diagnostics] [--program-dll EXE:DLL=MODE]... [--default]
      Move an existing Riftway bottle into the library (same disk: a rename),
      re-point R:, record a baseline from a fresh bottle on the same runtime,
      discover its game and build its bridge.
  riftway play-setup <game> (--link [--scheme S] | --command PATH [--args "ARGS"] | --reset)
      What Play starts. --link: the last link the game's site sent to the bridge
      (remembered automatically), or one pasted on standard input (never as an
      argument); links are kept in <home>/Secrets, outside every bottle.
  riftway diagnostics <game> on|off
      Diagnostic mode: Wine's errors and DLL loads in the bottle's logs/session-*.log.
  riftway program-dll <game> <program.exe> <dll> <mode|off|remove>
      A DLL override for one program of the game (mode: n, b, n,b, b,n; off = disabled).

Profiles and compatibility (profiles/ in the app, plus <home>/Profiles):
  riftway profiles [--check FILE...]
      List the known profiles, or validate profile files (what CI runs).
  riftway profile <game> [ID | --none | --auto]
      Show the game's profile and compatibility, or set it (--auto: find one)
      and write it to the bottle (registry, per-program overrides, dxmt.conf).
  riftway anticheat <folder>
      Look for anti-cheats in a folder (a game's or a bottle's drive_c).
"""

struct Options {
    var positional: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []

    static let valued: Set<String> = ["--bottle", "--prefix", "--wine", "--name", "--scheme", "--arg", "--icon", "--output",
                                      "--runtime", "--at", "--timeout", "--debug", "--app-dpi", "--mouselook", "--env",
                                      "--baseline-from", "--installer-arg", "--runtime-version", "--program-dll", "--command", "--args"]
    /// Everything after `--`, passed through untouched.
    var passthrough: [String] = []

    init(_ args: ArraySlice<String>) throws {
        var it = args.makeIterator()
        while let arg = it.next() {
            if arg == "--" {
                while let rest = it.next() { passthrough.append(rest) }
                break
            }
            if Self.valued.contains(arg) {
                guard let value = it.next() else { throw CLIError("\(arg) needs a value") }
                values[arg, default: []].append(value)
            } else if arg.hasPrefix("--") {
                flags.insert(arg)
            } else {
                positional.append(arg)
            }
        }
    }

    func one(_ key: String) -> String? { values[key]?.last }
    func many(_ key: String) -> [String] { values[key] ?? [] }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Per-game switches: --app-dpi "192:A.exe;B.exe", --mouselook EXE…, --env K=V…, --debug CHANNELS.
func gameOptions(from options: Options) throws -> GameOptions {
    var game = GameOptions()
    if let spec = options.one("--app-dpi") {
        let parts = spec.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let dpi = Int(parts[0]) else { throw CLIError("--app-dpi takes DPI:A.exe;B.exe") }
        game.appDPI = (dpi, parts[1].split(separator: ";").map(String.init))
    }
    game.mouselook = options.many("--mouselook")
    for pair in options.many("--env") {
        let kv = pair.split(separator: "=", maxSplits: 1)
        guard kv.count == 2 else { throw CLIError("--env takes NAME=VALUE") }
        game.environment[String(kv[0])] = String(kv[1])
    }
    if let debug = options.one("--debug") { game.environment["WINEDEBUG"] = debug }
    return game
}

func bottle(from options: Options) throws -> Bottle {
    if options.one("--runtime") != nil, options.one("--at") != nil {
        return try bottleSetup(options).bottle
    }
    if let name = options.one("--bottle") {
        guard let found = CrossOver.bottle(named: name) else { throw CLIError("No CrossOver bottle named \(name) in \(CrossOver.bottlesDirectory.path)") }
        return found
    }
    if let prefix = options.one("--prefix"), let wine = options.one("--wine") {
        let url = URL(fileURLWithPath: prefix).standardizedFileURL
        return Bottle(name: url.lastPathComponent, prefix: url.path, backend: .wine(wine: wine))
    }
    throw CLIError("Choose a bottle: --runtime DIR --at DIR (Riftway), --bottle NAME (CrossOver), or --prefix DIR --wine PATH")
}

func listBottles() {
    let bottles = CrossOver.bottles()
    if bottles.isEmpty { print("No CrossOver bottles in \(CrossOver.bottlesDirectory.path)") }
    for bottle in bottles {
        print(bottle.name)
        let protocols = bottle.urlProtocols()
        if protocols.isEmpty { print("  (no URL protocols)") }
        for p in protocols {
            let note = p.isClaimableFromMacOS ? "" : "  (left to macOS)"
            print("  \(p.scheme):  \(p.command)  [\(p.hive.rawValue)]\(note)")
        }
    }
}

/// The first `.ico` beside the program the scheme starts, as installers leave one.
func guessIcon(bottle: Bottle, schemes: [String]) -> URL? {
    let protocols = bottle.urlProtocols()
    for scheme in schemes {
        guard let exe = protocols.first(where: { $0.scheme == scheme })?.windowsExecutable,
              let folder = bottle.unixURL(forWindowsPath: exe)?.deletingLastPathComponent(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              let ico = names.sorted().first(where: { $0.lowercased().hasSuffix(".ico") })
        else { continue }
        return folder.appendingPathComponent(ico)
    }
    return nil
}

func makeShim(_ options: Options) async throws {
    let bottle = try bottle(from: options)
    let registered = bottle.urlProtocols().filter(\.isClaimableFromMacOS).map(\.scheme)
    var schemes = options.many("--scheme").map { $0.lowercased() }
    if schemes.isEmpty { schemes = registered }
    guard !schemes.isEmpty else { throw CLIError("Bottle \(bottle.name) registers no URL protocols of its own") }
    for scheme in schemes where !registered.contains(scheme) {
        throw CLIError("Bottle \(bottle.name) has no claimable \(scheme): protocol (claimable: \(registered.joined(separator: ", ")))")
    }

    var config = ShimConfig(displayName: options.one("--name") ?? bottle.name, bottle: bottle, schemes: schemes,
                            extraArguments: options.many("--arg"), dryRun: options.flags.contains("--dry-run"))
    config.wineLog = options.flags.contains("--wine-log")
    // Fail now, not on the first click, if the registered program is missing.
    _ = try config.bridge.planForProgram()

    let shimBinary = Bundle.main.executableURL!.resolvingSymlinksInPath().deletingLastPathComponent()
        .appendingPathComponent(ShimBundle.executableName)
    guard FileManager.default.isExecutableFile(atPath: shimBinary.path) else {
        throw CLIError("\(ShimBundle.executableName) was not found next to riftway (\(shimBinary.path)); build both products")
    }
    let output = options.one("--output").map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Riftway", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let icon = options.one("--icon").map { URL(fileURLWithPath: $0) } ?? guessIcon(bottle: bottle, schemes: schemes)

    let app = try ShimBundle.build(config: config, shimBinary: shimBinary, icon: icon, in: output)
    print("Built \(app.path)")
    print("  schemes: \(schemes.joined(separator: ", "))\(config.dryRun ? "  (dry run: logs instead of starting Wine)" : "")")

    if options.flags.contains("--register") || options.flags.contains("--default") {
        try ShimBundle.register(app)
        print("  registered with LaunchServices")
    }
    if options.flags.contains("--default") {
        for scheme in schemes {
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)
            print("  default handler for \(scheme):")
        }
    }
}

func describe(_ report: InstallerReport) -> String {
    let kind: String = switch report.kind {
    case .installer(let type): "installer (\(type.displayName))"
    case .portable: "program (no installer)"
    case .unsupported(let reason): "unsupported: \(reason)"
    }
    let signature: String = switch report.signature {
    case .unsigned: "unsigned"
    case .signed(let signer, let trusted): "signed by \(signer)\(trusted ? "" : " (chain not trusted by macOS)")"
    case .invalid(let reason): "INVALID: \(reason.rawValue)"
    case .unverified: "present, not verified (MSI)"
    }
    var lines = ["\(report.file.lastPathComponent)  [\(ByteCountFormatter.string(fromByteCount: report.fileSize, countStyle: .file))]",
                 "  kind:       \(kind)",
                 "  name:       \(report.displayName)"]
    let optional: [(String, String?)] = [("company", report.company), ("version", report.version),
                                         ("arch", report.architecture), ("execution", report.executionLevel),
                                         ("description", report.fileDescription)]
    for (label, value) in optional { if let value { lines.append("  \(label.padding(toLength: 11, withPad: " ", startingAt: 0)) \(value)") } }
    lines.append("  signature:  \(signature)")
    if report.isDotNet { lines.append("  .NET:       yes") }
    lines.append("  icon:       \(report.icon.map { "\($0.count) bytes" } ?? "none")")
    if !report.origin.isEmpty { lines.append("  origin:     \(report.origin.joined(separator: " ← "))") }
    if report.isQuarantined { lines.append("  quarantine: yes") }
    if !report.companions.isEmpty { lines.append("  companions: \(report.companions.map(\.lastPathComponent).joined(separator: ", "))") }
    return lines.joined(separator: "\n")
}

func describe(_ result: InstallResult) -> String {
    func target(_ p: DiscoveredProgram) -> String {
        switch p.target {
        case .executable(let path, let arguments): path + (arguments.map { $0.isEmpty ? "" : " " + $0 } ?? "")
        case .web(let url): "web: " + url
        }
    }
    var lines: [String] = []
    lines.append("primary:    " + (result.primary.map { "\($0.name) → \(target($0))" } ?? "none"))
    for p in result.programs { lines.append("program:    \(p.name) → \(target(p))") }
    for u in result.uninstall { lines.append("uninstall:  \(u.displayName ?? u.key) [\(u.publisher ?? "?")] \(u.uninstallString ?? "")") }
    for p in result.protocols { lines.append("protocol:   \(p.scheme): \(p.command)") }
    if !result.associations.isEmpty { lines.append("extensions: " + result.associations.joined(separator: " ")) }
    for d in result.drivers { lines.append("driver:     \(d.name) type=\(d.type.map(String.init) ?? "?") \(d.imagePath ?? "")") }
    for e in result.executables.prefix(5) { lines.append("exe:        \(e)") }
    for a in result.anticheat { lines.append("anti-cheat: \(describe(a))") }
    lines.append("changed files: \(result.changedFiles)")
    return lines.joined(separator: "\n")
}

func describe(_ finding: AntiCheatFinding) -> String {
    finding.vendor.displayName + (finding.driver ? " (kernel driver)" : "") + (finding.protonModule ? " (Proton module shipped)" : "")
        + "  ← " + finding.evidence
}

func describe(_ c: Compatibility) -> String {
    var lines = ["status:     " + c.status.rawValue + (c.profile.map { " (profile \($0.id), revision \($0.revision))" } ?? " (no profile)")]
    if let tested = c.profile?.tested {
        lines.append("tested:     \(tested.date), macOS \(tested.macos), \(tested.hardware), runtime \(tested.runtime)" + (tested.online == true ? ", online" : ""))
    }
    if let info = c.profile?.anticheat {
        lines.append("anti-cheat: \(info.vendor.displayName) (\(info.kernel ? "needs its kernel driver" : "user mode"), per the profile)")
    }
    for a in c.anticheat { lines.append("found:      \(describe(a))") }
    if let notes = c.profile?.notes { lines.append("notes:      " + notes) }
    return lines.joined(separator: "\n")
}

func shimBinary() throws -> URL {
    let shim = Bundle.main.executableURL!.resolvingSymlinksInPath().deletingLastPathComponent()
        .appendingPathComponent(ShimBundle.executableName)
    guard FileManager.default.isExecutableFile(atPath: shim.path) else {
        throw CLIError("\(ShimBundle.executableName) was not found next to riftway (\(shim.path)); build both products")
    }
    return shim
}

func findGame(_ library: Library, _ query: String?) throws -> LibraryEntry {
    guard let query else { throw CLIError("Pass the game (its name or id)") }
    let entries = library.entries()
    if let exact = entries.first(where: { $0.id == query || $0.game.name.caseInsensitiveCompare(query) == .orderedSame }) { return exact }
    let matches = entries.filter { $0.game.name.localizedCaseInsensitiveContains(query) }
    guard matches.count == 1 else {
        throw CLIError(matches.isEmpty ? "No game matches \(query)" : "Several games match \(query): " + matches.map(\.game.name).joined(separator: ", "))
    }
    return matches[0]
}

func target(_ program: DiscoveredProgram?) -> String {
    switch program?.target {
    case .executable(let path, let arguments): path + (arguments.map { $0.isEmpty ? "" : " " + $0 } ?? "")
    case .web(let url): url + " (web page)"
    case nil: "nothing to start"
    }
}

func setDefault(_ app: URL, schemes: [String]) async throws {
    for scheme in schemes {
        try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)
        print("  default handler for \(scheme):")
    }
}

func install(_ options: Options) async throws {
    guard let path = options.positional.first else { throw CLIError("Pass the installer") }
    let library = Library()
    guard let runtime = library.home.installedRuntimes().first else {
        throw CLIError("No runtime installed; run: riftway runtime-install work/runtime/artifacts/<version>")
    }
    let report = InstallerAnalyzer.analyze(URL(fileURLWithPath: path).standardizedFileURL)
    print(describe(report))
    if case .unsupported = report.kind { throw CLIError("Riftway can't install this file") }
    let profile = library.profiles.match(ProfileQuery(report: report, hash: library.profiles.usesHashes))
    print(describe(Compatibility(profile: profile)))
    let installation = Installation(report: report, name: options.one("--name"), runtime: runtime, library: library, profile: profile)
    print("Bottle: \(installation.root.path) (runtime \(runtime.version))")
    let start = Date()
    let result = try installation.run(arguments: options.many("--installer-arg")) { stage in
        switch stage {
        case .creatingBottle: print("Creating the bottle…")
        case .copyingInstaller: print("Copying the installer into the bottle…")
        case .runningInstaller: print("Running the installer (finish its wizard)…")
        case .discovering: print("Looking for what it installed…")
        }
    }
    print(describe(result))
    print(String(format: "(%.0f s)", Date().timeIntervalSince(start)))
    if result.isEmpty {
        print("The installer left nothing to start. The bottle stays at \(installation.root.path).")
        return
    }
    let game = installation.makeGame(result)
    try library.save(game, in: installation.root)
    print("Added to the library: \(game.name) → \(target(game.primary))")
    guard var entry = library.entry(at: installation.root) else { return }
    if let updated = try library.updateProfile(entry) {
        entry = updated
        print("Profile: \(updated.profile?.id ?? "none")")
    }
    print(describe(entry.compatibility))
    guard !options.flags.contains("--no-bridge") else { return }
    let app = try GameLauncher.makeBridge(for: entry, shimBinary: try shimBinary(), home: library.home)
    try library.save({ var g = game; g.bridge = app.path; return g }(), in: installation.root)
    print("Bridge: \(app.path)" + (game.schemes.isEmpty ? "" : " (schemes: \(game.schemes.joined(separator: ", ")))"))
    if options.flags.contains("--default") { try await setDefault(app, schemes: game.schemes) }
}

func play(_ options: Options) throws {
    let library = Library()
    let entry = try findGame(library, options.positional.first)
    switch try GameLauncher.action(for: entry) {
    case .openWebPage(let url):
        NSWorkspace.shared.open(url)
        print("Opened \(url.absoluteString)")
    case .wine(let plan, let log):
        let pid = try Launcher.start(plan, outputLog: log)
        print("Started \(entry.game.name) (pid \(pid))" + (log.map { "; log: \($0.path)" } ?? ""))
    }
    var game = entry.game
    game.lastPlayed = Date()
    try library.save(game, in: entry.root)
    if options.flags.contains("--wait") {
        try GameLauncher.waitForSessionEnd(entry)
        let (updated, newSchemes) = try library.rediscover(entry)
        print("Session ended. Programs: \(updated.programs.count); new schemes: \(newSchemes.isEmpty ? "none" : newSchemes.joined(separator: ", "))")
    }
}

func adopt(_ options: Options) async throws {
    guard let path = options.positional.first, let fresh = options.one("--baseline-from") else {
        throw CLIError("Pass the bottle folder and --baseline-from <a fresh bottle on the same runtime>")
    }
    let fm = FileManager.default
    let source = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    let library = Library()
    guard fm.fileExists(atPath: source.appendingPathComponent("prefix/system.reg").path),
          let recordData = try? Data(contentsOf: source.appendingPathComponent("bottle.json")) else {
        throw CLIError("\(source.path) is not a Riftway bottle (prefix/system.reg and bottle.json)")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var record = try decoder.decode(BottleRecord.self, from: recordData)
    let version = options.one("--runtime-version") ?? record.runtimeVersion
    guard let runtime = library.home.runtime(version: version) else {
        throw CLIError("Runtime \(version) is not installed (riftway runtime-install …)")
    }
    record.runtimeVersion = version
    if let spec = options.one("--app-dpi") {
        let parts = spec.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let dpi = Int(parts[0]) else { throw CLIError("--app-dpi takes DPI:A.exe;B.exe") }
        record.options.appDPI = (dpi, parts[1].split(separator: ";").map(String.init))
    }
    if options.flags.contains("--diagnostics") { record.options.diagnostics = true }
    for spec in options.many("--program-dll") {
        // EXE:DLL=MODE, MODE empty for disabled
        guard let colon = spec.lastIndex(of: ":"), let equals = spec.lastIndex(of: "="), colon < equals else {
            throw CLIError("--program-dll takes EXE:DLL=MODE")
        }
        let exe = String(spec[..<colon]), dll = String(spec[spec.index(after: colon)..<equals])
        record.options.programDllOverrides[exe, default: [:]][dll] = String(spec[spec.index(after: equals)...])
    }

    let name = options.one("--name") ?? record.name
    let root = library.home.newBottleRoot(for: name)
    try fm.createDirectory(at: library.home.bottles, withIntermediateDirectories: true)
    try fm.moveItem(at: source, to: root)
    print("Moved to \(root.path)")
    let setup = BottleSetup(runtime: runtime.runtime, root: root, options: record.options, runtimeVersion: record.runtimeVersion)
    try setup.isolate()
    record.name = name
    try library.save(record, in: root)

    let baseline = PrefixSnapshot.capture(prefix: URL(fileURLWithPath: fresh, isDirectory: true).appendingPathComponent("prefix"))
    try baseline.write(to: root.appendingPathComponent(Library.baselineFile))
    let result = InstallDiscovery.discover(prefix: setup.prefix, baseline: baseline, product: name)
    print(describe(result))
    var game = Game(id: root.lastPathComponent, name: name)
    game.merge(result)
    if let registered = game.uninstall?.displayName, options.one("--name") == nil { game.name = registered }
    game.publisher = game.uninstall?.publisher
    try library.save(game, in: root)
    try setup.applySettings()
    guard var entry = library.entry(at: root) else { throw CLIError("Could not read the adopted bottle") }
    if let updated = try library.updateProfile(entry) { entry = updated }
    print(describe(entry.compatibility))
    game = entry.game
    let app = try GameLauncher.makeBridge(for: entry, shimBinary: try shimBinary(), home: library.home)
    game.bridge = app.path
    try library.save(game, in: root)
    print("Added to the library: \(game.name) → \(target(game.primary)); bridge: \(app.path)")
    if options.flags.contains("--default") { try await setDefault(app, schemes: game.schemes) }
}

/// One line from standard input, without echo when it is a terminal.
func readSecretLine(prompt: String) -> String? {
    let terminal = isatty(STDIN_FILENO) == 1
    var saved = termios()
    if terminal {
        FileHandle.standardError.write(Data(prompt.utf8))
        tcgetattr(STDIN_FILENO, &saved)
        var silent = saved
        silent.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &silent)
    }
    defer {
        if terminal {
            tcsetattr(STDIN_FILENO, TCSANOW, &saved)
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }
    return readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces)
}

func playSetup(_ options: Options) throws {
    let library = Library()
    let entry = try findGame(library, options.positional.first)
    let game: Game
    if options.flags.contains("--reset") {
        game = try GameLauncher.setCustomLaunch(nil, for: entry, library: library)
        print("Play starts: \(target(game.primary))")
    } else if options.flags.contains("--link") {
        let scheme = options.one("--scheme")?.lowercased() ?? entry.game.schemes.first
        guard let scheme, entry.game.schemes.contains(scheme) else {
            throw CLIError("The game handles no such scheme (its schemes: \(entry.game.schemes.joined(separator: ", ")))")
        }
        let pasted = readSecretLine(prompt: "Paste a \(scheme): link and press Return (or just Return to wait for the site's): ")
        let link = pasted?.isEmpty == false ? pasted : nil
        game = try GameLauncher.setCustomLaunch(.link(scheme: scheme), link: link, for: entry, library: library)
        if let link {
            print("Play starts the saved \(scheme): link \(IncomingURL.redacted(link))")
        } else {
            print("Play opens the site until it sends a \(scheme): link; the bridge remembers it from then on")
        }
    } else if let path = options.one("--command") {
        game = try GameLauncher.setCustomLaunch(.command(path: path, arguments: options.one("--args")), for: entry, library: library)
        print("Play starts: \(path) \(options.one("--args") ?? "")")
    } else {
        throw CLIError("Pass --link, --command PATH or --reset")
    }
    if game.bridge != nil, let updated = library.entry(at: entry.root) {
        _ = try GameLauncher.makeBridge(for: updated, shimBinary: try shimBinary(), home: library.home)
    }
}

func bottleSetup(_ options: Options) throws -> BottleSetup {
    guard let runtime = options.one("--runtime"), let at = options.one("--at") else {
        throw CLIError("Pass --runtime DIR and --at DIR")
    }
    let runtimeURL = URL(fileURLWithPath: runtime).standardizedFileURL
    let game = try gameOptions(from: options)
    return BottleSetup(runtime: WineRuntime(root: runtimeURL.path), root: URL(fileURLWithPath: at, isDirectory: true).standardizedFileURL,
                       options: game)
}

func removeShim(_ path: String) throws {
    let app = URL(fileURLWithPath: path).standardizedFileURL
    guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources/" + ShimBundle.configName).path) else {
        throw CLIError("\(app.path) is not a Riftway shim")
    }
    // Move first: LaunchServices re-indexes a bundle still in place right after
    // `lsregister -u`, so unregistering it there leaves its schemes claimed.
    var trashed: NSURL?
    try FileManager.default.trashItem(at: app, resultingItemURL: &trashed)
    try ShimBundle.unregister(app)
    if let trashed = trashed as URL? { try? ShimBundle.unregister(trashed) }
    print("Unregistered and moved to the Trash: \(app.path)")
}

do {
    let args = CommandLine.arguments
    guard args.count >= 2 else { print(usage); exit(64) }
    let options = try Options(args.dropFirst(2))
    switch args[1] {
    case "bottles":
        listBottles()
    case "resolve", "open":
        guard let url = options.positional.first else { throw CLIError("Pass the URL") }
        let bottle = try bottle(from: options)
        let schemes = bottle.urlProtocols().filter(\.isClaimableFromMacOS).map(\.scheme)
        let bridge = URLBridge(bottle: bottle, schemes: Set(schemes), extraArguments: options.many("--arg"))
        let plan = try bridge.plan(forURL: url)
        let shown = plan.logDescription(hiding: url)
        if args[1] == "resolve" || options.flags.contains("--dry-run") {
            print(shown)
        } else {
            let pid = try Launcher.start(plan)
            Log().write("cli: started pid \(pid) in bottle \(bottle.name): \(shown)")
            print("Started pid \(pid): \(shown)")
        }
    case "make-shim":
        try await makeShim(options)
    case "remove-shim":
        guard let path = options.positional.first else { throw CLIError("Pass the shim's .app path") }
        try removeShim(path)
    case "bottle-create":
        let setup = try bottleSetup(options)
        let version = URL(fileURLWithPath: setup.runtime.root).lastPathComponent
        let start = Date()
        try setup.create(name: options.one("--name") ?? setup.root.lastPathComponent, runtimeVersion: version) { print($0) }
        print(String(format: "Bottle created at %@ in %.0f s", setup.root.path, Date().timeIntervalSince(start)))
    case "bottle-isolate":
        let setup = try bottleSetup(options)
        try setup.isolate()
        print("No Z: drive; R: → \(setup.runtime.root)/share/wine")
    case "bottle-fonts":
        let setup = try bottleSetup(options)
        let fallbacks = FontLinking.available()
        try setup.configureFontLinking(fallbacks: fallbacks)
        print("Linked \(FontLinking.linkedFonts.count) Windows UI fonts to: " + fallbacks.map { "\($0.label) (\($0.language))" }.joined(separator: ", "))
    case "bottle-wine":
        let setup = try bottleSetup(options)
        guard !options.passthrough.isEmpty else { throw CLIError("Pass the wine arguments after --") }
        let timeout = options.one("--timeout").flatMap(Double.init) ?? 120
        let status = try ProcessRunner.run(setup.plan("wine", options.passthrough), output: .inherit, timeout: timeout)
        try setup.waitForServer()
        exit(status)
    case "inspect":
        guard !options.positional.isEmpty else { throw CLIError("Pass one or more files") }
        let profiles = ProfileStore.standard()
        for path in options.positional {
            let report = InstallerAnalyzer.analyze(URL(fileURLWithPath: path))
            print(describe(report))
            if case .unsupported = report.kind { continue }
            let profile = profiles.match(ProfileQuery(report: report, hash: profiles.usesHashes))
            print(describe(Compatibility(profile: profile)).split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
        }
    case "profiles":
        if options.flags.contains("--check") || !options.positional.isEmpty {
            var failed = false
            for path in options.positional {
                do {
                    let profile = try GameProfile.load(try Data(contentsOf: URL(fileURLWithPath: path)))
                    print("ok   \(path) (\(profile.id), \(profile.status.rawValue))")
                } catch {
                    print("FAIL \(path): \(error)")
                    failed = true
                }
            }
            if failed { exit(1) }
        } else {
            let store = ProfileStore.standard()
            if store.profiles.isEmpty { print("No profiles (looked in: \(ProfileStore.shippedDirectories().map(\.path)))") }
            for p in store.profiles { print("\(p.id)  \(p.status.rawValue)  \(p.name)  [revision \(p.revision)]") }
            for (file, problem) in store.problems.sorted(by: { $0.key < $1.key }) { print("not loaded: \(file): \(problem)") }
        }
    case "profile":
        let library = Library()
        var entry = try findGame(library, options.positional.first)
        if options.positional.count > 1 || options.flags.contains("--none") || options.flags.contains("--auto") {
            guard !WineServer.isRunning(prefix: entry.root.appendingPathComponent("prefix")) else {
                throw CLIError("\(entry.game.name) is open; close it first")
            }
            let profile: GameProfile?
            if options.flags.contains("--none") {
                profile = nil
            } else if options.flags.contains("--auto") {
                guard let found = library.profiles.match(ProfileQuery(game: entry.game)) else { throw CLIError("No profile matches \(entry.game.name)") }
                profile = found
            } else {
                guard let found = library.profiles.profile(id: options.positional[1]) else { throw CLIError("No profile \(options.positional[1])") }
                profile = found
            }
            entry = try library.apply(profile, to: entry)
            if entry.game.bridge != nil { _ = try GameLauncher.makeBridge(for: entry, shimBinary: try shimBinary(), home: library.home) }
            print("Applied.")
        } else if let suggested = library.profiles.match(ProfileQuery(game: entry.game)), entry.profile == nil {
            print("A profile matches: \(suggested.id) (riftway profile \(entry.id) --auto)")
        }
        print(describe(entry.compatibility))
        if entry.profileIsStale { print("The profile changed since the bottle applied it; run riftway profile \(entry.id) --auto") }
    case "anticheat":
        guard let path = options.positional.first else { throw CLIError("Pass a folder") }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var files: [String] = []
        if let walker = FileManager.default.enumerator(atPath: root.path) {
            while let file = walker.nextObject() as? String { files.append(file) }
        }
        let found = AntiCheatDetector.scan(files: files)
        if found.isEmpty { print("No known anti-cheat in \(files.count) files") }
        for a in found { print(describe(a)) }
    case "shortcut":
        guard !options.positional.isEmpty else { throw CLIError("Pass one or more .lnk files") }
        for path in options.positional {
            let link = try ShellLink(contentsOf: URL(fileURLWithPath: path))
            print(URL(fileURLWithPath: path).lastPathComponent)
            for (label, value) in [("target", link.target), ("arguments", link.arguments), ("folder", link.workingDirectory),
                                   ("icon", link.iconLocation.map { "\($0),\(link.iconIndex)" }), ("comment", link.description)] {
                if let value { print("  \(label.padding(toLength: 10, withPad: " ", startingAt: 0)) \(value)") }
            }
        }
    case "discover":
        // Development: what a bottle gained since its baseline (or since another,
        // fresh bottle's state with --baseline-from).
        guard let at = options.one("--at") else { throw CLIError("Pass --at BOTTLE") }
        let root = URL(fileURLWithPath: at, isDirectory: true).standardizedFileURL
        let baseline: PrefixSnapshot
        if let other = options.one("--baseline-from") {
            baseline = PrefixSnapshot.capture(prefix: URL(fileURLWithPath: other, isDirectory: true).appendingPathComponent("prefix"))
        } else {
            baseline = try PrefixSnapshot.read(from: root.appendingPathComponent("baseline.json"))
        }
        let start = Date()
        let result = InstallDiscovery.discover(prefix: root.appendingPathComponent("prefix"), baseline: baseline, product: options.one("--name"))
        print(describe(result))
        print(String(format: "(%.2f s)", Date().timeIntervalSince(start)))
    case "runtime-install":
        guard let path = options.positional.first else { throw CLIError("Pass the runtime folder") }
        let installed = try RiftwayHome.standard.installRuntime(from: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL)
        print("Installed runtime \(installed.version) at \(installed.runtime.root)")
    case "runtimes":
        let runtimes = RiftwayHome.standard.installedRuntimes()
        if runtimes.isEmpty { print("No runtimes in \(RiftwayHome.standard.runtimes.path)") }
        for r in runtimes { print("\(r.version)  \(r.runtime.root)") }
    case "install":
        try await install(options)
    case "running":
        for e in Library().entries() {
            print("\(e.game.name): \(WineServer.isRunning(prefix: e.root.appendingPathComponent("prefix")) ? "running" : "stopped")")
        }
    case "play-setup":
        try playSetup(options)
    case "adopt":
        try await adopt(options)
    case "library":
        let entries = Library().entries()
        if entries.isEmpty { print("The library is empty (\(RiftwayHome.standard.bottles.path))") }
        for e in entries {
            print("\(e.game.name)  [\(e.id), runtime \(e.record.runtimeVersion)\(e.runtime == nil ? " MISSING" : "")\(e.record.options.diagnostics ? ", diagnostics" : "")]")
            switch e.game.customLaunch {
            case .link(let scheme)?:
                let saved = e.secrets.savedDate(account: e.game.secretAccount)
                print("  play:    last \(scheme): link" + (saved.map { " (saved \($0))" } ?? " (none yet: opens the site)"))
            case .command(let path, let arguments)?: print("  play:    \(path) \(arguments ?? "") (custom)")
            case nil: print("  play:    \(target(e.game.primary))")
            }
            if !e.game.schemes.isEmpty { print("  schemes: \(e.game.schemes.joined(separator: ", "))") }
            if let bridge = e.game.bridge { print("  bridge:  \(bridge)") }
            if !e.game.drivers.isEmpty { print("  drivers: \(e.game.drivers.map(\.name).joined(separator: ", "))") }
            let c = e.compatibility
            print("  status:  \(c.status.rawValue)" + (c.profile.map { " (profile \($0.id))" } ?? "")
                  + (c.vendors.isEmpty ? "" : "; anti-cheat: " + c.vendors.map(\.displayName).joined(separator: ", ")))
        }
    case "play":
        try play(options)
    case "rediscover":
        let library = Library()
        let entry = try findGame(library, options.positional.first)
        let (game, newSchemes) = try library.rediscover(entry)
        print("Programs: " + game.programs.map(\.name).joined(separator: ", "))
        print("Schemes: " + game.schemes.joined(separator: ", ") + (newSchemes.isEmpty ? "" : " (new: \(newSchemes.joined(separator: ", ")))"))
        if options.flags.contains("--bridge"), let updated = library.entry(at: entry.root) {
            print("Bridge: \(try GameLauncher.makeBridge(for: updated, shimBinary: try shimBinary(), home: library.home).path)")
        }
    case "bridge":
        let library = Library()
        let entry = try findGame(library, options.positional.first)
        let app = try GameLauncher.makeBridge(for: entry, shimBinary: try shimBinary(), home: library.home)
        var game = entry.game
        game.bridge = app.path
        try library.save(game, in: entry.root)
        print("Bridge: \(app.path)")
        if options.flags.contains("--default") { try await setDefault(app, schemes: game.schemes) }
    case "diagnostics", "program-dll":
        let library = Library()
        let entry = try findGame(library, options.positional.first)
        var record = entry.record
        if args[1] == "diagnostics" {
            guard options.positional.count == 2, ["on", "off"].contains(options.positional[1]) else { throw CLIError("Pass on or off") }
            record.options.diagnostics = options.positional[1] == "on"
        } else {
            guard options.positional.count == 4 else { throw CLIError("Pass <game> <program.exe> <dll> <mode|off|remove>") }
            let (program, dll, mode) = (options.positional[1], options.positional[2], options.positional[3])
            if mode == "remove" {
                record.options.programDllOverrides[program]?[dll] = nil
                if record.options.programDllOverrides[program]?.isEmpty == true { record.options.programDllOverrides[program] = nil }
            } else {
                record.options.programDllOverrides[program, default: [:]][dll] = mode == "off" ? "" : mode
            }
        }
        try library.save(record, in: entry.root)
        guard let updated = library.entry(at: entry.root), let setup = updated.setup else { throw CLIError("Runtime missing") }
        if args[1] == "program-dll" { try setup.applySettings() }
        // The bridge carries the bottle's options: rebuild it.
        if entry.game.bridge != nil { _ = try GameLauncher.makeBridge(for: updated, shimBinary: try shimBinary(), home: library.home) }
        print("Saved. Diagnostics: \(record.options.diagnostics ? "on" : "off"); program overrides: \(record.options.programDllOverrides)")
    case "help", "--help", "-h":
        print(usage)
    default:
        print(usage); exit(64)
    }
} catch {
    FileHandle.standardError.write(Data("riftway: \(error)\n".utf8))
    exit(1)
}
