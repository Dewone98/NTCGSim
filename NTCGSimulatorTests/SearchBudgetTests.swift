//
//  SearchBudgetTests.swift
//  NTCGSimulatorTests
//
//  Pins the thermal governor's contract: the search budget only ever shrinks
//  as the device's conditions worsen, critical thermals mean no search at
//  all, Low Power Mode both cuts the budget and bars the top tier's full
//  appetite, and the per-turn decay actually binds — a turn of many
//  decisions costs a few searches' worth, never many. Conditions are
//  fabricated values, not the test machine's real state, so every run
//  replays exactly whatever the CI box's thermals are doing.
//

import Testing
import Foundation
@testable import NTCGSimulator

// MARK: - Helpers

private func conditions(
    _ thermal: ProcessInfo.ThermalState,
    lowPower: Bool = false
) -> DeviceConditions {
    DeviceConditions(thermalState: thermal, isLowPowerModeEnabled: lowPower)
}

/// The searching tiers — genin has no budget to govern.
private let searchingTiers: [AIDifficulty] = [.chunin, .jonin, .kage]

// MARK: - Tests

@Suite("Search budget")
struct SearchBudgetTests {

    @Test("The budget shrinks monotonically as the thermal state worsens", arguments: searchingTiers)
    func thermalMonotonicity(tier: AIDifficulty) throws {
        let nominal = try #require(SearchBudget.resolved(for: tier, conditions: conditions(.nominal), decisionIndex: 0))
        let fair = try #require(SearchBudget.resolved(for: tier, conditions: conditions(.fair), decisionIndex: 0))
        let serious = try #require(SearchBudget.resolved(for: tier, conditions: conditions(.serious), decisionIndex: 0))

        #expect(nominal.iterations > fair.iterations)
        #expect(fair.iterations > serious.iterations)
        #expect(nominal.timeLimit >= fair.timeLimit)
        #expect(fair.timeLimit >= serious.timeLimit)

        // A cool device gets exactly the tier as chosen — the governor must
        // never tax a phone that is not warm.
        let baseline = try #require(tier.searchParameters)
        #expect(nominal.iterations == baseline.iterations)
        #expect(nominal.determinized == baseline.determinized)
    }

    @Test("Critical thermals mean no search at all", arguments: AIDifficulty.allCases)
    func criticalYieldsNoSearch(tier: AIDifficulty) {
        #expect(SearchBudget.resolved(for: tier, conditions: conditions(.critical), decisionIndex: 0) == nil)
    }

    @Test("Genin never searches, whatever the device is doing")
    func geninStaysGreedy() {
        for thermal: ProcessInfo.ThermalState in [.nominal, .fair, .serious, .critical] {
            #expect(SearchBudget.resolved(for: .genin, conditions: conditions(thermal), decisionIndex: 0) == nil)
            #expect(SearchBudget.resolved(for: .genin, conditions: conditions(thermal, lowPower: true), decisionIndex: 0) == nil)
        }
    }

    @Test("Low Power Mode cuts every searching tier's budget", arguments: searchingTiers)
    func lowPowerModeCuts(tier: AIDifficulty) throws {
        let normal = try #require(SearchBudget.resolved(for: tier, conditions: conditions(.nominal), decisionIndex: 0))
        let conserving = try #require(SearchBudget.resolved(for: tier, conditions: conditions(.nominal, lowPower: true), decisionIndex: 0))
        #expect(conserving.iterations < normal.iterations)
    }

    @Test("Low Power Mode bars the top tier: a conserving kage works less than a cool jonin")
    func lowPowerModeBarsKage() throws {
        let conservingKage = try #require(
            SearchBudget.resolved(for: .kage, conditions: conditions(.nominal, lowPower: true), decisionIndex: 0)
        )
        let joninBaseline = try #require(AIDifficulty.jonin.searchParameters)
        #expect(conservingKage.iterations < joninBaseline.iterations)
    }

    @Test("Later decisions in one turn get geometrically smaller budgets, down to a steady floor")
    func perTurnDecayBinds() throws {
        var previous = Int.max
        var floorValue: Int?
        for index in 0..<12 {
            let resolved = try #require(
                SearchBudget.resolved(for: .kage, conditions: conditions(.nominal), decisionIndex: index)
            )
            #expect(resolved.iterations <= previous, "Decision \(index) grew its budget.")
            #expect(resolved.iterations > 0)
            #expect(resolved.timeLimit > 0)

            if resolved.iterations == previous {
                // Once flat we must be at the floor, and stay there.
                if let floorValue {
                    #expect(resolved.iterations == floorValue)
                } else {
                    floorValue = resolved.iterations
                }
            }
            previous = resolved.iterations
        }
        // The decay must actually have run down to its floor within a
        // realistic turn's worth of decisions, and the floor must still be
        // a real search — sane play, not noise.
        let floor = try #require(floorValue)
        #expect(floor == SearchBudget.Tuning.iterationFloor)
    }

    @Test("A ten-decision turn costs a few searches' worth, not ten")
    func perTurnCumulativeCapBinds() throws {
        let baseline = try #require(AIDifficulty.kage.searchParameters).iterations
        var cumulative = 0
        for index in 0..<10 {
            let resolved = try #require(
                SearchBudget.resolved(for: .kage, conditions: conditions(.nominal), decisionIndex: index)
            )
            cumulative += resolved.iterations
        }
        // Unbounded, ten decisions would be 10× the baseline. The geometric
        // series plus the floor tail must land under 4× — that is the whole
        // point of the per-turn budget.
        #expect(cumulative < baseline * 4,
                "Ten decisions cost \(cumulative) iterations against a \(baseline) baseline.")
        #expect(cumulative > baseline, "The first decision alone should exceed one baseline search.")
    }

    @Test("The floor never undoes a thermal cut")
    func floorRespectsThermalCut() throws {
        // Chunin under .serious resolves below the global iteration floor;
        // the floor may soften the in-turn decay but must never lift a
        // budget back above what the thermal state allows.
        let base = try #require(
            SearchBudget.resolved(for: .chunin, conditions: conditions(.serious), decisionIndex: 0)
        ).iterations
        #expect(base < SearchBudget.Tuning.iterationFloor)
        for index in 1..<6 {
            let later = try #require(
                SearchBudget.resolved(for: .chunin, conditions: conditions(.serious), decisionIndex: index)
            ).iterations
            #expect(later <= base, "Decision \(index) rose above the thermal ceiling.")
        }
    }

    @Test("The turn ledger counts within a turn and resets on a new turn or game")
    func turnLedgerCountsAndResets() {
        let ledger = SearchBudget.TurnLedger()

        #expect(ledger.nextDecisionIndex(gameSeed: 7, turn: 3) == 0)
        #expect(ledger.nextDecisionIndex(gameSeed: 7, turn: 3) == 1)
        #expect(ledger.nextDecisionIndex(gameSeed: 7, turn: 3) == 2)

        // A new turn starts the count over…
        #expect(ledger.nextDecisionIndex(gameSeed: 7, turn: 4) == 0)
        #expect(ledger.nextDecisionIndex(gameSeed: 7, turn: 4) == 1)

        // …and so does a new game, even at the same turn number.
        #expect(ledger.nextDecisionIndex(gameSeed: 11, turn: 4) == 0)
    }
}
