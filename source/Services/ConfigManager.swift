import Foundation
import AutoMountyModel

// MARK: - Notification Names

extension Notification.Name {
    static let addNewProfile = Notification.Name("AddNewProfile")
    static let selectMountProfile = Notification.Name("SelectMountProfile")
    static let openSettings = Notification.Name("OpenSettings")
}

// MARK: - Profile Grouping

struct ProfileGroup: Identifiable {
    let name: String
    let profiles: [MountProfile]
    var id: String { name }
}

enum ProfileGrouper {
    static let protocolOrder = ["SMB", "AFP", "NFS", "WebDAV", "FTP (Read Only)", "Other"]

    static func group(_ profiles: [MountProfile]) -> [ProfileGroup] {
        let groups = Dictionary(grouping: profiles) { profile -> String in
            guard let url = URL(string: profile.serverURL), let scheme = url.scheme else {
                return "Other"
            }
            let s = scheme.lowercased()
            if s.hasPrefix("smb") { return "SMB" }
            if s.hasPrefix("afp") { return "AFP" }
            if s.hasPrefix("nfs") { return "NFS" }
            if s.hasPrefix("webdav") || s.hasPrefix("http") || s.hasPrefix("https") { return "WebDAV" }
            if s.hasPrefix("ftp") { return "FTP (Read Only)" }
            return "Other"
        }

        return protocolOrder.compactMap { key in
            guard let profiles = groups[key], !profiles.isEmpty else { return nil }
            return ProfileGroup(name: key, profiles: profiles)
        }
    }
}

@MainActor
class ConfigManager: ObservableObject {
    static let shared = ConfigManager()

    @Published var profiles: [MountProfile] = [] {
        didSet {
            scheduleSave()
        }
    }

    private let savePath: URL
    private var saveWorkItem: DispatchWorkItem?

    init() {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("AutoMounty")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true, attributes: nil)
        savePath = appSupport.appendingPathComponent("profiles.json")

        load()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: savePath.path) else { return }
        do {
            let data = try Data(contentsOf: savePath)
            let decoded = try JSONDecoder().decode([MountProfile].self, from: data)
            profiles = decoded
        } catch {
            Logger.error("Failed to load profiles: \(error)")
        }
    }

    /// Debounced save: coalesces rapid mutations into a single disk write.
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.save()
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encoded = try encoder.encode(profiles)
            try encoded.write(to: savePath, options: .atomic)
        } catch {
            Logger.error("Failed to save profiles: \(error)")
        }
    }

    /// Adds a profile. Returns true if added, false if a duplicate URL already exists.
    @discardableResult
    func add(profile: MountProfile) -> Bool {
        let normalized = MountProfile.normalizedURLString(profile.serverURL)
        if profiles.contains(where: { MountProfile.normalizedURLString($0.serverURL) == normalized }) {
            Logger.info("Duplicate URL rejected: \(profile.serverURL)")
            return false
        }
        profiles.append(profile)
        Logger.info("Added new profile: \(profile.serverURL)")
        return true
    }

    func update(profile: MountProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
            Logger.info("Updated profile: \(profile.serverURL)")
        }
    }

    func delete(at offsets: IndexSet) {
        Logger.info("Deleting profile(s) at offsets: \(offsets)")
        profiles.remove(atOffsets: offsets)
    }

    func delete(id: UUID) {
        if let profile = profiles.first(where: { $0.id == id }) {
            Logger.info("Deleting profile: \(profile.serverURL)")
            profiles.removeAll { $0.id == id }
        }
    }
}
