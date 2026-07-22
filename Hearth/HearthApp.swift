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
    }
}
