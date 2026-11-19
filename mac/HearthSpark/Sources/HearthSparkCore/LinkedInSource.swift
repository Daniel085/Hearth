import Foundation

/// LinkedIn as a Hearth Spark source: the user's own data export, unzipped on the Mac.
///
/// Hearth Spark never signs in to LinkedIn. It reads the export the user downloaded:
/// connections, endorsements, recommendations, invitations and their own job history,
/// and turns them into reasons like "Recommended you" or "Colleague at Fabrikam".
/// From invitations it uses only *whether* a note was written, never the note itself.
///
/// Like every other source, it only adds to people already in the user's Contacts.
/// Connections who aren't there are left out; Hearth's own LinkedIn import on the
/// iPhone is the place for them.
public enum LinkedInSource {

    public struct Result: Equatable {
        /// Signal per contact card, by index into the cards passed in.
        public var byCard: [Int: LinkedInSuggestion]
        public var connectionCount: Int
    }

    public static func read(folder: URL, cards: [ContactCard], now: Date = Date()) throws -> Result {
        guard let csv = LinkedInExport.find("Connections.csv", in: folder) else {
            throw SourceError.notSetUp("That folder has no Connections.csv. Choose the unzipped LinkedIn export.")
        }
        let connections = try LinkedInConnectionsParser.parse(data: Data(contentsOf: csv))
        let signals = LinkedInSignals.read(fromExportFolder: folder)
        return Result(
            byCard: match(connections, signals: signals, cards: cards, now: now),
            connectionCount: connections.count
        )
    }

    /// Finds each connection's contact card, then scores it.
    ///
    /// By email first. LinkedIn rarely includes one (12 of 860 on a real export), so
    /// mostly by name — and only when exactly one card has that name, because putting
    /// one Sam's recommendation on another Sam is worse than missing it.
    static func match(
        _ connections: [LinkedInConnection],
        signals: LinkedInSignals,
        cards: [ContactCard],
        now: Date
    ) -> [Int: LinkedInSuggestion] {
        var byHandle: [String: Int] = [:]
        var byName: [String: [Int]] = [:]
        for (index, card) in cards.enumerated() {
            for handle in card.handles where byHandle[handle] == nil { byHandle[handle] = index }
            byName[card.name.lowercased(), default: []].append(index)
        }

        var result: [Int: LinkedInSuggestion] = [:]
        for connection in connections {
            let viaEmail = connection.email.flatMap(Handle.normalize).flatMap { byHandle[$0] }
            let named = byName[connection.fullName.lowercased()] ?? []
            guard let index = viaEmail ?? (named.count == 1 ? named[0] : nil),
                  let suggestion = signals.suggestion(for: connection, now: now)
            else { continue }
            // Two connections on one card (a duplicate profile): keep the stronger.
            if (result[index]?.score ?? 0) < suggestion.score { result[index] = suggestion }
        }
        return result
    }
}
