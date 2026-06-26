import Foundation
import AutoMountyModel
import Network

@MainActor
class NetworkDiscovery: NSObject, ObservableObject, NetServiceDelegate {
    static let shared = NetworkDiscovery()
    
    @Published var discoveredServers: [DiscoveredServer] = []
    private var browsers: [NWBrowser] = []
    private var activeResolutions: [NetService] = [] // Keep strong reference during resolution
    private var directResolutions: [NetService] = [] // Keep strong reference during direct resolution

    struct DiscoveredServer: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let type: String
        let domain: String
        var ipAddress: String? = nil
        
        var urlScheme: String {
            if type.contains("_smb") { return "smb" }
            if type.contains("_afpovertcp") { return "afp" }
            if type.contains("_webdav") { return "http" }
            return "unknown"
        }
        
        var displayType: String {
            if type.contains("_smb") { return "SMB" }
            if type.contains("_afpovertcp") { return "AFP" }
            if type.contains("_webdav") { return "WebDAV" }
            return "Unknown"
        }
    }
    
    func startDiscovery() {
        stopDiscovery()
        discoveredServers.removeAll()
        activeResolutions.removeAll()
        
        // Browse for SMB
        startBrowsing(type: "_smb._tcp")
        // Browse for AFP
        startBrowsing(type: "_afpovertcp._tcp")
    }
    
    func stopDiscovery() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        activeResolutions.forEach { $0.stop() }
        activeResolutions.removeAll()
    }
    
    private func startBrowsing(type: String) {
        let descriptor = NWBrowser.Descriptor.bonjour(type: type, domain: "local.")
        let parameters = NWParameters()
        let browser = NWBrowser(for: descriptor, using: parameters)
        
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Logger.debug("Bonjour discovery ready for \(type)")
            case .failed(let error):
                Logger.error("Bonjour discovery failed: \(error)")
            default:
                break
            }
        }
        
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self = self else { return }
            
            Task { @MainActor in
                for result in results {
                    if case .service(let name, let type, let domain, _) = result.endpoint {
                        // Check if already discovered
                        if !self.discoveredServers.contains(where: { $0.name == name && $0.type == type }) {
                            let server = DiscoveredServer(name: name, type: type, domain: domain)
                            self.discoveredServers.append(server)
                            
                            // Start resolving IP
                            self.resolveIP(for: server)
                        }
                    }
                }
            }
        }
        
        browser.start(queue: .main)
        browsers.append(browser)
    }
    
    private func resolveIP(for server: DiscoveredServer) {
        let service = NetService(domain: server.domain, type: server.type, name: server.name)
        service.delegate = self
        service.resolve(withTimeout: 5.0)
        activeResolutions.append(service)
    }
    
    // MARK: - NetServiceDelegate
    
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let name = sender.name
        let type = sender.type
        let addresses = sender.addresses ?? []

        Task { @MainActor in
            var resolvedIP: String?

            if !addresses.isEmpty {
                // Prefer IPv4, fall back to IPv6
                var ipv4Result: String?
                var ipv6Result: String?

                for address in addresses {
                    let data = address as NSData
                    var storage = sockaddr_storage()
                    data.getBytes(&storage, length: MemoryLayout<sockaddr_storage>.size)

                    if storage.ss_family == sa_family_t(AF_INET) && ipv4Result == nil {
                        ipv4Result = String(cString: inet_ntoa(withUnsafePointer(to: &storage) {
                            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                                $0.pointee.sin_addr
                            }
                        }))
                    } else if storage.ss_family == sa_family_t(AF_INET6) && ipv6Result == nil {
                        var addr = withUnsafePointer(to: &storage) {
                            $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                        }
                        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                        inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN))
                        ipv6Result = String(cString: buffer)
                    }
                }

                resolvedIP = ipv4Result ?? ipv6Result
            }

            if let ip = resolvedIP {
                Logger.debug("Resolved IP for \(name): \(ip)")
                if let index = self.discoveredServers.firstIndex(where: { $0.name == name && $0.type == type }) {
                    self.discoveredServers[index].ipAddress = ip
                }
            }

            if let index = self.activeResolutions.firstIndex(where: { $0.name == name && $0.type == type }) {
                self.activeResolutions.remove(at: index)
            }
        }
    }
    
    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        let name = sender.name
        let type = sender.type
        
        Task { @MainActor in
            Logger.error("Failed to resolve IP for \(name): \(errorDict)")
            if let index = self.activeResolutions.firstIndex(where: { $0.name == name && $0.type == type }) {
                self.activeResolutions.remove(at: index)
            }
        }
    }
    
    // MARK: - Direct Resolution
    
    func resolve(hostname: String, type: String, completion: @escaping (String?) -> Void) {
        let service = NetService(domain: "local.", type: type, name: hostname)
        
        // Wrap completion to cleanup strong reference
        let wrappedCompletion: (String?) -> Void = { [weak self, weak service] ip in
            completion(ip)
            DispatchQueue.main.async {
                if let self = self, let s = service {
                    if let index = self.directResolutions.firstIndex(of: s) {
                        self.directResolutions.remove(at: index)
                    }
                }
            }
        }
        
        let delegate = OneShotResolver(completion: wrappedCompletion)
        // Keep delegate alive
        objc_setAssociatedObject(service, "OneShotResolver", delegate, .OBJC_ASSOCIATION_RETAIN)
        service.delegate = delegate
        
        // Keep service alive
        directResolutions.append(service)
        
        service.resolve(withTimeout: 3.0)
    }
    
    // MARK: - Batch Update
    
    func updateBonjourIPs(for profiles: [MountProfile], completion: @escaping () -> Void) {
        // Run on background thread to avoid blocking main thread, though network ops are async
        Task {
            let group = DispatchGroup()
            
            for profile in profiles {
                guard let hostname = profile.bonjourHostname, !hostname.isEmpty else { continue }
                
                // Infer type from URL
                let type: String
                if profile.serverURL.hasPrefix("smb") {
                    type = "_smb._tcp"
                } else if profile.serverURL.hasPrefix("afp") {
                    type = "_afpovertcp._tcp"
                } else if profile.serverURL.hasPrefix("http") {
                    type = "_webdav._tcp" // Assumed default for http/https webdav in this context
                } else {
                    continue
                }
                
                group.enter()
                Logger.info("Checking IP update for \(hostname) (\(type))")
                
                self.resolve(hostname: hostname, type: type) { ip in
                    defer { group.leave() }
                    guard let ip = ip else { return }
                    
                    // Check if IP matches current URL host
                    if let url = URL(string: profile.serverURL), let currentHost = url.host {
                        if currentHost != ip {
                            Logger.info("Updating IP for \(hostname) from \(currentHost) to \(ip)")
                            
                            // Construct new URL
                            if var components = URLComponents(string: profile.serverURL) {
                                components.host = ip
                                if let newURL = components.string {
                                    DispatchQueue.main.async {
                                        // Update config via ConfigManager
                                        // We need to fetch fresh profile to ensure index is correct
                                        if let currentIndex = ConfigManager.shared.profiles.firstIndex(where: { $0.id == profile.id }) {
                                            var updatedProfile = ConfigManager.shared.profiles[currentIndex]
                                            updatedProfile.serverURL = newURL
                                            ConfigManager.shared.update(profile: updatedProfile)
                                        }
                                    }
                                }
                            }
                        } else {
                            Logger.debug("IP for \(hostname) is up to date: \(ip)")
                        }
                    }
                }
            }
            
            group.notify(queue: .main) {
                completion()
            }
        }
    }
}

private class OneShotResolver: NSObject, NetServiceDelegate {
    let completion: (String?) -> Void
    var hasCalledCompletion = false
    
    init(completion: @escaping (String?) -> Void) {
        self.completion = completion
    }
    
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard !hasCalledCompletion else { return }

        if let addresses = sender.addresses, !addresses.isEmpty {
            var ipv4Result: String?
            var ipv6Result: String?

            for address in addresses {
                let data = address as NSData
                var storage = sockaddr_storage()
                data.getBytes(&storage, length: MemoryLayout<sockaddr_storage>.size)

                if storage.ss_family == sa_family_t(AF_INET) && ipv4Result == nil {
                    ipv4Result = String(cString: inet_ntoa(withUnsafePointer(to: &storage) {
                        $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                            $0.pointee.sin_addr
                        }
                    }))
                } else if storage.ss_family == sa_family_t(AF_INET6) && ipv6Result == nil {
                    var addr = withUnsafePointer(to: &storage) {
                        $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    }
                    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN))
                    ipv6Result = String(cString: buffer)
                }
            }

            if let ip = ipv4Result ?? ipv6Result {
                hasCalledCompletion = true
                completion(ip)
                sender.stop()
                return
            }
        }

        // No usable address found
        hasCalledCompletion = true
        completion(nil)
    }
    
    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        guard !hasCalledCompletion else { return }
        hasCalledCompletion = true
        completion(nil)
    }
    
    func netServiceDidStop(_ sender: NetService) {
        // Ensure completion called if stopped without success (e.g. timeout handling elsewhere, though NetService timeout calls didNotResolve usually?)
        // Actually NetService timeout logic is a bit manual if not using browse.
        // But resolve(withTimeout:) handles it.
        if !hasCalledCompletion {
            hasCalledCompletion = true
            completion(nil)
        }
    }
}
