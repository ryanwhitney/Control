import Testing
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
@testable import Control

/// Guards the state-change detection fix: `updateStateIfChanged` now compares the
/// whole `AppState`, so a play/pause flip on the same track (title unchanged) is
/// no longer dropped.
struct AppStateEqualityTests {

    @Test func playStateFlipIsAChange() {
        let playing = AppState(title: "Song", subtitle: "Artist", isPlaying: true, error: nil)
        let paused  = AppState(title: "Song", subtitle: "Artist", isPlaying: false, error: nil)
        #expect(playing != paused)
    }

    @Test func subtitleChangeIsAChange() {
        let a = AppState(title: "Song", subtitle: "Artist A", isPlaying: true, error: nil)
        let b = AppState(title: "Song", subtitle: "Artist B", isPlaying: true, error: nil)
        #expect(a != b)
    }

    @Test func identicalStatesAreEqual() {
        let a = AppState(title: "Song", subtitle: "Artist", isPlaying: true, error: nil)
        let b = AppState(title: "Song", subtitle: "Artist", isPlaying: true, error: nil)
        #expect(a == b)
    }
}

/// Guards the single shared error classifier both transports now call (they had
/// drifted into two divergent copies that mapped the same failure differently).
struct SSHErrorClassifyTests {

    @Test func passesThroughExistingSSHError() {
        if case .authenticationFailed = SSHError.classify(SSHError.authenticationFailed) {} else {
            Issue.record("authenticationFailed should pass through unchanged")
        }
        if case .timeout = SSHError.classify(SSHError.timeout) {} else {
            Issue.record("timeout should pass through unchanged")
        }
    }

    @Test func connectionRefusedMeansRemoteLoginOff() {
        // ECONNREFUSED's description ("Connection refused") doesn't collide with
        // the earlier network-phrase checks, so it reaches the POSIX branch.
        guard case .connectionFailed(let msg) = SSHError.classify(POSIXError(.ECONNREFUSED)) else {
            Issue.record("expected connectionFailed"); return
        }
        #expect(msg == "Remote Login is not enabled")
    }

    @Test func networkPhraseMeansConnectivityLost() {
        let err = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Network is unreachable"])
        guard case .connectionFailed(let msg) = SSHError.classify(err) else {
            Issue.record("expected connectionFailed"); return
        }
        #expect(msg == "Network connectivity lost")
    }

    @Test func resetPhraseMeansInterrupted() {
        let err = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connection reset by peer"])
        guard case .connectionFailed(let msg) = SSHError.classify(err) else {
            Issue.record("expected connectionFailed"); return
        }
        #expect(msg == "Connection was interrupted")
    }

    @Test func unknownFallsBackToGeneric() {
        let err = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Something unexpected"])
        guard case .connectionFailed(let msg) = SSHError.classify(err) else {
            Issue.record("expected connectionFailed"); return
        }
        #expect(msg == "Could not establish connection")
    }
}

/// Guards the single shared connection-loss substring list (previously duplicated
/// in three places that could drift apart).
struct SSHErrorConnectionLossTests {

    @Test func detectsLossPhrases() {
        for phrase in ["EOF", "broken pipe", "Connection reset", "TCP shutdown",
                       "no route to host", "connection closed", "network is unreachable"] {
            let err = NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: phrase])
            #expect(SSHError.isConnectionLoss(err), "expected loss for '\(phrase)'")
        }
    }

    @Test func ignoresNonLossPhrases() {
        for phrase in ["The username or password was incorrect", "Remote Login is not enabled", "hello world"] {
            let err = NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: phrase])
            #expect(!SSHError.isConnectionLoss(err), "did not expect loss for '\(phrase)'")
        }
    }
}

/// Guards the combinedStatusScript contract. The wrapper must return the exact
/// `ScriptTokens.notRunning` sentinel `AppController` matches (a hardcoded
/// "NOT_RUNNING" literal here once made every not-running app render as a
/// parse error). Self-guarding platforms (VLC/IINA/mpv) must skip the wrapper
/// — their fetchState already does the System Events process check, and it
/// must stay valid stand-alone because PermissionsView runs it bare.
struct CombinedStatusScriptTests {

    @Test func wrapperReturnsNotRunningSentinel() {
        let script = MusicApp().combinedStatusScript()
        #expect(script.contains(ScriptTokens.notRunning))
        #expect(script.contains("processes where name is \"Music\""))
    }

    @Test func selfGuardingPlatformsSkipWrapper() {
        #expect(VLCApp().combinedStatusScript() == VLCApp().fetchState())
        #expect(IINAApp().combinedStatusScript() == IINAApp().fetchState())
        #expect(MPVApp().combinedStatusScript() == MPVApp().fetchState())
    }

    @Test func selfGuardingFetchStateIsStandalone() {
        // Must bring their own System Events tell (PermissionsView runs these
        // bare) and handle the not-running case themselves.
        for script in [VLCApp().fetchState(), IINAApp().fetchState(), MPVApp().fetchState()] {
            #expect(script.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("tell application \"System Events\""))
        }
        #expect(VLCApp().fetchState().contains(ScriptTokens.notRunning))
    }
}

/// Guards the single-attempt password auth fix: a second challenge from the
/// server means the password was rejected — the delegate must fail fast instead
/// of re-offering the same password until the server closes the connection
/// (which surfaced as a generic error, never as `authenticationFailed`).
struct PasswordAuthDelegateTests {

    @Test func rejectedPasswordFailsFast() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let delegate = PasswordAuthDelegate(username: "user", password: "pw")
        var authFailureFired = false
        delegate.onAuthFailure = { authFailureFired = true }

        // First challenge: the password is offered.
        let first = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .password, nextChallengePromise: first)
        #expect(try first.futureResult.wait() != nil)
        #expect(delegate.authFailed == false)
        #expect(authFailureFired == false)

        // Second challenge: the server rejected it — fail, don't loop.
        let second = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .password, nextChallengePromise: second)
        #expect(try second.futureResult.wait() == nil)
        #expect(delegate.authFailed == true)
        #expect(authFailureFired == true)
    }

    @Test func passwordMethodUnavailableFailsImmediately() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let delegate = PasswordAuthDelegate(username: "user", password: "pw")
        var authFailureFired = false
        delegate.onAuthFailure = { authFailureFired = true }

        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .publicKey, nextChallengePromise: promise)
        #expect(try promise.futureResult.wait() == nil)
        #expect(delegate.authFailed == true)
        #expect(authFailureFired == true)
    }
}
