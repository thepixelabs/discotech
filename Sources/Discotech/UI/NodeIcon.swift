import SwiftUI

/// Row icon for any node: the Finder icon for real files and folders, a plain SF Symbol
/// for synthetic accounting nodes (free / purgeable / unseen / snapshot), which have no
/// file to ask LaunchServices about.
struct NodeIcon: View {
    let node: FileNode
    var size: CGFloat = Tokens.Size.rowIcon
    /// Load ahead of queued row icons (the hover card and strip).
    var urgent = false

    var body: some View {
        if let symbol = node.kind.symbolName {
            Image(systemName: symbol)
                .font(.system(size: size * 0.64, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            FileIconView(path: node.path, isDirectory: node.isDirectory, size: size, urgent: urgent)
        }
    }
}

extension FileNode.Kind {
    /// SF Symbol for synthetic kinds; nil for real items (they use the Finder icon).
    var symbolName: String? {
        switch self {
        case .item: return nil
        case .freeSpace: return "circle.dashed"
        case .purgeable: return "arrow.3.trianglepath"
        case .hidden: return "eye.slash"
        case .snapshot: return "clock.arrow.circlepath"
        }
    }

    /// One-line explanation shown where file actions would be (context menus, tooltips).
    var explanation: String? {
        switch self {
        case .item: return nil
        case .freeSpace: return "Space you can use right now"
        case .purgeable: return "Space macOS can free up when it needs to"
        case .hidden: return "Used space no scanned file accounts for — missing Full Disk Access can make this bigger"
        case .snapshot: return "A local snapshot kept by macOS"
        }
    }
}
