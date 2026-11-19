import HearthSparkCore
import SwiftUI

@main
struct HearthSparkApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Hearth Spark", id: "main") {
            ContentView()
                .environmentObject(appDelegate.model)
                .frame(minWidth: 620, minHeight: 640)
                // Permissions change in System Settings while the app is open.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    appDelegate.model.refreshPermissions()
                }
        }
        .windowResizability(.contentMinSize)
    }
}

/// Owns the model so quitting can check for an unconfirmed file first.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = SparkModel()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A file that hasn't been confirmed as received is never silently left behind or
    /// silently lost: the user decides.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.pendingFile != nil else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Your Hearth file hasn't been confirmed as received"
        alert.informativeText = "If you quit now, the copy on this Mac is deleted. You can run Hearth Spark again anytime to make a new one."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete and Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        model.discardPendingFile()
        return .terminateNow
    }
}

struct ContentView: View {
    @EnvironmentObject var model: SparkModel

    var body: some View {
        Group {
            switch model.stage {
            case .permissions: PermissionsView()
            case .scanning: ScanningView()
            case .review: ReviewView()
            case .confirmSent: ConfirmSentView()
            case .done: DoneView()
            }
        }
        .alert("Hearth Spark", isPresented: Binding(
            get: { model.errorMessage != nil && model.stage != .permissions },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Permissions

struct PermissionsView: View {
    @EnvironmentObject var model: SparkModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hearth Spark").font(.largeTitle.bold())
                    Text("Hearth Spark looks at your contacts, messages, calls and email on this Mac — and your LinkedIn export, if you add it — to recommend the people to keep close in Hearth.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Promise(
                            icon: "lock.laptopcomputer",
                            title: "Stays on your Mac",
                            detail: "Everything is processed here. Nothing is ever sent to a server — Hearth Spark doesn't use the internet at all."
                        )
                        Promise(
                            icon: "text.bubble",
                            title: "Who and when, never what",
                            detail: "It sees who you message, call and email, and when. It never reads what was said."
                        )
                        Promise(
                            icon: "eye",
                            title: "Nothing hidden",
                            detail: "You review everything it found, and choose who's included, before anything goes to Hearth."
                        )
                        Promise(
                            icon: "trash",
                            title: "Nothing kept",
                            detail: "No data is saved except the file you choose to send. At the end, it shows you exactly what's left."
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("What to read").font(.headline)
                    Text("Switch off anything you'd rather Hearth Spark didn't look at. A source that's off is never opened.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: .constant(true)) {
                            SourceLabel(name: "Contacts", blurb: "Always needed, to know who's who.")
                        }
                        .disabled(true)
                        ForEach(SparkSource.allCases, id: \.self) { source in
                            Toggle(isOn: sourceBinding(source)) {
                                SourceLabel(name: source.name, blurb: source.blurb)
                            }
                            if source == .linkedIn, let folder = model.linkedInFolder {
                                HStack {
                                    Label(folder.lastPathComponent, systemImage: "folder")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Button("Change…") { model.chooseLinkedInFolder() }
                                        .controlSize(.small)
                                }
                                .padding(.leading, 4)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                Text("Permissions").font(.headline)

                PermissionRow(
                    title: "Contacts",
                    detail: "To know who's who. Only names, numbers and emails are read, plus whether a birthday, address, nickname or relation is filled in.",
                    granted: model.contactsGranted,
                    required: true
                ) {
                    if model.contactsStatus == .notDetermined {
                        Button("Allow…") { model.requestContacts() }
                    } else {
                        Button("Open Settings") { model.open(.contacts) }
                    }
                }

                if model.needsFullDiskAccess {
                    PermissionRow(
                        title: "Full Disk Access",
                        detail: "To count \(enabledNames). macOS has no narrower permission for these. Add Hearth Spark with the + button, then reopen it. It's only used while a scan runs.",
                        granted: model.fullDiskAccess,
                        required: false
                    ) {
                        Button("Open Settings") { model.open(.fullDiskAccess) }
                    }
                } else {
                    Label("Full Disk Access isn't needed with only Contacts switched on.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }

                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    if model.needsFullDiskAccess, !model.fullDiskAccess, model.contactsGranted {
                        Text("Without Full Disk Access, suggestions come from Contacts alone.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button("Find My People") { model.runScan() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .disabled(!model.contactsGranted)
                }
            }
            .padding(28)
        }
    }
}

/// One line of the welcome screen's promise: a bold claim, then the plain detail.
struct Promise: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension PermissionsView {
    private func sourceBinding(_ source: SparkSource) -> Binding<Bool> {
        Binding(
            get: { model.enabledSources.contains(source) },
            set: { on in
                // Switching LinkedIn on needs the export folder; cancelling leaves it off.
                if on, source == .linkedIn, model.linkedInFolder == nil, !model.chooseLinkedInFolder() { return }
                if on { model.enabledSources.insert(source) } else { model.enabledSources.remove(source) }
            }
        )
    }

    /// "Messages, call history and Mail", for whichever are switched on.
    private var enabledNames: String {
        let names = SparkSource.handleSources.filter(model.enabledSources.contains).map { $0 == .calls ? "call history" : $0.name }
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}

struct SourceLabel: View {
    let name: String
    let blurb: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.body.weight(.medium))
            Text(blurb).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PermissionRow<Action: View>: View {
    let title: String
    let detail: String
    let granted: Bool
    let required: Bool
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(granted ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.body.weight(.semibold))
                    Text(required ? "Required" : "Recommended")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted { action() }
        }
    }
}

// MARK: - Scanning

struct ScanningView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Counting who you talk to…")
            Text("Only who and when — never what was said. Nothing leaves this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Review

struct ReviewView: View {
    @EnvironmentObject var model: SparkModel
    @State private var showingContents = false

    var body: some View {
        if let scan = model.scan {
            VStack(spacing: 0) {
                List {
                    Section("What was read") {
                        ForEach(scan.reports, id: \.name) { report in
                            Label {
                                VStack(alignment: .leading) {
                                    Text(report.name).font(.body.weight(.medium))
                                    Text(report.skipped ? "Skipped — \(report.detail)" : report.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: report.skipped ? "minus.circle" : "checkmark.circle")
                                    .foregroundStyle(report.skipped ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                            }
                        }
                        Text("Message text, email contents, subjects and attachments were never opened.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    let people = scan.result.file.people
                    // Grouped by the tier as it stands now, so moving someone moves
                    // their row to the new section.
                    ForEach(SparkTier.allCases, id: \.self) { tier in
                        let indices = people.indices.filter { model.tier(at: $0) == tier }
                        if !indices.isEmpty {
                            Section("\(tier.label) (\(indices.count))") {
                                ForEach(indices, id: \.self) { index in
                                    PersonRow(
                                        person: people[index],
                                        included: binding(for: index),
                                        tier: tierBinding(for: index)
                                    )
                                }
                            }
                        }
                    }

                    if scan.result.unmatchedHandles > 0 {
                        Section {
                            Text("Left out: \(scan.result.unmatchedHandles) numbers and emails you message, call or email that aren't in your Contacts. They're never named or sent.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        DisclosureGroup("Exact file contents", isExpanded: $showingContents) {
                            Text(model.fileContents)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } footer: {
                        Text("Per person: name, suggested closeness, month of last contact, the reasons above, and salted hashes of their numbers and emails so your iPhone can match them. No message content, no exact dates.")
                    }
                }

                Divider()
                if model.airDropCancelled {
                    Label {
                        Text("iPhone not showing up? Unlock it, open Control Center and set AirDrop to Contacts Only or Everyone, then try again. Or use Save File and move it with Finder or iCloud Drive. The file is kept until you confirm Hearth has it.")
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .top], 16)
                }
                HStack {
                    Button("Discard") { model.discard() }
                    Spacer()
                    Text("\(model.included.count) of \(scan.result.file.people.count) people")
                        .foregroundStyle(.secondary)
                    Button("Save File…") { model.saveAs() }
                        .disabled(model.included.isEmpty)
                    Button("Send to iPhone with AirDrop") { model.sendViaAirDrop() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.included.isEmpty)
                }
                .padding(16)
            }
        }
    }

    private func tierBinding(for index: Int) -> Binding<SparkTier> {
        Binding(
            get: { model.tier(at: index) ?? .keptWarm },
            set: { model.setTier($0, at: index) }
        )
    }

    private func binding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { model.included.contains(index) },
            set: { if $0 { model.included.insert(index) } else { model.included.remove(index) } }
        )
    }
}

struct PersonRow: View {
    let person: SparkPerson
    @Binding var included: Bool
    @Binding var tier: SparkTier

    var body: some View {
        HStack(alignment: .top) {
            details
            Spacer()
            Picker("Closeness", selection: $tier) {
                ForEach(SparkTier.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(!included)
        }
    }

    private var details: some View {
        Toggle(isOn: $included) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(person.name).font(.body.weight(.medium))
                    if let month = person.lastContactMonth {
                        Text("last \(month)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !person.reasons.isEmpty {
                    Text(person.reasons.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if tier != person.suggestedTier {
                    Text("You changed this from \(person.suggestedTier.label)")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
        }
        .toggleStyle(.checkbox)
        .opacity(included ? 1 : 0.5)
    }
}

// MARK: - Confirm sent

/// After AirDrop: the file stays on the Mac until the user confirms Hearth has it.
struct ConfirmSentView: View {
    @EnvironmentObject var model: SparkModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.sendOutcome {
            case .failed(let reason):
                Text("AirDrop didn't finish").font(.largeTitle.bold())
                Text(reason).foregroundStyle(.secondary)
                Text("Your file is safe on this Mac. Try again, or save it and move it to your iPhone another way.")
            default:
                Text("Did it arrive?").font(.largeTitle.bold())
                Text("Check your iPhone: Hearth should have opened the file. AirDrop says it was sent, but only you can see whether it landed.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox {
                Label {
                    Text("A copy is kept on this Mac until you confirm, so nothing is lost if AirDrop didn't make it.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "doc.badge.clock")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            if model.sendOutcome == .sent {
                Button {
                    model.confirmReceivedAndDelete()
                } label: {
                    Label("It's in Hearth — delete the copy on this Mac", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }

            if model.airDropCancelled {
                Label("iPhone not showing up? Unlock it, open Control Center and set AirDrop to Contacts Only or Everyone, then Send Again.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Back to Review") { model.backToReview() }
                Spacer()
                Button("Save File Instead…") { model.saveAs() }
                Button("Send Again") { model.sendViaAirDrop() }
            }
            Spacer()
        }
        .padding(28)
    }
}

// MARK: - Done

struct DoneView: View {
    @EnvironmentObject var model: SparkModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Done").font(.largeTitle.bold())
            GroupBox("What Hearth Spark kept on this Mac") {
                Text(model.keptMessage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }
            Text("The scan results were only ever in memory and have been cleared. There's no cache and no log.")
                .foregroundStyle(.secondary)
            Text("Run Hearth Spark again anytime to refresh your list.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
            }
            Spacer()
        }
        .padding(28)
    }
}
