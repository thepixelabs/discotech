import AppKit
import Testing
@testable import Discotech

/// A scroll event with exactly the fields the navigator reads. (`NSEvent` has no public
/// initialiser for scroll events with phases or the natural-scrolling flag.)
final class ScrollStub: NSEvent {
    var dy: CGFloat = 0
    var dx: CGFloat = 0
    var precise = false
    var gesturePhase: NSEvent.Phase = []
    var momentum: NSEvent.Phase = []
    var inverted = false

    override var scrollingDeltaY: CGFloat { dy }
    override var scrollingDeltaX: CGFloat { dx }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var phase: NSEvent.Phase { gesturePhase }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var isDirectionInvertedFromDevice: Bool { inverted }

    static func wheel(_ dy: CGFloat, inverted: Bool = false) -> ScrollStub {
        let e = ScrollStub(); e.dy = dy; e.inverted = inverted; return e
    }

    static func swipe(_ dy: CGFloat, _ phase: NSEvent.Phase = .changed, inverted: Bool = false) -> ScrollStub {
        let e = ScrollStub(); e.dy = dy; e.precise = true; e.gesturePhase = phase; e.inverted = inverted; return e
    }
}

/// Feeds events to a navigator with a clock the test controls.
private struct Rig {
    var navigator = ScrollLevelNavigator()
    var steps: [Bool] = []
    var consumed: [Bool] = []

    mutating func send(_ event: ScrollStub, at time: Double) {
        var recorded: [Bool] = []
        consumed.append(navigator.handle(event, now: time) { recorded.append($0) })
        steps += recorded
    }
}

@Suite("ScrollLevelNavigator")
struct ScrollLevelNavigatorTests {
    // MARK: Wheel

    @Test("a wheel notch away from you steps one level in, towards you one level out")
    func wheelDirection() {
        var rig = Rig()
        rig.send(.wheel(3), at: 0)
        rig.send(.wheel(-3), at: 1)
        #expect(rig.steps == [true, false])
        #expect(rig.consumed == [true, true])
    }

    @Test("natural scrolling is undone: the same physical movement steps the same way either way")
    func naturalScrollingInversion() {
        var normal = Rig(), natural = Rig()
        normal.send(.wheel(3, inverted: false), at: 0)
        natural.send(.wheel(-3, inverted: true), at: 0)
        #expect(normal.steps == [true])
        #expect(natural.steps == [true])
        var flipped = Rig()
        flipped.send(.wheel(3, inverted: true), at: 0)
        #expect(flipped.steps == [false])
    }

    @Test("a second notch inside the cooldown is swallowed, one after it steps again")
    func wheelCooldown() {
        var rig = Rig()
        rig.send(.wheel(1), at: 0)
        rig.send(.wheel(1), at: ScrollLevelNavigator.cooldown - 0.01)
        #expect(rig.steps.count == 1)
        rig.send(.wheel(1), at: ScrollLevelNavigator.cooldown + 0.01)
        #expect(rig.steps.count == 2)
        #expect(rig.consumed == [true, true, true])
    }

    @Test("the very first event is never held back by the cooldown, even at time zero")
    func firstEventSteps() {
        var rig = Rig()
        rig.send(.wheel(1), at: 0)
        #expect(rig.steps == [true])
    }

    // MARK: Ignored events

    @Test("momentum after the fingers lift is swallowed without a step")
    func momentumIgnored() {
        var rig = Rig()
        let coasting = ScrollStub.wheel(5)
        coasting.momentum = .changed
        rig.send(coasting, at: 0)
        #expect(rig.steps.isEmpty)
        #expect(rig.consumed == [true])
    }

    @Test("a mostly horizontal scroll is not taken, so it travels up the responder chain")
    func horizontalNotConsumed() {
        var rig = Rig()
        let sideways = ScrollStub.wheel(1)
        sideways.dx = 4
        rig.send(sideways, at: 0)
        #expect(rig.steps.isEmpty)
        #expect(rig.consumed == [false])
    }

    @Test("an event with no movement is consumed and does nothing")
    func zeroDelta() {
        var rig = Rig()
        rig.send(.wheel(0), at: 0)
        #expect(rig.steps.isEmpty)
        #expect(rig.consumed == [true])
    }

    // MARK: Trackpad

    @Test("a swipe steps once its travel reaches the threshold, not before")
    func preciseThreshold() {
        var rig = Rig()
        let half = ScrollLevelNavigator.preciseThreshold / 2
        rig.send(.swipe(half, .began), at: 0)
        #expect(rig.steps.isEmpty)
        rig.send(.swipe(half - 1), at: 0.01)
        #expect(rig.steps.isEmpty)
        rig.send(.swipe(1), at: 0.02)
        #expect(rig.steps == [true])
    }

    @Test("a swipe the other way steps out")
    func preciseOutward() {
        var rig = Rig()
        rig.send(.swipe(-ScrollLevelNavigator.preciseThreshold, .began), at: 0)
        #expect(rig.steps == [false])
    }

    @Test("a trackpad swipe moves one level however far the fingers keep going")
    func oneSwipeOneLevel() {
        var rig = Rig()
        rig.send(.swipe(30, .began), at: 0)
        for i in 1...20 { rig.send(.swipe(30), at: 0.01 * Double(i) + 1) }
        #expect(rig.steps.count == 1)
    }

    @Test("lifting the fingers ends the swipe, and the next swipe can step again after the cooldown")
    func nextSwipeAfterEnd() {
        var rig = Rig()
        rig.send(.swipe(30, .began), at: 0)
        rig.send(.swipe(0, .ended), at: 0.1)
        rig.send(.swipe(30, .began), at: 1)
        #expect(rig.steps == [true, true])
    }

    @Test("a new swipe inside the cooldown of the last step does not step")
    func swipeCooldown() {
        var rig = Rig()
        rig.send(.swipe(30, .began), at: 0)
        rig.send(.swipe(0, .ended), at: 0.05)
        rig.send(.swipe(30, .began), at: 0.1)
        #expect(rig.steps.count == 1)
    }

    @Test("starting a swipe throws away travel left over from the one before")
    func beganResetsTravel() {
        var rig = Rig()
        rig.send(.swipe(20, .began), at: 0)
        rig.send(.swipe(10, .began), at: 1)
        #expect(rig.steps.isEmpty)
    }

    @Test("a cancelled swipe throws its travel away")
    func cancelledResets() {
        var rig = Rig()
        rig.send(.swipe(20, .began), at: 0)
        rig.send(.swipe(0, .cancelled), at: 0.1)
        rig.send(.swipe(10), at: 1)
        #expect(rig.steps.isEmpty)
    }

    // MARK: Phase-less precise devices

    @Test("without gesture phases, travel accumulates across events and steps at the threshold")
    func phaselessAccumulates() {
        var rig = Rig()
        rig.send(.swipe(15, []), at: 0)
        #expect(rig.steps.isEmpty)
        rig.send(.swipe(15, []), at: 0.1)
        #expect(rig.steps == [true])
    }

    @Test("without gesture phases, travel is forgotten after the idle time")
    func phaselessIdleReset() {
        var rig = Rig()
        rig.send(.swipe(15, []), at: 0)
        rig.send(.swipe(15, []), at: ScrollLevelNavigator.idleReset + 0.1)
        #expect(rig.steps.isEmpty)
    }

    @Test("without gesture phases, the cooldown holds back a second step")
    func phaselessCooldown() {
        var rig = Rig()
        rig.send(.swipe(30, []), at: 0)
        rig.send(.swipe(30, []), at: 0.1)
        #expect(rig.steps.count == 1)
        rig.send(.swipe(30, []), at: 0.1 + ScrollLevelNavigator.cooldown + 0.01)
        #expect(rig.steps.count == 2)
    }
}
