import Foundation

/// What `ConsentStorage` persists: the host's snapshot exactly as it arrived (after
/// stamping), plus the newest host-supplied timestamp seen since the last clear.
///
/// The RAW snapshot is stored, never the reconciled view. Reconciliation is a
/// projection onto whatever registry is current, and persisting a projection loses
/// information: a build that registers fewer categories would silently delete the
/// user's decision for the ones it dropped, and a later build that registers them
/// again would read back a default the user never chose. Keeping the source of truth
/// raw means every registration recomputes the view losslessly.
///
/// `lastHostTimestamp` is the stale-snapshot watermark. Only two host-supplied
/// timestamps are comparable (same clock, same unit), so it is a high-water mark of
/// host timestamps alone — an untimestamped set carries it forward untouched rather
/// than resetting it, otherwise a host re-pushing the same decision without a
/// timestamp would let an older CMP replay overwrite a newer explicit choice.
internal struct StoredConsent: Codable, Equatable, Sendable {
    var consent: Consent
    var lastHostTimestamp: Int64?
}

/// Owns the consent state machine: the category registry, the current reconciled
/// view, persistence, and change subscriptions. The public API delegates here;
/// payload-attach reads `getConsent()` at enrichment time.
///
/// A lock-based class rather than an actor, on purpose. `setConsent` must be
/// read-your-writes synchronous: a host that calls `setConsent` and then `track` on
/// the next line expects the enrichment of that event to see the new state, and an
/// actor hop would let it read the old one. The same lock makes `getConsent()` a
/// plain synchronous call, which is what a CMP integration expects from a "what is
/// consent right now" read.
///
/// Subscriber callbacks are *enqueued* on `dispatch` while the lock is held and, with
/// the production main-queue dispatch, run later off the lock. Enqueuing inside the
/// lock is what makes delivery order equal commit order — enqueuing outside it let
/// a preempted thread deliver an older state after a newer one, leaving a subscriber
/// settled on consent the user had already changed. `dispatch` must deliver on the
/// main thread (handlers are `@MainActor`; delivering elsewhere traps at runtime)
/// and must be asynchronous: an inline dispatcher runs the handler under the lock,
/// where a handler that calls back into the manager deadlocks. Debug builds trap a
/// dispatcher that runs work before returning on the enqueuing thread; a
/// synchronous hop to another thread is not caught.
///
/// Persistence happens AFTER the lock is released. `UserDefaults` writes post
/// `didChangeNotification` and fire KVO synchronously on the calling thread, so a
/// host observer that reads consent back would re-enter the (non-recursive) lock
/// and hang. A commit sequence number keeps disk writes in commit order.
internal final class ConsentManager: @unchecked Sendable {

    /// Debug-only fail-fast for misconfigured registrations, injectable: assertions
    /// are active in test builds too, so tests exercising the release-degrade path
    /// swap this to observe instead of trap.
    internal nonisolated(unsafe) static var debugAssert: @Sendable (String) -> Void = {
        assertionFailure($0)
    }

    /// One subscription. `cancel()` is checked again at delivery time: unsubscribing
    /// must also drop deliveries that were already enqueued but have not run yet —
    /// a host that unsubscribes in `deinit` or `viewWillDisappear` must not get one
    /// more callback on the next run-loop turn into an object it considers gone.
    private final class Subscription: @unchecked Sendable {
        private let lock = NSLock()
        /// nil once cancelled, so a retained unsubscribe closure does not keep the
        /// handler's captures alive for the life of the process-wide manager.
        private var handler: ConsentHandler?

        init(handler: @escaping ConsentHandler) { self.handler = handler }

        /// The handler if still subscribed. Read under the subscription lock, invoked
        /// outside it, so a handler that unsubscribes itself cannot deadlock.
        var activeHandler: ConsentHandler? { lock.withLock { handler } }
        func cancel() { lock.withLock { handler = nil } }
    }

    #if DEBUG
    /// Traps a `dispatch` that runs work before returning, on the enqueuing thread:
    /// that work runs under the manager lock, where a re-entering handler deadlocks.
    private final class InlineDispatchCheck: @unchecked Sendable {
        private let lock = NSLock()
        private let thread = Thread.current
        private var returned = false

        func markReturned() { lock.withLock { returned = true } }
        func assertNotInline() {
            let inline = Thread.current == thread && !lock.withLock { returned }
            precondition(!inline, "ConsentManager dispatch ran a handler inline under the manager lock; it must be asynchronous")
        }
    }
    #endif

    private let lock = NSLock()
    private var storage: ConsentStorage
    private let clockMillis: @Sendable () -> Int64
    private let dispatch: @Sendable (@escaping @Sendable () -> Void) -> Void

    private var registry: [ConsentCategory] = []
    // Recomputed only when the registry changes: getConsent() sits on the per-event
    // enrichment path, and rebuilding the default map per event is avoidable work.
    private var implicitDefault: Consent = ConsentReconciler.implicitDefault(for: [])
    /// nil = the host has never set consent (or cleared it).
    private var stored: StoredConsent?
    /// `stored` projected onto `registry`; recomputed on every set and registration.
    private var reconciled: Consent?
    private var subscribers: [Subscription] = []
    private var warnedEmptyRegistry = false

    /// Commit ordering for off-lock persistence. Recursive: a persist can re-enter
    /// `setConsent` through a host's UserDefaults observer, and that nested commit
    /// must be able to persist too (it carries a higher sequence, so it wins).
    private var commitSequence: UInt64 = 0
    private let persistLock = NSRecursiveLock()
    private var persistedSequence: UInt64 = 0

    /// - Parameters:
    ///   - clockMillis: stamps a `setConsent` that arrives without a timestamp.
    ///   - dispatch: where subscriber callbacks run. Main queue by default, like
    ///     every UI-adjacent listener API on the platform. Tests may inject a
    ///     recorder, but must drain it on the main thread.
    init(
        storage: ConsentStorage,
        clockMillis: @escaping @Sendable () -> Int64 = WallClock.epochMillis,
        dispatch: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    ) {
        self.storage = storage
        self.clockMillis = clockMillis
        #if DEBUG
        self.dispatch = { work in
            let check = InlineDispatchCheck()
            dispatch { check.assertNotInline(); work() }
            check.markReturned()
        }
        #else
        self.dispatch = dispatch
        #endif
        // Loaded eagerly: the manager is built once per process alongside the
        // identity read from the same UserDefaults, and a consent persisted by a
        // prior launch must be visible to the very first read.
        self.stored = storage.get()
        self.reconciled = stored.map { ConsentReconciler.reconcile($0.consent, against: []) }
    }

    /// What readers currently see. Caller holds `lock`.
    private func visibleLocked() -> Consent {
        return reconciled ?? implicitDefault
    }

    // MARK: - Registry

    /// Replaces (not merges) the registered category set and recomputes the view of
    /// any stored consent against it.
    ///
    /// Recomputing is what keeps the block complete across app updates: a snapshot
    /// stored by a build that registered three categories would otherwise reach the
    /// server missing the fourth one this build added — and a missing key is not
    /// read as blocked downstream. The stored decision is preserved for every
    /// category it covers (storage holds the raw snapshot, so a category dropped by
    /// one build and re-added by the next comes back with the user's value); only
    /// categories the snapshot never mentioned take their registered default.
    ///
    /// Misconfigured input degrades instead of trapping in release — a registration
    /// typo must not take the host down: keys are trimmed and lowercased (incoming
    /// optOut keys are canonicalized the same way before matching), blank keys are dropped,
    /// and duplicates keep their first occurrence. Each case asserts in debug.
    func registerConsentCategories(_ categories: [ConsentCategory]) {
        let normalized = Self.normalize(categories)

        lock.lock()
        defer { lock.unlock() }
        let before = visibleLocked()
        registry = normalized
        implicitDefault = ConsentReconciler.implicitDefault(for: normalized)
        reconciled = stored.map { ConsentReconciler.reconcile($0.consent, against: normalized) }
        notifyIfChangedLocked(from: before)
    }

    private static func normalize(_ categories: [ConsentCategory]) -> [ConsentCategory] {
        var seen = Set<String>()
        var result: [ConsentCategory] = []
        result.reserveCapacity(categories.count)
        for category in categories {
            let key = ConsentKey.canonical(category.key)
            if key.isEmpty {
                let message = "registerConsentCategories: blank category key dropped"
                Logger.warn(message)
                debugAssert(message)
                continue
            }
            if key != category.key {
                let message = "registerConsentCategories: key \"\(category.key)\" normalized to \"\(key)\" — optOut keys are lowercase and matched exactly"
                Logger.warn(message)
                debugAssert(message)
            }
            if !seen.insert(key).inserted {
                let message = "registerConsentCategories: duplicate key \"\(key)\" — keeping the first occurrence"
                Logger.warn(message)
                debugAssert(message)
                continue
            }
            result.append(ConsentCategory(key: key, defaultOptOut: category.defaultOptOut))
        }
        return result
    }

    // MARK: - State

    /// Current consent. Never nil: before the first `setConsent` (and after
    /// `clearConsent`) this is the implicit default — `explicit: false`, registered
    /// categories at their defaults — so payload-attach always has a complete block.
    func getConsent() -> Consent {
        lock.lock()
        defer { lock.unlock() }
        return visibleLocked()
    }

    /// Reconciles, stores, persists, and notifies. Fully replaces prior state.
    ///
    /// - Returns: `false` when the update was ignored as stale: it carries a
    ///   host-supplied timestamp older than the newest host-supplied timestamp seen
    ///   since the last `clearConsent`. A CMP replaying a cached choice must not
    ///   overwrite the fresher one the user just made.
    ///
    /// Two timestamps are only comparable when the same party stamped them. The
    /// SDK's stamp is the device wall clock — which the host's CMP server time can
    /// trail by minutes, and which jumps backwards on its own (NTP, a user resetting
    /// the date). Comparing across those clocks rejected real choices: a banner
    /// callback carrying server time lost to an untimestamped regional default
    /// stamped moments earlier by a fast device clock. So an untimestamped call is
    /// always applied as the user's choice as of now and stamped with the device
    /// clock (informational only — `getConsent().timestamp` is not monotonic), and a
    /// host-timestamped call is checked only against the host watermark, which an
    /// untimestamped call carries forward rather than resets. `clearConsent` resets
    /// the watermark: a withdrawal starts arbitration over.
    ///
    /// A host timestamp past this is not epoch milliseconds — micro- or nanoseconds
    /// (~1.7e15+) — and would reject every later real timestamp until the next
    /// `clearConsent`; it is applied as untimestamped instead. A fixed date, not the
    /// device clock, which this rule deliberately never consults. Seconds are not
    /// caught: a host that sends one millisecond timestamp and then seconds has every
    /// seconds call rejected until it clears. Use one unit.
    static let maxPlausibleHostTimestamp: Int64 = 4_102_444_800_000   // 2100-01-01 in ms

    @discardableResult
    func setConsent(_ consent: Consent) -> Bool {
        var consent = consent
        if let hostTimestamp = consent.timestamp, hostTimestamp > Self.maxPlausibleHostTimestamp {
            // Warn only, no debug assertion: the timestamp usually comes from the
            // CMP SDK, and vendor data must not crash the host's debug build.
            Logger.warn("setConsent: timestamp \(hostTimestamp) is not epoch milliseconds — applied as untimestamped")
            consent = Consent(explicit: consent.explicit, optOut: consent.optOut)
        }

        lock.lock()
        let watermark = stored?.lastHostTimestamp
        let incoming: StoredConsent
        if let hostTimestamp = consent.timestamp {
            if let watermark, hostTimestamp < watermark {
                lock.unlock()
                Logger.warn("setConsent ignored: snapshot (\(hostTimestamp)) is older than the newest host-timestamped state (\(watermark))")
                return false
            }
            incoming = StoredConsent(consent: consent, lastHostTimestamp: hostTimestamp)
        } else {
            incoming = StoredConsent(
                consent: Consent(explicit: consent.explicit, optOut: consent.optOut, timestamp: clockMillis()),
                lastHostTimestamp: watermark
            )
        }

        var warnEmptyRegistry = false
        if registry.isEmpty && !warnedEmptyRegistry {
            // Once per process: the story asks for a warning on this path, and a host
            // that never registers would otherwise log on every CMP callback.
            warnedEmptyRegistry = true
            warnEmptyRegistry = true
        }
        let pending = commitLocked(incoming)
        lock.unlock()

        if warnEmptyRegistry {
            Logger.warn("setConsent called before registerConsentCategories — optOut stored as-is with no reconciliation. Register categories before initialize.")
        }
        persist(pending)
        return true
    }

    /// Wipes memory and persistence, watermark included, returning to the implicit
    /// default. Distinct from `reset()`, which clears identity and deliberately leaves
    /// consent alone.
    ///
    /// The watermark goes too. Keeping it rejected the CMP re-pushing its cached
    /// choice after a logout clear, and with an opt-in-default category that left a
    /// user who rejected everything opted in. A host that re-pushes a snapshot from
    /// before the clear gets that snapshot applied.
    func clearConsent() {
        lock.lock()
        let pending = commitLocked(nil)
        lock.unlock()
        persist(pending)
    }

    private struct PendingPersist {
        let sequence: UInt64
        let value: StoredConsent?
    }

    /// The one write path for stored state. Caller holds `lock` and must hand the
    /// returned value to `persist` after releasing it.
    private func commitLocked(_ newStored: StoredConsent?) -> PendingPersist {
        let before = visibleLocked()
        stored = newStored
        reconciled = newStored.map { ConsentReconciler.reconcile($0.consent, against: registry) }
        commitSequence += 1
        notifyIfChangedLocked(from: before)
        return PendingPersist(sequence: commitSequence, value: newStored)
    }

    /// Writes a commit to storage unless a later commit already has. Two threads can
    /// leave the manager lock in the opposite order from their commits; the sequence
    /// check keeps disk from ending on an older state than memory.
    private func persist(_ pending: PendingPersist) {
        persistLock.lock()
        defer { persistLock.unlock() }
        guard pending.sequence > persistedSequence else { return }
        persistedSequence = pending.sequence
        if let value = pending.value {
            storage.set(value)
        } else {
            storage.clear()
        }
    }

    // MARK: - Subscriptions

    /// Registers a change handler and immediately emits the current value — a late
    /// subscriber must not have to guess whether consent already arrived. Then fires
    /// on every real change, never on a value-identical `setConsent`.
    ///
    /// Registration, snapshot, and enqueue happen under the same lock as commits:
    /// otherwise a concurrent `setConsent` (which already sees the new subscriber)
    /// could enqueue the new value before this initial emission, delivering
    /// new-then-old and leaving the subscriber on stale state.
    ///
    /// - Returns: an unsubscribe closure; idempotent. Called from the main actor, it
    ///   guarantees the handler is not invoked again, including for deliveries that
    ///   were already enqueued (they are cancelled at delivery time). Called from
    ///   another thread it can race one in-flight delivery, so a handler capturing
    ///   `unowned` state should unsubscribe on the main actor.
    func subscribe(_ handler: @escaping ConsentHandler) -> ConsentUnsubscribe {
        let subscription = Subscription(handler: handler)
        lock.lock()
        subscribers.append(subscription)
        deliverLocked(visibleLocked(), to: subscription)
        lock.unlock()
        return { [weak self] in
            subscription.cancel()
            guard let self else { return }
            self.lock.lock()
            self.subscribers.removeAll { $0 === subscription }
            self.lock.unlock()
        }
    }

    /// Caller holds `lock`. Compares against what readers could see before the
    /// commit: a set that changes nothing visible — same values, fresher clock, or a
    /// first set equal to the implicit default — must not fire. Handlers react to
    /// decisions, not clocks.
    private func notifyIfChangedLocked(from before: Consent) {
        let after = visibleLocked()
        guard !after.sameDecision(as: before) else { return }
        for subscription in subscribers {
            deliverLocked(after, to: subscription)
        }
    }

    /// Caller holds `lock`. Only enqueues — with the production (asynchronous)
    /// dispatch the handler runs later off the lock, so a slow or re-entrant handler
    /// cannot stall a commit or deadlock.
    private func deliverLocked(_ consent: Consent, to subscription: Subscription) {
        dispatch {
            guard let handler = subscription.activeHandler else { return }
            MainActor.assumeIsolated {
                handler(consent)
            }
        }
    }

    // MARK: - Test seam

    /// Swaps the backing storage and rebuilds state from it, dropping registry and
    /// subscribers. For tests that must exercise the process-wide manager behind
    /// `MetaRouter` without touching `UserDefaults.standard`.
    func _replaceStorageForTesting(_ newStorage: ConsentStorage) {
        let loaded = newStorage.get()
        persistLock.lock()
        lock.lock()
        for subscription in subscribers { subscription.cancel() }
        subscribers.removeAll()
        storage = newStorage
        registry = []
        implicitDefault = ConsentReconciler.implicitDefault(for: [])
        stored = loaded
        reconciled = loaded.map { ConsentReconciler.reconcile($0.consent, against: []) }
        warnedEmptyRegistry = false
        commitSequence = 0
        persistedSequence = 0
        lock.unlock()
        persistLock.unlock()
    }
}
