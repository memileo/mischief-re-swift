import XCTest
@testable import ArtRenderLibrary

/// Pacing policy for the live view. A manual tick source replaces `CVDisplayLink` and a
/// manual timer replaces `DispatchQueue.asyncAfter`, so every start decision is
/// deterministic (including the cold-link fallback).
final class LiveFramePacingTests: XCTestCase {

    /// Stand-in for the display link: records start/stop and fires ticks on demand.
    private final class ManualTickSource: LiveFrameTickSource {
        var onTick: ((TimeInterval) -> Void)?
        private(set) var isRunning = false
        private(set) var isAvailable = true
        private(set) var startCount = 0
        private(set) var stopCount = 0

        func start() {
            isRunning = true
            startCount += 1
        }

        func stop() {
            guard isRunning else { return }
            isRunning = false
            stopCount += 1
        }

        func fire(at time: TimeInterval) {
            onTick?(time)
        }
    }

    /// Stand-in for the main-queue one-shot timer. `fireNext()` runs the oldest item.
    private final class ManualTimer {
        private var items: [(delay: TimeInterval, work: () -> Void)] = []

        var count: Int { items.count }
        var nextDelay: TimeInterval? { items.first?.delay }

        func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
            items.append((delay, work))
        }

        func fireNext() {
            guard !items.isEmpty else { return }
            let item = items.removeFirst()
            item.work()
        }
    }

    private var now: TimeInterval = 0
    private var starts = 0
    private var ticker: ManualTickSource!
    private var timer: ManualTimer!
    private var pacer: LiveFramePacer!

    override func setUp() {
        super.setUp()
        now = 0
        starts = 0
        ticker = ManualTickSource()
        timer = ManualTimer()
        pacer = makePacer(maxFPS: 60)
    }

    @discardableResult
    private func makePacer(maxFPS: Double) -> LiveFramePacer {
        let pacer = LiveFramePacer(
            maxFPS: maxFPS,
            mode: .displayLink,
            tickSource: ticker,
            now: { [unowned self] in self.now },
            timerScheduler: { [unowned self] delay, work in
                self.timer.schedule(after: delay, work)
            })
        pacer.onStart = { [unowned self] in self.starts += 1 }
        self.pacer = pacer
        return pacer
    }

    /// The first request starts immediately, then a tick proves the link is warm.
    private func warmUp() {
        pacer.request()
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(ticker.isRunning)
        ticker.fire(at: 0)
    }

    // MARK: - Display-link policy

    /// The first request after idle starts at once instead of waiting out a slot that
    /// began before the view existed. The link starts warming in the background.
    func testFirstRequestStartsImmediatelyAndWarmsTheLink() {
        pacer.request()
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(ticker.isRunning)
        XCTAssertEqual(timer.count, 0)
    }

    /// A frame that finishes inside its 60 fps slot waits for the next flip, and several
    /// requests arriving while it waits coalesce into one start.
    func testFastFrameWaitsForNextTickAndCoalesces() {
        warmUp()

        pacer.request()                     // render is in flight: pending
        now = 0.010                         // 10 ms render
        pacer.renderFinished()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(timer.count, 0, "a warm link must not fall back to the timer")

        pacer.request()                     // another request during the wait
        pacer.request()                     // ... newest still wins
        now = 1.0 / 60.0
        ticker.fire(at: now)
        XCTAssertEqual(starts, 2)
    }

    /// A frame slower than its slot starts immediately when it finishes: it has already
    /// missed the refresh it could have caught, so waiting for a flip only loses time.
    func testSlowFrameStartsImmediatelyAfterFinish() {
        warmUp()

        pacer.request()
        now = 0.020                         // 20 ms render, > 16.7 ms slot
        pacer.renderFinished()
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(timer.count, 0)
    }

    /// 60 fps on a 60 Hz panel must start on *consecutive* ticks. Anchoring the slot to the
    /// flip time (rather than to when the main-queue block ran) is what makes that true.
    func testSixtyFpsUsesConsecutiveTicks() {
        warmUp()

        pacer.request()
        now = 0.010
        pacer.renderFinished()

        var tick = 1.0 / 60.0
        ticker.fire(at: tick)
        XCTAssertEqual(starts, 2)

        pacer.request()
        now = tick + 0.010
        pacer.renderFinished()
        tick += 1.0 / 60.0
        ticker.fire(at: tick)
        XCTAssertEqual(starts, 3)
    }

    /// A 30 fps cap skips every other tick.
    func testThirtyFpsSkipsTicksUntilTheSlotElapses() {
        makePacer(maxFPS: 30)
        warmUp()

        pacer.request()
        now = 0.010
        pacer.renderFinished()

        now = 1.0 / 60.0
        ticker.fire(at: now)
        XCTAssertEqual(starts, 1, "16.7 ms is not a 30 fps slot yet")

        now = 2.0 / 60.0
        ticker.fire(at: now)
        XCTAssertEqual(starts, 2)
    }

    /// A cold link (its first tick is still ~40 ms away) falls back to the timer for the
    /// first frames instead of stalling. Once a tick arrives, ticks take over.
    func testColdLinkUsesTheTimerUntilTheFirstTick() {
        pacer.request()                     // starts now, link begins warming
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(ticker.isRunning)

        pacer.request()
        now = 0.010
        pacer.renderFinished()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(timer.count, 1, "cold link must be covered by the timer")
        XCTAssertEqual(timer.nextDelay ?? 0, 1.0 / 60.0 - 0.010, accuracy: 1e-9)

        now = 1.0 / 60.0
        timer.fireNext()
        XCTAssertEqual(starts, 2, "the timer path must not stall waiting for the link")

        // The link is now warm: the next finish waits for a tick instead of a timer.
        pacer.request()
        now = 0.020
        ticker.fire(at: now)                // warming tick, render still in flight
        now = 1.0 / 60.0 + 0.010
        pacer.renderFinished()
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(timer.count, 0)

        now = 2.0 / 60.0
        ticker.fire(at: now)
        XCTAssertEqual(starts, 3)
    }

    /// Uncapped keeps the old behaviour: no display link, start as soon as possible.
    func testUncappedStartsImmediatelyAndNeverTicks() {
        makePacer(maxFPS: 0)

        pacer.request()
        pacer.request()
        now = 0.001
        pacer.renderFinished()

        XCTAssertEqual(starts, 2)
        XCTAssertEqual(ticker.startCount, 0)
        XCTAssertEqual(timer.count, 0)
    }

    /// Going idle stops the link after a grace period so a stationary window costs no
    /// wake-ups, but a pause inside a gesture reuses the warm link.
    func testIdleStopsTheTickSourceAfterTheGracePeriod() {
        warmUp()

        pacer.request()
        now = 0.010
        pacer.renderFinished()              // fast: waits for a tick
        now = 1.0 / 60.0
        ticker.fire(at: now)
        XCTAssertEqual(starts, 2)

        now += 0.010
        pacer.renderFinished()              // nothing pending: arm the idle stop
        XCTAssertTrue(ticker.isRunning)
        XCTAssertEqual(timer.count, 1)
        XCTAssertEqual(timer.nextDelay ?? 0, 2.0, accuracy: 1e-9)

        timer.fireNext()
        XCTAssertFalse(ticker.isRunning)
    }

    /// A request before the idle stop fires cancels it and keeps the link warm.
    func testRequestCancelsTheIdleStop() {
        warmUp()

        pacer.request()
        now = 0.010
        pacer.renderFinished()
        now = 1.0 / 60.0
        ticker.fire(at: now)
        now += 0.010
        pacer.renderFinished()              // idle stop armed
        XCTAssertEqual(timer.count, 1)

        pacer.request()                     // new gesture before the grace expires
        XCTAssertTrue(ticker.isRunning)
        timer.fireNext()                    // the stale stop must be ignored
        XCTAssertTrue(ticker.isRunning)
    }

    /// A tick while a render is in flight is not a second start.
    func testTickDuringRenderIsIgnored() {
        warmUp()

        pacer.request()
        now = 1.0 / 60.0
        ticker.fire(at: now)
        XCTAssertEqual(starts, 1)
    }

    func testInvalidateStopsTicksAndIgnoresRequests() {
        warmUp()

        pacer.request()
        now = 0.010
        pacer.renderFinished()
        XCTAssertTrue(ticker.isRunning)

        pacer.invalidate()
        XCTAssertFalse(ticker.isRunning)

        pacer.request()
        XCTAssertEqual(starts, 1)
    }
}
