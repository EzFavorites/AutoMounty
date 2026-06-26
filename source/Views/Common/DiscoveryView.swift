import SwiftUI
import AutoMountyModel

struct DiscoveryView: View {
    @StateObject private var discovery = NetworkDiscovery.shared
    @Environment(\.dismiss) var dismiss
    @Environment(\.openWindow) var openWindow
    @State private var connectingServerId: UUID? // Track which server is connecting
    
    var body: some View {
        VStack(spacing: 0) {
            List {
                if discovery.discoveredServers.isEmpty {
                    HStack {
                        Spacer()
                        Text(LocalizedStringKey("Searching for local servers..."))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding()
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(discovery.discoveredServers) { server in
                        HStack {
                            Image(systemName: iconFor(server.displayType))
                                .font(.title2)
                                .foregroundStyle(.blue)
                                .frame(width: 30)
                            
                            VStack(alignment: .leading) {
                                Text(server.name)
                                    .font(.headline)
                                HStack {
                                    Text(LocalizedStringKey(server.displayType))
                                    if let ip = server.ipAddress {
                                        Text("•")
                                        Text(ip)
                                    }
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if connectingServerId == server.id {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 40)
                            } else {
                                Button(LocalizedStringKey("Add")) {
                                    addServer(server)
                                }
                                .buttonStyle(.bordered)
                                .disabled(connectingServerId != nil) // Disable all buttons when one is connecting
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.plain)
            
            Divider()
            
            HStack {
                Spacer()
                Button(LocalizedStringKey("Close")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 360, height: 320)
        .onAppear {
            discovery.startDiscovery()
        }
        .onDisappear {
            discovery.stopDiscovery()
        }
        .toolbar {
            if discovery.discoveredServers.isEmpty {
                ToolbarItem {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }
    
    private func iconFor(_ type: String) -> String {
        switch type {
        case "SMB": return "server.rack"
        case "AFP": return "xserve"
        case "WebDAV": return "globe"
        default: return "server.rack"
        }
    }
    
    private func addServer(_ server: NetworkDiscovery.DiscoveredServer) {
        // Construct URL
        // Always prefer IP address. If IP is missing, it means resolution failed.
        // We should try to use IP if available, otherwise fallback to local hostname but warn or expect issues.
        // User requested to fix "local domain connection issues", so we strongly prefer IP.
        
        let url: String
        
        if let ip = server.ipAddress {
            url = "\(server.urlScheme)://\(ip)"
        } else {
            // Fallback
            Logger.error("Attempting to add server \(server.name) without resolved IP. Connection might fail.")
            let host = "\(server.name).\(server.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))"
            url = "\(server.urlScheme)://\(host)"
        }
        
        // Set connecting state
        connectingServerId = server.id
        
        // Use shared service
        MountyManager.shared.importDiscoveredServer(url: url, bonjourHostname: server.name) { result in
            Task { @MainActor in
                self.connectingServerId = nil
                
                switch result {
                case .success(let profile):
                    self.finishAdding(profile: profile)
                    
                case .failure(let error):
                    Logger.error("Failed to add server: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func finishAdding(profile: MountProfile) {
        // Visual feedback
        dismiss()
        // Open main window to show the new profile
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        // Notify to select the new profile
        NotificationCenter.default.post(
            name: .selectMountProfile,
            object: nil,
            userInfo: ["id": profile.id]
        )
    }
}
