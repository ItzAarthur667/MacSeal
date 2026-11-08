import SwiftUI
import AppKit
import ServiceManagement

@main
struct MyApp: App {
    @NSApplicationDelegateAdaptor(MacSealAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            DashboardView()
        }
    }
}

@MainActor
final class MacSealAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        synchronizeLaunchAtLogin()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if UserDefaults.standard.bool(forKey: "macseal.isSealed") {
            return .terminateCancel
        }

        return .terminateNow
    }

    private func synchronizeLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }

        let defaults = UserDefaults.standard
        let preferenceKey = "macseal.launchAtLogin"
        if defaults.object(forKey: preferenceKey) == nil {
            defaults.set(false, forKey: preferenceKey)
        }

        let service = SMAppService.mainApp

        do {
            if defaults.bool(forKey: preferenceKey) {
                if service.status == .notRegistered {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            print("Unable to update MacSeal login item: \(error)")
        }
    }
}
