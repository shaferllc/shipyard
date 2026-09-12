import AppKit
import ShaferAccount
import SwiftUI

@main
struct ShipyardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Shipyard", id: "main") {
            ContentView()
        }
        .commands { ShaferAccountCommands() }

        Settings {
            AccountView()
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
