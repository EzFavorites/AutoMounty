import Foundation
import AutoMountyModel
import Network

@MainActor
class MountyMonitor: NSObject, ObservableObject {
    static let shared = MountyMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "MountyMonitor")
    private var lastAutoMountAttempt: [UUID: Date] = [:]
    private let autoMountCooldown: TimeInterval = 5
    private var networkDebounceTask: Task<Void, Never>?

    @Published var currentSSID: String?

    override init() {
        super.init()
    }

    func start() {
        Logger.info("MountyMonitor starting...")
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self = self else { return }
                Logger.debug("Network path changed. Status: \(path.status)")
                if path.status == .satisfied {
                    self.checkSSID()
                    // Debounce: cancel previous pending check and wait for network to stabilize
                    self.networkDebounceTask?.cancel()
                    self.networkDebounceTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
                        guard !Task.isCancelled else { return }
                        Logger.info("Network satisfied, triggering checkAutoMount...")
                        self.checkAutoMount()
                    }
                }
            }
        }
        monitor.start(queue: queue)

        // Trigger initial check
        Task { @MainActor in
             Logger.info("Performing initial network check...")
             self.checkSSID()
             try? await Task.sleep(nanoseconds: 1 * 1_000_000_000)
             Logger.info("Initial checkAutoMount triggered.")
             self.checkAutoMount()
        }
    }

    func checkSSID() {
        Task.detached {
            let ssid = NetworkService.shared.getCurrentSSID()
            await MainActor.run {
                self.currentSSID = ssid
            }
        }
    }

    func checkAutoMount() {
        let profiles = ConfigManager.shared.profiles
        Logger.debug("Checking auto-mount for \(profiles.count) profiles")
        for profile in profiles {
            checkAutoMount(for: profile)
        }
    }

    func checkAutoMount(for profile: MountProfile) {
        guard profile.isEnabled else {
            Logger.debug("Profile \(profile.serverURL) is disabled, skipping auto-mount.")
            return
        }
        guard profile.autoMount else {
            Logger.debug("Profile \(profile.serverURL) auto-mount is OFF, skipping.")
            return
        }

        // Check if manually unmounted by user (don't auto remount)
        if MountyManager.shared.isManuallyUnmounted(profile.id) {
            Logger.debug("Profile \(profile.serverURL) was manually unmounted, skipping auto-mount.")
            return
        }

        // Check if already mounted or mounting
        if MountyManager.shared.currentStatus[profile.id] == .mounted {
            Logger.debug("Profile \(profile.serverURL) is already mounted, skipping.")
            return
        }
        if MountyManager.shared.currentStatus[profile.id] == .mounting {
            Logger.debug("Profile \(profile.serverURL) is mounting, skipping.")
            return
        }

        if let lastAttempt = lastAutoMountAttempt[profile.id],
           Date().timeIntervalSince(lastAttempt) < autoMountCooldown {
            Logger.debug("Profile \(profile.serverURL) auto-mount is cooling down, skipping.")
            return
        }

        // Set cooldown BEFORE async rule evaluation to prevent overlapping mounts
        lastAutoMountAttempt[profile.id] = Date()

        Logger.debug("Evaluating rules for \(profile.serverURL)...")
        Task {
            if await RuleService.shared.evaluateRules(for: profile, currentSSID: currentSSID) {
                Logger.info("Auto mounting \(profile.serverURL) because rules matched")
                MountyManager.shared.mount(profile: profile) { _ in }
            } else {
                Logger.debug("Rules did not match for \(profile.serverURL)")
            }
        }
    }
}
