import SwiftUI
import Photos

/// One person: how close they are, how often you want to be in touch, and what Hearth
/// knows about them.
///
/// The tier and cadence controls matter most. Closeness is user-assigned by design —
/// photo frequency is a poor proxy, since you photograph a wedding you attended once far
/// more than a sibling you call weekly — so this screen is where the ranking actually
/// gets its signal. Until someone sets a tier, everyone sits at the default and the
/// Launchpad is guessing.
struct PersonDetailView: View {
    let personID: UUID

    @StateObject private var store = PersonStore()
    @Environment(\.dismiss) private var dismiss

    @State private var person: CDPerson?
    @State private var tier: RelationshipTier = .close
    @State private var usesCustomCadence = false
    @State private var cadenceDays: Double = 30
    @State private var editingName = false
    @State private var draftName = ""
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            if let person {
                closenessSection(person)
                cadenceSection(person)
                factsSection(person)
                faceGroupsSection(person)
                historySection(person)
                dangerSection(person)
            } else {
                Text("This person no longer exists.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(person?.displayName ?? "Person")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if person != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Rename") {
                        draftName = person?.displayName ?? ""
                        editingName = true
                    }
                }
            }
        }
        .alert("Rename", isPresented: $editingName) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let person { store.setDisplayName(draftName, for: person) }
                reload()
            }
        }
        .confirmationDialog(
            "Delete this person?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let person { store.delete(person) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes them from Hearth, along with the face groups and history Hearth has recorded. Your photos and contacts are not affected.")
        }
        .onAppear(perform: reload)
    }

    // MARK: - Sections

    private func closenessSection(_ person: CDPerson) -> some View {
        Section {
            Picker("Closeness", selection: $tier) {
                ForEach(RelationshipTier.allCases, id: \.self) { tier in
                    Text(tier.label).tag(tier)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: tier) { _, newValue in
                store.setTier(newValue, for: person)
                if !usesCustomCadence {
                    cadenceDays = Double(newValue.defaultCadenceDays)
                }
            }
        } header: {
            Text("How close are you?")
        } footer: {
            Text("You set this, not Hearth. How often someone appears in your photos says little about how much they matter — you might photograph a wedding you attended once far more than a sibling you call every week.")
        }
    }

    private func cadenceSection(_ person: CDPerson) -> some View {
        Section {
            Toggle("Set my own interval", isOn: $usesCustomCadence)
                .onChange(of: usesCustomCadence) { _, isOn in
                    store.setCadenceTargetDays(isOn ? Int(cadenceDays) : nil, for: person)
                }

            if usesCustomCadence {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Every \(Int(cadenceDays)) days")
                        .font(.subheadline.weight(.medium))
                    Slider(value: $cadenceDays, in: 1...365, step: 1) { editing in
                        if !editing {
                            store.setCadenceTargetDays(Int(cadenceDays), for: person)
                        }
                    }
                }
            } else {
                LabeledContent("Suggested", value: "every \(tier.defaultCadenceDays) days")
            }
        } header: {
            Text("How often")
        } footer: {
            Text("Hearth suggests an interval based on closeness. Override it for anyone with their own rhythm.")
        }
    }

    private func factsSection(_ person: CDPerson) -> some View {
        Section("What Hearth knows") {
            if let birthday = person.birthday {
                LabeledContent("Birthday", value: birthday.formatted(.dateTime.month(.wide).day()))
            }

            let photos = store.photoCount(for: person)
            if photos > 0 {
                LabeledContent("Photos", value: "\(photos)")
            }

            if let range = store.photoDateRange(for: person) {
                LabeledContent("Seen between", value: spanDescription(range))
            }

            if let last = store.lastInteraction(for: person) {
                // Hedged wording throughout: iOS exposes no call or message history, so
                // Hearth knows when it last *noticed* contact, not when contact happened.
                LabeledContent("Last noted", value: last.formatted(.relative(presentation: .named)))
            } else {
                LabeledContent("Last noted", value: "Nothing yet")
            }

            if person.contactIdentifier == nil {
                Label("Not linked to a contact", systemImage: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func faceGroupsSection(_ person: CDPerson) -> some View {
        let groups = store.faceGroups(for: person)
        if !groups.isEmpty {
            Section {
                ForEach(groups, id: \.id) { group in
                    FaceGroupRow(group: group, store: store)
                        .swipeActions {
                            Button("Not them", role: .destructive) {
                                store.detach(group)
                                reload()
                            }
                        }
                }
            } header: {
                Text("Face groups")
            } footer: {
                Text(groups.count == 1
                     ? "One group of photos Hearth matched to this person."
                     : "\(groups.count) groups. A face that changes over time — a baby especially — shows up as several, and that's expected. Swipe to remove one that isn't them.")
            }
        }
    }

    @ViewBuilder
    private func historySection(_ person: CDPerson) -> some View {
        let interactions = store.interactions(for: person)
        if !interactions.isEmpty {
            Section {
                ForEach(interactions.prefix(10), id: \.id) { interaction in
                    HStack {
                        Label(
                            InteractionKind(rawValue: interaction.kind)?.label ?? "Contact",
                            systemImage: InteractionKind(rawValue: interaction.kind)?.symbol ?? "circle"
                        )
                        Spacer()
                        Text(interaction.date.formatted(.dateTime.month().day()))
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                }
            } header: {
                Text("History")
            } footer: {
                Text("What Hearth noticed. Calls and messages made outside the app aren't visible to it — iOS doesn't share that.")
            }
        }
    }

    private func dangerSection(_ person: CDPerson) -> some View {
        Section {
            Toggle("Mute", isOn: Binding(
                get: { person.isMuted },
                set: { store.setMuted($0, for: person); reload() }
            ))
            Button("Delete person", role: .destructive) { confirmingDelete = true }
        } footer: {
            Text("Muting keeps everything but stops them appearing on Today.")
        }
    }

    // MARK: - Helpers

    private func reload() {
        person = store.allPeople().first { $0.id == personID }
        guard let person else { return }
        tier = RelationshipTier(rawValue: person.tier) ?? .close
        if let custom = person.cadenceTargetDays?.intValue {
            usesCustomCadence = true
            cadenceDays = Double(custom)
        } else {
            usesCustomCadence = false
            cadenceDays = Double(tier.defaultCadenceDays)
        }
    }

    private func spanDescription(_ range: ClosedRange<Date>) -> String {
        let formatted = { (date: Date) in date.formatted(.dateTime.month(.abbreviated).year()) }
        let start = formatted(range.lowerBound)
        let end = formatted(range.upperBound)
        return start == end ? start : "\(start) – \(end)"
    }
}

/// One face group, with a strip of thumbnails so it's obvious who it is.
struct FaceGroupRow: View {
    let group: CDFaceGroup
    let store: PersonStore

    @State private var thumbnails: [UIImage] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(spanText)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(store.appearances(in: group).count) photos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !thumbnails.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .task { await loadThumbnails() }
    }

    private var spanText: String {
        guard let earliest = group.earliestCapture else { return "Undated" }
        let latest = group.latestCapture ?? earliest
        let f = { (d: Date) in d.formatted(.dateTime.month(.abbreviated).year()) }
        return f(earliest) == f(latest) ? f(earliest) : "\(f(earliest)) – \(f(latest))"
    }

    private func loadThumbnails() async {
        guard thumbnails.isEmpty else { return }
        let identifiers = store.appearances(in: group).prefix(6).map(\.localIdentifier)
        guard !identifiers.isEmpty else { return }

        var loaded: [UIImage] = []
        for identifier in identifiers {
            if let image = await loadImage(identifier) { loaded.append(image) }
        }
        thumbnails = loaded
    }

    private func loadImage(_ identifier: String) async -> UIImage? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else { return nil }

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .opportunistic
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 156, height: 156),
                contentMode: .aspectFill, options: options
            ) { image, info in
                guard !resumed else { return }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}

extension InteractionKind {
    var label: String {
        switch self {
        case .call: "Call"
        case .message: "Message"
        case .email: "Email"
        case .inPerson: "In person"
        case .calendarEvent: "Event"
        case .manual: "Noted"
        }
    }

    var symbol: String {
        switch self {
        case .call: "phone"
        case .message: "message"
        case .email: "envelope"
        case .inPerson: "person.2"
        case .calendarEvent: "calendar"
        case .manual: "pencil"
        }
    }
}
