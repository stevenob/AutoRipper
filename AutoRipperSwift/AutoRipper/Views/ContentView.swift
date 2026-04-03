import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            Text("Rip — coming soon")
                .tabItem { Label("Rip", systemImage: "opticaldisc") }
            Text("Encode — coming soon")
                .tabItem { Label("Encode", systemImage: "film") }
            Text("Scrape — coming soon")
                .tabItem { Label("Scrape", systemImage: "photo.on.rectangle") }
            Text("Queue — coming soon")
                .tabItem { Label("Queue", systemImage: "list.bullet") }
            Text("Settings — coming soon")
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}
