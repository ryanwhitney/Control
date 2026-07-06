import Foundation
import Testing
@testable import Control

/// Opens a *real* SSH connection from the test process to a Mac (by default this
/// dev Mac at `127.0.0.1`) and runs raw AppleScript over the production
/// transport, so the live suite exercises the genuine engine:
/// `SSHClient`/`LegacySSHClient` → ChannelExecutor → PTY `osascript` → parser.
///
/// Credentials come from the environment only — nothing is committed. The whole
/// live suite is gated on `VC_LIVE=1` (see `isEnabled`); when it's off none of
/// this is constructed.
///
/// Required env vars:
///   VC_LIVE=1            enable the live suite
///   VC_LIVE_USER=<user>  a login account on the target Mac
///   VC_LIVE_PASS=<pass>  that account's password
/// Optional:
///   VC_LIVE_HOST=<host>  defaults to 127.0.0.1 (loopback avoids the iOS
///                        local-network prompt; Remote Login must be enabled)
/// Process-wide pool of live connections, one per transport, opened on first use
/// and reused for the whole suite. Opening a fresh connection per test churns
/// the Mac's `sshd` (rapid connect/teardown), which made the legacy transport
/// drop a channel mid-command (`Connection closed`); reusing one connection per
/// transport removes that churn and also mirrors production, where a single
/// long-lived connection serves many commands on dedicated channels.
actor LivePool {
    static let shared = LivePool()
    private var envs: [LiveEnvironment.Transport: LiveEnvironment] = [:]

    func env(_ transport: LiveEnvironment.Transport = .streaming) async throws -> LiveEnvironment {
        if let existing = envs[transport] { return existing }
        let created = try await LiveEnvironment(transport: transport)
        envs[transport] = created
        return created
    }
}

/// `@unchecked Sendable`: the only stored reference is an `SSHClient`/
/// `LegacySSHClient`, each already `Sendable`/thread-safe; the rest is value
/// types. This lets the shared `LivePool` hand one instance to serialized tests.
struct LiveEnvironment: @unchecked Sendable {
    /// Master gate for the whole live suite.
    static var isEnabled: Bool { value("VC_LIVE") == "1" }

    /// Strict mode (`VC_LIVE_STRICT=1`): every environmental skip becomes a
    /// failure. Off by default so the suite degrades gracefully on a dev Mac
    /// (an app that isn't running is skipped, loudly); turn it on when the
    /// target Mac is supposed to be fully provisioned — after running
    /// `Scripts/live-setup.sh`, or later against a baked VM image — so a
    /// missing fixture can't silently zero out coverage.
    static var isStrict: Bool { value("VC_LIVE_STRICT") == "1" }

    /// Reads a live-test variable, tolerating xcodebuild's `TEST_RUNNER_` prefix.
    /// Env vars set on the `xcodebuild` command reach a simulator test runner
    /// only when prefixed with `TEST_RUNNER_` (xcodebuild forwards those); vars
    /// set in the scheme's Test → Environment Variables arrive unprefixed. We
    /// accept either so both workflows work.
    static func value(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        return env[name] ?? env["TEST_RUNNER_" + name]
    }

    enum Transport: Sendable, CaseIterable, CustomStringConvertible {
        case streaming, compatibility
        var description: String {
            switch self {
            case .streaming: return "streaming"
            case .compatibility: return "compatibility"
            }
        }
    }

    enum LiveError: Error, CustomStringConvertible {
        case missingCredentials(String)
        var description: String {
            switch self {
            case .missingCredentials(let hint): return "Live test misconfigured: \(hint)"
            }
        }
    }

    let host: String
    let username: String
    let password: String
    /// The live connection itself. Internal (not private) so the controller
    /// tests can inject the *same* real transport into an `AppController`.
    let client: SSHClientProtocol

    /// Reads creds from the environment and opens a real connection over the
    /// chosen transport. Throws if creds are absent or the connection fails.
    init(transport: Transport = .streaming) async throws {
        host = Self.value("VC_LIVE_HOST") ?? "127.0.0.1"
        guard let user = Self.value("VC_LIVE_USER"), !user.isEmpty else {
            throw LiveError.missingCredentials("set VC_LIVE_USER")
        }
        guard let pass = Self.value("VC_LIVE_PASS"), !pass.isEmpty else {
            throw LiveError.missingCredentials("set VC_LIVE_PASS")
        }
        username = user
        password = pass
        switch transport {
        case .streaming: client = SSHClient()
        case .compatibility: client = LegacySSHClient()
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            client.connect(host: host, username: username, password: password) { cont.resume(with: $0) }
        }
    }

    func disconnect() { client.disconnect() }

    /// Runs a raw AppleScript on the given channel and returns trimmed output.
    func run(_ script: String, channelKey: String = "system") async throws -> String {
        let raw: String = try await withCheckedThrowingContinuation { cont in
            client.executeCommandOnDedicatedChannel(channelKey, script, description: "live-test") { cont.resume(with: $0) }
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the named macOS app is currently running — used to skip a
    /// platform's live test on a Mac where that app isn't up. Throws on a
    /// transport failure rather than reporting "not running": a broken
    /// connection must fail the test, not silently convert it into a skip.
    func isAppRunning(_ name: String) async throws -> Bool {
        let script = "tell application \"System Events\" to return (count of (processes where name is \"\(name)\")) > 0"
        return try await run(script).contains("true")
    }

    /// The platform's own parsed status, but only when its app is running with
    /// media actually loaded — the precondition every action test shares.
    /// Returns nil when the app is down, stopped, or empty ("Nothing playing"/
    /// "Not running" fallbacks), so callers skip instead of acting on nothing.
    func loadedState(_ platform: some AppPlatform) async throws -> AppState? {
        guard try await isAppRunning(platform.name) else { return nil }
        let output = try await run(platform.combinedStatusScript(), channelKey: platform.id)
        guard output != ScriptTokens.notRunning else { return nil }
        let state = platform.parseState(output)
        guard state.error == nil, state.isPlaying != nil,
              !state.title.hasPrefix("Nothing playing"),
              !state.title.hasPrefix("Not running") else { return nil }
        return state
    }
}

/// Marks a live test as skipped for an environmental reason (app not running,
/// no media loaded). Prints loudly so a green run still shows what wasn't
/// exercised; under `VC_LIVE_STRICT=1` it records a failure instead, so a
/// provisioned Mac/VM can't quietly lose coverage to a missing fixture.
func liveSkip(_ what: String, _ reason: String) {
    if LiveEnvironment.isStrict {
        Issue.record("\(what) not exercised: \(reason) — strict mode (VC_LIVE_STRICT=1) forbids skips")
    } else {
        print("⏭️ live skip — \(what): \(reason)")
    }
}
