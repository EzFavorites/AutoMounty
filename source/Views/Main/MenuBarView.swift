import SwiftUI
import AutoMountyModel

struct MenuBarView: View {
    @ObservedObject var config = ConfigManager.shared
    @Environment(\.openWindow) var openWindow
    
    var groupedProfiles: [ProfileGroup] {
        ProfileGrouper.group(config.profiles)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "server.rack")
                    .font(.system(size: 16, weight: .semibold))
                Text("Mounty")
                    .font(.headline)
                Spacer()
                
                // Add Server Button
                Button(action: {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    
                    // Delay slightly to ensure window is loaded
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NotificationCenter.default.post(name: .addNewProfile, object: nil)
                    }
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .help(Text("Add Server"))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                
                // Scan Server Button
                Button(action: {
                    openWindow(id: "discovery")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }) {
                    Image(systemName: "network")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .help(Text("Discover Local Servers"))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                
                // Settings Button
                Button(action: {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .help(Text("Settings"))
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            // Content
            if config.profiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.plus")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No Mounts Configured")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Button("Add Mount...") {
                        openWindow(id: "main")
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedProfiles) { group in
                            // Section Header
                            HStack {
                                Text(LocalizedStringKey(group.name))
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                            
                            ForEach(group.profiles) { profile in
                                MountRowView(profile: profile)
                                Divider()
                                    .padding(.leading, 16)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            
            Divider()
            
            // Footer
            HStack {
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 320, height: 400)
    }
}

struct MountRowView: View {
    let profile: MountProfile
    @ObservedObject var mounter = MountyManager.shared
    @State private var isHovering = false
    @Environment(\.openWindow) var openWindow
    
    // Helper to extract protocol
    var protocolName: String {
        if let url = URL(string: profile.serverURL), let scheme = url.scheme {
            return scheme.uppercased()
        }
        return "NEW"
    }
    
    var status: MountStatus {
        mounter.currentStatus[profile.id] ?? .unmounted
    }
    
    var body: some View {
        HStack(spacing: 12) {
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
            
            // Name
            Text(profile.displayName)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
            
            Spacer()
            
            // Status & Action
            HStack(spacing: 4) {
                switch status {
                case .mounted:
                    Text("Mounted")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    
                    // Open Folder Button
                    Button(action: {
                        if let path = mounter.mountPaths[profile.id] {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                        }
                    }) {
                        Image(systemName: "folder")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                    .help(Text("Open in Finder"))
                    
                    // Unmount Button
                    Button(action: {
                        mounter.unmount(profileId: profile.id)
                    }) {
                        Image(systemName: "eject.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                    .help(Text("Unmount"))
                    
                case .mounting:
                    Text("Connecting...")
                        .font(.footnote)
                        .foregroundColor(.orange)
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 8, height: 8)
                    
                case .error(let errorMessage):
                    Text("Error")
                        .font(.footnote)
                        .foregroundColor(.red)
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                        .help(Text(errorMessage))
                    
                    // Retry Button
                    Button(action: {
                        mounter.mount(profile: profile) { _ in }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                    
                case .unmounted:
                    Text("Available")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 8, height: 8)
                        
                    // Mount Button
                    Button(action: {
                        mounter.mount(profile: profile) { _ in }
                    }) {
                        Image(systemName: "play.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isHovering ? Color.secondary.opacity(0.1) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture(count: 2) {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(
                name: .selectMountProfile,
                object: nil,
                userInfo: ["id": profile.id]
            )
        }
    }
}
