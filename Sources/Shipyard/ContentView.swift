import AppKit
import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            // Not NSApp.applicationIconImage: NSApp is nil under `swift test`.
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .frame(width: 96, height: 96)
            Text("Shipyard")
                .font(.largeTitle.bold())
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }
}
