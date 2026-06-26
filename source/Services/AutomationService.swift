import Foundation
import AutoMountyModel
import AppKit

/// Result of automation execution, used to signal success/failure back to caller.
struct AutomationResult: Sendable {
    let hasFailures: Bool
    let failedCount: Int
    let totalCount: Int

    static let empty = AutomationResult(hasFailures: false, failedCount: 0, totalCount: 0)
}

struct AutomationService {
    static let shared = AutomationService()

    /// Maximum time a script is allowed to run (seconds)
    private static let scriptTimeout: TimeInterval = 60

    private init() {}

    /// Executes all enabled automations for a specific event within a profile.
    /// Returns an `AutomationResult` indicating whether any scripts failed.
    @discardableResult
    func executeAutomations(
        for event: ScriptEvent,
        profile: MountProfile,
        environment: [String: String] = [:]
    ) async -> AutomationResult {
        let tasks = profile.automations.filter { $0.enabled && $0.events.contains(event) }
        guard !tasks.isEmpty else { return .empty }

        Logger.info("Executing \(tasks.count) automation(s) for event: \(event.rawValue) on \(profile.serverURL)")

        // Build base environment available to all scripts
        var baseEnv: [String: String] = [
            "AUTOMOUNTY_SERVER_URL": profile.serverURL,
            "AUTOMOUNTY_PROFILE_NAME": profile.displayName,
            "AUTOMOUNTY_EVENT": event.rawValue
        ]
        if !profile.mountPoint.isEmpty {
            baseEnv["AUTOMOUNTY_MOUNT_POINT"] = profile.mountPoint
        }
        if let hostname = profile.bonjourHostname {
            baseEnv["AUTOMOUNTY_BONJOUR_HOST"] = hostname
        }
        // Merge caller-provided environment (overrides base)
        for (key, value) in environment {
            baseEnv[key] = value
        }

        var failedCount = 0
        for task in tasks {
            let success = await runAutomation(task, environment: baseEnv)
            if !success { failedCount += 1 }
        }

        return AutomationResult(
            hasFailures: failedCount > 0,
            failedCount: failedCount,
            totalCount: tasks.count
        )
    }

    @discardableResult
    private func runAutomation(_ config: AutomationConfig, environment: [String: String]) async -> Bool {
        let success: Bool
        switch config.type {
        case .shell:
            success = await runShellScript(config, environment: environment)
        case .app:
            success = await launchApp(config)
        case .wol:
            success = await sendWOL(config)
        }

        // Handle Wait Time
        if config.waitTime > 0 {
            Logger.info("Waiting \(config.waitTime)s after \(config.type.rawValue)...")
            try? await Task.sleep(nanoseconds: UInt64(config.waitTime * 1_000_000_000))
        }

        return success
    }

    // MARK: - Shell Script

    private func runShellScript(_ config: AutomationConfig, environment: [String: String]) async -> Bool {
        guard !config.path.isEmpty else { return true }

        Logger.debug("Running script: \(config.path) \(config.arguments)")

        let process = Process()

        // Use /bin/sh -c for proper shell argument parsing (handles quoted paths etc.)
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        var shellCommand = "'\(config.path.replacingOccurrences(of: "'", with: "'\\''"))'"
        if !config.arguments.isEmpty {
            shellCommand += " \(config.arguments)"
        }
        process.arguments = ["-c", shellCommand]

        // Inject environment variables
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()

            let exitCode = await MountyManager.waitForProcess(process, timeout: AutomationService.scriptTimeout)

            // Capture and log output
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            if let stdout = String(data: stdoutData, encoding: .utf8), !stdout.isEmpty {
                for line in stdout.components(separatedBy: .newlines) where !line.isEmpty {
                    Logger.debug("[\(config.path) stdout] \(line)")
                }
            }
            if let stderr = String(data: stderrData, encoding: .utf8), !stderr.isEmpty {
                for line in stderr.components(separatedBy: .newlines) where !line.isEmpty {
                    Logger.error("[\(config.path) stderr] \(line)")
                }
            }

            if exitCode == 0 {
                Logger.info("Script completed successfully: \(config.path)")
                return true
            } else if exitCode == -1 {
                Logger.error("Script timed out: \(config.path)")
                return false
            } else {
                Logger.error("Script failed with exit code \(exitCode): \(config.path)")
                return false
            }
        } catch {
            Logger.error("Failed to run script \(config.path): \(error)")
            return false
        }
    }

    // MARK: - App Launch

    private func launchApp(_ config: AutomationConfig) async -> Bool {
        guard !config.path.isEmpty else { return true }

        Logger.debug("Launching app: \(config.path)")
        let result = await MainActor.run {
            NSWorkspace.shared.open(URL(fileURLWithPath: config.path))
        }

        if !result {
            Logger.error("Failed to launch app: \(config.path)")
        }
        return result
    }

    // MARK: - Wake On LAN

    private func sendWOL(_ config: AutomationConfig) async -> Bool {
        guard !config.macAddress.isEmpty else {
            Logger.error("WOL: empty MAC address")
            return false
        }

        Logger.info("Sending WOL to \(config.macAddress) (broadcast: \(config.broadcastAddress):\(config.port))")
        await NetworkService.shared.sendWOL(
            macAddress: config.macAddress,
            broadcastAddress: config.broadcastAddress,
            port: config.port
        )
        return true
    }
}
