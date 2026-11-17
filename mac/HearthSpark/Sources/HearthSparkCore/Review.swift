import Foundation

/// The text the user reads before anything is written: what was read, what would be
/// sent, and what stays behind.
public enum Review {

    public struct SourceReport: Equatable {
        public var name: String
        public var detail: String
        /// Couldn't be read; `detail` says why.
        public var skipped: Bool
        public init(name: String, detail: String, skipped: Bool = false) {
            self.name = name
            self.detail = detail
            self.skipped = skipped
        }
    }

    public static func whatWasRead(_ sources: [SourceReport]) -> String {
        var out = "WHAT WAS READ (on this Mac only)\n"
        for source in sources {
            out += "  • \(source.name): \(source.skipped && !source.detail.hasPrefix("Switched off") ? "skipped — " : "")\(source.detail)\n"
        }
        out += "  Message text, email contents, subjects and attachments were never opened.\n"
        return out
    }

    /// Everyone who would go in the file, with the reasons — the same words the iOS
    /// app will show.
    public static func whatWouldBeSent(_ result: Recommender.Result, encodedSize: Int) -> String {
        let people = result.file.people
        var out = "WHAT WOULD BE SENT to your iPhone (\(people.count) people, \(formatBytes(encodedSize)))\n"
        out += "  Per person: name · suggested closeness · month of last contact · reasons ·\n"
        out += "  salted hashes of their numbers/emails so your phone can match them.\n"
        out += "  No counts beyond the reasons, no exact dates, no message content.\n\n"
        for tier in SparkTier.allCases {
            let inTier = people.filter { $0.suggestedTier == tier }
            guard !inTier.isEmpty else { continue }
            out += "  \(tier.label.uppercased()) (\(inTier.count))\n"
            for person in inTier {
                let last = person.lastContactMonth.map { "  · last \($0)" } ?? ""
                out += "    \(person.name)\(last)\n"
                if !person.reasons.isEmpty {
                    out += "      \(person.reasons.joined(separator: " · "))\n"
                }
            }
            out += "\n"
        }
        if result.unmatchedHandles > 0 {
            out += "  Left out: \(result.unmatchedHandles) numbers/emails you message or call that aren't in Contacts.\n"
        }
        return out
    }

    /// Aggregates only, with no names — safe to paste into a bug report or share.
    public static func summary(_ result: Recommender.Result, cardCount: Int, interactionHandles: Int) -> String {
        var out = "SUMMARY (no names)\n"
        out += "  Contacts read: \(cardCount)\n"
        out += "  Numbers/emails with messages or calls: \(interactionHandles)\n"
        out += "  …not in Contacts, dropped: \(result.unmatchedHandles)\n"
        out += "  People suggested: \(result.file.people.count)\n"
        for tier in SparkTier.allCases {
            out += "    \(tier.label): \(result.file.people.filter { $0.suggestedTier == tier }.count)\n"
        }
        var reasonKinds: [String: Int] = [:]
        for person in result.file.people {
            for reason in person.reasons { reasonKinds[kind(of: reason), default: 0] += 1 }
        }
        out += "  Reasons used:\n"
        for (kind, count) in reasonKinds.sorted(by: { $0.value > $1.value }) {
            out += "    \(count)\t\(kind)\n"
        }
        return out
    }

    public static func whatWasKept(written path: String?, bytes: Int) -> String {
        var out = "WHAT HEARTH SPARK KEPT on this Mac\n"
        if let path {
            out += "  Only the file you asked for: \(path) (\(formatBytes(bytes))).\n"
            out += "  Delete it once it's on your iPhone. Nothing else was saved — no cache, no logs.\n"
        } else {
            out += "  Nothing. This was a review; no file was written. Run with --write <file> to create one.\n"
        }
        return out
    }

    private static func kind(of reason: String) -> String {
        if reason.hasPrefix("Messaged") { return "Messaged both ways" }
        if reason.hasPrefix("Emailed") { return "Emailed both ways" }
        if reason.contains("call") { return "Calls" }
        if reason.hasPrefix("In touch since") { return "In touch 5+ years" }
        if reason.hasPrefix("Your card lists") { return "Relation on your card" }
        return reason
    }

    static func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
