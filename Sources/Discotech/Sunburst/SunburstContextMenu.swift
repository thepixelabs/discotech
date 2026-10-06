import AppKit

/// NSMenuItem with a closure action, so the sunburst's right-click menu can be
/// built inline without a target/selector dance.
final class SunburstClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() { handler() }
}
