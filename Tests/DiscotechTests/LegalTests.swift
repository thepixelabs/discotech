import Foundation
import Testing
@testable import Discotech

@MainActor
@Suite("TermsStore")
struct TermsStoreTests {
    private let key = TermsStore.defaultsKey

    @Test("nothing is accepted by default")
    func notAcceptedByDefault() async {
        await withIsolatedDefaults { defaults in
            let store = TermsStore(defaults: defaults, environment: [:])
            #expect(store.acceptedVersion == 0)
            #expect(!store.isAccepted)
        }
    }

    @Test("accepting stores the current version and a new store reads it back")
    func acceptStoresVersion() async {
        await withIsolatedDefaults { defaults in
            let store = TermsStore(defaults: defaults, environment: [:])
            store.accept()
            #expect(store.isAccepted)
            #expect(defaults.integer(forKey: key) == Terms.version)
            #expect(TermsStore(defaults: defaults, environment: [:]).isAccepted)
        }
    }

    @Test("a stored version one above the current one is still accepted")
    func newerStoredVersionIsAccepted() async {
        await withIsolatedDefaults { defaults in
            defaults.set(Terms.version + 1, forKey: key)
            #expect(TermsStore(defaults: defaults, environment: [:]).isAccepted)
        }
    }

    @Test("a stored version below the current one asks again")
    func lowerStoredVersionReprompts() async {
        await withIsolatedDefaults { defaults in
            defaults.set(Terms.version - 1, forKey: key)
            #expect(!TermsStore(defaults: defaults, environment: [:]).isAccepted)
        }
    }

    @Test("accepting after a lower stored version replaces it with the current one")
    func acceptingUpgradesTheStoredVersion() async {
        await withIsolatedDefaults { defaults in
            defaults.set(Terms.version - 1, forKey: key)
            let store = TermsStore(defaults: defaults, environment: [:])
            store.accept()
            #expect(defaults.integer(forKey: key) == Terms.version)
        }
    }

    @Test("accepting never lowers a higher stored version")
    func acceptNeverLowers() async {
        await withIsolatedDefaults { defaults in
            defaults.set(Terms.version + 5, forKey: key)
            let store = TermsStore(defaults: defaults, environment: [:])
            store.accept()
            #expect(defaults.integer(forKey: key) == Terms.version + 5)
        }
    }

    @Test("a stored value that is not a number does not count as acceptance")
    func garbageIsNotAcceptance() async {
        await withIsolatedDefaults { defaults in
            defaults.set("yes", forKey: key)
            #expect(!TermsStore(defaults: defaults, environment: [:]).isAccepted)
        }
    }

    #if DEBUG
    @Test("DISCOTECH_ACCEPT_TERMS skips the screen for the run without saving anything")
    func debugAcceptDoesNotPersist() async {
        await withIsolatedDefaults { defaults in
            let store = TermsStore(defaults: defaults, environment: ["DISCOTECH_ACCEPT_TERMS": "1"])
            #expect(store.isAccepted)
            store.accept()
            #expect(defaults.object(forKey: key) == nil)
        }
    }

    @Test("DISCOTECH_RESET_TERMS shows the screen again, ignores the stored value and leaves it alone")
    func debugResetDoesNotTouchStoredValue() async {
        await withIsolatedDefaults { defaults in
            defaults.set(Terms.version, forKey: key)
            let store = TermsStore(defaults: defaults, environment: ["DISCOTECH_RESET_TERMS": "1"])
            #expect(!store.isAccepted)
            store.accept()
            #expect(defaults.integer(forKey: key) == Terms.version)
        }
    }

    @Test("when both are set, ACCEPT wins over RESET")
    func debugAcceptBeatsReset() async {
        await withIsolatedDefaults { defaults in
            let store = TermsStore(defaults: defaults, environment: ["DISCOTECH_ACCEPT_TERMS": "1", "DISCOTECH_RESET_TERMS": "1"])
            #expect(store.isAccepted)
        }
    }
    #else
    @Test("release builds ignore the debug environment overrides")
    func releaseIgnoresDebugEnvironment() async {
        await withIsolatedDefaults { defaults in
            let store = TermsStore(defaults: defaults, environment: ["DISCOTECH_ACCEPT_TERMS": "1"])
            #expect(!store.isAccepted)
        }
    }
    #endif
}

/// `docs/TERMS.md` is the source of truth for every word the app shows about the terms.
/// These tests read it from the repository and compare, so the two cannot drift apart.
@Suite("Terms text matches docs/TERMS.md")
struct TermsDocumentTests {
    private static let markdown: String = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: root.appendingPathComponent("docs/TERMS.md"), encoding: .utf8)) ?? ""
    }()

    /// The lines of the section that starts at the heading beginning with `heading`, up to
    /// the next `## ` heading, with the trailing `---` rule removed.
    private func section(_ heading: String) -> [String] {
        let lines = Self.markdown.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## " + heading) }) else { return [] }
        var body = Array(lines[(start + 1)...].prefix { !$0.hasPrefix("## ") })
        while body.last?.isEmpty == true || body.last == "---" { body.removeLast() }
        while body.first?.isEmpty == true { body.removeFirst() }
        return body
    }

    /// The text after `label` on the line that starts with it.
    private func value(of label: String, in lines: [String]) -> String? {
        lines.first { $0.hasPrefix(label) }.map { String($0.dropFirst(label.count)).trimmingCharacters(in: .whitespaces) }
    }

    @Test("the document is found and has all the sections the app copies from")
    func documentIsReadable() {
        #expect(!Self.markdown.isEmpty, "docs/TERMS.md was not found relative to \(#filePath)")
        #expect(!section("1. In-app summary").isEmpty)
        #expect(!section("2. Full terms").isEmpty)
        #expect(!section("3. Delete reminder").isEmpty)
    }

    @Test("Terms.version equals TERMS_VERSION in the document")
    func versionMatches() throws {
        let line = try #require(Self.markdown.components(separatedBy: "\n").first { $0.hasPrefix("TERMS_VERSION:") })
        let documented = try #require(Int(line.dropFirst("TERMS_VERSION:".count).trimmingCharacters(in: .whitespaces)))
        #expect(Terms.version == documented)
    }

    @Test("the full terms name the same version as Terms.version")
    func fullTextVersionLine() {
        #expect(Terms.fullText.contains("\nVersion \(Terms.version). Effective "))
    }

    @Test("window title and heading match section 1")
    func titleAndHeading() {
        let s1 = section("1. In-app summary")
        #expect(value(of: "**Window title:**", in: s1) == Terms.windowTitle)
        #expect(value(of: "**Heading:**", in: s1) == Terms.heading)
    }

    @Test("the summary bullets match section 1, in order")
    func summaryBullets() {
        let bullets = section("1. In-app summary").filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
        #expect(bullets == Terms.summary)
    }

    @Test("the checkbox sentence matches section 1 word for word")
    func checkboxSentence() throws {
        let s1 = section("1. In-app summary")
        let label = try #require(s1.firstIndex { $0.hasPrefix("**Checkbox") })
        #expect(s1[label + 1] == Terms.checkbox)
    }

    @Test("the Quit and Agree button labels match section 1")
    func buttonLabels() throws {
        let buttons = try #require(value(of: "**Buttons:**", in: section("1. In-app summary")))
        #expect(buttons.contains("`\(Terms.quitButton)`"))
        #expect(buttons.contains("`\(Terms.agreeButton)`"))
    }

    @Test("the full terms match section 2 word for word, line breaks included")
    func fullTerms() {
        #expect(section("2. Full terms").joined(separator: "\n") == Terms.fullText)
    }

    @Test("the delete reminder matches the primary line in section 3")
    func deleteReminder() throws {
        let s3 = section("3. Delete reminder")
        let label = try #require(s3.firstIndex { $0.hasPrefix("**Primary") })
        #expect(s3[label + 1] == Terms.deleteReminder)
    }

    @Test("the primary reminder's stated length in the document is its real length")
    func reminderLength() throws {
        let s3 = section("3. Delete reminder")
        let label = try #require(s3.firstIndex { $0.hasPrefix("**Primary") })
        let stated = try #require(Int(s3[label].drop { !$0.isNumber }.prefix { $0.isNumber }))
        #expect(stated == Terms.deleteReminder.count)
    }

    @Test("the attributed full text keeps every line and bold run, with no links")
    func attributedText() {
        let plain = String(Terms.fullTextAttributed.characters)
        #expect(plain.contains("\n1.1 Discotech scans"))
        #expect(!plain.contains("**"))
        withKnownIssue("Terms.fullTextAttributed turns the contact URL in section 12 into a link, although its comment says nothing becomes a link") {
            #expect(!Terms.fullTextAttributed.runs.contains { $0.link != nil })
        }
    }
}
