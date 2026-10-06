import AppKit
import SwiftUI

/// The "?" toolbar button (browsing and start screens): opens the help centre in a popover.
struct HelpButton: View {
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Label("Help", systemImage: "questionmark.circle")
        }
        .help("\(Brand.name) Help (⌘?)")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            HelpCenterView()
                .frame(width: 380, height: 520)
        }
    }
}

/// The help centre: short, scannable sections, the colour section open by default and live
/// (it reads the current "Colour by" mode and theme). Shown in the toolbar popover and in
/// the Help window (Help → Discotech Help, ⌘?).
struct HelpCenterView: View {
    @ObservedObject private var colors = ColorModeStore.shared
    @ObservedObject private var themes = ThemeStore.shared
    @State private var open: Set<Section> = [.colours]

    enum Section: String, CaseIterable, Identifiable {
        case colours, views, moving, crate, findings, privacy, openSource
        var id: String { rawValue }
        var title: String {
            switch self {
            case .colours: return "What the colours mean"
            case .views: return "Views"
            case .moving: return "Moving around"
            case .crate: return "The \(Brand.crate)"
            case .findings: return "Findings"
            case .privacy: return "Privacy"
            case .openSource: return "Open source"
            }
        }
        var symbol: String {
            switch self {
            case .colours: return "paintpalette"
            case .views: return "circle.circle"
            case .moving: return "cursorarrow.click"
            case .crate: return "archivebox"
            case .findings: return "sparkle.magnifyingglass"
            case .privacy: return "lock"
            case .openSource: return "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text("\(Brand.name) Help")
                    .font(.title3.weight(.semibold))
                    .padding(.bottom, Tokens.Space.xs)
                ForEach(Section.allCases) { section in
                    DisclosureGroup(isExpanded: binding(section)) {
                        content(section)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Tokens.Space.xs)
                            .padding(.bottom, Tokens.Space.s)
                    } label: {
                        Label(section.title, systemImage: section.symbol)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Tokens.Colors.textPrimary)
                    }
                    if section != Section.allCases.last { Divider() }
                }
            }
            .padding(Tokens.Space.l)
        }
        // Rebuilt on a theme or mode switch so the swatches never go stale.
        .id("\(themes.lookID)-\(colors.mode.rawValue)")
        #if DEBUG
        .background(HelpSnapshotHook())
        #endif
    }

    private func binding(_ section: Section) -> Binding<Bool> {
        Binding(get: { open.contains(section) },
                set: { if $0 { open.insert(section) } else { open.remove(section) } })
    }

    @ViewBuilder private func content(_ section: Section) -> some View {
        switch section {
        case .colours: colours
        case .views:
            lines([
                ("Ball  ⌘1", "The folder in view at the centre, each ring one level deeper."),
                ("Layers  ⌘2", "One column per level, items stacked by size."),
                ("Floor  ⌘3", "Blocks sized by the space they take."),
            ])
        case .moving:
            bullets([
                "Click a folder to open it; click a file to select it.",
                "Go back up: click the Ball’s centre or an empty spot, press ⌘↑ or Delete, or use the back arrow.",
                "In the Ball and the Floor, scroll up to open the folder under the pointer, down to go back out.",
                "Click a folder in the path bar to jump to it.",
                "Space previews the selected item with Quick Look.",
            ])
        case .crate:
            bullets([
                "Drag rows from the sidebar into the \(Brand.crate), or use Add to \(Brand.crate) on a finding.",
                "Review the \(Brand.crate) (⌘⌫) to see everything in it and take out what you want to keep.",
                "Nothing is deleted until you confirm Move to Trash.",
                "Items in system or app-data folders are flagged, and you’re asked again before each one moves.",
                "Items only ever go to the Trash, so they come back until you empty it.",
            ])
        case .findings:
            bullets([
                "Findings sorts what it finds into two groups.",
                "Safe to clear: space that comes back on its own when needed, such as app, browser and package caches, and rebuildable dev output like node_modules and Xcode build data.",
                "Review first: things that are probably not needed but are personal or not rebuilt, such as device backups, simulators, installers in Downloads, large videos and your largest files. Look through them before adding any.",
                "Items already in the Trash are shown so you can see the space they take; empty the Trash in Finder to free it.",
                "Point at a card to light its items up in the chart; View items lists them. Adding a card only fills the \(Brand.crate): nothing moves to the Trash until you review it and confirm.",
            ])
        case .privacy:
            bullets([
                "Scans stay in memory while \(Brand.name) is open.",
                "Nothing about your files is written to disk or sent anywhere. Only your settings are saved.",
                "Scans are not cached on purpose: a saved map of your files could expose them to anyone who finds it, so results are gone when you quit.",
            ])
        case .openSource:
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text("\(Brand.name) is open source under the MIT licence.")
                    .foregroundStyle(Tokens.Colors.textSecondary)
                if let url = URL(string: "https://github.com/thepixelabs/discotech") {
                    Link("github.com/thepixelabs/discotech", destination: url)
                }
            }
        }
    }

    /// The live colour key for the current "Colour by" mode and theme.
    private var colours: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            HStack(spacing: Tokens.Space.xs) {
                Text("Colour by:").foregroundStyle(Tokens.Colors.textSecondary)
                Text(colors.mode.title).fontWeight(.semibold)
                Text("· \(themes.style == .signal ? themes.signal.title : themes.theme.title) (\(themes.style.title))")
                    .foregroundStyle(Tokens.Colors.textTertiary)
            }
            Text(colors.mode.explanation).foregroundStyle(Tokens.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            switch colors.mode {
            case .size:
                HStack(spacing: Tokens.Space.s) {
                    Text("Smaller").font(.caption).foregroundStyle(Tokens.Colors.textSecondary)
                    RampBar(cellWidth: 22, height: 9)
                    Text("Larger").font(.caption).foregroundStyle(Tokens.Colors.textSecondary)
                }
                Text("Size is measured against the folder in view, so colours shift as you zoom.")
                    .font(.caption).foregroundStyle(Tokens.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .kind:
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: Tokens.Space.xs) {
                    ForEach(ContentKind.allCases.sorted { $0.step > $1.step }) { kind in
                        HStack(spacing: Tokens.Space.xs) {
                            LegendDot(paint: Palette.Paint(step: kind.step), size: 10)
                            Text(kind.title).font(.caption).lineLimit(1)
                        }
                    }
                }
                Text("A folder takes the kind that fills most of it. Deeper rings and files are a little greyer.")
                    .font(.caption).foregroundStyle(Tokens.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .folder:
                RampBar(cellWidth: 22, height: 9)
                Text(themes.style == .signal
                     ? "Each top-level folder gets its own colour from the scale, the biggest at the far end. The key above the chart names them."
                     : "The biggest top-level folder gets the strongest colour, the next ones lighter steps. The key above the chart names them.")
                    .font(.caption).foregroundStyle(Tokens.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Free, purgeable and unseen space keep their own quiet tints in every mode.")
                .font(.caption).foregroundStyle(Tokens.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsLink { Text("Change in Settings…") }
                .controlSize(.small)
        }
    }

    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.xs) {
                    Text("•").foregroundStyle(Tokens.Colors.textTertiary).accessibilityHidden(true)
                    Text(item).foregroundStyle(Tokens.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func lines(_ items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            ForEach(items, id: \.0) { title, text in
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(.medium).foregroundStyle(Tokens.Colors.textPrimary)
                    Text(text).foregroundStyle(Tokens.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
