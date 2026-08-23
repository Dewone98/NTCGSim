//
//  SearchBudget.swift
//  NTCGSimulator
//
//  What a search may cost RIGHT NOW, not just what the chosen tier asks for.
//  The tiers in AIDifficulty.swift describe playing strength on an
//  unconstrained device; this file is the governor between that recipe and
//  the phone it actually runs on. Two live conditions scale the work — the
//  OS thermal state and Low Power Mode — and a per-turn ledger shrinks each
//  successive decision inside one turn, so a turn that needs ten decisions
//  can never cost ten full-length searches. The intent, in one line: the
//  player should feel the AI get slightly weaker before they ever feel the
//  phone get warm.
//
//  The resolver itself is a pure function of a `DeviceConditions` value, so
//  tests fabricate any thermal or power situation without touching the OS;
//  the shipping path feeds it the monitor's latest snapshot.
//

import Foundation

// MARK: - Device conditions

/// The two live inputs the budget answers to, snapshotted as a value.
struct DeviceConditions {

    /// The OS's own four-step heat ladder for this process.
    var thermalState: ProcessInfo.ThermalState

    /// Whether the user has asked the whole phone to conserve energy.
    var isLowPowerModeEnabled: Bool

    /// The device's actual conditions, kept fresh by the monitor below.
    static var current: DeviceConditions { DeviceConditionsMonitor.shared.snapshot }
}

// MARK: - Monitor

/// Caches the process's thermal and power state and keeps the cache fresh by
/// observing the OS's change notifications — so a phone that warms up (or
/// enters Low Power Mode) mid-game lands on the AI's very next decision,
/// rather than the launch-time reading standing for the whole session. The
/// cache exists so the per-decision path reads a value under a lock instead
/// of asking the kernel each time; the notifications are what keep that
/// cache honest.
final class DeviceConditionsMonitor: @unchecked Sendable {

    static let shared = DeviceConditionsMonitor()

    /// Both notifications arrive on arbitrary threads, and the AI reads from
    /// its own background queue, so the snapshot is guarded by a lock. The
    /// critical sections are two assignments — contention is not a concern.
    private let lock = NSLock()
    private var conditions: DeviceConditions
    private var observers: [NSObjectProtocol] = []

    private init() {
        let info = ProcessInfo.processInfo
        conditions = DeviceConditions(
            thermalState: info.thermalState,
            isLowPowerModeEnabled: info.isLowPowerModeEnabled
        )

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in self?.refresh() })
        observers.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: nil
        ) { [weak self] _ in self?.refresh() })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Both states are re-read on either notification — one syscall pair per
    /// actual change is nothing, and it keeps the two fields consistent.
    private func refresh() {
        let info = ProcessInfo.processInfo
        let fresh = DeviceConditions(
            thermalState: info.thermalState,
            isLowPowerModeEnabled: info.isLowPowerModeEnabled
        )
        lock.lock()
        conditions = fresh
        lock.unlock()
    }

    var snapshot: DeviceConditions {
        lock.lock()
        defer { lock.unlock() }
        return conditions
    }
}

// MARK: - Search budget

/// Resolves a difficulty tier into the search parameters the device can
/// afford right now. `nil` means "no search at all — play greedy", which is
/// both genin's normal answer and every tier's answer under critical
/// thermals.
enum SearchBudget {

    // MARK: Tuning

    /// The governor's knobs, named and documented in one place so the whole
    /// thermal policy reads off a single table.
    enum Tuning {

        /// Budget multiplier per thermal state, or `nil` for "do not search".
        ///
        /// - `.nominal` is full budget: a cool phone earns the tier as chosen.
        /// - `.fair` halves it. Fair is the first rung — the OS is saying the
        ///   trend is warming, and sustained MCTS is exactly the kind of load
        ///   that feeds that trend, so the cut comes early and hard rather
        ///   than waiting for the fans-and-warnings stages.
        /// - `.serious` quarters it. At serious the OS is already throttling
        ///   clocks; a quarter budget keeps the AI clearly playing (400
        ///   iterations at kage still searches) while shedding most of the
        ///   heat contribution.
        /// - `.critical` searches not at all. The phone is protecting itself;
        ///   the only correct contribution is silence, so the AI falls back
        ///   to the greedy policy until things cool.
        static func thermalFactor(_ state: ProcessInfo.ThermalState) -> Double? {
            switch state {
            case .nominal:  return 1.0
            case .fair:     return 0.5
            case .serious:  return 0.25
            case .critical: return nil
            @unknown default:
                // A rung Apple adds later is by definition not nominal;
                // treat it like the worst still-searching state.
                return 0.25
            }
        }

        /// Low Power Mode multiplier, applied on top of the thermal factor.
        /// 0.4 is chosen so that even a cool phone in Low Power Mode does
        /// well under half the chosen tier's work — the user has explicitly
        /// asked the device to conserve, and the AI is the single hungriest
        /// thing in this app.
        static let lowPowerFactor = 0.4

        /// While Low Power Mode is on, no tier may exceed this many baseline
        /// iterations — jonin's own count, taken from the table so the two
        /// can never drift apart. This is what "never run the top tier on a
        /// conserving phone" means concretely: kage is clamped to jonin's
        /// budget *before* the low-power cut, so a low-power kage always does
        /// strictly less work than a cool jonin. Kage keeps its
        /// perfect-information model — that flag changes what the search
        /// knows, not what it costs, and determinized iterations are in fact
        /// the more expensive kind (each one redeals and reshuffles).
        static let lowPowerIterationCeiling =
            AIDifficulty.jonin.searchParameters?.iterations ?? 900

        /// Geometric decay per additional decision inside one turn. An AI
        /// turn is 4–10 separate searches, so without this the per-decision
        /// budget multiplies into an unbounded per-turn cost. At 0.65 the
        /// whole geometric series sums to under 3× a single full search
        /// (1 / (1 − 0.65) ≈ 2.86), which turns "a long turn burns ten
        /// seconds of core" into "any turn costs about three decisions'
        /// worth, however long it runs".
        static let perDecisionDecay = 0.65

        /// No decayed decision falls below this many iterations (unless the
        /// thermal/power budget is itself already smaller — the floor may
        /// never *raise* a budget above its scaled base). 96 iterations is
        /// still a real search — enough visits to separate an obvious blunder
        /// from a playable line — so late decisions in a long turn get
        /// "sane", not "random".
        static let iterationFloor = 96

        /// The wall-clock cap scales with the same factors, but never below
        /// this. Whichever of the two budgets a given device hits first, a
        /// throttled decision costs at most 0.15s of core time — enough for
        /// the floor's iterations on a quick build, and an honest hard stop
        /// on a slow one, where the search keeps its best answer so far.
        static let timeLimitFloor: TimeInterval = 0.15
    }

    // MARK: Resolution

    /// The tier's parameters as the device can afford them for its
    /// `decisionIndex`-th searched decision of the current turn — or `nil`
    /// for "answer with the greedy policy instead".
    static func resolved(
        for tier: AIDifficulty,
        conditions: DeviceConditions = .current,
        decisionIndex: Int = 0
    ) -> GameSearch.Parameters? {
        guard var parameters = tier.searchParameters else { return nil }
        guard let thermal = Tuning.thermalFactor(conditions.thermalState) else { return nil }

        var ceiling = parameters.iterations
        var factor = thermal
        if conditions.isLowPowerModeEnabled {
            ceiling = Swift.min(ceiling, Tuning.lowPowerIterationCeiling)
            factor *= Tuning.lowPowerFactor
        }

        // The per-decision base after device conditions, then the in-turn
        // decay, then the floor — clamped so the floor can only ever soften
        // the decay, never undo the thermal or power cut.
        let decay = pow(Tuning.perDecisionDecay, Double(Swift.max(0, decisionIndex)))
        let base = Double(ceiling) * factor
        let decayed = base * decay
        let floor = Swift.min(Double(Tuning.iterationFloor), base)
        parameters.iterations = Swift.max(Int(Swift.max(decayed, floor).rounded()), 1)

        parameters.timeLimit = Swift.max(
            parameters.timeLimit * factor * decay,
            Swift.min(Tuning.timeLimitFloor, parameters.timeLimit)
        )
        return parameters
    }

    // MARK: - Turn ledger

    /// Counts the AI's searched decisions within the current turn, so the
    /// resolver's decay has an index to work from. Keyed by game seed and
    /// turn number: a new turn — or a new game — starts the count over. The
    /// state is a single small tuple behind a lock because decisions are
    /// requested from an async context.
    final class TurnLedger: @unchecked Sendable {

        static let shared = TurnLedger()

        private let lock = NSLock()
        private var gameSeed: UInt64?
        private var turn = 0
        private var decisions = 0

        /// The 0-based index of the decision being asked for, and one more
        /// on the count. Any change of game or turn resets to zero — the
        /// budget is per-turn by design, so a fresh turn always earns a
        /// fresh full budget.
        func nextDecisionIndex(gameSeed: UInt64, turn: Int) -> Int {
            lock.lock()
            defer { lock.unlock() }
            if self.gameSeed != gameSeed || self.turn != turn {
                self.gameSeed = gameSeed
                self.turn = turn
                decisions = 0
            }
            let index = decisions
            decisions += 1
            return index
        }
    }
}
