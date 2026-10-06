#if DEBUG
import AppKit

/// Synthetic scroll events for the DISCOTECH_SCROLL_TEST self-tests (Ball and Floor).
enum ScrollTestEvents {
    /// A scroll event: `precise` with gesture/momentum phases (trackpad) or a wheel notch.
    static func make(dy: Int32, precise: Bool, phase: Int64 = 0, momentum: Int64 = 0) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                               wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        if let field = CGEventField(rawValue: 99) { cg.setIntegerValueField(field, value: phase) }      // scroll phase
        if let field = CGEventField(rawValue: 123) { cg.setIntegerValueField(field, value: momentum) }  // momentum phase
        return NSEvent(cgEvent: cg)
    }

    /// Trackpad swipe, fingers moving up: began, 8 x 6 pt, ended, then momentum.
    static func swipeUp() -> [NSEvent?] {
        // Built step by step: one long `+` chain is too much for older compilers to type-check.
        var events: [NSEvent?] = [make(dy: 0, precise: true, phase: 1)]
        for _ in 0..<8 { events.append(make(dy: 6, precise: true, phase: 2)) }
        events.append(make(dy: 0, precise: true, phase: 4))
        for i in 0..<6 { events.append(make(dy: 12, precise: true, momentum: i == 0 ? 1 : 2)) }
        return events
    }

    /// Trackpad swipe, fingers moving down: began, 6 x -7 pt, ended.
    static func swipeDown() -> [NSEvent?] {
        var events: [NSEvent?] = [make(dy: 0, precise: true, phase: 1)]
        for _ in 0..<6 { events.append(make(dy: -7, precise: true, phase: 2)) }
        events.append(make(dy: 0, precise: true, phase: 4))
        return events
    }

    static func notches(_ count: Int, dy: Int32) -> [NSEvent?] {
        (0..<count).map { _ in make(dy: dy, precise: false) }
    }
}
#endif
