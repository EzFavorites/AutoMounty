import Foundation

public struct MountProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var schemaVersion: Int = 2
    public var serverURL: String // smb://user@server/share
    public var mountPoint: String // Optional: local path to mount at
    public var isEnabled: Bool = true
    public var autoMount: Bool = false

    // New Rules System
    public var rules: [MountRule] = []
    public var ruleLogic: RuleLogic = .all

    // Bonjour Support
    public var bonjourHostname: String? // Stores the Bonjour service name (e.g. "MyNAS") for IP updates

    // Scripting & Automation
    public var automations: [AutomationConfig] = []

    // UI Helper
    public var displayName: String {
        if serverURL.isEmpty { return "Untitled Server" }
        guard let url = URL(string: serverURL) else { return serverURL }

        let lastComponent = url.lastPathComponent
        if !lastComponent.isEmpty && lastComponent != "/" {
            return lastComponent
        }

        if let host = url.host {
            return host
        }

        return serverURL
    }

    /// Normalize a server URL for deduplication comparison.
    /// Lowercased, trimmed of leading/trailing slashes, username stripped.
    public static func normalizedURLString(_ raw: String) -> String {
        guard let url = URL(string: raw) else {
            return raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        let result = components?.string ?? raw
        return result.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Instance convenience accessor.
    public var normalizedServerURL: String {
        return MountProfile.normalizedURLString(serverURL)
    }

    // Custom decoding to handle migration
    enum CodingKeys: String, CodingKey {
        case id, schemaVersion, serverURL, mountPoint, allowedSSIDs, isEnabled, autoMount, wifiSSID, rules, ruleLogic, bonjourHostname, scripts, wolConfig, automations
    }

    public init(id: UUID = UUID(), serverURL: String, mountPoint: String, rules: [MountRule] = [], ruleLogic: RuleLogic = .all, isEnabled: Bool = true, autoMount: Bool = false, bonjourHostname: String? = nil, automations: [AutomationConfig] = []) {
        self.id = id
        self.schemaVersion = 2
        self.serverURL = serverURL
        self.mountPoint = mountPoint
        self.rules = rules
        self.ruleLogic = ruleLogic
        self.isEnabled = isEnabled
        self.autoMount = autoMount
        self.bonjourHostname = bonjourHostname
        self.automations = automations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        serverURL = try container.decode(String.self, forKey: .serverURL)
        mountPoint = try container.decode(String.self, forKey: .mountPoint)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        autoMount = try container.decode(Bool.self, forKey: .autoMount)
        bonjourHostname = try container.decodeIfPresent(String.self, forKey: .bonjourHostname)

        // Load new automations
        automations = try container.decodeIfPresent([AutomationConfig].self, forKey: .automations) ?? []

        // Migration: Load old scripts
        if let oldScripts = try? container.decodeIfPresent([OldScriptConfig].self, forKey: .scripts), !oldScripts.isEmpty {
            for script in oldScripts {
                var newAuto = AutomationConfig()
                newAuto.type = script.path.hasSuffix(".app") ? .app : .shell
                newAuto.path = script.path
                newAuto.arguments = script.arguments
                newAuto.enabled = script.enabled
                newAuto.events = script.events
                automations.append(newAuto)
            }
        }

        // Migration: Load old WOL
        if let wol = try? container.decodeIfPresent(WOLConfig.self, forKey: .wolConfig) {
            var newAuto = AutomationConfig()
            newAuto.type = .wol
            newAuto.macAddress = wol.macAddress
            newAuto.broadcastAddress = wol.broadcastAddress
            newAuto.port = wol.port
            newAuto.waitTime = wol.waitTime
            newAuto.events = [.preMount] // Default WOL to pre-mount
            automations.append(newAuto)
        }

        // New fields
        rules = try container.decodeIfPresent([MountRule].self, forKey: .rules) ?? []
        ruleLogic = try container.decodeIfPresent(RuleLogic.self, forKey: .ruleLogic) ?? .all

        // Migration logic: Convert old SSIDs to rules if rules are empty
        if rules.isEmpty {
            if let ssids = try? container.decode([String].self, forKey: .allowedSSIDs), !ssids.isEmpty {
                ruleLogic = .any
                for ssid in ssids {
                    rules.append(MountRule(type: .wifi, operator: .equals, value: ssid))
                }
            } else if let singleSSID = try? container.decodeIfPresent(String.self, forKey: .wifiSSID), !singleSSID.isEmpty {
                rules.append(MountRule(type: .wifi, operator: .equals, value: singleSSID))
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(serverURL, forKey: .serverURL)
        try container.encode(mountPoint, forKey: .mountPoint)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(autoMount, forKey: .autoMount)
        try container.encode(rules, forKey: .rules)
        try container.encode(ruleLogic, forKey: .ruleLogic)
        try container.encode(bonjourHostname, forKey: .bonjourHostname)
        try container.encode(automations, forKey: .automations)
    }
}

// MARK: - Automation Types

public enum ScriptEvent: String, Codable, CaseIterable, Identifiable, Sendable {
    case preMount = "Mounting"
    case mounted = "Mounted"
    case preUnmount = "Unmounting"
    case unmounted = "Unmounted"
    case mountFailed = "Mount Failed"
    
    public var id: String { rawValue }
    
    public var localizedName: String {
        switch self {
        case .preMount: return NSLocalizedString("Mounting", comment: "Event: Before mount starts")
        case .mounted: return NSLocalizedString("Mounted", comment: "Event: After mount success")
        case .preUnmount: return NSLocalizedString("Unmounting", comment: "Event: Before unmount starts")
        case .unmounted: return NSLocalizedString("Unmounted", comment: "Event: After unmount success")
        case .mountFailed: return NSLocalizedString("Mount Failed", comment: "Event: When mount fails")
        }
    }
}

public enum AutomationType: String, Codable, CaseIterable, Identifiable, Sendable {
    case shell = "Shell Script"
    case app = "Application"
    case wol = "Wake On LAN"
    
    public var id: String { rawValue }
    
    public var localizedName: String {
        switch self {
        case .shell: return NSLocalizedString("Shell Script", comment: "Automation type: Shell Script")
        case .app: return NSLocalizedString("Application", comment: "Automation type: Application")
        case .wol: return NSLocalizedString("Wake On LAN", comment: "Automation type: Wake On LAN")
        }
    }
}

public struct AutomationConfig: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var type: AutomationType = .shell
    public var enabled: Bool = true
    
    // Common/Script
    public var path: String = ""
    public var arguments: String = ""
    public var events: Set<ScriptEvent> = []
    
    // WOL
    public var macAddress: String = ""
    public var broadcastAddress: String = "255.255.255.255"
    public var port: UInt16 = 9
    public var waitTime: TimeInterval = 0

    public init(id: UUID = UUID(), type: AutomationType = .shell, enabled: Bool = true, path: String = "", arguments: String = "", events: Set<ScriptEvent> = [], macAddress: String = "", broadcastAddress: String = "255.255.255.255", port: UInt16 = 9, waitTime: TimeInterval = 0) {
        self.id = id
        self.type = type
        self.enabled = enabled
        self.path = path
        self.arguments = arguments
        self.events = events
        self.macAddress = macAddress
        self.broadcastAddress = broadcastAddress
        self.port = port
        self.waitTime = waitTime
    }

    // Custom CodingKeys to encode WOL fields under their own keys
    private enum CodingKeys: String, CodingKey {
        case id, type, enabled, path, arguments, events
        case macAddress, broadcastAddress, port, waitTime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try container.decodeIfPresent(AutomationType.self, forKey: .type) ?? .shell
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        arguments = try container.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        events = try container.decodeIfPresent(Set<ScriptEvent>.self, forKey: .events) ?? []
        macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress) ?? ""
        broadcastAddress = try container.decodeIfPresent(String.self, forKey: .broadcastAddress) ?? "255.255.255.255"
        port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 9
        waitTime = try container.decodeIfPresent(TimeInterval.self, forKey: .waitTime) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(path, forKey: .path)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(events, forKey: .events)
        try container.encode(macAddress, forKey: .macAddress)
        try container.encode(broadcastAddress, forKey: .broadcastAddress)
        try container.encode(port, forKey: .port)
        try container.encode(waitTime, forKey: .waitTime)
    }
}

// Migration-only types
@available(*, deprecated, message: "Legacy type kept for data migration only")
struct OldScriptConfig: Codable {
    var id = UUID()
    var path: String
    var arguments: String
    var enabled: Bool
    var events: Set<ScriptEvent>
}

@available(*, deprecated, message: "Legacy type kept for data migration only")
public struct WOLConfig: Codable, Hashable, Sendable {
    public var macAddress: String = ""
    public var broadcastAddress: String = "255.255.255.255"
    public var port: UInt16 = 9
    public var waitTime: TimeInterval = 0
    
    public init(macAddress: String = "", broadcastAddress: String = "255.255.255.255", port: UInt16 = 9, waitTime: TimeInterval = 0) {
        self.macAddress = macAddress
        self.broadcastAddress = broadcastAddress
        self.port = port
        self.waitTime = waitTime
    }
}

public enum RuleType: String, Codable, CaseIterable, Identifiable, Sendable {
    case wifi = "WiFi Connection"
    case vpn = "VPN Connection"
    case app = "Running Application"
    
    public var id: String { rawValue }
    
    public var localizedName: String {
        switch self {
        case .wifi: return NSLocalizedString("WiFi Connection", comment: "Rule type: WiFi")
        case .vpn: return NSLocalizedString("VPN Connection", comment: "Rule type: VPN")
        case .app: return NSLocalizedString("Running Application", comment: "Rule type: Application")
        }
    }
}

public enum RuleOperator: String, Codable, CaseIterable, Identifiable, Sendable {
    case equals = "is"
    case doesNotEqual = "is not"
    case contains = "contains"
    
    public var id: String { rawValue }
    
    public var localizedName: String {
        switch self {
        case .equals: return NSLocalizedString("is", comment: "Operator: equals")
        case .doesNotEqual: return NSLocalizedString("is not", comment: "Operator: does not equal")
        case .contains: return NSLocalizedString("contains", comment: "Operator: contains")
        }
    }
}

public enum RuleLogic: String, Codable, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case any = "Any"
    
    public var id: String { rawValue }
    
    public var localizedName: String {
        switch self {
        case .all: return NSLocalizedString("All", comment: "Logic: All rules must match")
        case .any: return NSLocalizedString("Any", comment: "Logic: Any rule matches")
        }
    }
}

public struct MountRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var type: RuleType
    public var `operator`: RuleOperator
    public var value: String
    
    public init(id: UUID = UUID(), type: RuleType, operator: RuleOperator, value: String) {
        self.id = id
        self.type = type
        self.operator = `operator`
        self.value = value
    }
}

public enum MountStatus: Equatable, Sendable {
    case mounted
    case unmounted
    case error(String)
    case mounting
}
