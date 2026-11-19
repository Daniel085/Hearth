import Foundation
import SQLite3
import Testing
@testable import HearthSparkCore

// MARK: - Fixtures

/// Builds a throwaway SQLite database from SQL statements.
private func makeDatabase(_ statements: [String]) throws -> String {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("hearthspark-\(UUID().uuidString).sqlite").path
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { throw SourceError.notReadable(path) }
    defer { sqlite3_close(db) }
    for sql in statements {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "?"
            sqlite3_free(error)
            throw SourceError.queryFailed("\(message) in: \(sql)")
        }
    }
    return path
}

/// Tables with *only* the columns Hearth Spark is allowed to read. If a query ever
/// reached for message text or anything else, SQLite would fail with "no such column"
/// — so these fixtures enforce the allowlist, not just illustrate it.
private func schema(_ columns: [String: Set<String>]) -> [String] {
    columns.map { table, cols in
        "CREATE TABLE \(table) (\(cols.sorted().map { $0 == "ROWID" ? "ROWID INTEGER PRIMARY KEY" : $0 }.joined(separator: ", ")))"
    }
}

private let now = Date(timeIntervalSinceReferenceDate: 815_000_000) // Oct 2026
private func ns(daysAgo: Double) -> Int { Int((now.timeIntervalSinceReferenceDate - daysAgo * 86_400) * 1e9) }
private func secs(daysAgo: Double) -> Double { now.timeIntervalSinceReferenceDate - daysAgo * 86_400 }

private func messagesDatabase() throws -> String {
    try makeDatabase(schema(MessagesSource.columnsRead) + [
        // Handles: Jane by phone, a business short code, and a group-chat member.
        "INSERT INTO handle VALUES (1, '+1 (415) 555-0100')",
        "INSERT INTO handle VALUES (2, '12345')",
        "INSERT INTO handle VALUES (3, 'sam@example.com')",
        // Chat 10: one-to-one with Jane. Chat 20: group with Jane and Sam.
        "INSERT INTO chat_handle_join VALUES (10, 1)",
        "INSERT INTO chat_handle_join VALUES (20, 1)",
        "INSERT INTO chat_handle_join VALUES (20, 3)",
        "INSERT INTO chat_handle_join VALUES (30, 2)",
        // Jane, 1:1: two sent, one received this year, one received six years ago,
        // and a tapback that must not count.
        "INSERT INTO message VALUES (0, \(ns(daysAgo: 3)), 1, 1)",
        "INSERT INTO message VALUES (0, \(ns(daysAgo: 40)), 1, 2)",
        "INSERT INTO message VALUES (0, \(ns(daysAgo: 41)), 0, 3)",
        "INSERT INTO message VALUES (0, \(ns(daysAgo: 2200)), 0, 4)",
        "INSERT INTO message VALUES (2000, \(ns(daysAgo: 2)), 0, 5)",
        // Group chat messages: ignored.
        "INSERT INTO message VALUES (0, \(ns(daysAgo: 1)), 0, 6)",
        "INSERT INTO message VALUES (0, \(ns(daysAgo: 1)), 1, 7)",
        // Short-code business: normalizes to nothing.
        "INSERT INTO message VALUES (0, \(ns(daysAgo: 1)), 0, 8)",
        "INSERT INTO chat_message_join VALUES (10, 1)",
        "INSERT INTO chat_message_join VALUES (10, 2)",
        "INSERT INTO chat_message_join VALUES (10, 3)",
        "INSERT INTO chat_message_join VALUES (10, 4)",
        "INSERT INTO chat_message_join VALUES (10, 5)",
        "INSERT INTO chat_message_join VALUES (20, 6)",
        "INSERT INTO chat_message_join VALUES (20, 7)",
        "INSERT INTO chat_message_join VALUES (30, 8)",
    ].map { $0.replacingOccurrences(of: "INSERT INTO message VALUES (", with: "INSERT INTO message (associated_message_type, date, is_from_me, ROWID) VALUES (") })
}

// MARK: - Sources

@Test
func messagesCountsOneToOneConversationsOnly() throws {
    let stats = try MessagesSource.read(path: try messagesDatabase(), now: now)

    let jane = try #require(stats["4155550100"])
    #expect(jane.sentLastYear == 2)
    #expect(jane.receivedLastYear == 1)   // tapback and group messages excluded
    #expect(jane.last.map { now.timeIntervalSince($0) / 86_400 }.map { Int($0.rounded()) } == 3)
    #expect(jane.first.map { now.timeIntervalSince($0) / 86_400 }.map { Int($0.rounded()) } == 2200)

    #expect(stats["sam@example.com"] == nil)  // only ever in a group chat
    #expect(stats.count == 1)                 // short code dropped
}

@Test
func callsCountConnectedCallsIncludingThoseAnsweredOnThePhone() throws {
    let path = try makeDatabase(schema(CallsSource.columnsRead) + [
        // ZADDRESS, ZANSWERED, ZDATE, ZDURATION (sorted column order)
        "INSERT INTO ZCALLRECORD VALUES ('+14155550100', 1, \(secs(daysAgo: 5)), 600)",
        // Answered on the iPhone: synced with no duration, still a call.
        "INSERT INTO ZCALLRECORD VALUES ('4155550100', 1, \(secs(daysAgo: 20)), 0)",
        // Missed: not contact.
        "INSERT INTO ZCALLRECORD VALUES ('4155550100', 0, \(secs(daysAgo: 1)), 0)",
        // Over a year ago: counts toward "first", not this year's total.
        "INSERT INTO ZCALLRECORD VALUES ('4155550100', 1, \(secs(daysAgo: 500)), 60)",
    ])
    let stats = try CallsSource.read(path: path, now: now)
    let jane = try #require(stats["4155550100"])
    #expect(jane.callsLastYear == 2)
    #expect(jane.callMinutesLastYear == 10)
    #expect(jane.last.map { Int((now.timeIntervalSince($0) / 86_400).rounded()) } == 5)
}

@Test
func changedSchemaIsRefusedNotGuessed() throws {
    let path = try makeDatabase(["CREATE TABLE ZCALLRECORD (ZADDRESS, ZDATE)"])
    #expect(throws: SourceError.unexpectedSchema(table: "ZCALLRECORD", missing: ["ZANSWERED", "ZDURATION"])) {
        try CallsSource.read(path: path, now: now)
    }
}

@Test
func queriesNeverReachForContent() {
    // Belt and braces alongside the column-only fixtures: no wildcard selects, and
    // none of the known content columns are even mentioned.
    let forbidden = ["*", "text", "attributedbody", "subject", "attachment", "payload", "summary", "snippet", "zname", "zlocation"]
    for sql in [MessagesSource.sql, CallsSource.sql, MailSource.receivedSQL, MailSource.sentSQL] {
        let lowered = sql.lowercased()
        for word in forbidden where word != "*" {
            #expect(!lowered.contains(word), "query mentions \(word)")
        }
        #expect(!lowered.contains("select *") && !lowered.contains(".*"))
    }
}

// MARK: - Handles

@Test
func handlesNormalizeAcrossFormats() {
    #expect(Handle.normalize("+1 (415) 555-0100") == "4155550100")
    #expect(Handle.normalize("415.555.0100") == "4155550100")
    #expect(Handle.normalize(" Jane@Example.COM ") == "jane@example.com")
    #expect(Handle.normalize("12345") == nil)
}

// MARK: - Scoring and the file

private let jane = ContactCard(name: "Jane Doe", handles: ["4155550100", "jane@example.com"], hasBirthday: true, relation: "sister")
private let acquaintance = ContactCard(name: "Pat Lee", handles: ["6505550199"])
private let silent = ContactCard(name: "No Signal", handles: ["2125550123"])

private func janeStats() -> HandleStats {
    var s = HandleStats()
    s.sentLastYear = 120
    s.receivedLastYear = 140
    s.callsLastYear = 6
    s.callMinutesLastYear = 95
    s.first = now.addingTimeInterval(-9 * 365 * 86_400)
    s.last = now.addingTimeInterval(-2 * 86_400)
    return s
}

@Test
func reciprocityMattersMoreThanVolume() {
    var oneWay = HandleStats()
    oneWay.receivedLastYear = 500     // a stream they never answer
    oneWay.last = now
    let scored = Recommender(now: now).score(card: acquaintance, stats: oneWay)
    #expect(scored.score == 0)
    #expect(scored.reasons.isEmpty)
}

@Test
func closeFamilyLandsInInnerCircleWithReasons() {
    let scored = Recommender(now: now).score(card: jane, stats: janeStats())
    #expect(Recommender.tier(for: scored.score) == .innerCircle)
    // Six calls totalling 95 minutes outweigh 120 two-way messages; both are listed.
    #expect(scored.reasons.first == "6 calls this past year (95 min)")
    #expect(scored.reasons.contains("Messaged both ways this past year (120 sent, 140 received)"))
    #expect(scored.reasons.contains("Your card lists them as sister"))
    #expect(scored.reasons.contains("In touch since \(Calendar.current.component(.year, from: janeStats().first!))"))
}

@Test
func fileHoldsOnlyContactsWithSignalAndNoRawHandles() throws {
    var interactions = ["4155550100": janeStats()]
    var light = HandleStats()
    light.sentLastYear = 3
    light.receivedLastYear = 3
    light.last = now.addingTimeInterval(-200 * 86_400)
    interactions["6505550199"] = light
    interactions["9995550000"] = janeStats()  // a stranger: not in Contacts

    let result = Recommender(now: now).build(cards: [jane, acquaintance, silent], interactions: interactions, salt: "test-salt")
    let names = result.file.people.map(\.name)

    #expect(names == ["Jane Doe"])            // Pat below threshold; No Signal has none
    #expect(result.unmatchedHandles == 1)     // the stranger, counted, never named

    let json = try #require(String(data: try result.file.encoded(), encoding: .utf8))
    // Handles never appear in the clear — not the contact's, not the stranger's.
    for raw in ["4155550100", "jane@example.com", "9995550000", "6505550199"] {
        #expect(!json.contains(raw), "\(raw) leaked into the file")
    }
    #expect(result.file.people[0].matchKeys == [
        MatchKey.hash("4155550100", salt: "test-salt"),
        MatchKey.hash("jane@example.com", salt: "test-salt"),
    ].sorted())
    // Month, not day.
    #expect(result.file.people[0].lastContactMonth?.count == 7)
}

@Test
func saltMakesTheSameNumberHashDifferently() {
    #expect(MatchKey.hash("4155550100", salt: "a") != MatchKey.hash("4155550100", salt: "b"))
    #expect(MatchKey.newSalt() != MatchKey.newSalt())
}

@Test
func fileRoundTripsAndRejectsForeignFiles() throws {
    let file = SparkFile(createdMonth: "2026-11", salt: "s", people: [
        SparkPerson(name: "A", matchKeys: ["k"], suggestedTier: .close, lastContactMonth: nil, reasons: []),
    ])
    #expect(try SparkFile.decode(file.encoded()) == file)

    var future = file
    future.version = SparkFile.currentVersion + 1
    #expect(throws: SparkError.unsupportedFile) { try SparkFile.decode(future.encoded()) }
}

@Test
func reviewNamesNobodyInSummaryMode() {
    let result = Recommender(now: now).build(cards: [jane], interactions: ["4155550100": janeStats()])
    let summary = Review.summary(result, cardCount: 1, interactionHandles: 1)
    #expect(!summary.contains("Jane"))
    #expect(summary.contains("People suggested: 1"))
}

// MARK: - Mail

private func unix(daysAgo: Double) -> Double { now.timeIntervalSince1970 - daysAgo * 86_400 }

@Test
func mailCountsPersonalEmailBothWaysAndSkipsListsAndJunk() throws {
    let path = try makeDatabase(schema(MailSource.columnsRead) + [
        "INSERT INTO mailboxes (ROWID, url) VALUES (1, 'imap://me@example.com/INBOX')",
        "INSERT INTO mailboxes (ROWID, url) VALUES (2, 'imap://me@example.com/Sent%20Messages')",
        "INSERT INTO mailboxes (ROWID, url) VALUES (3, 'imap://me@example.com/Junk')",
        "INSERT INTO addresses (ROWID, address) VALUES (1, 'me@example.com')",
        "INSERT INTO addresses (ROWID, address) VALUES (2, 'Jane@Example.com')",
        "INSERT INTO addresses (ROWID, address) VALUES (3, 'news@shop.example')",
        "INSERT INTO addresses (ROWID, address) VALUES (4, 'list@groups.example')",
        // From Jane, to me: counts as received.
        "INSERT INTO messages (ROWID, sender, mailbox, date_sent, date_received) VALUES (1, 2, 1, \(unix(daysAgo: 10)), \(unix(daysAgo: 10)))",
        "INSERT INTO recipients (message, address) VALUES (1, 1)",
        // Me to Jane, in Sent: counts as sent.
        "INSERT INTO messages (ROWID, sender, mailbox, date_sent, date_received) VALUES (2, 1, 2, \(unix(daysAgo: 9)), \(unix(daysAgo: 9)))",
        "INSERT INTO recipients (message, address) VALUES (2, 2)",
        // From Jane but in Junk: ignored.
        "INSERT INTO messages (ROWID, sender, mailbox, date_sent, date_received) VALUES (3, 2, 3, \(unix(daysAgo: 1)), \(unix(daysAgo: 1)))",
        "INSERT INTO recipients (message, address) VALUES (3, 1)",
        // Newsletter to six people: a list, not a conversation.
        "INSERT INTO messages (ROWID, sender, mailbox, date_sent, date_received) VALUES (4, 3, 1, \(unix(daysAgo: 2)), \(unix(daysAgo: 2)))",
    ] + (10...15).map { "INSERT INTO recipients (message, address) VALUES (4, \($0))" })

    let stats = try MailSource.read(path: path, now: now)
    let jane = try #require(stats["jane@example.com"])
    #expect(jane.emailsReceivedLastYear == 1)
    #expect(jane.emailsSentLastYear == 1)
    #expect(jane.last.map { Int((now.timeIntervalSince($0) / 86_400).rounded()) } == 9)
    #expect(stats["news@shop.example"] == nil)
}

@Test
func mailNotSetUpIsSkippedWithAReason() {
    #expect(throws: SourceError.notSetUp("Apple Mail isn't set up on this Mac.")) {
        try MailSource.read(path: nil, now: now)
    }
}

@Test
func twoWayEmailScoresButOneWayDoesNot() {
    var both = HandleStats()
    both.emailsSentLastYear = 7
    both.emailsReceivedLastYear = 9
    both.last = now.addingTimeInterval(-5 * 86_400)
    let scored = Recommender(now: now).score(card: acquaintance, stats: both)
    #expect(scored.reasons == ["Emailed both ways this past year (7 sent, 9 received)"])
    #expect(Recommender.tier(for: scored.score) == .keptWarm)

    var inbound = HandleStats()
    inbound.emailsReceivedLastYear = 300
    inbound.last = now
    #expect(Recommender(now: now).score(card: acquaintance, stats: inbound).score == 0)
}

// MARK: - Review edits

@Test
func reviewedFileKeepsOnlyTickedPeopleAtTheChosenTier() {
    let file = SparkFile(createdMonth: "2026-11", salt: "s", people: [
        SparkPerson(name: "A", matchKeys: ["a"], suggestedTier: .close, lastContactMonth: nil, reasons: []),
        SparkPerson(name: "B", matchKeys: ["b"], suggestedTier: .keptWarm, lastContactMonth: nil, reasons: []),
        SparkPerson(name: "C", matchKeys: ["c"], suggestedTier: .innerCircle, lastContactMonth: nil, reasons: []),
    ])
    let reviewed = file.reviewed(keeping: [0, 2], tiers: [0: .innerCircle, 1: .distant])
    #expect(reviewed.people.map(\.name) == ["A", "C"])
    #expect(reviewed.people.map(\.suggestedTier) == [.innerCircle, .innerCircle])
    // B's change doesn't matter: B isn't sent at all.
}

// MARK: - Source switches

@Test
func switchedOffSourcesAreNeverOpened() {
    var opened: [SparkSource] = []
    let (interactions, reports) = SparkScan.gather([.calls]) { source in
        opened.append(source)
        var s = HandleStats()
        s.callsLastYear = 2
        return ["4155550100": s]
    }
    #expect(opened == [.calls])
    #expect(interactions["4155550100"]?.callsLastYear == 2)
    #expect(reports.map(\.name) == ["Messages", "Call history", "Mail"])
    let skipped = reports.filter { $0.skipped }.map { $0.detail }
    #expect(skipped == [
        "Switched off, so it was never opened.",
        "Switched off, so it was never opened.",
    ])
}

@Test
func everythingOffStillWorksFromContactsAlone() {
    let (interactions, reports) = SparkScan.gather([]) { _ in
        Issue.record("no source should be read")
        return [:]
    }
    #expect(interactions.isEmpty)
    let allSkipped = reports.allSatisfy { $0.skipped }
    #expect(allSkipped)
}

@Test
func anUnreadableSourceIsSkippedNotFatal() {
    let (interactions, reports) = SparkScan.gather([.mail, .messages]) { source in
        if source == .mail { throw SourceError.notSetUp("Apple Mail isn't set up on this Mac.") }
        var s = HandleStats()
        s.sentLastYear = 1
        return ["jane@example.com": s]
    }
    #expect(interactions.count == 1)
    let mail = reports.first { $0.name == "Mail" }
    #expect(mail?.detail == "Apple Mail isn't set up on this Mac.")
}

// MARK: - LinkedIn

private func connection(_ first: String, _ last: String, email: String? = nil, company: String? = nil) -> LinkedInConnection {
    LinkedInConnection(
        firstName: first, lastName: last, email: email, company: company, position: nil,
        profileURL: URL(string: "https://www.linkedin.com/in/\(first.lowercased())-\(last.lowercased())"),
        connectedOn: nil
    )
}

private let recommended = LinkedInSignals.parse(recommendationsReceived: """
    First Name,Last Name,Company,Job Title,Text,Creation Date,Status
    Jane,Doe,Acme,CTO,"Great",01/01/25,VISIBLE
    Sam,Lee,Acme,PM,"Great",01/01/25,VISIBLE
    Pat,Lee,Acme,PM,"Great",01/01/25,VISIBLE
    Robin,Ray,Acme,PM,"Great",01/01/25,VISIBLE
    """)

@Test
func linkedInMatchesByEmailThenUniqueNameOnly() {
    let cards = [
        ContactCard(name: "Jane Doe", handles: ["jane@example.com"]),
        ContactCard(name: "Sam Lee", handles: ["4155550100"]),
        ContactCard(name: "Pat Lee", handles: ["4155550101"]),
        ContactCard(name: "Pat Lee", handles: ["4155550102"]),   // two Pat Lees
        ContactCard(name: "Someone Else", handles: ["robin.work@example.com"]),
    ]
    let matched = LinkedInSource.match([
        connection("Jane", "Doe"),                                       // by unique name
        connection("Sam", "Lee"),                                        // by unique name
        connection("Pat", "Lee"),                                        // ambiguous: skipped
        connection("Robin", "Ray", email: "Robin.Work@example.com"),     // by email, despite the name
        connection("Not", "Saved"),                                      // not in Contacts
    ], signals: recommended, cards: cards, now: now)

    #expect(Set(matched.keys) == [0, 1, 4])
    #expect(matched[0]?.reasons == ["Recommended you"])
}

@Test
func linkedInLiftsButCannotOutrankRealConversation() {
    let heavy = LinkedInSuggestion(score: 20, reasons: ["Recommended you", "Colleague at Acme", "Endorsed you 5×"])
    let onlyLinkedIn = Recommender(now: now).score(card: acquaintance, stats: HandleStats(), linkedIn: heavy)
    #expect(onlyLinkedIn.score == Recommender.linkedInCap)
    #expect(onlyLinkedIn.reasons == ["LinkedIn: Recommended you", "LinkedIn: Colleague at Acme", "LinkedIn: Endorsed you 5×"])

    let talks = Recommender(now: now).score(card: acquaintance, stats: janeStats())
    #expect(talks.score > onlyLinkedIn.score)
}

@Test
func linkedInSwitchedOffOrMissingFolderIsReportedNotRead() {
    let off = SparkScan.readLinkedIn(URL(fileURLWithPath: "/nonexistent"), enabled: false, cards: [], now: now)
    #expect(off.0.isEmpty)
    #expect(off.1.detail == "Switched off, so it was never opened.")

    let noFolder = SparkScan.readLinkedIn(nil, enabled: true, cards: [], now: now)
    #expect(noFolder.1.skipped)
    #expect(noFolder.1.detail == "No export folder chosen.")
}

@Test
func linkedInReadsAnExportFolderEndToEnd() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("li-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try """
    Notes:
    "Some preamble"

    First Name,Last Name,URL,Email Address,Company,Position,Connected On
    Jane,Doe,https://www.linkedin.com/in/jane-doe,,Acme,CTO,01 Feb 2024
    Not,Saved,https://www.linkedin.com/in/not-saved,,Acme,PM,01 Feb 2024
    """.write(to: folder.appendingPathComponent("Connections.csv"), atomically: true, encoding: .utf8)
    try """
    First Name,Last Name,Company,Job Title,Text,Creation Date,Status
    Jane,Doe,Acme,CTO,"Great",01/01/25,VISIBLE
    """.write(to: folder.appendingPathComponent("Recommendations_Received.csv"), atomically: true, encoding: .utf8)

    let (byCard, report) = SparkScan.readLinkedIn(folder, enabled: true, cards: [jane], now: now)
    #expect(!report.skipped)
    #expect(report.detail.hasPrefix("2 connections; 1 of your contacts"))
    #expect(byCard[0]?.reasons == ["Recommended you"])

    // And it flows through to the file: Jane gains a LinkedIn reason.
    let result = Recommender(now: now).build(cards: [jane], interactions: ["4155550100": janeStats()], linkedIn: byCard)
    #expect(result.file.people.first?.reasons.contains("LinkedIn: Recommended you") == true)
}
