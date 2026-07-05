import Testing
@testable import Control

/// Guards the transport capability that drives AppController's refresh strategy:
/// streaming serialises all app commands on one channel (refresh visible-first),
/// legacy opens a channel per command (a bulk sweep is fine). Both transports
/// instantiate without connecting.
struct SSHClientCapabilityTests {

    @Test func streamingSerializesAppCommands() {
        #expect(SSHClient().serializesAppCommands == true)
    }

    @Test func legacyDoesNotSerializeAppCommands() {
        #expect(LegacySSHClient().serializesAppCommands == false)
    }
}
