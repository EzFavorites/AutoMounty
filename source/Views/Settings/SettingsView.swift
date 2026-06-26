import SwiftUI
import AutoMountyModel

struct SettingsView: View {
    @ObservedObject var logger = Logger.shared
    @ObservedObject var systemInfo = SystemInfoService.shared
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("System Settings")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            Form {
                Section(header: Text("General")) {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { systemInfo.isLaunchAtLoginEnabled },
                        set: { systemInfo.setLaunchAtLoginEnabled($0) }
                    ))
                    
                    Toggle("Open Main Window on Launch", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "LaunchOpenMainWindow") },
                        set: { UserDefaults.standard.set($0, forKey: "LaunchOpenMainWindow") }
                    ))
                    
                    Toggle("Show Icon in Dock", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "ShowDockIcon") },
                        set: { newValue in
                            UserDefaults.standard.set(newValue, forKey: "ShowDockIcon")
                            let policy: NSApplication.ActivationPolicy = newValue ? .regular : .accessory
                            NSApp.setActivationPolicy(policy)
                            if newValue {
                                NSApp.activate(ignoringOtherApps: true)
                            }
                        }
                    ))
                    
                    Toggle("Auto Update Server IP via Bonjour", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "AutoUpdateBonjourIP") },
                        set: { UserDefaults.standard.set($0, forKey: "AutoUpdateBonjourIP") }
                    ))
                }
                
                Section(header: Text("Logging")) {
                    HStack {
                        Picker("Log Level", selection: $logger.logLevel) {
                            ForEach(LogLevel.allCases) { level in
                                Text(LocalizedStringKey(level.displayName)).tag(level)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 250)
                        
                        Spacer()
                        
                        Button("Open Log Folder") {
                            logger.openLogFolder()
                        }
                    }
                }
            }
            .padding()
            .frame(width: 450)
            
            Divider()
            
            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
    }
}
