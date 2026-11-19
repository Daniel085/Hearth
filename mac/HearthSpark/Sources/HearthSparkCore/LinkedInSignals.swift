import Foundation

/// Evidence, from the rest of a LinkedIn export, that a connection is more than a click.
///
/// LinkedIn doesn't export messages, so this is the best closeness signal on offer:
/// who endorsed or recommended whom, who wrote a note with their invitation, and who
/// works where the user worked. Most connections have none of it — on a real 860-person
/// export, 81% had no signal at all — which is exactly what makes it useful for
/// floating the few that matter to the top of a long list.
struct LinkedInSignals: Sendable {
    var endorsedYou: [String: Int] = [:]        // keyed by profile slug
    var youEndorsed: [String: Int] = [:]
    var recommendedYou: Set<String> = []        // keyed by lowercased full name
    var youRecommended: Set<String> = []
    var personalInvites: Set<String> = []       // profile slug
    var positions: [Position] = []

    struct Position: Sendable, Equatable {
        let company: String
        let start: Date
        /// Nil while the user still works there.
        let end: Date?
    }

    var isEmpty: Bool {
        endorsedYou.isEmpty && youEndorsed.isEmpty && recommendedYou.isEmpty
            && youRecommended.isEmpty && personalInvites.isEmpty && positions.isEmpty
    }
}

/// Why a connection is suggested, strongest reason first.
public struct LinkedInSuggestion: Sendable, Equatable {
    public let score: Double
    public let reasons: [String]

    public init(score: Double, reasons: [String]) {
        self.score = score
        self.reasons = reasons
    }
}

extension LinkedInSignals {

    /// Reads every signal file present in an export. Missing files are skipped: users
    /// may hand over a partial archive, and LinkedIn's file list changes over time.
    static func read(fromExportFolder folder: URL) -> LinkedInSignals {
        func text(_ name: String) -> String? {
            guard let url = LinkedInExport.find(name, in: folder),
                  let data = try? Data(contentsOf: url)
            else { return nil }
            return try? LinkedInConnectionsParser.decode(data)
        }
        return parse(
            endorsementsReceived: text("Endorsement_Received_Info.csv"),
            endorsementsGiven: text("Endorsement_Given_Info.csv"),
            recommendationsReceived: text("Recommendations_Received.csv"),
            recommendationsGiven: text("Recommendations_Given.csv"),
            invitations: text("Invitations.csv"),
            positions: text("Positions.csv")
        )
    }

    static func parse(
        endorsementsReceived: String? = nil,
        endorsementsGiven: String? = nil,
        recommendationsReceived: String? = nil,
        recommendationsGiven: String? = nil,
        invitations: String? = nil,
        positions: String? = nil
    ) -> LinkedInSignals {
        typealias P = LinkedInConnectionsParser
        var signals = LinkedInSignals()

        for record in endorsementsReceived.flatMap({ P.records($0, requiring: ["endorser public url"]) }) ?? [] {
            if let slug = profileSlug(record["endorser public url"]) {
                signals.endorsedYou[slug, default: 0] += 1
            }
        }
        for record in endorsementsGiven.flatMap({ P.records($0, requiring: ["endorsee public url"]) }) ?? [] {
            if let slug = profileSlug(record["endorsee public url"]) {
                signals.youEndorsed[slug, default: 0] += 1
            }
        }
        // Recommendations carry names but no profile link, so they match by name.
        for record in recommendationsReceived.flatMap({ P.records($0, requiring: ["first name", "last name"]) }) ?? [] {
            signals.recommendedYou.insert(nameKey(record["first name"], record["last name"]))
        }
        for record in recommendationsGiven.flatMap({ P.records($0, requiring: ["first name", "last name"]) }) ?? [] {
            signals.youRecommended.insert(nameKey(record["first name"], record["last name"]))
        }
        // An invitation with a written note, in either direction. Most are sent blank;
        // taking the time to write one says something.
        for record in invitations.flatMap({ P.records($0, requiring: ["direction"]) }) ?? []
        where record["message"] != nil {
            let url = record["direction"]?.uppercased() == "OUTGOING"
                ? record["inviteeprofileurl"] : record["inviterprofileurl"]
            if let slug = profileSlug(url) { signals.personalInvites.insert(slug) }
        }
        for record in positions.flatMap({ P.records($0, requiring: ["company name", "started on"]) }) ?? [] {
            guard let company = record["company name"],
                  let start = record["started on"].flatMap(P.parseDate)
            else { continue }
            signals.positions.append(Position(
                company: company,
                start: start,
                end: record["finished on"].flatMap(P.parseDate)
            ))
        }
        return signals
    }

    // MARK: - Ranking

    /// Scores a connection, or nil if nothing links them to the user.
    ///
    /// Weights favour effort: a written recommendation outweighs any number of
    /// one-tap endorsements, and endorsement counts are capped so a prolific endorser
    /// can't outrank a recommendation on volume alone.
    func suggestion(for connection: LinkedInConnection, now: Date = Date()) -> LinkedInSuggestion? {
        var score = 0.0
        var reasons: [(weight: Double, text: String)] = []
        func add(_ weight: Double, _ text: String) {
            score += weight
            reasons.append((weight, text))
        }

        let name = Self.nameKey(connection.firstName, connection.lastName)
        let slug = Self.profileSlug(connection.profileURL?.absoluteString)

        if recommendedYou.contains(name) { add(5, "Recommended you") }
        if youRecommended.contains(name) { add(5, "You recommended them") }
        if let slug {
            if let n = endorsedYou[slug] { add(Double(min(n, 5)), n == 1 ? "Endorsed you" : "Endorsed you \(n)×") }
            if let n = youEndorsed[slug] { add(Double(min(n, 5)), "You endorsed them") }
            if personalInvites.contains(slug) { add(2, "Wrote a note when connecting") }
        }

        if let company = connection.company {
            // One employer often spans several positions (promotions are separate
            // rows), so check every stint, not just the first.
            let stints = positions.filter { Self.sameCompany($0.company, company) }
            // Connecting while the user worked there is the best available hint they
            // overlapped: the export only has each connection's *current* company,
            // with no history or dates, so true overlap can't be computed.
            if let connected = connection.connectedOn,
               let stint = stints.first(where: { connected >= $0.start && connected <= ($0.end ?? now) }) {
                add(3, "Colleague at \(stint.company)")
            } else if let stint = stints.first {
                add(1, "Works at \(stint.company)")
            }
        }

        guard score > 0 else { return nil }
        return LinkedInSuggestion(
            score: score,
            reasons: reasons.sorted { $0.weight > $1.weight }.map(\.text)
        )
    }

    // MARK: - Matching

    /// The `in/<slug>` part of a profile URL, which is stable across http/https,
    /// "www.", trailing slashes and query strings.
    static func profileSlug(_ url: String?) -> String? {
        guard let url = url?.lowercased(),
              let range = url.range(of: "linkedin.com/in/")
        else { return nil }
        let slug = url[range.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return slug.isEmpty ? nil : String(slug).removingPercentEncoding ?? String(slug)
    }

    static func nameKey(_ first: String?, _ last: String?) -> String {
        [first, last].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ").lowercased()
    }

    /// Whether two company names are the same employer.
    ///
    /// One name's words must *begin* the other's — so "Northwind" matches "NORTHWIND
    /// Traders, Inc." and "Tailspin Labs" matches "Tailspin!", but "Springfield" does
    /// not match "UC Springfield". Slash-separated histories like "Litware/Fabrikam/Adatum"
    /// match on any part.
    static func sameCompany(_ a: String, _ b: String) -> Bool {
        let aParts = a.split(separator: "/").map(companyWords)
        let bParts = b.split(separator: "/").map(companyWords)
        for x in aParts where !x.isEmpty {
            for y in bParts where !y.isEmpty {
                let (short, long) = x.count <= y.count ? (x, y) : (y, x)
                if Array(long.prefix(short.count)) == short { return true }
            }
        }
        return false
    }

    private static let legalSuffixes: Set<String> = ["inc", "llc", "ltd", "corp", "corporation", "co", "plc", "gmbh"]

    private static func companyWords(_ name: Substring) -> [String] {
        name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !legalSuffixes.contains($0) }
    }
}

/// Locating files inside an unzipped LinkedIn export.
enum LinkedInExport {
    /// Finds a file by name, case-insensitively, up to two folders deep — the Files
    /// app sometimes unzips into an extra enclosing folder.
    static func find(_ name: String, in folder: URL) -> URL? {
        let target = name.lowercased()
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        for case let url as URL in enumerator {
            if enumerator.level > 3 { enumerator.skipDescendants(); continue }
            if url.lastPathComponent.lowercased() == target { return url }
        }
        return nil
    }
}
