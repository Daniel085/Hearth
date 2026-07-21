import SwiftUI

/// The Launchpad — who needs attention, why, and what to do about it.
///
/// A deliberately quiet surface. You come here to start a conversation; it does not
/// interrupt you. Cards state their reason plainly and offer a direct action.
struct LaunchpadView: View {
    @StateObject private var model = LaunchpadModel()

    var body: some View {
        Group {
            if model.people.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(model.people) { person in
                        LaunchpadCard(person: person) { action in
                            model.perform(action, for: person)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Today")
        .onAppear { model.refresh() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nobody needs you today", systemImage: "checkmark.circle")
        } description: {
            Text("Hearth will let you know when someone's worth reaching out to.")
        }
    }
}

/// One person, one reason, one action.
struct LaunchpadCard: View {
    let person: ScoredPerson
    let onAction: (LaunchpadAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(.tint.opacity(0.15))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Text(initials)
                            .font(.headline)
                            .foregroundStyle(.tint)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(person.displayName)
                        .font(.headline)
                    if let headline = person.headline {
                        Text(headline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                ForEach(LaunchpadAction.allCases, id: \.self) { action in
                    Button {
                        onAction(action)
                    } label: {
                        Label(action.label, systemImage: action.symbol)
                            .labelStyle(.iconOnly)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("\(action.label) \(person.displayName)")
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private var initials: String {
        person.displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }
}

enum LaunchpadAction: CaseIterable, Hashable {
    case call, message, email, snooze

    var label: String {
        switch self {
        case .call: "Call"
        case .message: "Message"
        case .email: "Email"
        case .snooze: "Not now"
        }
    }

    var symbol: String {
        switch self {
        case .call: "phone"
        case .message: "message"
        case .email: "envelope"
        case .snooze: "clock"
        }
    }
}

@MainActor
final class LaunchpadModel: ObservableObject {
    @Published private(set) var people: [ScoredPerson] = []

    private let scorer = RelationshipScorer()

    /// Recomputes the ranking.
    ///
    /// Currently reads sample data — the Person records this will eventually query are
    /// created by the labelling flow, which doesn't exist yet. Wiring this to Core Data
    /// is the next step; the scoring itself is real and unit-tested.
    func refresh() {
        people = scorer.rank(SampleData.people(now: Date()), now: Date())
    }

    func perform(_ action: LaunchpadAction, for person: ScoredPerson) {
        // Actions are not yet wired to the system. Launching a call or composing a
        // message needs the Person to carry a real phone number or address, which
        // arrives with the labelling flow. Deliberately inert rather than
        // half-implemented — a button that silently does nothing is worse than one
        // that isn't there yet.
        switch action {
        case .call, .message, .email, .snooze:
            break
        }
    }
}

/// Placeholder people so the Launchpad can be seen and judged before the labelling flow
/// exists. Not shipped behaviour — replaced by a Core Data fetch.
private enum SampleData {
    static func people(now: Date) -> [ScoringInput] {
        let cal = Calendar.current
        func ago(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }
        func ahead(_ d: Double) -> Date { now.addingTimeInterval(d * 86_400) }

        var birthday = DateComponents()
        birthday.year = 1988
        birthday.month = cal.component(.month, from: now.addingTimeInterval(2 * 86_400))
        birthday.day = cal.component(.day, from: now.addingTimeInterval(2 * 86_400))

        return [
            ScoringInput(
                personID: UUID(), displayName: "Sarah Chen", tier: .close,
                cadenceTargetDays: nil, lastInteraction: ago(21),
                birthday: cal.date(from: birthday)
            ),
            ScoringInput(
                personID: UUID(), displayName: "Joe Ramirez", tier: .keptWarm,
                cadenceTargetDays: nil, lastInteraction: ago(140), birthday: nil,
                isNearAssociatedPlace: true, nearbyPlaceName: "Joe's Coffee"
            ),
            ScoringInput(
                personID: UUID(), displayName: "Mum", tier: .innerCircle,
                cadenceTargetDays: nil, lastInteraction: ago(12), birthday: nil,
                upcomingEventDate: ahead(3), upcomingEventTitle: "Sunday lunch"
            ),
            ScoringInput(
                personID: UUID(), displayName: "Priya Nair", tier: .close,
                cadenceTargetDays: nil, lastInteraction: ago(75), birthday: nil,
                unactionedAppearances: 3
            ),
            ScoringInput(
                personID: UUID(), displayName: "Tom Beckett", tier: .distant,
                cadenceTargetDays: nil, lastInteraction: ago(400), birthday: nil
            ),
        ]
    }
}
