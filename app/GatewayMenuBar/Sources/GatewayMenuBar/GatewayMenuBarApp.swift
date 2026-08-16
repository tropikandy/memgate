import SwiftUI

// MenuBarExtra's content closure is lazy -- SwiftUI only builds it the
// first time the user clicks the status item, so .onAppear there never
// fires at launch (found live: polling never started, icon stuck on
// "unreachable"). An AppDelegate's applicationDidFinishLaunching is the
// reliable place to kick off background work regardless of what's shown.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let client = GatewayClient()

    func applicationDidFinishLaunching(_ notification: Notification) {
        client.start()
    }
}

@main
struct GatewayMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(client: appDelegate.client)
        } label: {
            MenuBarLabelView(client: appDelegate.client)
        }
        .menuBarExtraStyle(.window)
    }
}
