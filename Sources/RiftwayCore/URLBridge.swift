import Foundation

/// A process to start: no shell is involved, each argument reaches Wine as is.
public struct LaunchPlan: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    /// Added to (and overriding) the inherited environment, or the whole
    /// environment when `replacesEnvironment` is set.
    public var environment: [String: String]
    public var workingDirectory: String
    public var replacesEnvironment = false

    public init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String,
                replacesEnvironment: Bool = false) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.replacesEnvironment = replacesEnvironment
    }

    /// The command for logs, with `secret` (the incoming URL) redacted.
    public func logDescription(hiding secret: String?) -> String {
        let shown = arguments.map { arg -> String in
            guard let secret, !secret.isEmpty, arg.contains(secret) else { return arg }
            return arg.replacingOccurrences(of: secret, with: IncomingURL.redacted(secret))
        }
        return ([executable] + shown).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }
}

/// Hands URLs that macOS received (from Safari, Chrome, another app) to the
/// Windows program that registered their scheme inside one bottle, exactly as
/// ShellExecute would inside Windows. The bridge never reads the URL's payload.
public struct URLBridge: Sendable {
    public var bottle: Bottle
    /// Schemes this bridge accepts; anything else is refused before Wine sees it.
    public var schemes: Set<String>
    /// Appended to the registered command (for the protocol's own program).
    public var extraArguments: [String]
    public var environment: [String: String]

    public init(bottle: Bottle, schemes: Set<String>, extraArguments: [String] = [], environment: [String: String] = [:]) {
        self.bottle = bottle
        self.schemes = Set(schemes.map { $0.lowercased() }).subtracting(URLProtocolRegistration.reservedSchemes)
        self.extraArguments = extraArguments
        self.environment = environment
    }

    public func plan(forURL url: String) throws(BridgeError) -> LaunchPlan {
        let scheme: String
        do { scheme = try IncomingURL.validate(url, schemes: schemes) } catch { throw .invalidURL(error) }
        let registration = try registration(for: scheme)
        let args = WindowsCommandLine.expand(template: registration.command, argument: url) + extraArguments
        return try bottle.launchPlan(windowsArguments: args, environment: environment)
    }

    /// Opens the protocol's program without a URL, for a double-click on the shim.
    public func planForProgram() throws(BridgeError) -> LaunchPlan {
        guard let scheme = schemes.sorted().first else { throw .schemeNotRegistered(scheme: "", bottle: bottle.name) }
        let registration = try registration(for: scheme)
        let args = WindowsCommandLine.expand(template: registration.command, argument: nil) + extraArguments
        return try bottle.launchPlan(windowsArguments: args, environment: environment)
    }

    private func registration(for scheme: String) throws(BridgeError) -> URLProtocolRegistration {
        guard let found = bottle.urlProtocols().first(where: { $0.scheme == scheme }) else {
            throw .schemeNotRegistered(scheme: scheme, bottle: bottle.name)
        }
        return found
    }
}

public enum Launcher {
    /// Starts `plan` detached from the caller and returns its pid. Wine's own
    /// output is discarded unless `outputLog` is given: Wine can print the
    /// program's command line, which holds the URL.
    @discardableResult
    public static func start(_ plan: LaunchPlan, outputLog: URL? = nil) throws(BridgeError) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: plan.workingDirectory, isDirectory: true)
        var env = plan.replacesEnvironment ? [:] : ProcessInfo.processInfo.environment
        // Apps opened by LaunchServices get a minimal PATH; CrossOver's wine is a script.
        if env["PATH"].map({ $0.isEmpty }) ?? true { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        env.merge(plan.environment) { $1 }
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        if let outputLog, let handle = try? Log.appendHandle(outputLog) {
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        do { try process.run() } catch { throw .launchFailed(error.localizedDescription) }
        return process.processIdentifier
    }
}
