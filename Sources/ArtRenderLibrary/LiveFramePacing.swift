//
//  LiveFramePacing.swift
//  ArtRenderLibrary
//
//  Frame-start pacing for the interactive live view, shared by the Quick Look
//  extension and the app's document windows.
//
//  Why a display link
//  ------------------
//  `LiveFrameThrottle` keeps the *rate* right (start-to-start), but a main-queue
//  timer has no relationship to the panel's refresh: its period is nominally the
//  same, so its phase drifts and a frame periodically misses a refresh even
//  though the render fits. Driving the start from the display link removes the
//  drift: a frame that fits is started right after a flip and presented at the
//  next one.
//
//  The link is also only *one* of the modes. `ART_LIVE_PACING=timer` forces the
//  previous timer-based schedule so the two can be compared interactively; a
//  machine without a usable display link (or Linux) falls back to it too.
//
//  Threading
//  ---------
//  Everything in this file is main-thread state. The CVDisplayLink callback runs
//  on its own high-priority thread and only posts a coalesced tick to the main
//  queue, so the pacer and its owner never need locks.
//

import Foundation
import Dispatch

#if os(macOS)
import CoreVideo
import QuartzCore
#endif

// MARK: - Tick source

/// A source of display-refresh ticks. The real implementation is a `CVDisplayLink`;
/// tests use a manual source so the pacing policy can be exercised deterministically.
public protocol LiveFrameTickSource: AnyObject {
    /// Called on the main queue with the time of the flip (seconds, monotonic).
    var onTick: ((TimeInterval) -> Void)? { get set }
    /// Main thread only.
    var isRunning: Bool { get }
    /// False when this source has no display link and the pacer must use a timer.
    var isAvailable: Bool { get }
    func start()
    func stop()
}

#if os(macOS)
/// Drives ticks from `CVDisplayLink`.
///
/// `CVDisplayLink` is deprecated in macOS 15 (the replacement, `NSView.displayLink`,
/// starts at macOS 14), but it is the only option for the macOS 12 deployment target
/// and still works. The callback thread posts one coalesced tick to the main queue:
/// if the main thread is busy, older ticks are dropped rather than queued.
public final class LiveDisplayTickSource: LiveFrameTickSource {
    public var onTick: ((TimeInterval) -> Void)?

    public private(set) var isRunning = false

    /// True when a CVDisplayLink was created. When false the pacer uses its timer path.
    public var isAvailable: Bool { displayLink != nil }

    private var displayLink: CVDisplayLink?

    // Main-thread state, guarded only because the callback thread writes the
    // pending tick before hopping to the main queue.
    private let lock = NSLock()
    private var pendingTickTime: TimeInterval?
    private var pendingTickGeneration: UInt64 = 0
    private var generation: UInt64 = 0
    private var tickQueued = false

    /// - Parameter forceTimer: skip the display link and report unavailable, which is
    ///   how `ART_LIVE_PACING=timer` selects the old pacing path.
    public init(forceTimer: Bool = false) {
        guard !forceTimer else { return }

        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
              let link else { return }

        let result = CVDisplayLinkSetOutputCallback(link, { _, _, outputTime, _, _, context in
            guard let context else { return kCVReturnSuccess }
            let source = Unmanaged<LiveDisplayTickSource>
                .fromOpaque(context)
                .takeUnretainedValue()
            let frequency = CVGetHostClockFrequency()
            let seconds = frequency > 0
                ? Double(outputTime.pointee.hostTime) / frequency
                : LiveFramePacer.currentTime()
            source.displayLinkFired(at: seconds)
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())

        guard result == kCVReturnSuccess else { return }
        self.displayLink = link
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        lock.lock()
        generation &+= 1
        pendingTickTime = nil
        tickQueued = false
        lock.unlock()
        if let displayLink, CVDisplayLinkStart(displayLink) == kCVReturnSuccess {
            return
        }
        // Creation succeeded but starting did not: report unavailable so the pacer
        // can switch to its timer path. (The pacer checks `isAvailable` only at init,
        // so this is a safety net for the next frame; the current one just gets no
        // ticks, which the timer path will cover after `stop`/`start`.)
        isRunning = false
        self.displayLink = nil
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
        lock.lock()
        generation &+= 1
        pendingTickTime = nil
        tickQueued = false
        lock.unlock()
    }

    /// CVDisplayLink thread. Coalesce: only the newest tick survives a busy main queue.
    fileprivate func displayLinkFired(at time: TimeInterval) {
        lock.lock()
        pendingTickTime = time
        pendingTickGeneration = generation
        if tickQueued {
            lock.unlock()
            return
        }
        tickQueued = true
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let time = self.pendingTickTime
            let tickGeneration = self.pendingTickGeneration
            let currentGeneration = self.generation
            self.pendingTickTime = nil
            self.tickQueued = false
            self.lock.unlock()
            // A tick posted before the latest start/stop belongs to the previous run:
            // delivering it would make the pacer believe a cold link is warm.
            guard self.isRunning, tickGeneration == currentGeneration, let time else { return }
            self.onTick?(time)
        }
    }

    deinit {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }
}
#else
/// Linux / non-macOS placeholder: no display link, so the pacer uses its timer path.
public final class LiveDisplayTickSource: LiveFrameTickSource {
    public var onTick: ((TimeInterval) -> Void)?
    public private(set) var isRunning = false
    public var isAvailable: Bool { false }

    public init(forceTimer: Bool = false) {}

    public func start() {}
    public func stop() {}
}
#endif

// MARK: - Pacer

/// How the live view decides when a pending request may start.
public enum LiveFramePacingMode: String {
    /// Start on display-refresh ticks (the default).
    case displayLink
    /// Start on a main-queue timer, the pre-display-link behaviour.
    case timer
}

/// Decides when the next live frame may start.
///
/// The owner records a request (newest wins) and calls `request()`. The pacer either
/// starts it immediately or waits for the next display tick; when a render finishes,
/// `renderFinished()` starts a pending request or goes idle.
///
/// Three details keep the cadence right:
///
/// * **A frame that fits waits for the next flip.** At 60 fps on a 60 Hz panel the next
///   tick is exactly one slot later, so starts are phase-locked to the panel instead of
///   drifting. The slot is anchored to the **flip time** (the tick's `inOutputTime`), not
///   to when the main-queue block ran; a 1 ms tolerance covers a tick that lands a hair
///   early. Without that, the 60 fps cap periodically skipped a tick and halved to 30 fps.
/// * **A frame that does not fit starts immediately.** Once the slot has elapsed, the
///   frame has already missed the refresh it could have caught; starting on finish is
///   never worse than adding another wait, and it keeps slow documents (robotcrab layer 2
///   is ~57 ms at zoom 3) at render throughput instead of quantising them to the next
///   refresh. Only frames that finish inside their slot wait.
/// * **A cold display link does not stall the first frames.** `CVDisplayLinkStart` takes
///   ~40 ms to deliver its first tick on macOS. The pacer therefore starts the link in the
///   background and runs the old one-shot timer until the first tick proves the link is
///   warm; from then on it switches to tick-driven starts. The link is stopped after a
///   short idle grace so a stationary window does not keep waking the main queue; the next
///   gesture starts on the timer again while the link warms.
public final class LiveFramePacer {
    /// Main-thread monotonic time on the same timebase as the display link.
    public static func currentTime() -> TimeInterval {
#if os(macOS)
        return CACurrentMediaTime()
#else
        return TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
#endif
    }

    /// Called on the main thread when the owner should start the pending request.
    public var onStart: (() -> Void)?

    private let throttle: LiveFrameThrottle
    private var mode: LiveFramePacingMode
    private let ticker: LiveFrameTickSource
    private let now: () -> TimeInterval
    private let timerScheduler: (TimeInterval, @escaping () -> Void) -> Void

    private var pending = false
    private var rendering = false
    private var lastStarted: TimeInterval
    private var invalidated = false

    /// The link has delivered at least one tick since it was last started. Until then the
    /// one-shot timer covers starts; a stopped link is no longer warm.
    private var tickerWarm = false
    private var timerScheduled = false
    /// Generation counter for the idle stop: a newer request invalidates older work.
    private var idleGeneration = 0

    /// Ticks arrive at the flip time; allow this much slack when comparing against the
    /// slot so 16.667 ms is not rounded just short of 16.667 ms.
    private static let tickTolerance: TimeInterval = 0.001
    /// Keep the warm link around briefly so a pause inside a gesture does not pay the
    /// display link's startup cost again.
    private static let idleGrace: TimeInterval = 2.0

    public convenience init(maxFPS: Double,
                            mode requestedMode: LiveFramePacingMode? = nil,
                            tickSource: LiveFrameTickSource? = nil,
                            now: @escaping () -> TimeInterval = LiveFramePacer.currentTime) {
        self.init(maxFPS: maxFPS, mode: requestedMode, tickSource: tickSource, now: now,
                  timerScheduler: { delay, work in
                      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                  })
    }

    /// Designated initialiser with an injectable timer, so tests can drive both the
    /// display-link and the timer path without sleeping.
    init(maxFPS: Double,
         mode requestedMode: LiveFramePacingMode?,
         tickSource: LiveFrameTickSource?,
         now: @escaping () -> TimeInterval,
         timerScheduler: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.throttle = LiveFrameThrottle(maxFPS: maxFPS)
        self.now = now
        self.timerScheduler = timerScheduler

        let source = tickSource ?? LiveDisplayTickSource(
            forceTimer: requestedMode == .timer
                || ProcessInfo.processInfo.environment["ART_LIVE_PACING"] == "timer")
        self.ticker = source

        let requested = requestedMode ?? Self.environmentMode()
        // A requested display-link mode still falls back to the timer when this machine
        // (or platform) has no usable link.
        self.mode = (requested == .displayLink && source.isAvailable) ? .displayLink : .timer

        // The first request starts immediately rather than waiting out a slot that
        // began before the view existed.
        self.lastStarted = now() - (self.throttle.isUncapped ? 0 : self.throttle.interval)

        source.onTick = { [weak self] time in self?.tick(at: time) }
    }

    /// `ART_LIVE_PACING=timer` selects the old timer path for an interactive A/B.
    private static func environmentMode() -> LiveFramePacingMode {
        ProcessInfo.processInfo.environment["ART_LIVE_PACING"] == "timer" ? .timer : .displayLink
    }

    // MARK: Owner API (main thread)

    /// A new request is pending. The owner has already stored it (newest wins).
    public func request() {
        guard !invalidated else { return }
        cancelIdleStop()
        pending = true

        // Warm the link even when this request starts immediately: the next frame is the
        // one that would otherwise pay the startup cost.
        if mode == .displayLink, !throttle.isUncapped {
            _ = startTicker()
        }
        guard !rendering else { return }
        schedule()
    }

    /// The current render has finished (or failed) and the next one may start.
    public func renderFinished() {
        guard !invalidated else { return }
        rendering = false
        guard pending else {
            scheduleIdleStop()
            return
        }
        schedule()
    }

    /// The view is going away: stop all timers/ticks and ignore future requests.
    public func invalidate() {
        invalidated = true
        pending = false
        rendering = false
        timerScheduled = false
        cancelIdleStop()
        stopTicker()
    }

    // MARK: Scheduling

    private func schedule() {
        guard pending, !rendering, !invalidated else { return }
        let t = now()

        // Uncapped keeps the old "as fast as the renderer allows" behaviour.
        if throttle.isUncapped {
            start(at: t)
            return
        }

        if mode == .displayLink {
            _ = startTicker()
        }

        if mode == .displayLink, tickerWarm {
            // If the slot has already elapsed, start now: waiting for a flip would only
            // add latency to a frame that has already missed one. Otherwise the next tick
            // starts it.
            let wait = throttle.waitTime(now: t + Self.tickTolerance,
                                         lastStarted: lastStarted)
            if wait <= 0 {
                start(at: t)
            }
            return
        }

        // No link, or still warming: the pre-display-link one-shot timer. This is what
        // keeps the first frames after a cold start from stalling for ~40 ms.
        scheduleTimer(now: t)
    }

    /// One-shot timer for the timer mode and for a display link that is still warming.
    private func scheduleTimer(now t: TimeInterval) {
        let wait = throttle.waitTime(now: t, lastStarted: lastStarted)
        if wait <= 0 {
            start(at: t)
            return
        }
        guard !timerScheduled else { return }
        timerScheduled = true
        timerScheduler(wait) { [weak self] in
            guard let self else { return }
            self.timerScheduled = false
            guard !self.invalidated, self.pending, !self.rendering else { return }
            self.schedule()
        }
    }

    /// Display-link tick (main thread). The timestamp is the flip time.
    private func tick(at time: TimeInterval) {
        guard !invalidated else {
            stopTicker()
            return
        }
        tickerWarm = true

        // A tick during a render is not a start opportunity: exactly one render is in
        // flight. Keep ticking so the frame after it can align.
        guard !rendering else { return }
        guard pending else { return }
        let wait = throttle.waitTime(now: time + Self.tickTolerance,
                                     lastStarted: lastStarted)
        guard wait <= 0 else { return }
        // Anchor the next slot to the flip, not to whenever this block ran.
        start(at: time)
    }

    private func start(at time: TimeInterval) {
        guard pending, !rendering, !invalidated else { return }
        pending = false
        rendering = true
        lastStarted = time
        onStart?()
    }

    @discardableResult
    private func startTicker() -> Bool {
        guard mode == .displayLink else { return false }
        if !ticker.isRunning {
            guard ticker.isAvailable else {
                mode = .timer
                return false
            }
            tickerWarm = false
            ticker.start()
            guard ticker.isRunning else {
                // Creation succeeded but starting did not (display asleep, host
                // limitation, ...). Fall back to the timer instead of stalling.
                mode = .timer
                return false
            }
        }
        return true
    }

    private func stopTicker() {
        cancelIdleStop()
        tickerWarm = false
        guard ticker.isRunning else { return }
        ticker.stop()
    }

    private func scheduleIdleStop() {
        guard ticker.isRunning else { return }
        idleGeneration += 1
        let generation = idleGeneration
        timerScheduler(Self.idleGrace) { [weak self] in
            guard let self, generation == self.idleGeneration else { return }
            guard !self.pending, !self.rendering, !self.invalidated else { return }
            self.stopTicker()
        }
    }

    private func cancelIdleStop() {
        idleGeneration += 1
    }
}
