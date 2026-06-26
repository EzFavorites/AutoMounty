import Foundation
import AutoMountyModel
import NetFS
import AppKit

// Define NetFS keys if not available
nonisolated(unsafe) let kNetFSSoftMountKey = "SoftMount" as CFString
nonisolated(unsafe) let kNetFSMountAtMountDirKey = "MountAtMountDir" as CFString

@MainActor
class MountyManager: ObservableObject {
    static let shared = MountyManager()

    @Published var currentStatus: [UUID: MountStatus] = [:]
    @Published var mountPaths: [UUID: String] = [:]

    private var manuallyUnmountedProfiles: Set<UUID> = []
    private var appInitiatedUnmounts: Set<UUID> = [] // Suppress duplicate notification handling
    private var healthCheckTask: Task<Void, Never>?
    private let healthCheckInterval: TimeInterval = 30

    private init() {
        setupObservers()
        startHealthCheck()
    }

    // MARK: - Unified Status Update

    func updateStatus(for id: UUID, status: MountStatus) {
        let old = currentStatus[id]
        currentStatus[id] = status
        if old != status {
            Logger.debug("Status [\(id)]: \(describeStatus(old)) → \(describeStatus(status))")
        }
    }

    private func describeStatus(_ status: MountStatus?) -> String {
        switch status {
        case .mounted: return "mounted"
        case .unmounted: return "unmounted"
        case .mounting: return "mounting"
        case .error(let msg): return "error(\(msg))"
        case nil: return "nil"
        }
    }

    // MARK: - Health Check

    /// Periodically verifies that all "mounted" profiles still have active mount points.
    private func startHealthCheck() {
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.healthCheckInterval ?? 30) * 1_000_000_000))
                guard let self = self, !Task.isCancelled else { break }
                self.verifyMountHealth()
            }
        }
    }

    private func verifyMountHealth() {
        let mountedIds = currentStatus.filter { $0.value == .mounted }.map { $0.key }
        guard !mountedIds.isEmpty else { return }

        // Get current system mounts
        var mntbuf: UnsafeMutablePointer<statfs>? = nil
        let count = getmntinfo(&mntbuf, MNT_NOWAIT)
        guard count > 0, let mnt = mntbuf else { return }

        var activePaths = Set<String>()
        for i in 0..<Int(count) {
            let f_mntonname = withUnsafePointer(to: mnt[i].f_mntonname) {
                $0.withMemoryRebound(to: UInt8.self, capacity: 1024) { String(cString: $0) }
            }
            activePaths.insert(f_mntonname)
        }

        // Check each "mounted" profile
        for id in mountedIds {
            guard let expectedPath = mountPaths[id] else {
                // Status says mounted but no path recorded — suspicious
                Logger.debug("Health check: \(id) marked mounted but no mount path recorded")
                updateStatus(for: id, status: .unmounted)
                continue
            }

            if !activePaths.contains(expectedPath) {
                Logger.info("Health check: \(expectedPath) no longer mounted, updating status")
                updateStatus(for: id, status: .unmounted)
                mountPaths.removeValue(forKey: id)
            }
        }

        // Detect stale unmounted profiles (status was never updated)
        for (id, path) in mountPaths {
            if !activePaths.contains(path) && currentStatus[id] == .mounted {
                Logger.info("Health check: stale mount detected for \(path)")
                updateStatus(for: id, status: .unmounted)
                mountPaths.removeValue(forKey: id)
            }
        }
    }

    // MARK: - Unmount Notification Observer

    private func setupObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleUnmountNotification(_:)),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )
    }

    @objc private func handleUnmountNotification(_ notification: Notification) {
        guard let path = notification.userInfo?["NSDevicePath"] as? String else { return }
        Logger.debug("System unmounted path: \(path)")

        Task { @MainActor in
            if let (id, _) = mountPaths.first(where: { $0.value == path }) {
                // Skip if this was an app-initiated unmount (already handled)
                if appInitiatedUnmounts.contains(id) {
                    Logger.debug("Skipping system unmount notification for app-initiated unmount: \(id)")
                    appInitiatedUnmounts.remove(id)
                    return
                }

                Logger.info("Detected external unmount for profile ID: \(id)")
                updateStatus(for: id, status: .unmounted)
                mountPaths.removeValue(forKey: id)

                if let profile = ConfigManager.shared.profiles.first(where: { $0.id == id }) {
                    checkReachabilityAndMarkManual(for: profile)
                }
            }
        }
    }

    private func checkReachabilityAndMarkManual(for profile: MountProfile) {
        guard let host = URL(string: profile.serverURL)?.host else { return }

        Task.detached {
            let isReachable = await NetworkService.shared.isHostReachable(host)
            await MainActor.run {
                if isReachable {
                    Logger.info("Server \(host) is reachable. Marking \(profile.serverURL) as manually unmounted.")
                    self.manuallyUnmountedProfiles.insert(profile.id)
                } else {
                    Logger.info("Server \(host) is unreachable. Assuming network disconnect for \(profile.serverURL).")
                }
            }
        }
    }

    // MARK: - Manual Unmount Tracking

    func isManuallyUnmounted(_ id: UUID) -> Bool {
        return manuallyUnmountedProfiles.contains(id)
    }

    func clearManualUnmountStatus(_ id: UUID) {
        if manuallyUnmountedProfiles.contains(id) {
            Logger.info("Clearing manual unmount status for ID: \(id)")
            manuallyUnmountedProfiles.remove(id)
        }
    }

    // MARK: - Mount

    func mount(profile: MountProfile, completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        clearManualUnmountStatus(profile.id)
        Logger.info("Starting mount for \(profile.serverURL)")
        updateStatus(for: profile.id, status: .mounting)

        Task.detached {
            // Pre-mount automations (WOL, Scripts, etc.)
            let preMountResult = await AutomationService.shared.executeAutomations(for: .preMount, profile: profile)

            // If a pre-mount script failed, abort the mount
            if preMountResult.hasFailures {
                Logger.error("Pre-mount automation failed for \(profile.serverURL), aborting mount.")
                await self.updateStatus(for: profile.id, status: .error("Pre-mount script failed"))
                await MainActor.run {
                    completion(.failure(NSError(domain: "AutoMounty", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Pre-mount automation failed"])))
                }
                return
            }

            guard let shareURL = URL(string: profile.serverURL) else {
                Logger.error("Invalid URL: \(profile.serverURL)")
                await self.updateStatus(for: profile.id, status: .error("Invalid URL"))
                await MainActor.run {
                    completion(.failure(NSError(domain: "AutoMounty", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid Server URL"])))
                }
                return
            }

            var mountPointURL: URL? = nil
            if !profile.mountPoint.isEmpty {
                let path = (profile.mountPoint as NSString).expandingTildeInPath
                mountPointURL = URL(fileURLWithPath: path)

                var isDirectory: ObjCBool = false
                if !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
                    do {
                        Logger.debug("Creating mount point directory: \(path)")
                        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                    } catch {
                        Logger.error("Failed to create mount directory: \(error)")
                        await self.updateStatus(for: profile.id, status: .error("Create Dir Failed"))
                        await MainActor.run { completion(.failure(error)) }
                        return
                    }
                }
            }

            let options = NSMutableDictionary()
            options[kNetFSSoftMountKey] = kCFBooleanTrue
            if mountPointURL != nil {
                options[kNetFSMountAtMountDirKey] = kCFBooleanTrue
            }

            Logger.debug("Mounting with NetFS...")
            var mountPoints: Unmanaged<CFArray>?

            let result = NetFSMountURLSync(
                shareURL as CFURL,
                mountPointURL as CFURL?,
                nil,
                nil,
                nil,
                options,
                &mountPoints
            )

            let pointsArray = mountPoints?.takeRetainedValue() as? [String]

            await MainActor.run {
                if result == 0 {
                    var actualMountPoint = profile.mountPoint
                    if let first = pointsArray?.first {
                        actualMountPoint = first
                    }

                    Logger.info("Mount success: \(profile.serverURL) at \(actualMountPoint)")
                    self.updateStatus(for: profile.id, status: .mounted)
                    self.mountPaths[profile.id] = actualMountPoint

                    self.checkAndUpdateProfileURL(profile: profile, mountPoint: actualMountPoint)

                    Task {
                        await AutomationService.shared.executeAutomations(
                            for: .mounted, profile: profile,
                            environment: ["AUTOMOUNTY_MOUNT_POINT": actualMountPoint]
                        )
                    }

                    completion(.success(actualMountPoint))
                } else {
                    let errorMsg = "Mount failed (code \(result))"
                    Logger.error("Mount failed for \(profile.serverURL). Code: \(result)")
                    self.updateStatus(for: profile.id, status: .error(errorMsg))

                    Task { await AutomationService.shared.executeAutomations(for: .mountFailed, profile: profile) }

                    completion(.failure(NSError(domain: "NetFS", code: Int(result),
                        userInfo: [NSLocalizedDescriptionKey: errorMsg])))
                }
            }
        }
    }

    // MARK: - Unmount

    func unmount(profileId: UUID) {
        manuallyUnmountedProfiles.insert(profileId)
        appInitiatedUnmounts.insert(profileId)

        guard let path = mountPaths[profileId] else {
            Logger.debug("Unmount skipped: no mount path for \(profileId)")
            return
        }

        let profile = ConfigManager.shared.profiles.first(where: { $0.id == profileId })
        Logger.info("Unmounting \(path)")

        Task.detached {
            if let profile = profile {
                await AutomationService.shared.executeAutomations(for: .preUnmount, profile: profile)
            }

            // Find umount binary
            let umountPaths = ["/sbin/umount", "/usr/sbin/umount", "/bin/umount"]
            guard let umountPath = umountPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                Logger.error("umount binary not found")
                await MainActor.run {
                    self.updateStatus(for: profileId, status: .error("umount not found"))
                }
                return
            }

            let task = Process()
            task.executableURL = URL(fileURLWithPath: umountPath)
            task.arguments = [path]
            task.standardOutput = Pipe()
            task.standardError = Pipe()

            let exitCode: Int32
            do {
                try task.run()
                exitCode = await MountyManager.waitForProcess(task, timeout: 15)
            } catch {
                Logger.error("Failed to run umount: \(error)")
                await MainActor.run {
                    self.updateStatus(for: profileId, status: .error("umount failed"))
                }
                return
            }

            await MainActor.run {
                if exitCode == 0 {
                    Logger.info("Unmount success: \(path)")
                    self.updateStatus(for: profileId, status: .unmounted)
                    self.mountPaths.removeValue(forKey: profileId)

                    if let profile = profile {
                        Task { await AutomationService.shared.executeAutomations(for: .unmounted, profile: profile) }
                    }
                } else {
                    Logger.error("Unmount failed for \(path). Exit code: \(exitCode)")
                    self.appInitiatedUnmounts.remove(profileId) // Re-allow notification handling
                    self.updateStatus(for: profileId, status: .error("Unmount failed (code \(exitCode))"))
                }
            }
        }
    }

    /// Non-blocking process wait with timeout.
    nonisolated static func waitForProcess(_ process: Process, timeout: TimeInterval) async -> Int32 {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let timeoutDate = Date().addingTimeInterval(timeout)
                while process.isRunning {
                    if Date() >= timeoutDate {
                        Logger.error("Process timed out after \(timeout)s, terminating...")
                        process.terminate()
                        continuation.resume(returning: -1)
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }

    // MARK: - URL Helpers

    func getActualURL(from mountPoint: String) -> String? {
        var stat = statfs()
        if statfs(mountPoint, &stat) == 0 {
            let f_mntfromname = withUnsafePointer(to: stat.f_mntfromname) {
                $0.withMemoryRebound(to: UInt8.self, capacity: 1024) { String(cString: $0) }
            }
            let f_type = withUnsafePointer(to: stat.f_fstypename) {
                $0.withMemoryRebound(to: UInt8.self, capacity: 16) { String(cString: $0) }
            }

            var actualURL = f_mntfromname
            if f_type == "smbfs" && actualURL.hasPrefix("//") {
                actualURL = "smb:" + actualURL
            } else if f_type == "afpfs" && !actualURL.hasPrefix("afp://") && !actualURL.contains("://") {
                actualURL = "afp://" + actualURL
            }

            return actualURL
        }
        return nil
    }

    private func checkAndUpdateProfileURL(profile: MountProfile, mountPoint: String) {
        guard let actualURL = getActualURL(from: mountPoint) else { return }

        let profileURLStr = profile.serverURL.removingPercentEncoding ?? profile.serverURL
        let detectedURLStr = actualURL.removingPercentEncoding ?? actualURL

        let cleanProfile = profileURLStr.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanDetected = detectedURLStr.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if cleanProfile != cleanDetected {
            Logger.info("Detected URL mismatch. Profile: \(cleanProfile), Actual: \(cleanDetected). Updating profile.")

            var finalNewURL = actualURL

            if let profileURL = URL(string: profile.serverURL),
               let profilePort = profileURL.port,
               let detectedURL = URL(string: actualURL),
               detectedURL.port == nil {

                var components = URLComponents(url: detectedURL, resolvingAgainstBaseURL: false)
                components?.port = profilePort
                if let fixedURL = components?.string {
                    finalNewURL = fixedURL
                    Logger.info("Preserving custom port \(profilePort) in updated URL: \(finalNewURL)")
                }
            }

            var updatedProfile = profile
            updatedProfile.serverURL = finalNewURL
            ConfigManager.shared.update(profile: updatedProfile)
        }
    }

    // MARK: - Scan & Import

    func scanAndImportMounts() {
        var mntbuf: UnsafeMutablePointer<statfs>? = nil
        let count = getmntinfo(&mntbuf, MNT_NOWAIT)

        guard count > 0, let mnt = mntbuf else { return }

        for i in 0..<Int(count) {
            let stat = mnt[i]
            let f_type = withUnsafePointer(to: stat.f_fstypename) {
                $0.withMemoryRebound(to: UInt8.self, capacity: 16) { String(cString: $0) }
            }

            if ["smbfs", "afpfs", "nfs", "webdav"].contains(f_type) {
                let f_mntfromname = withUnsafePointer(to: stat.f_mntfromname) {
                    $0.withMemoryRebound(to: UInt8.self, capacity: 1024) { String(cString: $0) }
                }
                let f_mntonname = withUnsafePointer(to: stat.f_mntonname) {
                    $0.withMemoryRebound(to: UInt8.self, capacity: 1024) { String(cString: $0) }
                }

                var serverURL = f_mntfromname
                if f_type == "smbfs" && serverURL.hasPrefix("//") {
                    serverURL = "smb:" + serverURL
                } else if f_type == "afpfs" && !serverURL.hasPrefix("afp://") && !serverURL.contains("://") {
                    serverURL = "afp://" + serverURL
                }

                let normalizedServerURL = serverURL.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))

                if let existingProfile = ConfigManager.shared.profiles.first(where: {
                    $0.serverURL.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) == normalizedServerURL
                }) {
                    Logger.debug("Found existing mounted profile: \(serverURL)")
                    self.updateStatus(for: existingProfile.id, status: .mounted)
                    self.mountPaths[existingProfile.id] = f_mntonname
                } else if !ConfigManager.shared.profiles.contains(where: {
                    $0.serverURL.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) == normalizedServerURL
                }) {
                    Logger.info("Importing found mount: \(serverURL) at \(f_mntonname)")
                    let newProfile = MountProfile(serverURL: serverURL, mountPoint: "")
                    ConfigManager.shared.add(profile: newProfile)
                    self.updateStatus(for: newProfile.id, status: .mounted)
                    self.mountPaths[newProfile.id] = f_mntonname
                }
            }
        }
    }

    // MARK: - Discovery Import

    func importDiscoveredServer(url: String, bonjourHostname: String? = nil, mountPoint: String = "", completion: @escaping @Sendable (Result<MountProfile, Error>) -> Void) {

        // 1. Check by Bonjour hostname
        if let hostname = bonjourHostname,
           let existingIndex = ConfigManager.shared.profiles.firstIndex(where: { $0.bonjourHostname == hostname }) {

            var profile = ConfigManager.shared.profiles[existingIndex]

            if let newURL = URL(string: url), let newHost = newURL.host,
               let currentURL = URL(string: profile.serverURL), let currentHost = currentURL.host,
               newHost != currentHost {

                Logger.info("Updating IP for \(hostname) from \(currentHost) to \(newHost)")

                if var components = URLComponents(string: profile.serverURL) {
                    components.host = newHost
                    if let updatedURLStr = components.string {
                        profile.serverURL = updatedURLStr
                        ConfigManager.shared.update(profile: profile)
                    }
                }
            }

            completion(.success(profile))
            return
        }

        // 2. Check by URL
        let normalizedURL = url.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let existingProfile = ConfigManager.shared.profiles.first(where: {
            $0.serverURL.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) == normalizedURL
        }) {
            if existingProfile.bonjourHostname == nil && bonjourHostname != nil {
                var updated = existingProfile
                updated.bonjourHostname = bonjourHostname
                ConfigManager.shared.update(profile: updated)
            }

            if self.currentStatus[existingProfile.id] != .mounted {
                Logger.info("Profile exists but is unmounted. Attempting to mount: \(existingProfile.serverURL)")
                self.mount(profile: existingProfile) { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success:
                            completion(.success(existingProfile))
                        case .failure(let error):
                            completion(.failure(error))
                        }
                    }
                }
            } else {
                completion(.success(existingProfile))
            }
            return
        }

        // 3. Try-mount for new server
        let tempProfile = MountProfile(serverURL: url, mountPoint: mountPoint, bonjourHostname: bonjourHostname)

        self.mount(profile: tempProfile) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let mountedPath):
                    var finalURL = url
                    if let resolvedURL = self.getActualURL(from: mountedPath) {
                        if let originalURLObj = URL(string: url),
                           let originalPort = originalURLObj.port,
                           let resolvedURLObj = URL(string: resolvedURL),
                           resolvedURLObj.port == nil {
                            var components = URLComponents(url: resolvedURLObj, resolvingAgainstBaseURL: false)
                            components?.port = originalPort
                            if let fixedURL = components?.string {
                                finalURL = fixedURL
                            } else {
                                finalURL = resolvedURL
                            }
                        } else {
                            finalURL = resolvedURL
                        }
                    }

                    let newProfile = MountProfile(serverURL: finalURL, mountPoint: mountPoint, bonjourHostname: bonjourHostname)

                    if let existing = ConfigManager.shared.profiles.first(where: { $0.serverURL == finalURL }) {
                        Logger.info("Profile already exists for \(finalURL). Skipping add.")
                        // Transfer status from temp to existing
                        self.mountPaths.removeValue(forKey: tempProfile.id)
                        self.currentStatus.removeValue(forKey: tempProfile.id)
                        self.updateStatus(for: existing.id, status: .mounted)
                        self.mountPaths[existing.id] = mountedPath
                        completion(.success(existing))
                    } else {
                        ConfigManager.shared.add(profile: newProfile)

                        self.mountPaths.removeValue(forKey: tempProfile.id)
                        self.currentStatus.removeValue(forKey: tempProfile.id)

                        self.updateStatus(for: newProfile.id, status: .mounted)
                        self.mountPaths[newProfile.id] = mountedPath

                        Logger.info("Successfully added and mounted: \(finalURL)")
                        completion(.success(newProfile))
                    }

                case .failure(let error):
                    Logger.error("Failed to verify/mount server \(url): \(error.localizedDescription)")
                    // Clean up temp status
                    self.currentStatus.removeValue(forKey: tempProfile.id)
                    completion(.failure(error))
                }
            }
        }
    }
}
