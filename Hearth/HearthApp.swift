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
    @State private var incomingSpark: IncomingSpark?

    var body: some View {
        TabView {
            NavigationStack {
                LaunchpadView()
            }
            .tabItem { Label("Today", systemImage: "house") }

            NavigationStack {
                PeopleListView()
            }
            .tabItem { Label("People", systemImage: "person.2") }

            NavigationStack {
                ScanView()
            }
            .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
        }
        // A Hearth Spark file AirDropped from the user's Mac, or opened from Files.
        .onOpenURL { url in
            if url.pathExtension.lowercased() == "hearthspark" {
                incomingSpark = IncomingSpark(url: url)
            }
        }
        .sheet(item: $incomingSpark) { SparkImportView(url: $0.url) }
    }
}
