import AppKit
import QuartzCore

/// Turns scroll-wheel / trackpad events into discrete "one level in / one level out"
/// steps. Shared by the Ball and the Floor so the thresholds and the gesture rules can
/// never drift apart. The view owns the meaning of a step (which folder, which zoom);
/// this type only decides *when* a step happens.
///
/// Up / forward (the fingers or the wheel moving away from you, whatever the
/// natural-scrolling setting) is "in", down / back is "out", like zooming a map.
struct ScrollLevelNavigator {
    /// Points of precise (trackpad, Magic Mouse) travel before a swipe counts. Small
    /// enough for a short flick, big enough that resting fingers never step.
    static let preciseThreshold: CGFloat = 24
    /// Minimum time between two steps: a classic wheel notch is one level, a fast
    /// spin is held to one level per this long.
    static let cooldown: CFTimeInterval = 0.25
    /// A phase-less precise accumulator idle this long starts over.
    static let idleReset: CFTimeInterval = 0.3

    private var accumulated: CGFloat = 0
    /// The current trackpad swipe has already moved a level (one swipe, one level).
    private var gestureStepped = false
    private var lastStep: CFTimeInterval = -.infinity
    private var lastEvent: CFTimeInterval = -.infinity

    /// Feeds one scroll event. Calls `step(inward)` at most once. Returns false for
    /// events that aren't ours to take (mostly horizontal), which should then travel up
    /// the responder chain; true when the event was consumed.
    /// `now` is the event's time; callers leave it at the default (tests pass their own clock).
    mutating func handle(_ event: NSEvent, now: CFTimeInterval = CACurrentMediaTime(),
                         step: (_ inward: Bool) -> Void) -> Bool {
        // Momentum is the system coasting after the fingers lifted, not the user: swallow
        // it so one swipe can never run on into a second level.
        if !event.momentumPhase.isEmpty { return true }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            accumulated = 0
            gestureStepped = false
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            accumulated = 0
            gestureStepped = false
            return true
        }
        // Physical direction, whatever the natural-scrolling setting: positive means the
        // fingers or the wheel moved up / away from you.
        let dy = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        let dx = event.scrollingDeltaX
        guard abs(dy) >= abs(dx) else { return false }
        guard dy != 0 else { return true }

        if !event.hasPreciseScrollingDeltas {
            // Classic wheel: one notch, one level.
            guard now - lastStep >= Self.cooldown else { return true }
            lastStep = now
            step(dy > 0)
            return true
        }
        if event.phase.isEmpty {
            // Precise deltas without gesture phases (some mice): accumulate, then cool down.
            if now - lastEvent > Self.idleReset { accumulated = 0 }
            lastEvent = now
        } else if gestureStepped {
            return true
        }
        accumulated += dy
        guard abs(accumulated) >= Self.preciseThreshold, now - lastStep >= Self.cooldown else { return true }
        let inward = accumulated > 0
        accumulated = 0
        if !event.phase.isEmpty { gestureStepped = true }
        lastStep = now
        step(inward)
        return true
    }
}
