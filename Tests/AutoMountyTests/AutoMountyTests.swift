import XCTest
@testable import AutoMountyModel

final class AutoMountyTests: XCTestCase {
    
    func testMountProfileDisplayName() throws {
        // Test Case 1: Standard URL
        let profile1 = MountProfile(serverURL: "smb://user@server/share", mountPoint: "/Volumes/share")
        XCTAssertEqual(profile1.displayName, "share", "Should extract last component")
        
        // Test Case 2: Root URL
        let profile2 = MountProfile(serverURL: "smb://server", mountPoint: "")
        XCTAssertEqual(profile2.displayName, "server", "Should use host if path is empty")
        
        // Test Case 3: Empty
        let profile3 = MountProfile(serverURL: "", mountPoint: "")
        XCTAssertEqual(profile3.displayName, "Untitled Server", "Should return fallback name")
    }
    
    func testMountProfileJSONCoding() throws {
        let originalProfile = MountProfile(
            serverURL: "smb://test/data",
            mountPoint: "/Volumes/data",
            rules: [
                MountRule(type: .wifi, operator: .equals, value: "HomeWiFi")
            ],
            ruleLogic: .any,
            isEnabled: true,
            autoMount: true,
            bonjourHostname: "MyNAS",
            automations: [
                AutomationConfig(type: .shell, enabled: true, path: "/bin/ls", arguments: "-la", events: [.mounted])
            ]
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(originalProfile)
        
        let decoder = JSONDecoder()
        let decodedProfile = try decoder.decode(MountProfile.self, from: data)
        
        XCTAssertEqual(originalProfile.id, decodedProfile.id)
        XCTAssertEqual(originalProfile.serverURL, decodedProfile.serverURL)
        XCTAssertEqual(originalProfile.rules.count, 1)
        XCTAssertEqual(originalProfile.rules.first?.value, "HomeWiFi")
        XCTAssertEqual(originalProfile.automations.count, 1)
        XCTAssertEqual(originalProfile.automations.first?.path, "/bin/ls")
    }
    
    func testRuleLogic() {
        let allLogic = RuleLogic.all
        XCTAssertEqual(allLogic.id, "All")
        
        let anyLogic = RuleLogic.any
        XCTAssertEqual(anyLogic.id, "Any")
    }

    func testNormalizedServerURL() {
        // Same URL with different case should normalize equally
        let p1 = MountProfile(serverURL: "smb://Server/Share", mountPoint: "")
        let p2 = MountProfile(serverURL: "smb://server/share", mountPoint: "")
        XCTAssertEqual(p1.normalizedServerURL, p2.normalizedServerURL, "Case-insensitive match")

        // Username should be stripped
        let p3 = MountProfile(serverURL: "smb://user@server/share", mountPoint: "")
        let p4 = MountProfile(serverURL: "smb://server/share", mountPoint: "")
        XCTAssertEqual(p3.normalizedServerURL, p4.normalizedServerURL, "Username stripped")

        // Trailing slashes should be trimmed
        let p5 = MountProfile(serverURL: "smb://server/share/", mountPoint: "")
        let p6 = MountProfile(serverURL: "smb://server/share", mountPoint: "")
        XCTAssertEqual(p5.normalizedServerURL, p6.normalizedServerURL, "Trailing slash trimmed")

        // Different paths should NOT match
        let p7 = MountProfile(serverURL: "smb://server/share1", mountPoint: "")
        let p8 = MountProfile(serverURL: "smb://server/share2", mountPoint: "")
        XCTAssertNotEqual(p7.normalizedServerURL, p8.normalizedServerURL, "Different paths")
    }
}
