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

    /// A model number fused directly onto a letter, with no separator, is
    /// part of the name and must not be read as a Bonjour rename suffix.
    @Test func modelNumbersDoNotCollide() {
        #expect(
            HostIdentityHeuristics.nameStem("Mac Studio M1")
                != HostIdentityHeuristics.nameStem("Mac Studio M2")
        )
    }

    /// The separator-before-digit case must still strip, distinguishing a
    /// genuine rename suffix from a fused model number.
    @Test func separatedTrailingNumbersStillStem() {
        #expect(
            HostIdentityHeuristics.nameStem("Steve's Mac 2")
                == HostIdentityHeuristics.nameStem("Steve's Mac")
        )
    }
}

struct NormalizedHostnameTests {

    @Test func stripsTheRootDot() {
        #expect(HostIdentityHeuristics.normalizedHostname("mymac.local.") == "mymac.local")
        #expect(HostIdentityHeuristics.normalizedHostname("mymac.local") == "mymac.local")
    }

    /// A remote hostname is as root-dot-insensitive as a .local one. If it
    /// weren't stripped here, `home.example.com.` would miss the pinned row for
    /// `home.example.com`, fork a second one with an empty trust set, and
    /// silently trust whatever answered.
    @Test func stripsTheRootDotFromRemoteHostnamesToo() {
        #expect(HostIdentityHeuristics.normalizedHostname("home.example.com.") == "home.example.com")
        #expect(HostIdentityHeuristics.normalizedHostname("home.example.com") == "home.example.com")
    }

    /// Callers compare the result case-insensitively, so casing must survive
    /// untouched rather than being folded here.
    @Test func stripsTheRootDotRegardlessOfCase() {
        #expect(HostIdentityHeuristics.normalizedHostname("MYMAC.LOCAL.") == "MYMAC.LOCAL")
        #expect(HostIdentityHeuristics.normalizedHostname("MyMac.Local.") == "MyMac.Local")
    }

    /// Only the trailing dot goes: a dot inside the name is part of it.
    @Test func leavesInteriorDotsAlone() {
        #expect(HostIdentityHeuristics.normalizedHostname("a.local.b.local") == "a.local.b.local")
    }
}
