//
//  Journal.swift
//  NTCGSimulator
//
//  The game log shown in the board's Journal panel. Every action the engine
//  accepts writes one line here, so the panel is a faithful record of the game
//  rather than a separate story the UI has to keep in step.
//

import Foundation

// MARK: - Entry

/// One logged line: who acted, and what happened.
struct JournalEntry: Identifiable, Hashable, Codable {

    let id: UUID

    /// Who the line belongs to — a player label, or `Journal.systemActor` for
    /// turn and response-window announcements.
    let actor: String

    /// Sentence-case description of what happened, ending in a full stop.
    let message: String

    let timestamp: Date

    init(id: UUID = UUID(), actor: String, message: String, timestamp: Date = Date()) {
        self.id = id
        self.actor = actor
        self.message = message
        self.timestamp = timestamp
    }

    /// Whether this line came from the engine itself rather than a player.
    var isSystem: Bool { actor == Journal.systemActor }

    /// Flattened form used for sharing and debugging.
    var line: String { "\(actor) — \(message)" }
}

// MARK: - Journal

/// A capped, ordered history of entries, oldest first. It is a collection, so
/// the Journal panel can iterate it directly.
struct Journal: RandomAccessCollection, Hashable, Codable {

    /// Actor label for engine announcements.
    static let systemActor = "Game"

    /// Lines kept before the oldest are dropped. Long games would otherwise
    /// grow the log without bound for a panel that only shows the tail.
    static let defaultLimit = 250

    private(set) var entries: [JournalEntry] = []

    /// Maximum retained lines.
    var limit: Int

    /// When true, `record` drops every line instead of storing it. The AI's
    /// search sets this on its cloned engines: a 1,600-iteration search
    /// replays thousands of actions, and none of them belong in a log —
    /// muting also skips the `Date`/`UUID` allocation each line would cost.
    /// Runtime-only, so it is deliberately excluded from coding.
    var isMuted = false

    private enum CodingKeys: String, CodingKey {
        case entries
        case limit
    }

    init(limit: Int = Journal.defaultLimit) {
        self.limit = Swift.max(1, limit)
    }

    // MARK: Collection

    var startIndex: Int { entries.startIndex }
    var endIndex: Int { entries.endIndex }

    subscript(position: Int) -> JournalEntry { entries[position] }

    // MARK: Recording

    /// Appends a line, trimming the oldest once the cap is passed.
    /// - Parameter timestamp: injectable so tests can pin the clock.
    mutating func record(actor: String, message: String, at timestamp: Date = Date()) {
        guard !isMuted else { return }
        entries.append(JournalEntry(actor: actor, message: message, timestamp: timestamp))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    /// Records an engine announcement — turn changes, response windows, results.
    mutating func system(_ message: String, at timestamp: Date = Date()) {
        record(actor: Journal.systemActor, message: message, at: timestamp)
    }

    mutating func clear() {
        entries.removeAll()
    }

    // MARK: Reading

    /// The most recent line, for the board's single-line status strip.
    var latest: JournalEntry? { entries.last }

    /// The last `count` lines, newest last.
    func tail(_ count: Int) -> [JournalEntry] {
        Array(entries.suffix(Swift.max(0, count)))
    }

    /// The whole log as text, for sharing or debugging.
    var transcript: String {
        entries.map(\.line).joined(separator: "\n")
    }
}
