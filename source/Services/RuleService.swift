import Foundation
import AutoMountyModel
import AppKit
import CoreWLAN
import SystemConfiguration.CaptiveNetwork

struct RuleService {
    static let shared = RuleService()

    private init() {}

    // MARK: - Rule Evaluation

    /// Evaluates if a profile's auto-mount rules are satisfied.
    func evaluateRules(for profile: MountProfile, currentSSID: String?) async -> Bool {
        if profile.rules.isEmpty {
            return true
        }

        let logic = profile.ruleLogic
        var results: [Bool] = []

        for rule in profile.rules {
            let result: Bool
            switch rule.type {
            case .wifi:
                result = evaluateWiFiRule(rule, currentSSID: currentSSID)
            case .app:
                let runningApps = await SystemInfoService.shared.getRunningApplications()
                result = evaluateAppRule(rule, runningApps: runningApps)
            case .vpn:
                let vpnInterfaces = NetworkService.shared.getAvailableVPNInterfaces()
                result = evaluateVPNRule(rule, vpnInterfaces: vpnInterfaces)
            }
            results.append(result)
        }

        if logic == .all {
            return !results.contains(false)
        } else {
            return results.contains(true)
        }
    }

    // MARK: - Per-Type Rule Evaluation

    private func evaluateWiFiRule(_ rule: MountRule, currentSSID: String?) -> Bool {
        guard let current = currentSSID else {
            return rule.operator == .doesNotEqual
        }

        switch rule.operator {
        case .equals:
            return current == rule.value
        case .doesNotEqual:
            return current != rule.value
        case .contains:
            return current.localizedCaseInsensitiveContains(rule.value)
        }
    }

    private func evaluateAppRule(_ rule: MountRule, runningApps: [String]) -> Bool {
        let matches: Bool
        switch rule.operator {
        case .equals:
            matches = runningApps.contains { $0.localizedCaseInsensitiveCompare(rule.value) == .orderedSame }
        case .doesNotEqual:
            matches = !runningApps.contains { $0.localizedCaseInsensitiveCompare(rule.value) == .orderedSame }
        case .contains:
            matches = runningApps.contains { $0.localizedCaseInsensitiveContains(rule.value) }
        }
        return matches
    }

    private func evaluateVPNRule(_ rule: MountRule, vpnInterfaces: [String]) -> Bool {
        let vpnActive = !vpnInterfaces.isEmpty

        // If value is empty, treat as "Is VPN Connected" check
        if rule.value.isEmpty {
            switch rule.operator {
            case .equals:
                return vpnActive
            case .doesNotEqual:
                return !vpnActive
            case .contains:
                return vpnActive
            }
        }

        // If value is present, check interface name
        guard vpnActive else {
            // VPN not active: "equals X" -> false, "doesNotEqual X" -> true, "contains X" -> false
            return rule.operator == .doesNotEqual
        }

        switch rule.operator {
        case .equals:
            return vpnInterfaces.contains { $0.localizedCaseInsensitiveCompare(rule.value) == .orderedSame }
        case .doesNotEqual:
            return !vpnInterfaces.contains { $0.localizedCaseInsensitiveCompare(rule.value) == .orderedSame }
        case .contains:
            return vpnInterfaces.contains { $0.localizedCaseInsensitiveContains(rule.value) }
        }
    }
}
