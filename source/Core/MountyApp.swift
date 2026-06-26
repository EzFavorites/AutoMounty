import SwiftUI
import AutoMountyModel

@main
struct MountyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        MenuBarExtra("Mounty", systemImage: "server.rack") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)
        
        Window("Mounty Configuration", id: "main") {
            ContentView()
        }
        
        Window("Network Discovery", id: "discovery") {
            DiscoveryView()
        }
        .windowResizability(.contentSize)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private let mainWindowOpenDelay: TimeInterval = 0.5
    private let bonjourTimeout: TimeInterval = 5.0
    private var bonjourTimeoutWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist sets LSUIElement=true; app starts as menu bar only.

        // Set default preferences
        UserDefaults.standard.register(defaults: [
            "AutoUpdateBonjourIP": true,
            "LaunchOpenMainWindow": true,
            "ShowDockIcon": true
        ])

        // Handle Dock Icon preference
        let showDockIcon = UserDefaults.standard.bool(forKey: "ShowDockIcon")
        if showDockIcon {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }

        // Handle Open Main Window preference
        if UserDefaults.standard.bool(forKey: "LaunchOpenMainWindow") {
            DispatchQueue.main.asyncAfter(deadline: .now() + mainWindowOpenDelay) {
                if let url = URL(string: "mounty://main") {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        // Scan for existing network mounts on background queue
        Task { @MainActor in
            MountyManager.shared.scanAndImportMounts()
        }

        // Check if we should update IPs before starting monitor
        if UserDefaults.standard.bool(forKey: "AutoUpdateBonjourIP") {
            Logger.info("Starting Bonjour IP update check...")

            // Use a cancellable work item for timeout safety
            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.bonjourTimeoutWorkItem = nil
                Logger.error("Bonjour IP update check timed out. Forcing start.")
                MountyMonitor.shared.start()
            }
            bonjourTimeoutWorkItem = timeoutWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + bonjourTimeout, execute: timeoutWorkItem)

            NetworkDiscovery.shared.updateBonjourIPs(for: ConfigManager.shared.profiles) { [weak self] in
                // Cancel timeout if Bonjour finished first
                self?.bonjourTimeoutWorkItem?.cancel()
                self?.bonjourTimeoutWorkItem = nil
                Logger.info("Bonjour IP update check completed.")
                MountyMonitor.shared.start()
            }
        } else {
            MountyMonitor.shared.start()
        }
    }
}
