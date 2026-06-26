import SwiftUI
import AutoMountyModel
import AppKit

struct ProfileDetailView: View {
    @Binding var profile: MountProfile
    @ObservedObject var netMonitor = MountyMonitor.shared
    @ObservedObject var mounter = MountyManager.shared
    
    @State private var draftProfile: MountProfile?
    @State private var runningApps: [String] = []
    @State private var installedApps: [String] = []
    @State private var showingDeleteAlert = false
    
    // Check if there are unsaved changes (excluding isEnabled which is synced immediately)
    var hasChanges: Bool {
        guard let draft = draftProfile else { return false }
        // Create copies to compare, ignoring isEnabled since it's handled separately
        var p1 = profile
        var p2 = draft
        p1.isEnabled = true
        p2.isEnabled = true
        return p1 != p2
    }
    
    var body: some View {
        Form {
            if let _ = draftProfile {
                Section("General") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("Enabled", isOn: Binding(
                                get: { profile.isEnabled },
                                set: { newValue in
                                    profile.isEnabled = newValue
                                    draftProfile?.isEnabled = newValue
                                    if newValue {
                                        MountyMonitor.shared.checkAutoMount(for: profile)
                                    } else {
                                        mounter.unmount(profileId: profile.id)
                                    }
                                }
                            ))
                            .controlSize(.small)
                            
                            Spacer()
                            
                            if mounter.currentStatus[profile.id] == .mounted {
                                Button("Unmount") {
                                    mounter.unmount(profileId: profile.id)
                                }
                                .controlSize(.small)
                            } else {
                                Button("Mount") {
                                    mounter.mount(profile: profile) { _ in }
                                }
                                .controlSize(.small)
                                .disabled(profile.serverURL.isEmpty || hasChanges)
                                .help(hasChanges ? LocalizedStringKey("Save changes before mounting") : LocalizedStringKey("Mount this share"))
                            }
                        }
                        
                        if hasChanges {
                            Text("Configuration has unsaved changes.")
                                .foregroundColor(.orange)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        
                        if case .error(let msg) = mounter.currentStatus[profile.id] {
                            Text(msg)
                                .foregroundColor(.red)
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                
                // Bind to draftProfile (safe: guarded by outer if-let above)
                ServerConfigurationView(profile: Binding($draftProfile)!, allowProtocolChange: false)
                
                RuleConfigurationView(
                    profile: Binding($draftProfile)!,
                    runningApps: runningApps,
                    installedApps: installedApps
                )
                
                AutomationView(profile: Binding($draftProfile)!)
                
                Section {
                    if ConfigManager.shared.profiles.contains(where: { $0.id == profile.id }) {
                        Button(role: .destructive) {
                            showingDeleteAlert = true
                        } label: {
                            HStack {
                                Spacer()
                                Text(LocalizedStringKey("Delete Profile"))
                                Spacer()
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .formStyle(.grouped)
        .padding()
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                let isNew = !ConfigManager.shared.profiles.contains(where: { $0.id == profile.id })
                
                if hasChanges || isNew {
                    if !isNew {
                        Button(LocalizedStringKey("Revert")) {
                            draftProfile = profile
                        }
                    }
                    
                    Button(LocalizedStringKey("Save")) {
                        saveChanges()
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(draftProfile?.serverURL.isEmpty ?? true)
                }
            }
        }
        .alert(LocalizedStringKey("Delete Profile"), isPresented: $showingDeleteAlert) {
            Button(LocalizedStringKey("Delete"), role: .destructive) {
                ConfigManager.shared.delete(id: profile.id)
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) { }
        } message: {
            Text(LocalizedStringKey("Are you sure you want to delete this profile? This action cannot be undone."))
        }
        .task(id: profile.id) {
            // Load profile into draft
            draftProfile = profile
            await refreshData()
        }
    }
    
    private func saveChanges() {
        guard let draft = draftProfile else { return }
        
        let needsReconnect = (draft.serverURL != profile.serverURL || draft.mountPoint != profile.mountPoint) && mounter.currentStatus[profile.id] == .mounted
        
        var newProfile = draft
        newProfile.isEnabled = profile.isEnabled 
        profile = newProfile
        
        // Handle Reconnect if needed
        if needsReconnect {
            Logger.info("Configuration changed significantly, reconnecting...")
            mounter.unmount(profileId: profile.id)
            Task {
                try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)
                mounter.mount(profile: profile) { _ in }
            }
        } else if profile.isEnabled && profile.autoMount && mounter.currentStatus[profile.id] != .mounted {
            Logger.info("Configuration saved, checking auto-mount rules...")
            MountyMonitor.shared.checkAutoMount(for: profile)
        }
    }
    
    private func refreshData() async {
        let apps = SystemInfoService.shared.getRunningApplications()
        let installed = await Task.detached {
            await SystemInfoService.shared.getInstalledApplications()
        }.value
        
        runningApps = apps
        installedApps = installed
    }
}
