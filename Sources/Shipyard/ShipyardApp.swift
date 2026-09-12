import AppKit
import ShaferAccount
import SwiftUI

@main
struct ShipyardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var fleet = Fleet()

    var body: some Scene {
        Window("Shipyard", id: "main") {
            ContentView()
                .environmentObject(fleet)
        }
        .defaultSize(width: 980, height: 640)
        .commands {
            ShaferAccountCommands()
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await fleet.refresh() } }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            TabView {
                SettingsView()
                    .tabItem { Label("Folders", systemImage: "folder") }
                AccountView()
                    .tabItem { Label("Account", systemImage: "person.crop.circle") }
            }
            .frame(width: 460)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launch finishes, so a shipyard://activate that launched the app is caught.
        ShaferAccount.configure(product: "shipyard", name: "Shipyard")
    }

    /// `shipyard://activate` from shafer.llc; anything else is the app's own.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where !ShaferAccount.handle(url) {
            NSLog("Shipyard: unhandled URL %@", url.absoluteString)
        }
    }
}
