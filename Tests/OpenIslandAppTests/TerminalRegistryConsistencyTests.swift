import Foundation
import Testing
@testable import OpenIslandApp
import OpenIslandCore

/// Adding a terminal means registering it in several places, and the pieces
/// have silently disagreed before: 89d8428 added Qoder to `vscodeFamilyCLI`
/// but not to `knownApps`, which made the new entry unreachable — `jump(to:)`
/// resolves a descriptor first, so a bundle id with no descriptor never gets
/// to the family dispatch. d943168 was the follow-up fix.
///
/// These assert the relationships between the registries rather than their
/// contents, so adding a terminal does not require editing this file — only
/// registering it consistently.
@Suite(.serialized)
struct TerminalRegistryConsistencyTests {
    /// Every CLI-family bundle id must have a descriptor, or its entry is dead
    /// code. This is exactly the Qoder regression.
    @Test
    func everyFamilyCLIBundleIDHasADescriptor() {
        let descriptorIDs = Set(TerminalJumpService.knownApps.flatMap(\.allBundleIdentifiers))

        for bundleID in TerminalJumpService.vscodeFamilyCLI.keys {
            #expect(
                descriptorIDs.contains(bundleID),
                "\(bundleID) is in vscodeFamilyCLI but has no knownApps descriptor, so jump() can never reach it"
            )
        }

        for bundleID in TerminalJumpService.jetbrainsCLI.keys {
            #expect(
                descriptorIDs.contains(bundleID),
                "\(bundleID) is in jetbrainsCLI but has no knownApps descriptor, so jump() can never reach it"
            )
        }
    }

    /// The JetBrains dispatch keys off `jetbrainsBundleIDs`, which is derived
    /// from the `com.jetbrains.` prefix of `knownApps`. A JetBrains descriptor
    /// without a CLI entry reaches the dispatch and then silently fails to open
    /// the project.
    @Test
    func everyJetBrainsDescriptorHasACLIEntry() {
        let jetbrainsDescriptors = TerminalJumpService.knownApps
            .filter { $0.bundleIdentifier.hasPrefix("com.jetbrains.") }

        #expect(!jetbrainsDescriptors.isEmpty)

        for descriptor in jetbrainsDescriptors {
            #expect(
                TerminalJumpService.jetbrainsCLI[descriptor.bundleIdentifier] != nil,
                "\(descriptor.displayName) is dispatched as JetBrains but has no CLI launcher name"
            )
        }
    }

    /// Two descriptors claiming one bundle id makes `resolveTerminalApp`
    /// order-dependent: whichever is declared first wins and the other is
    /// unreachable.
    @Test
    func noBundleIdentifierIsClaimedByTwoDescriptors() {
        var owners: [String: String] = [:]

        for descriptor in TerminalJumpService.knownApps {
            for bundleID in descriptor.allBundleIdentifiers {
                #expect(
                    owners[bundleID] == nil,
                    "\(bundleID) is claimed by both \(owners[bundleID] ?? "") and \(descriptor.displayName)"
                )
                owners[bundleID] = descriptor.displayName
            }
        }
    }

    /// Aliases are how a hook-side terminal name reaches a descriptor. Two
    /// descriptors sharing an alias makes that name resolve by declaration
    /// order, which is the guessing this codebase just removed elsewhere.
    @Test
    func noAliasIsClaimedByTwoDescriptors() {
        var owners: [String: String] = [:]

        for descriptor in TerminalJumpService.knownApps {
            for alias in descriptor.aliases {
                #expect(
                    owners[alias] == nil,
                    "alias '\(alias)' is claimed by both \(owners[alias] ?? "") and \(descriptor.displayName)"
                )
                owners[alias] = descriptor.displayName
            }
        }
    }

    /// `resolveTerminalApp` lowercases the incoming name before comparing, so
    /// an alias with an uppercase character can never match.
    @Test
    func everyAliasIsLowercasedAndNonEmpty() {
        for descriptor in TerminalJumpService.knownApps {
            for alias in descriptor.aliases {
                #expect(alias == alias.lowercased(), "alias '\(alias)' can never match: matching lowercases first")
                #expect(!alias.isEmpty)
            }
        }
    }

    /// "unknown" is the hook-side sentinel for an unclassified terminal and is
    /// short-circuited before matching. A descriptor claiming it as a name or
    /// alias would be dead.
    @Test
    func noDescriptorClaimsTheUnknownSentinel() {
        for descriptor in TerminalJumpService.knownApps {
            #expect(descriptor.displayName.lowercased() != "unknown")
            #expect(!descriptor.aliases.contains("unknown"))
        }
    }

    /// Each descriptor's own display name has to resolve back to it. If it does
    /// not, a session reported under that exact name falls through to the
    /// Finder fallback instead of its terminal.
    @Test
    func everyDisplayNameResolvesToItsOwnDescriptor() {
        let service = TerminalJumpService(
            applicationResolver: { _ in URL(fileURLWithPath: "/Applications/Stub.app") },
            appRunningChecker: { _ in true },
            openAction: { _ in },
            appleScriptRunner: { _ in "" }
        )

        for descriptor in TerminalJumpService.knownApps {
            let resolved = service.resolveTerminalAppForTesting(preferredName: descriptor.displayName)
            #expect(
                resolved?.bundleIdentifier == descriptor.bundleIdentifier,
                "\(descriptor.displayName) does not resolve to itself"
            )
        }
    }
}
