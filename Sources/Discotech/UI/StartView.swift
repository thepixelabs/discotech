import AppKit
import SwiftUI

/// Phase `.start`: pick a drive or a folder to scan.
///
/// The page has one job — scan the startup disk — so that disk gets one large card
/// with the page's only primary button. Every other volume is a compact row below it
/// (installer and other read-only disk images included, so they never compete).
struct StartView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var volumes: [Volume] = Volume.mounted()
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted()
    @AppStorage("fdaNoticeDismissed") private var fdaNoticeDismissed = false
    @State private var showingAccessInfo = false
    @State private var isDropTargeted = false

    /// The startup disk, or whatever volume comes first if it isn't listed.
    private var primary: Volume? { volumes.first { $0.url.path == "/" } ?? volumes.first }
    private var others: [Volume] { volumes.filter { $0.id != primary?.id } }

    var body: some View {
        ZStack {
            Backdrop(wash: UnitPoint(x: 0.5, y: 0.45))

            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: Tokens.Space.xl) {
                        hero

                        if let error = state.scanError {
                            Banner(systemImage: "exclamationmark.triangle.fill", tint: Tokens.Colors.critical,
                                   title: "The scan stopped early", message: error) {
                                if state.scanRoot != nil {
                                    Button("Try Again") { state.rescan() }.buttonStyle(.studioSecondary)
                                }
                            }
                        }

                        if let primary {
                            StartupDiskCard(volume: primary, isStartupDisk: primary.url.path == "/",
                                            scan: { state.startScan(primary.url) }, scanFolder: chooseFolder)
                        } else {
                            noVolumes
                        }

                        if !others.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: Tokens.Breakpoint.startTwoUp / 2),
                                                         spacing: Tokens.Space.m)],
                                      spacing: Tokens.Space.m) {
                                ForEach(others) { volume in
                                    VolumeRow(volume: volume) { state.startScan(volume.url) }
                                }
                            }
                        }

                        Text("or drop a folder anywhere on this window")
                            .font(.callout)
                            .foregroundStyle(Tokens.Colors.textTertiary)
                    }
                    .padding(.horizontal, Tokens.Space.hero)
                    .padding(.vertical, Tokens.Space.xl)
                    .frame(maxWidth: Tokens.Size.contentMaxWidth + Tokens.Space.hero * 2)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            if isDropTargeted { DropOverlay() }
        }
        #if DEBUG
        .onAppear { if DebugHooks.previewDrop { isDropTargeted = true } }
        #endif
        .hidingWindowTitle()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .help("Settings (⌘,)")
                HelpButton()
            }
            if !hasFullDiskAccess && !fdaNoticeDismissed {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingAccessInfo.toggle()
                    } label: {
                        HStack(spacing: Tokens.Space.xs) {
                            Image(systemName: "lock.fill")
                            Text("Full Disk Access is off ·")
                            Text("Allow…").foregroundStyle(Tokens.Colors.accentText)
                        }
                        .font(.callout)
                        .lineLimit(1)
                    }
                    .help("Some folders are hidden from scans until you allow Full Disk Access")
                    .accessibilityLabel("Full Disk Access is off. Allow")
                    .popover(isPresented: $showingAccessInfo, arrowEdge: .bottom) {
                        FullDiskAccessInfo {
                            FullDiskAccess.openSettings()
                            showingAccessInfo = false
                        } dismiss: {
                            showingAccessInfo = false
                            fdaNoticeDismissed = true
                        }
                    }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: FolderPicker.isDirectory) else { return false }
            state.startScan(url)
            return true
        } isTargeted: { targeted in
            withAnimation(Tokens.Motion.hover(reduceMotion)) { isDropTargeted = targeted }
        }
        .background {
            // ⌘O works even when no card shows the folder button.
            Button("Scan a Folder…", action: chooseFolder)
                .keyboardShortcut("o", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in refreshVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in refreshVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didRenameVolumeNotification)) { _ in refreshVolumes() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from System Settings: re-check access; free space may have changed too.
            hasFullDiskAccess = FullDiskAccess.isGranted()
            refreshVolumes()
        }
    }

    private var hero: some View {
        VStack(spacing: Tokens.Space.s) {
            BrandMark()
                .padding(.bottom, Tokens.Space.xs)
            Text("See exactly where your space went")
                .font(Tokens.Typeface.hero)
                .foregroundStyle(Tokens.Colors.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Pick a drive or a folder to map every file by size, biggest first.")
                .font(.title3)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var noVolumes: some View {
        VStack(spacing: Tokens.Space.m) {
            ContentUnavailableView("No drives found", systemImage: "externaldrive.badge.questionmark",
                                   description: Text("Connect a drive, or scan a folder instead."))
            Button("Scan a Folder…", action: chooseFolder)
                .buttonStyle(.studio(.primary, large: true))
                .keyboardShortcut(.defaultAction)
        }
        .padding(Tokens.Space.xl)
        .frame(maxWidth: .infinity)
        .cardSurface(RoundedRectangle(cornerRadius: Tokens.Radius.hero, style: .continuous))
    }

    private func chooseFolder() {
        if let url = FolderPicker.choose() { state.startScan(url) }
    }

    private func refreshVolumes() { volumes = Volume.mounted() }
}

// MARK: - Startup disk card

/// The page's first stop: a large gauge, the disk's name and usage, and the one
/// primary button. Stacks the gauge above the text when the window is narrow.
struct StartupDiskCard: View {
    let volume: Volume
    let isStartupDisk: Bool
    let scan: () -> Void
    let scanFolder: () -> Void

    private var usedFraction: Double {
        volume.totalCapacity > 0 ? Double(volume.usedCapacity) / Double(volume.totalCapacity) : 0
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Tokens.Space.xxl) {
                gauge
                details(alignment: .leading)
                Spacer(minLength: 0)
            }
            .frame(minWidth: Tokens.Breakpoint.startStack - Tokens.Space.hero * 2)
            VStack(spacing: Tokens.Space.l) {
                gauge
                details(alignment: .center)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(Tokens.Space.xl + Tokens.Space.xs)
        .cardSurface(RoundedRectangle(cornerRadius: Tokens.Radius.hero, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(volume.name), \(isStartupDisk ? "startup disk" : "disk"). \(Bytes.string(volume.availableCapacity)) free of \(Bytes.string(volume.totalCapacity)).")
    }

    private var gauge: some View {
        ZStack {
            RingGauge(fraction: usedFraction)
            VStack(spacing: Tokens.Space.xxs) {
                Text(Bytes.string(volume.availableCapacity))
                    .font(Tokens.Typeface.figure(26))
                    .foregroundStyle(Tokens.Colors.freeSpace(usedFraction: usedFraction))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("free of \(Bytes.string(volume.totalCapacity))")
                    .font(.caption)
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Tokens.Size.gaugeLine + Tokens.Space.s)
        }
        .frame(width: Tokens.Size.gauge, height: Tokens.Size.gauge)
    }

    private func details(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: Tokens.Space.xs) {
            Text(isStartupDisk ? "STARTUP DISK" : (volume.isInternal ? "INTERNAL" : "EXTERNAL"))
                .font(Tokens.Typeface.eyebrow)
                .tracking(Tokens.Typeface.eyebrowTracking)
                .foregroundStyle(Tokens.Colors.textTertiary)
            Text(volume.name)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Tokens.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(Bytes.string(volume.usedCapacity)) used of \(Bytes.string(volume.totalCapacity))")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(Tokens.Colors.textSecondary)
                .lineLimit(1)
            HStack(spacing: Tokens.Space.s + Tokens.Space.xxs) {
                Button(action: scan) {
                    Text("Scan \(volume.name)").lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.studio(.primary, large: true))
                .keyboardShortcut(.defaultAction)
                Button(action: scanFolder) {
                    Text("Scan a Folder…").lineLimit(1)
                }
                .buttonStyle(.studio(.secondary, large: true))
                .help("Choose a folder to scan (⌘O)")
            }
            .fixedSize()
            .padding(.top, Tokens.Space.m)
        }
    }
}

// MARK: - Volume row

/// Any volume other than the startup disk: one compact row.
struct VolumeRow: View {
    let volume: Volume
    let scan: () -> Void

    /// Disk images and other read-only volumes are always "full"; don't alarm about them.
    @State private var isReadOnly = false

    private var usedFraction: Double {
        volume.totalCapacity > 0 ? Double(volume.usedCapacity) / Double(volume.totalCapacity) : 0
    }

    private var detail: Text {
        if isReadOnly { return Text("Read-only disk image · \(Bytes.string(volume.totalCapacity))") }
        let kind = volume.isInternal ? "Internal" : (volume.isRemovable ? "Removable" : "External")
        return Text("\(kind) · ")
            + Text("\(Bytes.string(volume.availableCapacity)) free").foregroundStyle(freeColor)
            + Text(" of \(Bytes.string(volume.totalCapacity))")
    }

    private var freeColor: Color {
        usedFraction < 0.85 ? Tokens.Colors.textSecondary : Tokens.Colors.freeSpace(usedFraction: usedFraction)
    }

    var body: some View {
        HStack(spacing: Tokens.Space.m) {
            FileIconView(path: volume.url.path, isDirectory: true, size: Tokens.Size.volumeRowIcon)
            VStack(alignment: .leading, spacing: 1) {
                Text(volume.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Tokens.Space.s)
            Button("Scan", action: scan)
                .buttonStyle(.studioSecondary)
                .fixedSize()
                .accessibilityLabel("Scan \(volume.name)")
        }
        .padding(.horizontal, Tokens.Space.m)
        .padding(.vertical, Tokens.Space.s + Tokens.Space.xxs)
        .cardSurface(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
        .task(id: volume.url) {
            isReadOnly = (try? volume.url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Drop overlay

/// Whole-window rim while a folder is dragged over the start screen.
struct DropOverlay: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.hero, style: .continuous)
        ZStack {
            if reduceTransparency {
                shape.fill(Tokens.Colors.canvas.opacity(0.92))
            } else {
                shape.fill(.ultraThinMaterial)
            }
            SpectrumRim(shape: shape, lineWidth: 2.5)
            Label("Drop to scan this folder", systemImage: "folder.fill")
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundStyle(Tokens.Colors.textPrimary)
                .padding(.horizontal, Tokens.Space.xl)
                .padding(.vertical, Tokens.Space.m)
                .glassSurface(Capsule())
        }
        .padding(Tokens.Space.m)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

// MARK: - Full Disk Access popover

private struct FullDiskAccessInfo: View {
    let openSettings: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Label {
                Text("Get complete totals").font(.system(.headline, design: .rounded))
            } icon: {
                Image(systemName: "lock.shield.fill").foregroundStyle(Tokens.Colors.info)
            }
            Text("macOS keeps Mail, Messages, Safari and other protected folders out of every scan until you allow Full Disk Access. Without it, some space shows up as unaccounted for.")
                .font(.callout)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Turn it on in System Settings › Privacy & Security › Full Disk Access, then come back.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Don’t Show Again", action: dismiss)
                Spacer()
                Button("Open Privacy Settings", action: openSettings)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, Tokens.Space.xs)
        }
        .padding(Tokens.Space.l + Tokens.Space.xxs)
        .frame(width: 340)
    }
}
