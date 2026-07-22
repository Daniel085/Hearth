import EventKit
import Contacts
import Foundation

/// Finds upcoming shared calendar events, matched to Hearth's people.
///
/// A shared event is one of the strongest, most specific reasons to reach out —
/// "dinner with Joe Thursday" beats "you haven't seen Joe in a while" because the user
/// can act on it concretely. This feeds `ScoringInput.upcomingEventDate`.
///
/// Named `…Service` and free of Core Data: it reads the calendar and returns plain
/// values keyed by a matcher the caller supplies, so it can be tested without a store.
@MainActor
final class CalendarService {
    private let store = EKEventStore()

    enum Access {
        case granted
        case denied
        case notDetermined
    }

    var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// Requests full calendar access. Returns whether it was granted.
    ///
    /// Calendar is optional, like photos: the app is fully usable without it, cadence and
    /// birthdays still work, and denial is not a dead end.
    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// The next shared event for each matched person within `horizon` days.
    ///
    /// Returns the *soonest* event per person, since that's the one worth prompting
    /// about. The `match` closure maps a set of attendee identities to a person id —
    /// supplied by the caller so this stays independent of how people are stored.
    func upcomingEvents(
        within horizonDays: Int = 14,
        now: Date = Date(),
        match: (EventAttendees) -> UUID?
    ) -> [UUID: UpcomingEvent] {
        guard access == .granted else { return [:] }

        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .day, value: horizonDays, to: now) else {
            return [:]
        }

        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate)

        var result: [UUID: UpcomingEvent] = [:]

        for event in events {
            // All-day birthdays and holidays are noise here; we surface birthdays through
            // the dedicated signal, not as "events".
            guard !event.isAllDay, let start = event.startDate, start >= now else { continue }
            guard let attendees = event.attendees, !attendees.isEmpty else { continue }

            let identities = EventAttendees(
                names: attendees.compactMap(\.name),
                emails: attendees.compactMap { emailAddress(from: $0) }
            )

            guard let personID = match(identities) else { continue }

            let candidate = UpcomingEvent(
                date: start,
                title: event.title ?? "You have plans"
            )

            // Keep the soonest event per person.
            if let existing = result[personID], existing.date <= candidate.date { continue }
            result[personID] = candidate
        }

        return result
    }

    /// Pulls an email out of a participant's `mailto:` URL, if present.
    private func emailAddress(from participant: EKParticipant) -> String? {
        let url = participant.url
        guard url.scheme == "mailto" else { return nil }
        let email = url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        return email.isEmpty ? nil : email
    }
}

/// The identities on one event, for matching against a person.
struct EventAttendees: Sendable {
    let names: [String]
    let emails: [String]
}

struct UpcomingEvent: Sendable, Equatable {
    let date: Date
    let title: String
}
