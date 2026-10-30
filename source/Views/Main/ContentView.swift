import SwiftUI
import AutoMountyModel

struct ContentView: View {
    @ObservedObject var config = ConfigManager.shared
    @State private var showingSettings = false
    @State private var selectedProfileId: UUID?
    @State private var newProfile: MountProfile? // Draft profile not yet added
    
    var groupedProfiles: [ProfileGroup] {
        ProfileGrouper.group(config.profiles)
    }
    
    private func addNewProfile() {
        // If already creating, just select it
        if let existingDraft = newProfile {
            selectedProfileId = existingDraft.id
            return
        }
        
        let profile = MountProfile(serverURL: "", mountPoint: "", bonjourHostname: nil)
        newProfile = profile
        // Select the new profile (this won't select anything in the list as it's not there yet, 
        // but it will trigger the detail view)
        selectedProfileId = profile.id
    }
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedProfileId) {
                ForEach(groupedProfiles) { group in
                    Section(header: Text(LocalizedStringKey(group.name))) {
                        ForEach(group.profiles) { profile in
                            NavigationLink(value: profile.id) {
                                SidebarRow(profile: profile)
                            }
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    config.delete(id: profile.id)
                                    if selectedProfileId == profile.id {
                                        selectedProfileId = nil
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Mounts")
            .listStyle(.sidebar)
            .toolbar {
                Button(action: { showingSettings = true }) {
                    Label("Settings", systemImage: "gear")
                }
                Button(action: addNewProfile) {
                    Label("Add Share", systemImage: "plus")
                }
            }
        } detail: {
            if let draft = newProfile, selectedProfileId == draft.id {
                 ProfileDetailView(profile: Binding(
                     get: { draft },
                     set: { updatedProfile in
                         // This closure is called when RuleEditorView commits changes (Save)
                         // Add to ConfigManager
                         config.add(profile: updatedProfile)
                         
                         // Clear draft state
                         newProfile = nil
                         
                         // Ensure selection remains on the now-persisted profile
                         // Use async to let the list update
                         let id = updatedProfile.id
                         DispatchQueue.main.async {
                             selectedProfileId = id
                         }
                     }
                 ))
                 .id(draft.id)
            } else if let id = selectedProfileId, let index = config.profiles.firstIndex(where: { $0.id == id }) {
                ProfileDetailView(profile: $config.profiles[index])
                    .id(id) // Force refresh when switching
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "server.rack")
                    .font(.system(size: 64))
                    .foregroundColor(.secondary.opacity(0.5))
                    Text("Select a Mount Profile")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Button("Add New Share") {
                        addNewProfile()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .onChange(of: selectedProfileId) { oldValue, newValue in
            // Discard draft if we navigate away
            if let draft = newProfile, newValue != draft.id {
                newProfile = nil
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .addNewProfile)) { _ in
            addNewProfile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showingSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectMountProfile)) { notification in
            if let id = notification.userInfo?["id"] as? UUID {
                // Delay slightly to ensure list is updated
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    selectedProfileId = id
                }
            }
        }
    }
}

struct SidebarRow: View {
    let profile: MountProfile
    @ObservedObject var mounter = MountyManager.shared
    
    var statusColor: Color {
        switch mounter.currentStatus[profile.id] {
        case .mounted: return .green
        case .mounting: return .orange
        case .error: return .red
        default: return .gray.opacity(0.3)
        }
    }
    
    var protocolName: String {
        if let url = URL(string: profile.serverURL), let scheme = url.scheme {
            return scheme.uppercased()
        }
        return "NEW"
    }

    var body: some View {
        HStack {
            // Protocol Badge
            Text(protocolName)
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                )
                .foregroundColor(.secondary)
                .frame(width: 50)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                if !profile.mountPoint.isEmpty {
                    Text(profile.mountPoint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            
            Spacer()
            
            if profile.isEnabled && profile.autoMount {
                Image(systemName: "bolt.fill")
                    .font(.caption2)
                    .foregroundColor(.yellow)
                    .help("Auto Mount Enabled")
            }
            
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.5), radius: 2, x: 0, y: 0)
        }
        .padding(.vertical, 4)
    }
}
