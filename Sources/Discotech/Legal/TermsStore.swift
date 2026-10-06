import Foundation

/// Which version of the terms this Mac accepted. The one thing stored: an integer under
/// `acceptedTermsVersion` in the app's UserDefaults (nothing about the person, nothing
/// that leaves the Mac). Missing or lower than `Terms.version` means the agreement screen
/// shows and nothing else runs.
@MainActor
final class TermsStore: ObservableObject {
    static let shared = TermsStore()
    static let defaultsKey = "acceptedTermsVersion"

    /// The accepted version, 0 when never accepted.
    @Published private(set) var acceptedVersion: Int
    var isAccepted: Bool { acceptedVersion >= Terms.version }

    /// False only for DEBUG runs that must not touch the stored value.
    private let persists: Bool
    private let defaults: UserDefaults

    /// `defaults` and `environment` are injectable so tests never read or write the real
    /// settings; the app only ever uses `shared`.
    init(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        var accepted = Self.storedVersion(in: defaults)
        var persists = true
        #if DEBUG
        // DISCOTECH_RESET_TERMS=1   show the agreement screen as on a first launch; the stored
        //                           value is ignored and left as it is, and Agree is not saved.
        // DISCOTECH_ACCEPT_TERMS=1  skip the screen for this run (autoscan and other hooks),
        //                           without saving anything. Wins over RESET.
        let env = environment
        if env["DISCOTECH_RESET_TERMS"] == "1" { accepted = 0; persists = false }
        if env["DISCOTECH_ACCEPT_TERMS"] == "1" { accepted = Terms.version; persists = false }
        #endif
        acceptedVersion = accepted
        self.persists = persists
    }

    /// Called only by the agreement screen's Agree button.
    func accept() {
        acceptedVersion = max(acceptedVersion, Terms.version)
        if persists { defaults.set(acceptedVersion, forKey: Self.defaultsKey) }
        ScanLog.line("terms accepted: version \(acceptedVersion)\(persists ? "" : " (not saved)")")
    }

    private static func storedVersion(in defaults: UserDefaults) -> Int {
        #if !DEBUG
        // A launch argument (`-acceptedTermsVersion N`) lands in the argument domain and
        // would read as acceptance. Release builds count only what Agree saved: with the
        // key on the command line the screen shows, whatever the saved value.
        if defaults.volatileDomain(forName: UserDefaults.argumentDomain)[defaultsKey] != nil { return 0 }
        #endif
        return defaults.integer(forKey: defaultsKey)
    }
}
