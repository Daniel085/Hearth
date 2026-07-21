import SwiftUI
import Photos

/// The scan screen — first step of onboarding and, right now, the validation harness.
struct ScanView: View {
    @StateObject private var scanner = PhotoLibraryScanner()
    @State private var sampleLimit: Double = 300
    @State private var scanTask: Task<Void, Never>?

    var body: some View {
        Group {
            switch scanner.state {
            case .idle:
                introView
            case .requestingPermission:
                progressView("Requesting photo access…")
            case .denied:
                deniedView
            case let .scanning(processed, total, faces):
                scanningView(processed: processed, total: total, faces: faces)
            case .clustering:
                progressView("Grouping faces…")
            case let .finished(summary):
                ResultsView(scanner: scanner, summary: summary)
            case let .failed(message):
                ContentUnavailableView("Scan failed", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
        .navigationTitle("Hearth")
        .onDisappear { scanTask?.cancel() }
    }

    private var introView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.2.circle")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Find the people in your photos")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Hearth looks through a sample of your photos to find faces that appear often. Everything stays on this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 4) {
                Text("Photos to scan: \(Int(sampleLimit))")
                    .font(.subheadline.weight(.medium))
                Slider(value: $sampleLimit, in: 50...1000, step: 50)
                Text("A larger sample gives a better result but takes longer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 4) {
                Text("Crop padding: \(scanner.cropPadding, format: .percent.precision(.fractionLength(0)))")
                    .font(.subheadline.weight(.medium))
                Slider(value: $scanner.cropPadding, in: 0...0.75, step: 0.05)
                Text("How much around each face to include. 25% beat 0% on this library; higher values are untested and eventually pull in background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            Button {
                scanTask = Task { await scanner.scan(sampleLimit: Int(sampleLimit)) }
            } label: {
                Text("Start scan").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)

            Spacer()
        }
    }

    private func scanningView(processed: Int, total: Int, faces: Int) -> some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView(value: Double(processed), total: Double(total))
                .progressViewStyle(.linear)
                .padding(.horizontal, 40)

            Text("\(processed) of \(total) photos")
                .font(.headline)
            Text("\(faces) faces found")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Cancel", role: .cancel) { scanTask?.cancel() }
                .padding(.top)
            Spacer()
        }
    }

    private func progressView(_ label: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
            Text(label).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var deniedView: some View {
        ContentUnavailableView {
            Label("Photo access needed", systemImage: "lock")
        } description: {
            Text("Hearth needs access to your photos to find the people in them. Nothing leaves your device.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
