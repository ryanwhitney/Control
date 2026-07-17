import Testing
@testable import Control

struct HostProvenanceTests {

    @Test func classifiesAddressShapes() {
        #expect(HostProvenance(host: "192.168.1.50") == .ipAddress)
        #expect(HostProvenance(host: "fe80::1") == .ipAddress)
        #expect(HostProvenance(host: "Mac-mini.local") == .localHostname)
        #expect(HostProvenance(host: "mac-mini.local.") == .localHostname)
        #expect(HostProvenance(host: "my-mac.tailnet.ts.net") == .remoteHostname)
        #expect(HostProvenance(host: "home.example.com") == .remoteHostname)
    }
}

struct NameStemTests {

    /// A Bonjour rename ("Mac mini (2)") and its hostname form must stem back
    /// to the original, so renamed duplicates are found as probe candidates.
    @Test func renamedDuplicatesShareAStem() {
        let original = HostIdentityHeuristics.nameStem("Mac mini")
        #expect(HostIdentityHeuristics.nameStem("Mac mini (2)") == original)
        #expect(HostIdentityHeuristics.nameStem("Mac-mini-2.local") == original)
        #expect(HostIdentityHeuristics.nameStem("Mac-mini.local") == original)
    }

    @Test func apostrophesAndSeparatorsNormalize() {
        #expect(
            HostIdentityHeuristics.nameStem("Ryan's MacBook Pro")
                == HostIdentityHeuristics.nameStem("Ryans-MacBook-Pro.local")
        )
    }

    @Test func unrelatedNamesDoNotCollide() {
        #expect(
            HostIdentityHeuristics.nameStem("Mac mini")
                != HostIdentityHeuristics.nameStem("MacBook Air")
        )
    }
}
