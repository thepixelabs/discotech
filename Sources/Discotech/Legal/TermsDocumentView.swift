import AppKit
import SwiftUI

/// Help → Discotech Terms of Use… and Settings → Terms: the full terms, read-only, with the
/// current and the accepted version. No checkbox, no Agree; a Close button only.
struct TermsDocumentView: View {
    static let windowID = "terms"
    @ObservedObject private var terms = TermsStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Text(Terms.windowTitle)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(versionLine)
                    .font(.callout)
                    .foregroundStyle(Tokens.Colors.textSecondary)
            }
            FullTermsText()
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.studio(.secondary, large: true))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Tokens.Space.xl)
        .frame(width: 520, height: 640)
        .background(Tokens.Colors.canvas)
        #if DEBUG
        .background(DebugHooks.WindowSnapshotHook(envKey: "DISCOTECH_TERMS_SNAPSHOT"))
        #endif
    }

    private var versionLine: String {
        let accepted = terms.acceptedVersion > 0 ? "You accepted version \(terms.acceptedVersion)." : "Not accepted yet."
        return "Version \(Terms.version). \(accepted)"
    }
}

/// The "Terms" row at the bottom of Settings: the accepted version and a way to read them.
struct TermsSettingsRow: View {
    @ObservedObject private var terms = TermsStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Space.l) {
            VStack(alignment: .leading, spacing: Tokens.Space.xxs) {
                Text("Terms").font(.headline)
                Text(terms.acceptedVersion > 0 ? "You accepted version \(terms.acceptedVersion) of the \(Terms.windowTitle)."
                                               : "Not accepted yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("View Terms…") { openWindow(id: TermsDocumentView.windowID) }
                .buttonStyle(.studioSecondary)
                .disabled(!terms.isAccepted)
        }
        .accessibilityElement(children: .contain)
    }
}
