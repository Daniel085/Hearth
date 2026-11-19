import AppKit
import Contacts
import HearthSparkCore
import SwiftUI

/// Drives the app: check permissions, scan, review, send, then report what was kept.
///
/// Results live only in this object's memory. Quitting the app discards them; the only
/// thing ever written is the Spark file the user chooses to send or save.
@MainActor
final class SparkModel: NSObject, ObservableObject {
    enum Stage { case permissions, scanning, review, confirmSent, done }

    /// How the last AirDrop went, as far as macOS reports it.
    enum SendOutcome: Equatable {
        case sent
        case failed(String)
    }

    @Published var stage: Stage = .permissions
    @Published var contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
    @Published var fullDiskAccess = Permissions.hasFullDiskAccess
    @Published var scan: SparkScan?
    /// Indices into `scan.result.file.people` the user is keeping. All, to start.
    @Published var included: Set<Int> = []
    /// Closeness the user changed in the review, by index. Absent means "as suggested".
    @Published var tierOverrides: [Int: SparkTier] = [:]
    /// Sources the user has switched on. All, to start; held for this session only,
    /// like everything else.
    @Published var enabledSources = Set(SparkSource.handleSources)
    /// The unzipped LinkedIn export the user chose. LinkedIn stays off until there is one.
    @Published var linkedInFolder: URL?
    @Published var errorMessage: String?
    @Published var keptMessage = ""
    @Published var sendOutcome: SendOutcome?
    /// Set when the AirDrop sheet was closed without sending — usually because the
    /// iPhone didn't show up.
    @Published var airDropCancelled = false

    /// The file waiting to be confirmed as received. Kept until the user says it
    /// arrived, so a failed or invisible AirDrop never loses it.
    @Published private(set) var pendingFile: URL?

    // MARK: Permissions

    func refreshPermissions() {
        contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
        fullDiskAccess = Permissions.hasFullDiskAccess
    }

    /// Full Disk Access is only needed for the optional sources.
    /// (LinkedIn is a folder the user picks, which needs no special permission.)
    var needsFullDiskAccess: Bool { !enabledSources.isDisjoint(with: SparkSource.handleSources) }

    /// Asks for the LinkedIn export folder. Returns false if the user cancels.
    @discardableResult
    func chooseLinkedInFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose your unzipped LinkedIn data export — the folder that contains Connections.csv."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        linkedInFolder = url
        return true
    }

    // macOS has no "limited" Contacts access; it's all or nothing.
    var contactsGranted: Bool { contactsStatus == .authorized }

    func requestContacts() {
        CNContactStore().requestAccess(for: .contacts) { _, _ in
            Task { @MainActor in self.refreshPermissions() }
        }
    }

    enum SettingsPane: String {
        case contacts = "Privacy_Contacts"
        case fullDiskAccess = "Privacy_AllFiles"
    }

    func open(_ pane: SettingsPane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Scan

    func runScan() {
        stage = .scanning
        errorMessage = nil
        let sources = enabledSources
        let linkedInFolder = linkedInFolder
        Task.detached(priority: .userInitiated) {
            do {
                let scan = try SparkScan.run(sources: sources, linkedInFolder: linkedInFolder)
                await MainActor.run {
                    self.scan = scan
                    self.included = Set(scan.result.file.people.indices)
                    self.tierOverrides = [:]
                    self.stage = .review
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.stage = .permissions
                }
            }
        }
    }

    /// Exactly what would be sent: the file with only the ticked people.
    var fileToSend: SparkFile? {
        scan?.result.file.reviewed(keeping: included, tiers: tierOverrides)
    }

    func tier(at index: Int) -> SparkTier? {
        tierOverrides[index] ?? scan?.result.file.people[index].suggestedTier
    }

    func setTier(_ tier: SparkTier, at index: Int) {
        // Choosing the suggested tier again clears the override rather than storing it.
        if tier == scan?.result.file.people[index].suggestedTier {
            tierOverrides[index] = nil
        } else {
            tierOverrides[index] = tier
        }
    }

    var fileContents: String {
        guard let data = try? fileToSend?.encoded() else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Send or save

    /// Writes the current file to a private temporary folder and opens AirDrop.
    ///
    /// The copy is *not* deleted when AirDrop finishes. macOS reports success when the
    /// transfer is handed off, not when Hearth has it, and an iPhone that never showed
    /// up would otherwise mean a lost file. It's deleted when the user confirms it
    /// arrived — or discards, or quits.
    func sendViaAirDrop() {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            errorMessage = "AirDrop isn't available on this Mac. Use Save File instead."
            return
        }
        do {
            let url = try writePendingFile()
            airDropCancelled = false
            service.delegate = self
            service.perform(withItems: [url])
        } catch {
            errorMessage = "Couldn't prepare the file: \(error.localizedDescription)"
        }
    }

    /// Always rewrites, so a send after changes in the review carries those changes.
    private func writePendingFile() throws -> URL {
        guard let data = try fileToSend?.encoded() else { throw CocoaError(.fileWriteUnknown) }
        let folder = pendingFile?.deletingLastPathComponent()
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("HearthSpark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent("Hearth Spark.hearthspark")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        pendingFile = url
        return url
    }

    /// The user confirmed Hearth has the file: delete the Mac's copy, and check it's gone.
    func confirmReceivedAndDelete() {
        guard let file = pendingFile else { return }
        let folder = file.deletingLastPathComponent()
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            errorMessage = "Couldn't delete the copy at \(file.path): \(error.localizedDescription)"
            return
        }
        guard !FileManager.default.fileExists(atPath: file.path) else {
            errorMessage = "The copy at \(file.path) is still there. Delete it in Finder."
            return
        }
        pendingFile = nil
        finish(kept: "Nothing. Hearth on your iPhone has the file, and the copy on this Mac was deleted.")
    }

    func backToReview() {
        sendOutcome = nil
        stage = .review
    }

    func saveAs() {
        guard let data = try? fileToSend?.encoded() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Hearth Spark.hearthspark"
        panel.message = "This file holds the people listed in the review. Delete it once it's in Hearth on your iPhone."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            // The saved file supersedes any temporary AirDrop copy.
            discardPendingFile()
            finish(kept: "Only the file you saved: \(url.path) (\(Self.size(data))). Delete it once it's in Hearth on your iPhone.")
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }

    func discard() {
        discardPendingFile()
        finish(kept: "Nothing. You discarded the results without sending or saving a file.")
    }

    /// Deletes an unconfirmed copy. Used when the user discards, saves elsewhere, or
    /// chooses to quit anyway.
    func discardPendingFile() {
        if let folder = pendingFile?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: folder)
        }
        pendingFile = nil
    }

    private func finish(kept: String) {
        // Drop the scan from memory now rather than at quit.
        scan = nil
        included = []
        tierOverrides = [:]
        sendOutcome = nil
        airDropCancelled = false
        keptMessage = kept
        stage = .done
    }

    static func size(_ data: Data) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}

extension SparkModel: NSSharingServiceDelegate {
    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        Task { @MainActor in
            self.sendOutcome = .sent
            self.stage = .confirmSent
        }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        Task { @MainActor in
            if (error as NSError).code == NSUserCancelledError {
                // Closed without sending — often because the iPhone never appeared.
                // Stay on the review, keep the file, and offer help.
                self.airDropCancelled = true
            } else {
                self.sendOutcome = .failed(error.localizedDescription)
                self.stage = .confirmSent
            }
        }
    }
}
