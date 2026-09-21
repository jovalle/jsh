import AppKit
import ApplicationServices

// Operate the actual controls. macOS 27 no longer applies com.apple.ncprefs edits.
// This UI adapter targets the English Notifications pane and fails on unknown layouts.
struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
let arguments = Set(CommandLine.arguments.dropFirst())
let inspectOnly = arguments.contains("--dry-run") || arguments.contains("--check")

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
func label(_ element: AXUIElement) -> String {
    let title = string(element, kAXTitleAttribute)
    if !title.isEmpty { return title }
    if let linked = attribute(element, kAXTitleUIElementAttribute) {
        let text = string(unsafeBitCast(linked, to: AXUIElement.self), kAXValueAttribute)
        if !text.isEmpty { return text }
    }
    return string(element, kAXDescriptionAttribute)
}
func waitFor<T>(_ description: String, _ operation: () -> T?) throws -> T {
    let deadline = Date().addingTimeInterval(10)
    repeat {
        if let result = operation() { return result }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    throw Failure("Timed out waiting for \(description). No success was reported; rerun to finish any remaining controls.")
}
func press(_ element: AXUIElement) throws {
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else { throw Failure("Cannot press \(label(element)): AX error \(result.rawValue)") }
}
func mainWindow() throws -> AXUIElement {
    try waitFor("System Settings window") {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.first { string($0, kAXIdentifierAttribute) == "Main" }
    }
}
func findID(_ id: String) throws -> AXUIElement {
    try waitFor(id) {
        guard let window = try? mainWindow() else { return nil }
        return descendants(window).first { string($0, kAXIdentifierAttribute) == id }
    }
}
func overview() throws {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    try press(findID("com.apple.settings.notifications"))
    let elements = descendants(try mainWindow())
    if elements.contains(where: { string($0, kAXIdentifierAttribute) == "allow-when-sleeping" }) { return }
    guard let backButton = elements.first(where: { string($0, kAXIdentifierAttribute) == "chevron.backward" }) else {
        _ = try findID("allow-when-sleeping")
        return
    }
    try press(backButton)
    _ = try findID("allow-when-sleeping")
}
func off(_ control: AXUIElement, _ name: String) throws {
    guard let value = attribute(control, kAXValueAttribute) as? NSNumber else {
        throw Failure("Cannot read \(name).")
    }
    if value.intValue != 0 {
        guard attribute(control, kAXEnabledAttribute) as? Bool == true else {
            throw Failure("\(name) is on but cannot be changed.")
        }
        try press(control)
    }
    let id = string(control, kAXIdentifierAttribute)
    let controlRole = role(control)
    let controlLabel = label(control)
    _ = try waitFor("\(name) to turn off") { () -> Bool? in
        guard let window = try? mainWindow() else { return nil }
        let current = descendants(window).first {
            if !id.isEmpty { return string($0, kAXIdentifierAttribute) == id }
            return role($0) == controlRole && label($0) == controlLabel
        }
        return (current.flatMap { attribute($0, kAXValueAttribute) } as? NSNumber)?.intValue == 0 ? true : nil
    }
}
func choose(_ id: String, _ title: String) throws {
    let control = try findID(id)
    if string(control, kAXValueAttribute) != title {
        try press(control)
        let item: AXUIElement = try waitFor(title) {
            guard let window = try? mainWindow() else { return nil }
            return descendants(window).first { role($0) == kAXMenuItemRole && label($0) == title }
        }
        try press(item)
    }
    _ = try waitFor("\(id) = \(title)") { () -> Bool? in
        guard let window = try? mainWindow() else { return nil }
        let current = descendants(window).first { string($0, kAXIdentifierAttribute) == id }
        return current.map { string($0, kAXValueAttribute) == title } == true ? true : nil
    }
}
func appButtons() throws -> [AXUIElement] {
    let window = try mainWindow()
    guard let heading = descendants(window).first(where: {
        role($0) == "AXHeading" && label($0) == "Application Notifications"
    }) else { throw Failure("Cannot locate Application Notifications. An English System Settings interface is required.") }
    guard let parentValue = attribute(heading, kAXParentAttribute) else { throw Failure("Missing application list.") }
    let parent = unsafeBitCast(parentValue, to: AXUIElement.self)
    let siblings = children(parent)
    guard let index = siblings.firstIndex(where: { CFEqual($0, heading) }), index + 1 < siblings.count else {
        throw Failure("Unknown application list layout.")
    }
    let buttons = descendants(siblings[index + 1]).filter { role($0) == kAXButtonRole }
    guard !buttons.isEmpty else { throw Failure("No app notification controls found.") }
    return buttons
}
func buttonText(_ button: AXUIElement) -> String {
    label(button)
}
func appIsOff(_ button: AXUIElement) -> Bool {
    buttonText(button).hasSuffix(", Off")
}
func appName(_ button: AXUIElement) -> String {
    buttonText(button).components(separatedBy: ", ").first ?? buttonText(button)
}
func appButton(_ name: String) throws -> AXUIElement {
    try waitFor(name) {
        guard let buttons = try? appButtons() else { return nil }
        return buttons.first { appName($0) == name }
    }
}
func back() throws {
    try press(findID("chevron.backward"))
    _ = try findID("allow-when-sleeping")
}
struct Change {
    let name: String
    let current: String
    let desired: String
}
func changes() throws -> [Change] {
    var changes = [Change]()
    for id in ["allow-when-sleeping", "allow-when-locked"] {
        let control = try findID(id)
        if (attribute(control, kAXValueAttribute) as? NSNumber)?.intValue != 0 {
            let name = label(control)
            changes.append(Change(name: name.isEmpty ? id : name, current: "On", desired: "Off"))
        }
    }
    for (id, expected) in [("show-previews", "Never"), ("allow-when-sharing", "Notifications Off")] {
        let control = try findID(id)
        let current = string(control, kAXValueAttribute)
        let name = label(control)
        if current != expected { changes.append(Change(name: name.isEmpty ? id : name, current: current, desired: expected)) }
    }
    let summary = try findID("summarize-previews")
    if role(summary) == kAXButtonRole && !buttonText(summary).hasSuffix("Off") {
        changes.append(Change(name: "Summarize notifications", current: "On", desired: "Off"))
    }
    for button in try appButtons() where !appIsOff(button) {
        let name = buttonText(button).components(separatedBy: ", ").first ?? buttonText(button)
        changes.append(Change(name: name, current: "On", desired: "Off"))
    }
    return changes
}
func printPlan(_ changes: [Change]) {
    for change in changes {
        print("\(change.name): \(change.current) -> \(change.desired)")
    }
}
func run() throws {
    guard AXIsProcessTrusted() else {
        throw Failure("Enable Accessibility for your terminal in System Settings > Privacy & Security > Accessibility, then rerun.")
    }
    try overview()
    if inspectOnly {
        let pending = try changes()
        if !pending.isEmpty { printPlan(pending) }
        if arguments.contains("--check") && !pending.isEmpty { throw Failure("Notification controls differ from the desired state.") }
        return
    }
    try off(findID("allow-when-sleeping"), "Notifications while sleeping")
    try off(findID("allow-when-locked"), "Notifications while locked")
    try choose("show-previews", "Never")
    try choose("allow-when-sharing", "Notifications Off")
    print("Verified global notification controls.")
    let summary = try findID("summarize-previews")
    if !buttonText(summary).hasSuffix("Off") {
        try press(summary)
        let toggle: AXUIElement = try waitFor("Summarize notifications switch") {
            guard let window = try? mainWindow() else { return nil }
            return descendants(window).first { role($0) == kAXCheckBoxRole && label($0) == "Summarize notifications" }
        }
        try off(toggle, "Summarize notifications")
        try back()
    }
    let names = try appButtons().map(appName)
    for name in names {
        let button = try appButton(name)
        if appIsOff(button) { continue }
        try press(button)
        try off(findID("allow-notifications"), name)
        try back()
        guard appIsOff(try appButton(name)) else { throw Failure("\(name) still has notifications enabled.") }
        print("Disabled \(name).")
        fflush(stdout)
    }
    let remaining = try changes()
    guard remaining.isEmpty else { throw Failure("Notification controls still differ from the desired state.") }
    print("Verified all \(names.count) applications and global notification controls are off.")
}
do { try run() }
catch { fputs("\(error)\n", stderr); exit(1) }
