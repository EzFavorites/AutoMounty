import Foundation
import AutoMountyModel
import Network
import CoreWLAN
import SystemConfiguration.CaptiveNetwork

struct NetworkService {
    static let shared = NetworkService()
    
    private init() {}
    
    // MARK: - Network State (SSID, Interfaces)
    
    /// Gets the current WiFi SSID.
    /// Note: Requires Location Permission on recent macOS.
    func getCurrentSSID() -> String? {
        if let interface = CWWiFiClient.shared().interface() {
            return interface.ssid()
        }
        return nil
    }
    
    /// Returns a list of active VPN/Tunnel interface names.
    func getAvailableVPNInterfaces() -> [String] {
        let interfaces = getAllNetworkInterfaces()
        return interfaces.filter { name in
            let lower = name.lowercased()
            return lower.hasPrefix("utun") || lower.hasPrefix("ppp") || lower.hasPrefix("ipsec") || lower.contains("vpn") || lower.contains("tun") || lower.contains("tap")
        }.sorted()
    }
    
    private func getAllNetworkInterfaces() -> [String] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return [] }
        defer { freeifaddrs(addresses) }
        
        var names = Set<String>()
        var ptr = addresses
        while ptr != nil {
            if let interface = ptr?.pointee {
                let name = String(cString: interface.ifa_name)
                names.insert(name)
            }
            ptr = ptr?.pointee.ifa_next
        }
        return Array(names)
    }
    
    // MARK: - Reachability (Ping)

    /// Checks if a host is reachable via a simple ping command.
    func isHostReachable(_ host: String) async -> Bool {
        // Find ping binary — location varies across macOS versions
        let pingPaths = ["/sbin/ping", "/usr/sbin/ping"]
        guard let pingPath = pingPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            Logger.error("ping binary not found")
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pingPath)
        process.arguments = ["-c", "1", "-t", "1", host]

        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    // MARK: - Wake On LAN (WOL)
    
    /// Sends a Wake On LAN (Magic Packet) to the specified MAC address.
    /// - Parameters:
    ///   - macAddress: The target MAC address (e.g., "00:11:22:33:44:55").
    ///   - broadcastAddress: The broadcast IP (default "255.255.255.255").
    ///   - port: The target port (default 9).
    func sendWOL(macAddress: String, broadcastAddress: String = "255.255.255.255", port: UInt16 = 9) async {
        Logger.info("Sending WOL to \(macAddress)")
        
        let macParts = macAddress.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard macParts.count == 6 else {
            Logger.error("Invalid MAC address for WOL: \(macAddress)")
            return
        }
        
        // Magic Packet: 6 * FF + 16 * MAC
        var packetData = Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        for _ in 0..<16 {
            packetData.append(contentsOf: macParts)
        }
        
        let params = NWParameters.udp
        let connection = NWConnection(host: NWEndpoint.Host(broadcastAddress), port: NWEndpoint.Port(rawValue: port) ?? 9, using: params)
        
        connection.start(queue: .global())
        
        return await withCheckedContinuation { continuation in
            connection.send(content: packetData, completion: .contentProcessed { error in
                if let error = error {
                    Logger.error("WOL Send Error: \(error)")
                } else {
                    Logger.debug("WOL Packet Sent")
                }
                connection.cancel()
                continuation.resume()
            })
        }
    }
}
