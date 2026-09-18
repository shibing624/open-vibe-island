import Foundation
import Testing
@testable import OpenIslandApp

/// One rule, two consumers. It is asserted on its own because it is the only
/// thing standing between `ITERM_SESSION_ID`'s `w0t0p0:UUID` form and a
/// comparison that silently never matches.
@Suite
struct TerminalSessionIdentityTests {
    @Test
    func aBareUUIDIsReturnedUnchanged() {
        let bare = "2DBAB2C2-74D9-42A7-A014-10CD3E324E7B"
        #expect(TerminalSessionIdentity.iTermSessionID(bare) == bare)
    }

    /// This is the shape `ITERM_SESSION_ID` carries. `iTerm2.sdef` documents it
    /// as `w0t0p0:UUID`, so the window/tab/pane prefixes are dotless — assert
    /// that they survive intact rather than only that a colon splits the value.
    @Test
    func theEnvironmentFormLosesOnlyItsWindowTabPanePrefix() {
        let prefixed = "w0t0p0:2DBAB2C2-74D9-42A7-A014-10CD3E324E7B"
        #expect(
            TerminalSessionIdentity.iTermSessionID(prefixed)
                == "2DBAB2C2-74D9-42A7-A014-10CD3E324E7B"
        )
    }

    /// A second indentifier level (`w0t1p2:`) must still yield the UUID, not the
    /// text after the *first* colon.
    @Test
    func onlyTheLastSeparatorIsTreatedAsTheBoundary() {
        #expect(TerminalSessionIdentity.iTermSessionID("w12t3p45:UUID") == "UUID")
    }

    /// A value that is not a UUID at all still round-trips, so an id from some
    /// other source is not mangled.
    @Test
    func aValueWithoutASeparatorIsNotRewritten() {
        #expect(TerminalSessionIdentity.iTermSessionID("") == "")
        #expect(TerminalSessionIdentity.iTermSessionID("not-a-uuid") == "not-a-uuid")
    }

    /// The property that makes this safe to apply to a value already in the
    /// store: normalizing twice changes nothing.
    @Test
    func normalizingIsIdempotent() {
        for raw in [
            "2DBAB2C2-74D9-42A7-A014-10CD3E324E7B",
            "w0t0p0:2DBAB2C2-74D9-42A7-A014-10CD3E324E7B",
            "w12t3p45:UUID",
            "",
        ] {
            let once = TerminalSessionIdentity.iTermSessionID(raw)
            #expect(TerminalSessionIdentity.iTermSessionID(once) == once)
        }
    }
}
