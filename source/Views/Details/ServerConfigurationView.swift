import SwiftUI
import AutoMountyModel
import AppKit

// MARK: - Server Configuration Components

enum ProtocolType: String, CaseIterable, Identifiable {
    case smb = "SMB"
    case afp = "AFP"
    case nfs = "NFS"
    case webdav = "WebDAV (HTTP)"
    case webdavs = "WebDAV (HTTPS)"
    case ftp = "FTP"
    
    var scheme: String {
        switch self {
        case .smb: return "smb"
        case .afp: return "afp"
        case .nfs: return "nfs"
        case .webdav: return "http"
        case .webdavs: return "https"
        case .ftp: return "ftp"
        }
    }
    
    var id: String { rawValue }
}

struct ServerConfigurationView: View {
    @Binding var profile: MountProfile
    var allowProtocolChange: Bool = true
    
    @State private var selectedProtocol: ProtocolType = .smb
    @State private var host: String = ""
    @State private var port: String = ""
    @State private var username: String = ""
    @State private var path: String = ""
    @State private var availableShares: [String] = []
    @State private var isFetchingShares: Bool = false
    @State private var lastFetchHost: String = ""
    @State private var showFetchError: Bool = false
    @State private var fetchErrorMsg: String = ""
    @State private var isDetailsExpanded: Bool = false
    
    // Raw URL Input
    @State private var rawURL: String = ""
    
    var body: some View {
        Section("Server Configuration") {
            // Part 1: Main URL Input
            LabeledContent {
                TextField("", text: $rawURL, prompt: Text("Server URL (e.g. smb://server/share)"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onChange(of: rawURL) { _, newValue in
                        parseRawURL(newValue)
                    }
            } label: {
                Text("Server URL")
            }
            .help("Enter the URL of the server you want to connect to.\nSupported protocols: smb, afp, nfs, ftp, webdav")
            
            // Part 2: Advanced Options Toggle Row
            HStack {
                Spacer()
                
                Button {
                    withAnimation(.snappy) {
                        isDetailsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(isDetailsExpanded ? LocalizedStringKey("Hide Advanced Options") : LocalizedStringKey("Show Advanced Options"))
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isDetailsExpanded ? 90 : 0))
                    }
                    .foregroundStyle(.secondary)
                    .font(.callout)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
            
            // Part 3: Advanced Details Rows
            if isDetailsExpanded {
                // Protocol
                LabeledContent("Protocol") {
                    if allowProtocolChange {
                        Picker("", selection: $selectedProtocol) {
                            ForEach(ProtocolType.allCases) { type in
                                Text(LocalizedStringKey(type.rawValue)).tag(type)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: selectedProtocol) { _, _ in updateURL() }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // Read Only mode
                        if selectedProtocol == .webdav || selectedProtocol == .webdavs {
                            Picker("", selection: $selectedProtocol) {
                                Text(LocalizedStringKey(ProtocolType.webdav.rawValue)).tag(ProtocolType.webdav)
                                Text(LocalizedStringKey(ProtocolType.webdavs.rawValue)).tag(ProtocolType.webdavs)
                            }
                            .labelsHidden()
                            .onChange(of: selectedProtocol) { _, _ in updateURL() }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(LocalizedStringKey(selectedProtocol.rawValue))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                
                // Host
                LabeledContent("Host") {
                    TextField("", text: $host, prompt: Text("IP or Hostname"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onChange(of: host) { _, _ in updateURL() }
                }
                
                // Port
                LabeledContent("Port") {
                    TextField("", text: $port, prompt: Text("Default"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onChange(of: port) { _, _ in updateURL() }
                }
                
                // Path / Share
                let showFetch = selectedProtocol == .smb
                let showMenu = selectedProtocol == .smb && !availableShares.isEmpty && host == lastFetchHost
                
                LabeledContent("Shared Folder") {
                    HStack(spacing: 8) {
                        TextField("", text: $path, prompt: Text("/path/to/share"))
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .onChange(of: path) { _, _ in updateURL() }
                        
                        // Actions
                        HStack(spacing: 4) {
                            if showMenu {
                                Menu {
                                    ForEach(availableShares, id: \.self) { share in
                                        let sharePath = "/" + share
                                        let isConfigured = isShareConfigured(sharePath)
                                        
                                        Button {
                                            path = sharePath
                                            updateURL()
                                        } label: {
                                            if isConfigured {
                                                Text("\(share) \(NSLocalizedString("(Configured)", comment: ""))")
                                            } else {
                                                Text(share)
                                            }
                                        }
                                        .disabled(isConfigured)
                                    }
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .frame(width: Metrics.accessoryWidth)
                            } else {
                                Color.clear.frame(width: Metrics.accessoryWidth, height: 1)
                            }
                            
                            if showFetch {
                                Button {
                                    fetchSMBShares()
                                } label: {
                                    if isFetchingShares {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                    }
                                }
                                .buttonStyle(.plain)
                                .frame(width: Metrics.accessoryWidth)
                                .disabled(host.isEmpty || isFetchingShares)
                                .help(LocalizedStringKey("Fetch SMB Shares"))
                                .popover(isPresented: $showFetchError) {
                                    Text(fetchErrorMsg)
                                        .padding()
                                        .frame(width: 250)
                                        .multilineTextAlignment(.leading)
                                }
                            } else {
                                Color.clear.frame(width: Metrics.accessoryWidth, height: 1)
                            }
                        }
                        .frame(width: 60, alignment: .trailing)
                    }
                }
                
                // Username
                LabeledContent("Username") {
                    TextField("", text: $username, prompt: Text("Optional"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onChange(of: username) { _, _ in updateURL() }
                }
                
                // Local Mount Point
                LabeledContent("Local Mount Point") {
                    HStack(spacing: 8) {
                        TextField("", text: $profile.mountPoint, prompt: Text(defaultMountPoint))
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                        
                        // Actions
                        HStack(spacing: 4) {
                            Button {
                                selectMountPoint()
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.plain)
                            .frame(width: Metrics.accessoryWidth)
                            .help(LocalizedStringKey("Select local mount point..."))
                        }
                        .frame(width: 60, alignment: .trailing)
                    }
                }
            }
        }
        .onChange(of: profile.serverURL, initial: true) { _, _ in
            // Sync UI if profile is updated externally
            parseURL()
            // Also sync rawURL
            if rawURL != profile.serverURL {
                rawURL = profile.serverURL
            }
        }
    }
    
    // Calculate default mount point for placeholder
    private var defaultMountPoint: String {
        if let url = URL(string: profile.serverURL) {
            let lastComponent = url.lastPathComponent
            if !lastComponent.isEmpty && lastComponent != "/" {
                return "/Volumes/" + lastComponent
            }
            if let host = url.host, !host.isEmpty {
                return "/Volumes/" + host
            }
        }
        return "/Volumes/Share"
    }
    
    private func parseRawURL(_ urlString: String) {
        // Basic heuristic to detect protocol if typed manually
        let input = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Auto-detect protocol if just typing host
        if !input.contains("://") {
            // No scheme yet, default to SMB unless we detect otherwise?
            // For now, let's not force change the protocol in UI until we have a scheme,
            // or we can assume smb if it looks like an IP or hostname
            // But updating 'profile.serverURL' needs a scheme.
            
            // Just update the profile with what we have, but if it's missing scheme, 
            // parseURL might fail to extract components properly.
            // Let's rely on standard URL parsing.
        }
        
        // If user typed a scheme, update selectedProtocol
        if let url = URL(string: input), let scheme = url.scheme {
             if let type = ProtocolType.allCases.first(where: { $0.scheme == scheme }) {
                 if selectedProtocol != type { selectedProtocol = type }
             }
        }
        
        // Update the profile directly from raw input
        // But we also need to update the breakdown fields (Host, Port, etc)
        // So we can re-use parseURL logic but based on this input string
        
        // Temporarily set profile URL to parse components
        // Note: We don't want to trigger the onChange(of: profile.serverURL) loop
        // But since we are inside rawURL onChange, we should be careful.
        
        if profile.serverURL != input {
            profile.serverURL = input
            
            // Now extract components to update UI fields
            // We can reuse the logic from parseURL but apply it to the input string directly
            if let url = URL(string: input) {
                // Host
                let newHost = url.host ?? ""
                if host != newHost { host = newHost }
                
                // Port
                let newPort = url.port.map { String($0) } ?? ""
                if port != newPort { port = newPort }
                
                // User
                let newUser = url.user ?? ""
                if username != newUser { username = newUser }
                
                // Path
                let newPath = url.path
                if path != newPath { path = newPath }
            }
        }
    }

    private func parseURL() {
        guard let url = URL(string: profile.serverURL), let scheme = url.scheme else { return }
        
        // Protocol
        if let type = ProtocolType.allCases.first(where: { $0.scheme == scheme }) {
            // Only update if changed to avoid unnecessary cycles
            if selectedProtocol != type {
                selectedProtocol = type
            }
        } else if scheme == "http" {
             if selectedProtocol != .webdav { selectedProtocol = .webdav }
        } else if scheme == "https" {
             if selectedProtocol != .webdavs { selectedProtocol = .webdavs }
        } else {
             if selectedProtocol != .smb { selectedProtocol = .smb }
        }
        
        // Host
        let newHost = url.host ?? ""
        if host != newHost { host = newHost }
        
        // Port
        let newPort = url.port.map { String($0) } ?? ""
        if port != newPort { port = newPort }
        
        // User
        let newUser = url.user ?? ""
        if username != newUser { username = newUser }
        
        // Path
        let newPath = url.path
        if path != newPath { path = newPath }
    }
    
    private func updateURL() {
        var components = URLComponents()
        components.scheme = selectedProtocol.scheme
        components.host = host.isEmpty ? nil : host
        if let p = Int(port) {
            components.port = p
        }
        if !username.isEmpty {
            components.user = username
        }
        if !path.isEmpty {
            components.path = path.hasPrefix("/") ? path : "/" + path
        } else {
            components.path = ""
        }
        
        if let string = components.string {
            // Only update if actually changed to avoid loop
            if profile.serverURL != string {
                profile.serverURL = string
            }
            if rawURL != string {
                rawURL = string
            }
        }
    }
    
    private func fetchSMBShares() {
        guard !host.isEmpty else { return }
        isFetchingShares = true
        lastFetchHost = host
        showFetchError = false
        
        Task {
            var finalShares: [String]? = nil
            var errorMsg: String? = nil
            
            // 1. Try with -N (No prompt), using current username if available
            // This relies on Keychain or no-auth
            if let shares = await runSMBUtil(host: host, username: username, options: ["-N"]) {
                finalShares = shares
            } else {
                // 2. If failed, try Guest access (-g -N)
                // Note: -N is still needed to prevent interactive prompt
                if let shares = await runSMBUtil(host: host, username: username, options: ["-N", "-g"]) {
                    finalShares = shares
                } else {
                    errorMsg = NSLocalizedString("Could not list shares. Please ensure you have connected to this server at least once to save credentials, or that Guest access is enabled.", comment: "SMB Share Fetch Error")
                }
            }
            
            isFetchingShares = false
            if let shares = finalShares {
                self.availableShares = shares.sorted()
                if shares.isEmpty {
                    self.fetchErrorMsg = NSLocalizedString("No shares found.", comment: "No SMB Shares")
                    self.showFetchError = true
                }
            } else {
                self.availableShares = []
                if let msg = errorMsg {
                    self.fetchErrorMsg = msg
                    self.showFetchError = true
                }
            }
        }
    }
    
    private func runSMBUtil(host: String, username: String, options: [String]) async -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/smbutil")

        var urlString = "//"
        if !username.isEmpty {
            urlString += "\(username)@"
        }
        urlString += host

        var args = ["view"]
        args.append(contentsOf: options)
        args.append(urlString)

        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            let exitCode = await MountyManager.waitForProcess(process, timeout: 15)

            if exitCode == 0 {
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    return parseSMBOutput(output)
                }
                return []
            } else {
                return nil
            }
        } catch {
            Logger.error("SMB Fetch Error: \(error)")
            return nil
        }
    }

    private func parseSMBOutput(_ output: String) -> [String] {
        // Output format:
        // Share        Type       Comments
        // -------------------------------
        // sharename    Disk       Description
        
        var shares: [String] = []
        let lines = output.components(separatedBy: .newlines)
        
        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2 {
                // Check if 2nd column is 'Disk'
                // The output columns are variable width, but split by space usually works
                // unless share name has spaces.
                // smbutil view output is a bit tricky with spaces.
                // But typically: "Sharename" "Type" "Comment"
                // If Sharename has spaces, it might be messy.
                // Let's assume standard simple output for now or try to be smarter.
                
                // Heuristic: Find "Disk" keyword
                if let typeIndex = parts.firstIndex(of: "Disk") {
                    if typeIndex > 0 {
                        // Everything before "Disk" is likely the name
                        let nameParts = parts[0..<typeIndex]
                        let name = nameParts.joined(separator: " ")
                        shares.append(name)
                    }
                }
            }
        }
        return shares
    }
    
    @MainActor
    private func isShareConfigured(_ sharePath: String) -> Bool {
        // Build a candidate URL from current host + sharePath
        guard let currentUrl = URL(string: self.profile.serverURL) else { return false }
        var components = URLComponents()
        components.scheme = currentUrl.scheme
        components.host = currentUrl.host
        components.port = currentUrl.port
        components.path = sharePath
        guard let candidateURL = components.string else { return false }

        return ConfigManager.shared.profiles.contains { profile in
            MountProfile.normalizedURLString(profile.serverURL) == MountProfile.normalizedURLString(candidateURL)
        }
    }
    
    private func selectMountPoint() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                profile.mountPoint = url.path
            }
        }
    }
}
