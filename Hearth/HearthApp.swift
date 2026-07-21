import SwiftUI

@main
struct HearthApp: App {
    private let persistence = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.managedObjectContext, persistence.container.viewContext)
        }
    }
}

struct RootView: View {
    var body: some View {
        NavigationStack {
            ScanView()
        }
    }
}
