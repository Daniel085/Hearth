import Foundation

/// What Hearth Spark knows about one phone number or email, after counting.
///
/// Totals only. Individual messages and calls are counted inside SQLite by the queries
/// below and never enter this process as rows.
public struct HandleStats: Equatable, Sendable {
    public var sentLastYear = 0
    public var receivedLastYear = 0
    public var callsLastYear = 0
    public var callMinutesLastYear = 0.0
    public var emailsSentLastYear = 0
    public var emailsReceivedLastYear = 0
    public var first: Date?
    public var last: Date?

    public init() {}

    public mutating func merge(_ other: HandleStats) {
        sentLastYear += other.sentLastYear
        receivedLastYear += other.receivedLastYear
        callsLastYear += other.callsLastYear
        callMinutesLastYear += other.callMinutesLastYear
        emailsSentLastYear += other.emailsSentLastYear
        emailsReceivedLastYear += other.emailsReceivedLastYear
        first = [first, other.first].compactMap { $0 }.min()
        last = [last, other.last].compactMap { $0 }.max()
    }
}

// MARK: - Messages

/// Reads `~/Library/Messages/chat.db`: who, when, and which direction. Never what.
public enum MessagesSource {
    public static let defaultPath = NSHomeDirectory() + "/Library/Messages/chat.db"

    /// Every column the query touches, by table. The privacy test holds the query to
    /// this list and fails if it names anything else — message text, subjects and
    /// attachments in particular.
    public static let columnsRead: [String: Set<String>] = [
        "message": ["ROWID", "date", "is_from_me", "associated_message_type"],
        "handle": ["ROWID", "id"],
        "chat_message_join": ["chat_id", "message_id"],
        "chat_handle_join": ["chat_id", "handle_id"],
    ]

    /// One-to-one conversations only (a chat with exactly one other person): being in
    /// the same busy group chat says little about closeness. Tapbacks are excluded —
    /// they're reactions to messages, not messages (`associated_message_type` is 0 for
    /// ordinary messages).
    static let sql = """
        SELECT h.id,
               SUM(CASE WHEN m.is_from_me = 1 AND m.date >= ?1 THEN 1 ELSE 0 END),
               SUM(CASE WHEN m.is_from_me = 0 AND m.date >= ?1 THEN 1 ELSE 0 END),
               MIN(m.date),
               MAX(m.date)
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat_handle_join chj ON chj.chat_id = cmj.chat_id
        JOIN handle h ON h.ROWID = chj.handle_id
        WHERE m.associated_message_type = 0
          AND cmj.chat_id IN (
              SELECT chat_id FROM chat_handle_join GROUP BY chat_id HAVING COUNT(*) = 1
          )
        GROUP BY h.id
        """

    public static func read(path: String = defaultPath, now: Date = Date()) throws -> [String: HandleStats] {
        let db = try ReadOnlyDatabase(path: path)
        try verifySchema(db, columnsRead)

        // Messages stores dates as time since 2001 — in seconds on old databases and
        // nanoseconds since macOS 10.13. Detect which from the newest value.
        var newest = 0.0
        try db.query("SELECT MAX(date) FROM message") { newest = $0.double(0) ?? 0 }
        let scale = newest > 1e12 ? 1e9 : 1.0
        let since = now.addingTimeInterval(-365 * 86_400).timeIntervalSinceReferenceDate * scale

        var stats: [String: HandleStats] = [:]
        try db.query(sql, bind: [since]) { row in
            guard let raw = row.text(0), let key = Handle.normalize(raw) else { return }
            var s = HandleStats()
            s.sentLastYear = row.int(1)
            s.receivedLastYear = row.int(2)
            s.first = row.double(3).map { Date(timeIntervalSinceReferenceDate: $0 / scale) }
            s.last = row.double(4).map { Date(timeIntervalSinceReferenceDate: $0 / scale) }
            stats[key, default: HandleStats()].merge(s)
        }
        return stats
    }
}

// MARK: - Calls

/// Reads the call history, which iCloud syncs from the iPhone to the Mac.
public enum CallsSource {
    public static let defaultPath = NSHomeDirectory()
        + "/Library/Application Support/CallHistoryDB/CallHistory.storedata"

    public static let columnsRead: [String: Set<String>] = [
        "ZCALLRECORD": ["ZADDRESS", "ZDATE", "ZDURATION", "ZANSWERED"],
    ]

    /// Counts calls that connected. Missed and unanswered calls aren't contact. Calls
    /// answered on the iPhone sync to the Mac without a duration, so "answered" counts
    /// even when the minutes are zero.
    static let sql = """
        SELECT ZADDRESS,
               SUM(CASE WHEN ZDATE >= ?1 THEN 1 ELSE 0 END),
               SUM(CASE WHEN ZDATE >= ?1 THEN ZDURATION ELSE 0 END),
               MIN(ZDATE),
               MAX(ZDATE)
        FROM ZCALLRECORD
        WHERE ZADDRESS IS NOT NULL
          AND (ZANSWERED = 1 OR ZDURATION > 0)
        GROUP BY ZADDRESS
        """

    public static func read(path: String = defaultPath, now: Date = Date()) throws -> [String: HandleStats] {
        let db = try ReadOnlyDatabase(path: path)
        try verifySchema(db, columnsRead)
        let since = now.addingTimeInterval(-365 * 86_400).timeIntervalSinceReferenceDate

        var stats: [String: HandleStats] = [:]
        try db.query(sql, bind: [since]) { row in
            guard let raw = row.text(0), let key = Handle.normalize(raw) else { return }
            var s = HandleStats()
            s.callsLastYear = row.int(1)
            s.callMinutesLastYear = (row.double(2) ?? 0) / 60
            s.first = row.double(3).map(Date.init(timeIntervalSinceReferenceDate:))
            s.last = row.double(4).map(Date.init(timeIntervalSinceReferenceDate:))
            stats[key, default: HandleStats()].merge(s)
        }
        return stats
    }
}

// MARK: - Mail

/// Reads Apple Mail's local index (`~/Library/Mail/V*/MailData/Envelope Index`): who
/// emailed whom, and when. Email bodies live in separate files that are never opened,
/// and the index's subject and summary columns are never queried.
///
/// Only Apple Mail. Webmail (Gmail in a browser) has nothing on this Mac to read, and
/// fetching it would need the network, which Hearth Spark never uses.
public enum MailSource {

    /// The newest Mail data folder present ("V10", "V11", …), or nil if Apple Mail
    /// has never been set up.
    public static var defaultPath: String? {
        let root = NSHomeDirectory() + "/Library/Mail"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
            .filter { $0.hasPrefix("V") }
            .compactMap { name in Int(name.dropFirst()).map { (name, $0) } }
            .sorted { $0.1 > $1.1 }
        for (name, _) in versions {
            let path = "\(root)/\(name)/MailData/Envelope Index"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        // The folder exists but can't be listed: no Full Disk Access yet.
        if FileManager.default.fileExists(atPath: root) { return root + "/V10/MailData/Envelope Index" }
        return nil
    }

    public static let columnsRead: [String: Set<String>] = [
        "messages": ["ROWID", "sender", "mailbox", "date_sent", "date_received"],
        "addresses": ["ROWID", "address"],
        "recipients": ["message", "address"],
        "mailboxes": ["ROWID", "url"],
    ]

    /// Email from them: not in a Sent, Junk or Trash mailbox, and addressed to five
    /// people or fewer — mailing lists and newsletters are not conversations.
    static let receivedSQL = """
        SELECT a.address,
               SUM(CASE WHEN m.date_received >= ?1 THEN 1 ELSE 0 END),
               MIN(m.date_received),
               MAX(m.date_received)
        FROM messages m
        JOIN addresses a ON a.ROWID = m.sender
        JOIN mailboxes mb ON mb.ROWID = m.mailbox
        WHERE lower(mb.url) NOT LIKE '%sent%'
          AND lower(mb.url) NOT LIKE '%junk%'
          AND lower(mb.url) NOT LIKE '%spam%'
          AND lower(mb.url) NOT LIKE '%trash%'
          AND lower(mb.url) NOT LIKE '%deleted%'
          AND (SELECT COUNT(*) FROM recipients r WHERE r.message = m.ROWID) <= 5
        GROUP BY a.address
        """

    /// Email to them: in a Sent mailbox, counted once per recipient, same size limit.
    static let sentSQL = """
        SELECT a.address,
               SUM(CASE WHEN m.date_sent >= ?1 THEN 1 ELSE 0 END),
               MIN(m.date_sent),
               MAX(m.date_sent)
        FROM messages m
        JOIN mailboxes mb ON mb.ROWID = m.mailbox
        JOIN recipients r ON r.message = m.ROWID
        JOIN addresses a ON a.ROWID = r.address
        WHERE lower(mb.url) LIKE '%sent%'
          AND (SELECT COUNT(*) FROM recipients r2 WHERE r2.message = m.ROWID) <= 5
        GROUP BY a.address
        """

    public static func read(path: String? = defaultPath, now: Date = Date()) throws -> [String: HandleStats] {
        guard let path else { throw SourceError.notSetUp("Apple Mail isn't set up on this Mac.") }
        let db = try ReadOnlyDatabase(path: path)
        try verifySchema(db, columnsRead)

        // Mail stores Unix time; guard against a version that switches to Apple's
        // 2001-based reference dates, as Messages and call history use.
        var newest = 0.0
        try db.query("SELECT MAX(date_received) FROM messages") { newest = $0.double(0) ?? 0 }
        let unix = newest == 0 || newest > 1.2e9
        let since = unix
            ? now.addingTimeInterval(-365 * 86_400).timeIntervalSince1970
            : now.addingTimeInterval(-365 * 86_400).timeIntervalSinceReferenceDate
        func date(_ value: Double?) -> Date? {
            value.map { unix ? Date(timeIntervalSince1970: $0) : Date(timeIntervalSinceReferenceDate: $0) }
        }

        var stats: [String: HandleStats] = [:]
        try db.query(receivedSQL, bind: [since]) { row in
            guard let raw = row.text(0), let key = Handle.normalize(raw) else { return }
            var s = HandleStats()
            s.emailsReceivedLastYear = row.int(1)
            s.first = date(row.double(2))
            s.last = date(row.double(3))
            stats[key, default: HandleStats()].merge(s)
        }
        try db.query(sentSQL, bind: [since]) { row in
            guard let raw = row.text(0), let key = Handle.normalize(raw) else { return }
            var s = HandleStats()
            s.emailsSentLastYear = row.int(1)
            s.first = date(row.double(2))
            s.last = date(row.double(3))
            stats[key, default: HandleStats()].merge(s)
        }
        return stats
    }
}

/// Refuses to query a database whose tables don't have the expected columns. Apple
/// doesn't document these schemas; guessing after a macOS update could silently
/// produce wrong numbers.
func verifySchema(_ db: ReadOnlyDatabase, _ expected: [String: Set<String>]) throws {
    for (table, columns) in expected.sorted(by: { $0.key < $1.key }) {
        let missing = columns.subtracting(try db.columns(of: table))
        if !missing.isEmpty {
            throw SourceError.unexpectedSchema(table: table, missing: missing.sorted())
        }
    }
}
