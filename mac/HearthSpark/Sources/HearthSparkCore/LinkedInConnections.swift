import Foundation

/// One row of LinkedIn's `Connections.csv` data export.
///
/// Hearth never talks to LinkedIn. The user requests their own archive from LinkedIn
/// (Settings → Data privacy → Get a copy of your data → Connections) and hands the file
/// to Hearth, which reads it on device. Scraping LinkedIn is against its terms and risks
/// the user's account; the export is the sanctioned route and carries the same data.
struct LinkedInConnection: Hashable, Sendable, Identifiable {
    let firstName: String
    let lastName: String
    /// Usually empty: LinkedIn only includes it when the connection opted to share it.
    let email: String?
    let company: String?
    let position: String?
    let profileURL: URL?
    let connectedOn: Date?

    var id: String { profileURL?.absoluteString ?? "\(fullName)|\(email ?? "")" }

    var fullName: String {
        [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "Designer at Acme", "Acme", "Designer", or nil.
    var workSummary: String? {
        switch (position, company) {
        case let (p?, c?): "\(p) at \(c)"
        case let (p?, nil): p
        case let (nil, c?): c
        case (nil, nil): nil
        }
    }
}

enum LinkedInImportError: LocalizedError, Equatable {
    case unreadable
    case notAConnectionsFile

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "Hearth couldn't read that file."
        case .notAConnectionsFile:
            "That doesn't look like LinkedIn's Connections.csv. It should have First Name and Last Name columns."
        }
    }
}

/// Parses LinkedIn's `Connections.csv`.
///
/// The file is not a clean CSV: it opens with a free-text "Notes:" preamble before the
/// header row, and fields are quoted inconsistently. So the parser finds the header by
/// its column names rather than assuming line one, and maps columns by name rather
/// than position, in case LinkedIn reorders them.
enum LinkedInConnectionsParser {

    static func parse(data: Data) throws -> [LinkedInConnection] {
        try parse(decode(data))
    }

    static func parse(_ text: String) throws -> [LinkedInConnection] {
        guard let records = records(text, requiring: ["first name", "last name"])
        else { throw LinkedInImportError.notAConnectionsFile }

        var seen = Set<String>()
        var connections: [LinkedInConnection] = []

        for record in records {
            let first = record["first name"] ?? ""
            let last = record["last name"] ?? ""
            // LinkedIn leaves both names blank for members who restrict their data.
            // With no name there is nothing Hearth can show or match on.
            guard !(first.isEmpty && last.isEmpty) else { continue }

            let connection = LinkedInConnection(
                firstName: first,
                lastName: last,
                email: record["email address"],
                company: record["company"],
                position: record["position"],
                profileURL: record["url"].flatMap(URL.init(string:)),
                connectedOn: record["connected on"].flatMap(parseDate)
            )
            guard seen.insert(connection.id).inserted else { continue }
            connections.append(connection)
        }
        return connections
    }

    // MARK: - Tables

    static func decode(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else { throw LinkedInImportError.unreadable }
        return text
    }

    /// Rows below the first row that contains every `requiring` column, keyed by
    /// lowercased column name, with blank values left out. Nil if no such header.
    ///
    /// Every file in LinkedIn's export shares this shape — sometimes with a preamble
    /// above the header — so one reader serves them all.
    static func records(_ text: String, requiring: Set<String>) -> [[String: String]]? {
        let rows = csvRows(text)
        guard let headerIndex = rows.firstIndex(where: {
            requiring.isSubset(of: Set($0.map(normalized)))
        }) else { return nil }

        let header = rows[headerIndex].map(normalized)
        return rows[(headerIndex + 1)...].map { row in
            var record: [String: String] = [:]
            for (index, name) in header.enumerated() where index < row.count {
                let value = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { record[name] = value }
            }
            return record
        }
    }

    // MARK: - CSV

    /// RFC 4180 rows: quoted fields may contain commas, newlines and doubled quotes.
    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = chars.next()

        // Skip a byte-order mark, which Excel round-trips tend to add.
        if pending == "\u{FEFF}" { pending = chars.next() }

        func endRow() {
            row.append(field)
            field = ""
            // A blank line parses as a single empty field; drop it.
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let c = pending {
            pending = chars.next()
            if inQuotes {
                if c == "\"" {
                    if pending == "\"" {
                        field.unicodeScalars.append("\"")
                        pending = chars.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
                continue
            }
            switch c {
            case "\"" where field.isEmpty:
                inQuotes = true
            case ",":
                row.append(field)
                field = ""
            case "\r":
                if pending == "\n" { pending = chars.next() }
                endRow()
            case "\n":
                endRow()
            default:
                field.unicodeScalars.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    private static func normalized(_ header: String) -> String {
        header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// LinkedIn writes "14 Nov 2026"; older exports used "11/14/26".
    static func parseDate(_ string: String) -> Date? {
        for format in ["dd MMM yyyy", "d MMM yyyy", "MM/dd/yy", "yyyy-MM-dd",
                       // Positions.csv: "Jan 2026", or a bare year for education.
                       "MMM yyyy", "yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
