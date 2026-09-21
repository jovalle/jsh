import AppKit
import ApplicationServices
import Foundation

// Revoke app privacy grants through the English macOS Privacy & Security pane.
struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
struct Change {
    let category: String
    let name: String
}
struct Policy: Codable {
    let schema: Int
    let allow: [String: [String]]
}

let arguments = Set(CommandLine.arguments.dropFirst())
let inspectOnly = arguments.contains("--dry-run") || arguments.contains("--check")
let exportOnly = arguments.contains("--export")
let managedCategories = Set([
    "App Management",
    "Automation",
    "Bluetooth",
    "Calendars",
    "Camera",
    "Contacts",
    "Developer Tools",
    "Device Control and Data Access",
    "Files & Folders",
    "Focus",
    "Full Disk Access",
    "Home",
    "Input Monitoring",
    "Local Network",
    "Location Services",
    "Media & Apple Music",
    "Microphone",
    "Motion & Fitness",
    "Passkeys Access for Web Browsers",
    "Photos",
    "Reminders",
    "Remote Desktop",
    "Screen & System Audio Recording",
    "Speech Recognition",
])
let ignoredCategories = Set([
    "Accessibility",
    "Analytics & Improvements",
    "Apple Advertising",
    "Apple Intelligence Report",
    "Blocked Contacts",
    "Lockdown Mode",
    "Sensitive Content Warning",
])

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}
func string(_ element: AXUIElement, _ name: String) -> String {
    attribute(element, name) as? String ?? ""
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}
func descendants(_ element: AXUIElement) -> [AXUIElement] {
    children(element).flatMap { [$0] + descendants($0) }
}
func role(_ element: AXUIElement) -> String { string(element, kAXRoleAttribute) }
func identifier(_ element: AXUIElement) -> String { string(element, kAXIdentifierAttribute) }
func argumentValue(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
func argumentValues(_ name: String) -> [String] {
    let arguments = CommandLine.arguments
    return arguments.indices.compactMap { index in
        arguments[index] == name && index + 1 < arguments.count ? arguments[index + 1] : nil
    }
}
func waitFor<T>(_ description: String, _ operation: () -> T?) throws -> T {
    let deadline = Date().addingTimeInterval(10)
    repeat {
        if let result = operation() { return result }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    throw Failure("Timed out waiting for \(description). Rerun to finish any remaining permissions.")
}
func press(_ element: AXUIElement) throws {
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else { throw Failure("Cannot operate \(identifier(element)): AX error \(result.rawValue)") }
}
func emit(_ event: String, _ current: Int, _ total: Int, _ detail: String) {
    let safeDetail = detail.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    print("\(event)\t\(current)\t\(total)\t\(safeDetail)")
    fflush(stdout)
}
func mainWindow() throws -> AXUIElement {
    try waitFor("System Settings window") {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.first { string($0, kAXIdentifierAttribute) == "Main" }
    }
}
func systemSettingsElements() -> [AXUIElement] {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else { return [] }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
    return windows.flatMap { [$0] + descendants($0) }
}
func categoryName(_ element: AXUIElement) -> String? {
    let id = identifier(element)
    guard let marker = id.range(of: "_Navigator") else { return nil }
    return String(id[..<marker.lowerBound])
}
func categoryButtons() throws -> [AXUIElement] {
    let buttons = descendants(try mainWindow()).filter { role($0) == kAXButtonRole && categoryName($0) != nil }
    let unknown = Set(buttons.compactMap(categoryName)).subtracting(managedCategories).subtracting(ignoredCategories)
    guard unknown.isEmpty else { throw Failure("Unknown privacy categories: \(unknown.sorted().joined(separator: ", ")).") }
    return buttons.filter { categoryName($0).map(managedCategories.contains) == true }
}
func openPrivacySettings() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw Failure("Cannot open Privacy & Security.") }
}
func foregroundSystemSettings() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", "System Settings"]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw Failure("Cannot foreground System Settings for authorization.") }
}
func authorizationPromptVisible() -> Bool {
    systemSettingsElements().contains {
        ["AXSheet", "AXDialog", "AXSecureTextField"].contains(role($0))
    }
}
func waitForPermissionChange(
    id: String,
    previousCount: Int,
    category: String,
    name: String,
    current: Int,
    total: Int
) throws {
    var deadline = Date().addingTimeInterval(10)
    var awaitingAuthorization = false
    var authorizationDismissedAt: Date?
    repeat {
        guard let window = try? mainWindow() else {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            continue
        }
        let remaining = descendants(window).filter {
            role($0) == kAXCheckBoxRole && identifier($0) == id &&
                (attribute($0, kAXValueAttribute) as? NSNumber)?.intValue != 0
        }.count
        if remaining < previousCount { return }
        if authorizationPromptVisible() {
            authorizationDismissedAt = nil
            if !awaitingAuthorization {
                awaitingAuthorization = true
                deadline = Date().addingTimeInterval(300)
                emit("AUTH", current, total, "\(category) / \(name)")
                try foregroundSystemSettings()
            }
        } else if awaitingAuthorization {
            if authorizationDismissedAt == nil {
                authorizationDismissedAt = Date()
                deadline = Date().addingTimeInterval(10)
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    if authorizationDismissedAt != nil {
        throw Failure("Authorization was dismissed before changing \(category) / \(name).")
    }
    if awaitingAuthorization {
        throw Failure("Timed out waiting for authorization for \(category) / \(name).")
    }
    throw Failure("Timed out waiting for \(category) / \(name) to turn off.")
}
func overview() throws {
    try openPrivacySettings()
    try press(try waitFor("Privacy & Security") {
        guard let window = try? mainWindow() else { return nil }
        return descendants(window).first { identifier($0) == "com.apple.settings.privacyAndSecurity" }
    })
    for _ in 0..<4 {
        if !(try categoryButtons()).isEmpty { return }
        guard let back = descendants(try mainWindow()).first(where: { identifier($0) == "chevron.backward" }) else { break }
        try press(back)
        _ = try waitFor("Privacy & Security overview") { () -> Bool? in
            guard let buttons = try? categoryButtons() else { return nil }
            return buttons.isEmpty ? nil : true
        }
    }
    guard !(try categoryButtons()).isEmpty else {
        throw Failure("Cannot locate privacy categories. An English System Settings interface is required.")
    }
}
func enter(_ category: String) throws {
    let button: AXUIElement = try waitFor(category) {
        guard let buttons = try? categoryButtons() else { return nil }
        return buttons.first { categoryName($0) == category }
    }
    try press(button)
    _ = try waitFor(category) { () -> Bool? in
        guard let buttons = try? categoryButtons() else { return nil }
        return buttons.contains(where: { categoryName($0) == category }) ? nil : true
    }
}
func back() throws {
    let button: AXUIElement = try waitFor("Privacy & Security back button") {
        guard let window = try? mainWindow() else { return nil }
        return descendants(window).first { identifier($0) == "chevron.backward" }
    }
    try press(button)
    _ = try waitFor("Privacy & Security overview") { () -> Bool? in
        guard let buttons = try? categoryButtons() else { return nil }
        return buttons.isEmpty ? nil : true
    }
}
func expandRows() throws {
    for _ in 0..<100 {
        let collapsed = descendants(try mainWindow()).first {
            role($0) == "AXDisclosureTriangle" && (attribute($0, kAXValueAttribute) as? NSNumber)?.intValue == 0
        }
        guard let collapsed else { return }
        try press(collapsed)
    }
    throw Failure("Too many nested permission rows.")
}
func permissionName(_ control: AXUIElement) throws -> String {
    let id = identifier(control)
    guard !id.isEmpty else { throw Failure("Found an unnamed privacy control.") }
    return id.replacingOccurrences(of: "_Toggle", with: "").replacingOccurrences(of: ".app", with: "")
}
func isPreserved(_ change: Change) -> Bool {
    change.category == "Location Services" && ["Location_Services", "Find My"].contains(change.name)
}
func enabledPermissions(in category: String) throws -> [Change] {
    try expandRows()
    return try descendants(try mainWindow()).filter {
        role($0) == kAXCheckBoxRole && (attribute($0, kAXValueAttribute) as? NSNumber)?.intValue != 0
    }.map { Change(category: category, name: try permissionName($0)) }.filter { !isPreserved($0) }
}
func currentPermissions() throws -> [Change] {
    try overview()
    let categories = try categoryButtons().compactMap(categoryName)
    var changes = [Change]()
    for category in categories {
        try enter(category)
        changes.append(contentsOf: try enabledPermissions(in: category))
        try back()
    }
    return changes
}
func permissionKey(_ change: Change) -> String { "\(change.category)\u{0}\(change.name)" }
func loadPolicy(_ path: String) throws -> Set<String> {
    let policy: Policy
    do {
        policy = try JSONDecoder().decode(Policy.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        throw Failure("Cannot read privacy policy \(path): \(error.localizedDescription)")
    }
    guard policy.schema == 1 else { throw Failure("Unsupported privacy policy schema: \(policy.schema).") }
    let unknown = Set(policy.allow.keys).subtracting(managedCategories)
    guard unknown.isEmpty else { throw Failure("Unknown policy categories: \(unknown.sorted().joined(separator: ", ")).") }
    var allowed = Set<String>()
    for (category, names) in policy.allow {
        guard Set(names).count == names.count else { throw Failure("Duplicate entries in privacy policy category: \(category).") }
        for name in names {
            guard !name.isEmpty else { throw Failure("Empty permission name in privacy policy category: \(category).") }
            allowed.insert(permissionKey(Change(category: category, name: name)))
        }
    }
    return allowed
}
func exportPolicy(_ changes: [Change]) throws {
    var grouped = [String: Set<String>]()
    for change in changes { grouped[change.category, default: []].insert(change.name) }
    let allow = grouped.mapValues { $0.sorted() }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(Policy(schema: 1, allow: allow))
    guard let output = String(data: data, encoding: .utf8) else { throw Failure("Cannot encode privacy policy.") }
    print(output)
}
func plan(_ allowed: Set<String>) throws -> [Change] {
    try currentPermissions().filter { !allowed.contains(permissionKey($0)) }
}
func printPlan(_ changes: [Change]) {
    let totals = Dictionary(grouping: changes, by: { "\($0.category)\u{0}\($0.name)" }).mapValues(\.count)
    var occurrences = [String: Int]()
    for change in changes {
        let key = "\(change.category)\u{0}\(change.name)"
        occurrences[key, default: 0] += 1
        let suffix = totals[key, default: 0] > 1 ? " [\(occurrences[key, default: 0]) of \(totals[key, default: 0])]" : ""
        print("\(change.category) / \(change.name)\(suffix): Allowed -> Not Allowed")
    }
}
func revokePermissions(_ allowed: Set<String>, total: Int, targetCategories: Set<String>) throws -> Int {
    try overview()
    try foregroundSystemSettings()
    let availableCategories = try categoryButtons().compactMap(categoryName)
    let missingCategories = targetCategories.subtracting(availableCategories)
    guard missingCategories.isEmpty else {
        throw Failure("Cannot locate target privacy categories: \(missingCategories.sorted().joined(separator: ", ")).")
    }
    let categories = availableCategories.filter(targetCategories.contains)
    var revoked = 0
    for category in categories {
        try enter(category)
        for _ in 0..<500 {
            try expandRows()
            let controls = descendants(try mainWindow()).filter {
                role($0) == kAXCheckBoxRole && (attribute($0, kAXValueAttribute) as? NSNumber)?.intValue != 0
            }
            var next: AXUIElement?
            for control in controls {
                let change = Change(category: category, name: try permissionName(control))
                if !isPreserved(change) && !allowed.contains(permissionKey(change)) { next = control; break }
            }
            guard let control = next else { break }
            let name = try permissionName(control)
            let id = identifier(control)
            let previousCount = controls.filter { identifier($0) == id }.count
            guard attribute(control, kAXEnabledAttribute) as? Bool == true else {
                throw Failure("\(category) / \(name) is allowed but cannot be changed.")
            }
            emit("BEGIN", revoked, total, "\(category) / \(name)")
            try press(control)
            try waitForPermissionChange(
                id: id,
                previousCount: previousCount,
                category: category,
                name: name,
                current: revoked,
                total: total
            )
            revoked += 1
            emit("PROGRESS", revoked, total, "\(category) / \(name)")
        }
        let remaining = try enabledPermissions(in: category).filter { !allowed.contains(permissionKey($0)) }
        guard remaining.isEmpty else { throw Failure("Some \(category) permissions remain allowed.") }
        try back()
    }
    emit("COMPLETE", revoked, revoked, "Complete")
    return revoked
}
func run() throws {
    guard AXIsProcessTrusted() else {
        throw Failure("Enable Accessibility for your terminal in System Settings > Privacy & Security > Accessibility, then rerun.")
    }
    if exportOnly {
        try exportPolicy(currentPermissions())
        return
    }
    guard let policyPath = argumentValue("--policy") else { throw Failure("A privacy policy path is required.") }
    let allowed = try loadPolicy(policyPath)
    if inspectOnly {
        let pending = try plan(allowed)
        if !pending.isEmpty { printPlan(pending) }
        if arguments.contains("--check") && !pending.isEmpty {
            throw Failure("Privacy permissions differ from the desired state.")
        }
        return
    }
    guard let totalValue = argumentValue("--total"), let total = Int(totalValue), total >= 0 else {
        throw Failure("A valid permission total is required when applying changes.")
    }
    let targetCategories = Set(argumentValues("--category"))
    guard !targetCategories.isEmpty else { throw Failure("At least one target privacy category is required when applying changes.") }
    let unknownTargets = targetCategories.subtracting(managedCategories)
    guard unknownTargets.isEmpty else {
        throw Failure("Unknown target privacy categories: \(unknownTargets.sorted().joined(separator: ", ")).")
    }
    let revoked = try revokePermissions(allowed, total: total, targetCategories: targetCategories)
    if revoked != 0 { print("Revoked \(revoked) privacy permissions.") }
}

do { try run() }
catch { fputs("\(error)\n", stderr); exit(1) }
