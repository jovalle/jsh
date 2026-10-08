import AppKit
import Carbon
import Network
import QuartzCore

// The companion owns windows/hotkeys; Spotify owns music state and mutations.
struct Request {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func parse(_ data: Data) throws -> Request? {
        guard data.count <= 262144 else { throw MiniError.invalidRequest }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let header = String(data: data[..<boundary.lowerBound], encoding: .utf8) else {
            throw MiniError.invalidRequest
        }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1" else { throw MiniError.invalidRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw MiniError.invalidRequest }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { throw MiniError.invalidRequest }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? "0"), (0...250000).contains(length)
        else { throw MiniError.invalidRequest }
        guard data.count >= boundary.upperBound + length else { return nil }
        guard data.count == boundary.upperBound + length else { throw MiniError.invalidRequest }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers,
                       body: data.subdata(in: boundary.upperBound..<data.count))
    }
}

enum MiniError: Error { case invalidRequest, invalidConfig }

let origins = ["https://xpui.app.spotify.com", "https://open.spotify.com"]
let keyCodes: [String: UInt32] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
    "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16,
    "t": 17, "o": 31, "u": 32, "i": 34, "p": 35,
    "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
]

func migratedKeys(_ keys: [String]) -> [String] {
    guard keys.count == 4 else { return keys }
    return keys + [(["r", "u", "d", "x"] + Array(keyCodes.keys).sorted()).first { !keys.contains($0) && !$0.allSatisfy(\.isNumber) }!]
}

func validKeys(_ keys: [String], modifiers: UInt32) -> Bool {
    let all = keys
    let allowed = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    return keys.count == 5 && all.allSatisfy { keyCodes[$0] != nil } &&
        Set(all).count == all.count && modifiers & ~allowed == 0 &&
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
}

final class SquarePanel: NSPanel {
    var visibilityChanged: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    override func orderOut(_ sender: Any?) { super.orderOut(sender); visibilityChanged?() }
}

final class Gradient: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [NSColor.black.withAlphaComponent(0.94),
                            NSColor.black.withAlphaComponent(0)])?.draw(in: bounds, angle: 90)
    }
}

final class MusicButton: NSButton {
    private var hoverArea: NSTrackingArea?
    var hovered = false { didSet { refreshAppearance() } }
    private var pressing = false
    fileprivate var keyboardFocused = false { didSet { refreshAppearance() } }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        keyboardFocused = accepted && NSApp.currentEvent?.type == .keyDown
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { keyboardFocused = false }
        return resigned
    }

    override var isEnabled: Bool {
        didSet {
            refreshAppearance()
            if oldValue != isEnabled { window?.invalidateCursorRects(for: self) }
        }
    }

    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(hoverArea!)
        super.updateTrackingAreas()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow)
    }
    override func mouseDown(with event: NSEvent) {
        (window?.firstResponder as? MusicButton)?.keyboardFocused = false
        keyboardFocused = false
        guard isEnabled else { return }
        pressing = true
        refreshAppearance()
        displayIfNeeded()
        super.mouseDown(with: event)
        pressing = false
        refreshAppearance()
    }

    func refreshAppearance() {
        guard let layer else { return }
        let scale = isEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ?
            (pressing ? 0.92 : hovered ? 1.1 : 1) : 1
        var transform = CATransform3DMakeScale(scale, scale, 1)
        // AppKit anchors view layers at a corner; keep growth centered on the icon.
        transform.m41 = layer.bounds.width * (0.5 - layer.anchorPoint.x) * (1 - scale)
        transform.m42 = layer.bounds.height * (0.5 - layer.anchorPoint.y) * (1 - scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = transform
        layer.cornerRadius = 4
        layer.borderColor = NSColor.white.cgColor
        layer.borderWidth = keyboardFocused ? 1.5 : 0
        CATransaction.commit()
    }
}

// Keep the confirmed snapshot separate so failed or expired commands restore it.
func displayedState(_ snapshot: [String: Any], _ commands: [[String: Any]]) -> [String: Any] {
    var state = snapshot
    for command in commands where command["uri"] as? String == snapshot["uri"] as? String &&
        command["account"] as? String == snapshot["account"] as? String {
        let action = command["action"] as? String
        if let value = command["value"] as? Bool {
            if action == "like" {
                state["liked"] = value
                if !value { state["loved"] = false }
            }
            if action == "love" {
                state["loved"] = value
                if value { state["liked"] = true }
            }
        }
        if action == "remove" || action == "undo" {
            let original = command["removal"] as? [String: Any] ?? [:]
            var removal = snapshot["removal"] as? [String: Any] ?? [:]
            if ["context", "itemUid", "provider"].allSatisfy({ original[$0] as? String == removal[$0] as? String }) {
                removal["action"] = action == "remove" ? "undo" : "remove"
                state["removal"] = removal
            }
        }
    }
    return state
}

final class Mini: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let configURL: URL
    var config: [String: Any]
    var token: String { config["token"] as! String }
    var port: UInt16 { (config["port"] as! NSNumber).uint16Value }
    var keys: [String] { config["keys"] as? [String] ?? ["m", "h", "l", "p", "r"] }
    var modifiers: UInt32 { (config["modifiers"] as? NSNumber)?.uint32Value ?? UInt32(cmdKey | optionKey | controlKey) }
    var listener: NWListener?
    var panel: SquarePanel!
    var statusItem: NSStatusItem!
    var shortcuts: [UInt32: EventHotKeyRef] = [:]
    var eventHandler: EventHandlerRef?
    var pressed = Set<UInt32>()
    var hotkeyEvents = 0
    var snapshot: [String: Any] = [:]
    var lastSync = Date.distantPast
    var commands: [[String: Any]] = []
    var imageURL = ""
    var imageTask: URLSessionDataTask?
    var visibleActions = false
    let artwork = NSImageView()
    let shade = Gradient()
    let title = NSTextField(labelWithString: "Waiting for Spotify")
    let artist = NSTextField(labelWithString: "Artist unavailable")
    let album = NSTextField(labelWithString: "Album unavailable")
    let notice = NSTextField(labelWithString: "Connecting to Spotify…")
    var buttons: [MusicButton] = []

    init(configURL: URL) throws {
        self.configURL = configURL
        guard let data = try? Data(contentsOf: configURL),
              let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = config["token"] as? String,
              token.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let port = config["port"] as? NSNumber, (1024...65535).contains(port.intValue)
        else { throw MiniError.invalidConfig }
        self.config = config
        self.config["keys"] = migratedKeys(config["keys"] as? [String] ?? ["m", "h", "l", "p", "r"])
        super.init()
        guard validKeys(keys, modifiers: modifiers) else { throw MiniError.invalidConfig }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let showInitially = config["visible"] as? Bool ?? true
        makePanel()
        let menu = NSMenu()
        for (text, action) in [("Show / Hide Mini Player", #selector(toggle)),
                               ("Shortcuts…", #selector(editShortcuts)),
                               ("Reset Position", #selector(resetPosition)),
                               ("Quit Mini Player", #selector(quit))] {
            let item = NSMenuItem(title: text, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Mini Player")
        statusItem.menu = menu
        installHotkeyHandler()
        registerToggle()
        if showInitially { panel.orderFrontRegardless(); save() }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            listener = try NWListener(using: params)
            listener?.newConnectionHandler = { [weak self] connection in self?.receive(connection) }
            listener?.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.showNotice("Connection failed: \(error.localizedDescription)")
                    fputs("Mini Player listener failed: \(error)\n", stderr)
                }
            }
            listener?.start(queue: .main)
        } catch { showNotice("Could not start connection: \(error.localizedDescription)") }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastSync) > 4 {
                self.showNotice("Spotify disconnected — actions disabled")
                self.buttons.forEach { $0.isEnabled = false }
            }
            let now = Date().timeIntervalSince1970 * 1000
            if self.commands.contains(where: { ($0["expires"] as? Double ?? 0) + 10000 < now }) {
                self.showNotice("Action timed out — check Spotify before retrying")
                self.commands.removeAll { ($0["expires"] as? Double ?? 0) + 10000 < now }
                self.refreshPendingButtons()
            }
            self.refreshActionHotkeys()
        }
    }

    func makePanel() {
        let savedBounds = config["bounds"] as? [Double]
        panel = SquarePanel(contentRect: NSRect(x: 100, y: 100, width: 320, height: 320),
            styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Mini Player"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.visibilityChanged = { [weak self] in self?.refreshActionHotkeys() }
        panel.delegate = self
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.aspectRatio = NSSize(width: 1, height: 1)
        panel.minSize = NSSize(width: 280, height: 280)
        panel.maxSize = NSSize(width: 640, height: 640)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if #available(macOS 14.0, *) { panel.collectionBehavior.insert(.canJoinAllApplications) }
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = .black
        panel.isOpaque = true
        let content = NSView()
        panel.contentView = content
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.setAccessibilityLabel("Playing album artwork")
        content.addSubview(artwork)
        content.addSubview(shade)
        for (label, size) in [(title, 19.0), (artist, 14), (album, 12), (notice, 12)] {
            label.font = .systemFont(ofSize: size, weight: label === title ? .semibold : .regular)
            label.textColor = .white
            label.lineBreakMode = .byTruncatingTail
            content.addSubview(label)
        }
        notice.alignment = .center
        for (index, symbol) in ["heart", "star", "plus", "trash"].enumerated() {
            let button = MusicButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: ["Love", "Like", "Add to playlists", "Remove from playing playlist"][index])!,
                                  target: self, action: #selector(clicked(_:)))
            button.tag = index
            button.bezelStyle = .inline
            button.isBordered = false
            button.focusRingType = .none
            (button.cell as? NSButtonCell)?.highlightsBy = []
            button.contentTintColor = .white
            button.wantsLayer = true
            button.setAccessibilityLabel(["Love", "Like", "Add to playlists", "Remove from playing playlist"][index])
            content.addSubview(button)
            buttons.append(button)
        }
        if let bounds = savedBounds, bounds.count == 3,
           bounds.allSatisfy({ $0.isFinite }), (280...640).contains(bounds[2]) {
            panel.setFrame(NSRect(x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[2]), display: false)
        } else {
            panel.setFrame(NSRect(x: 100, y: 100, width: 320, height: 320), display: false)
        }
        clampPosition()
        layout()
    }

    func layout() {
        let size = panel.contentView!.bounds.size
        artwork.frame = NSRect(origin: .zero, size: size)
        shade.frame = NSRect(x: 0, y: 0, width: size.width, height: 166)
        for (label, y, height) in [(title, 121.0, 26.0), (artist, 97, 20), (album, 77, 18)] {
            label.frame = NSRect(x: 16, y: y, width: size.width - 32, height: height)
        }
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: (size.width - CGFloat(buttons.count) * 54 + 10) / 2 + CGFloat(index) * 54, y: 6, width: 44, height: 44)
            button.refreshAppearance()
        }
        notice.frame = NSRect(x: 16, y: 51, width: size.width - 32, height: 20)
    }

    func clampPosition() {
        guard !NSScreen.screens.contains(where: { $0.visibleFrame.contains(panel.frame) }),
              let screen = NSScreen.main else { return }
        var frame = panel.frame
        frame.origin.x = min(max(frame.minX, screen.visibleFrame.minX), screen.visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, screen.visibleFrame.minY), screen.visibleFrame.maxY - frame.height)
        panel.setFrame(frame, display: false)
    }

    func save() {
        config["bounds"] = [panel.frame.minX, panel.frame.minY, panel.frame.width]
        config["visible"] = panel.isVisible
        do { try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        } catch { showNotice("Could not save preferences") }
    }
    func windowDidResize(_ notification: Notification) { layout(); save() }
    func windowDidMove(_ notification: Notification) { save() }
    func windowWillClose(_ notification: Notification) { visibleActions = false; refreshActionHotkeys() }
    func windowDidChangeScreen(_ notification: Notification) { clampPosition() }
    @objc func resetPosition() { panel.center(); save() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func toggle() {
        if panel.isVisible { panel.orderOut(nil); save() }
        else { clampPosition(); panel.orderFrontRegardless(); save() }
        refreshActionHotkeys()
    }
    @objc func clicked(_ button: NSButton) { action(button.tag == 3 ? 13 : button.tag + 1) }

    func showNotice(_ text: String) {
        guard notice.stringValue != text else { return }
        notice.stringValue = text
        notice.toolTip = text
        notice.isHidden = text.isEmpty
        if !text.isEmpty {
            NSAccessibility.post(element: panel!, notification: .announcementRequested,
                userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    func refreshPendingButtons() {
        renderButtons(displayedState(snapshot, commands))
        let actions = Set(commands.map { $0["action"] as? String ?? "" })
        let supported = Date().timeIntervalSince(lastSync) <= 4 && snapshot["supported"] as? Bool == true &&
            !(snapshot["account"] as? String ?? "").isEmpty
        for (index, button) in buttons.enumerated() {
            let pending = index < 2 ? !actions.isDisjoint(with: ["like", "love"]) :
                index == 2 ? actions.contains("add") : !actions.isDisjoint(with: ["remove", "undo"])
            button.setAccessibilityHelp(pending ? "\(button.toolTip ?? "") · Updating Spotify" : button.toolTip)
            let available = index < 2 ? snapshot[index == 0 ? "loved" : "liked"] as? Bool != nil :
                index == 2 ? true : (snapshot["removal"] as? [String: Any])?["enabled"] as? Bool == true
            button.isEnabled = supported && available
        }
    }

    func renderButtons(_ state: [String: Any]) {
        let supported = state["supported"] as? Bool == true && !(state["account"] as? String ?? "").isEmpty
        for (index, key) in ["loved", "liked"].enumerated() {
            let value = state[key] as? Bool
            buttons[index].isEnabled = supported && value != nil
            let symbol = index == 0 ? "heart" : "star"
            buttons[index].image = NSImage(systemSymbolName: symbol + (value == true ? ".fill" : ""), accessibilityDescription: index == 0 ? "Love" : "Like")
            buttons[index].contentTintColor = value == true ? (index == 0 ? .systemRed : .systemYellow) : .white
            let accessibilityValue = value == true ? "On" : "Off"
            let changed = buttons[index].accessibilityValue() as? String != accessibilityValue
            buttons[index].setAccessibilityValue(accessibilityValue)
            if changed { NSAccessibility.post(element: buttons[index], notification: .valueChanged) }
        }
        buttons[2].isEnabled = supported
        let removal = state["removal"] as? [String: Any] ?? [:]
        let undo = removal["action"] as? String == "undo"
        let removalLabel = undo ? "Undo removal" : "Remove from playing playlist"
        buttons[3].isEnabled = supported && removal["enabled"] as? Bool == true
        buttons[3].image = NSImage(systemSymbolName: undo ? "arrow.uturn.backward" : "trash", accessibilityDescription: removalLabel)
        buttons[3].setAccessibilityLabel(removalLabel)
        buttons[3].toolTip = "\(removalLabel) — \(shortcutLabel(keys[4]))\(buttons[3].isEnabled ? "" : " · " + (removal["reason"] as? String ?? "Unavailable"))"
        buttons[0].toolTip = "Love — \(shortcutLabel(keys[1]))"
        buttons[1].toolTip = "Like — \(shortcutLabel(keys[2]))"
        buttons[2].toolTip = "Add to playlists — \(shortcutLabel(keys[3]))"
    }

    func update(_ incoming: [String: Any]) {
        var state = incoming
        if snapshot["account"] as? String == state["account"] as? String && snapshot["uri"] as? String == state["uri"] as? String {
            for key in ["loved", "liked"] where state[key] as? Bool == nil {
                state[key] = snapshot[key] as? Bool
            }
        }
        let accountChanged = snapshot["account"] as? String != state["account"] as? String
        if accountChanged { commands.removeAll(); showNotice("") }
        if accountChanged || snapshot["uri"] as? String != state["uri"] as? String {
            showNotice("")
            buttons.forEach { $0.layer?.removeAllAnimations() }
        }
        snapshot = state
        lastSync = Date()
        for (label, key) in [(title, "title"), (artist, "artist"), (album, "album")] {
            label.stringValue = state[key] as? String ?? "Unavailable"
            label.toolTip = label.stringValue
        }
        refreshPendingButtons()
        if notice.stringValue.hasPrefix("Spotify disconnected") || notice.stringValue.hasPrefix("Connecting") {
            showNotice("")
        }
        let url = state["image"] as? String ?? ""
        if url != imageURL {
            imageURL = url
            imageTask?.cancel()
            artwork.image = nil
            if let remote = URL(string: url), remote.scheme == "https", remote.host?.hasSuffix(".scdn.co") == true {
                imageTask = URLSession.shared.dataTask(with: remote) { [weak self] data, _, _ in
                    guard let data, data.count < 15_000_000, let image = NSImage(data: data) else { return }
                    DispatchQueue.main.async { if self?.imageURL == url { self?.artwork.image = image } }
                }
                imageTask?.resume()
            }
        }
        refreshActionHotkeys()
    }

    func action(_ id: Int) {
        if id == 0 { toggle(); return }
        guard [1, 2, 3, 13].contains(id) else { return }
        guard panel.isVisible, Date().timeIntervalSince(lastSync) <= 4,
              snapshot["supported"] as? Bool == true else { showNotice("Play a track in Spotify first"); return }
        let pending = commands.contains { command in
            let action = command["action"] as? String
            if id <= 2 { return action == "like" || action == "love" }
            if id == 3 { return action == "add" }
            if id == 13 { return action == "remove" || action == "undo" }
            return false
        }
        guard id <= 2 || !pending else { return }
        if id <= 2 && !buttons[id - 1].isEnabled { showNotice("Track state is still loading"); return }
        if id == 13 && !buttons[3].isEnabled {
            showNotice((snapshot["removal"] as? [String: Any])?["reason"] as? String ?? "Remove unavailable"); return
        }
        if id == 3 {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first?.activate(options: [])
        }
        queueAction(id)
    }

    func queueAction(_ id: Int) {
        let removal = snapshot["removal"] as? [String: Any] ?? [:]
        var command: [String: Any] = ["id": UUID().uuidString, "action": id == 1 ? "love" : id == 2 ? "like" : id == 3 ? "add" : (removal["action"] as? String ?? "remove"),
            "removal": removal,
            "uri": snapshot["uri"] as? String ?? "", "account": snapshot["account"] as? String ?? "",
            "expires": Date().timeIntervalSince1970 * 1000 + 5000]
        if id <= 2 {
            let current = displayedState(snapshot, commands)
            command["value"] = !(current[id == 1 ? "loved" : "liked"] as? Bool ?? false)
        }
        commands.append(command)
        showNotice("")
        refreshPendingButtons()
    }

    func shortcutLabel(_ key: String) -> String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map { $0.1 }.joined() + key.uppercased()
    }

    func installHotkeyHandler() {
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<Mini>.fromOpaque(pointer).takeUnretainedValue()
            app.hotkeyEvents += 1
            var key = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr else { return OSStatus(eventNotHandledErr) }
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) { app.pressed.remove(key.id) }
            else if app.pressed.insert(key.id).inserted { app.action(Int(key.id)) }
            return noErr
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        if status != noErr { showNotice("Could not install shortcut handler (\(status))") }
    }

    func register(_ id: UInt32, _ key: String) -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCodes[key]!, modifiers,
            EventHotKeyID(signature: 0x4A53484D, id: id), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            showNotice("Shortcut \(shortcutLabel(key)) unavailable (\(status)); edit Shortcuts…")
            return false
        }
        shortcuts[id] = ref
        return true
    }
    func registerToggle() { _ = register(0, keys[0]) }
    func refreshActionHotkeys() {
        let enabled = panel.isVisible && Date().timeIntervalSince(lastSync) <= 4 && snapshot["supported"] as? Bool == true
        guard enabled != visibleActions else { return }
        visibleActions = enabled
        for (id, ref) in shortcuts where id != 0 { UnregisterEventHotKey(ref); shortcuts.removeValue(forKey: id) }
        pressed.formIntersection([0])
        if enabled {
            for (index, key) in Array(keys.dropFirst().prefix(3)).enumerated() { _ = register(UInt32(index + 1), key) }
            _ = register(13, keys[4])
        }
    }

    @objc func editShortcuts() {
        let alert = NSAlert()
        alert.messageText = "Mini Player Shortcuts"
        alert.informativeText = "Actions work only while the mini player is visible. Letter keys refer to physical US keyboard positions."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 210))
        var boxes: [(NSButton, UInt32)] = []
        for (index, pair) in [("Control", controlKey), ("Option", optionKey), ("Command", cmdKey), ("Shift", shiftKey)].enumerated() {
            let button = NSButton(checkboxWithTitle: pair.0, target: nil, action: nil)
            button.frame = NSRect(x: index % 2 * 160, y: 180 - index / 2 * 25, width: 150, height: 24)
            button.state = modifiers & UInt32(pair.1) != 0 ? .on : .off
            view.addSubview(button)
            boxes.append((button, UInt32(pair.1)))
        }
        var fields: [NSTextField] = []
        for (index, text) in ["Toggle", "Love", "Like", "Add", "Remove / Undo"].enumerated() {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: 0, y: 126 - index * 25, width: 180, height: 24)
            let field = NSTextField(string: keys[index])
            field.frame = NSRect(x: 200, y: 126 - index * 25, width: 60, height: 24)
            view.addSubview(label); view.addSubview(field); fields.append(field)
        }
        alert.accessoryView = view
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let next = fields.map { $0.stringValue.trimmingCharacters(in: .whitespaces).lowercased() }
        let flags = boxes.filter { $0.0.state == .on }.reduce(UInt32(0)) { $0 | $1.1 }
        guard validKeys(next, modifiers: flags) else { showNotice("Use distinct letter keys and at least one Control/Option/Command modifier"); return }
        for ref in shortcuts.values { UnregisterEventHotKey(ref) }
        shortcuts.removeAll(); pressed.removeAll(); visibleActions = false
        config["keys"] = next; config["modifiers"] = flags
        save(); registerToggle(); refreshActionHotkeys()
    }

    func receive(_ connection: NWConnection) {
        connection.start(queue: .main)
        var buffer = Data()
        let deadline = DispatchWorkItem { connection.cancel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: deadline)
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
                if let data { buffer.append(data) }
                do {
                    if let request = try Request.parse(buffer) {
                        deadline.cancel()
                        self?.respond(connection, request)
                    } else if complete || error != nil { deadline.cancel(); connection.cancel() }
                    else { read() }
                } catch { deadline.cancel(); connection.cancel() }
            }
        }
        read()
    }

    func complete(_ results: [[String: Any]]) {
        for result in results {
            if let id = result["id"] as? String, let command = commands.first(where: { $0["id"] as? String == id }) {
                commands.removeAll { $0["id"] as? String == id }
                let action = command["action"] as? String ?? ""
                let removal = command["removal"] as? [String: Any] ?? [:]
                let currentRemoval = snapshot["removal"] as? [String: Any] ?? [:]
                let currentEntry = !["remove", "undo"].contains(action) ||
                    ["context", "itemUid", "provider"].allSatisfy { removal[$0] as? String == currentRemoval[$0] as? String }
                if command["uri"] as? String == snapshot["uri"] as? String && currentEntry {
                    if result["ok"] as? Bool == true {
                        showNotice("")
                    } else {
                        showNotice(result["message"] as? String ?? "Could not complete action")
                    }
                }
            }
        }
        refreshPendingButtons()
    }

    func respond(_ connection: NWConnection, _ request: Request) {
        let origin = request.headers["origin"]
        let allowedOrigin = origin == nil || origins.contains(origin!)
        let authenticated = request.headers["authorization"] == "Bearer \(token)"
        var status = 200
        var payload: [String: Any] = [:]
        if !allowedOrigin { status = 403 }
        else if request.path == "/status" && request.method == "GET" && authenticated {
            payload = ["visible": panel.isVisible, "hotkeys": shortcuts.keys.sorted(),
                "handlerInstalled": eventHandler != nil, "hotkeyEvents": hotkeyEvents,
                "onActiveSpace": panel.isOnActiveSpace,
                "occluded": !panel.occlusionState.contains(.visible),
                "connected": Date().timeIntervalSince(lastSync) <= 4,
                "bounds": [panel.frame.minX, panel.frame.minY, panel.frame.width, panel.frame.height],
                "title": title.stringValue, "notice": notice.stringValue]
        }
        else if request.path != "/sync" { status = 404 }
        else if request.method == "OPTIONS" { status = 204 }
        else if request.method != "POST" { status = 405 }
        else if !authenticated { status = 401 }
        else if let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                let state = json["state"] as? [String: Any],
                let account = state["account"] as? String, !account.isEmpty {
            update(state)
            complete(json["results"] as? [[String: Any]] ?? [])
            payload = ["commands": commands]
        } else { status = 400 }
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        var headers = "HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if let origin, allowedOrigin {
            headers += "Access-Control-Allow-Origin: \(origin)\r\nVary: Origin\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Authorization, Content-Type\r\nAccess-Control-Allow-Private-Network: true\r\n"
        }
        connection.send(content: Data((headers + "\r\n").utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    func applicationWillTerminate(_ notification: Notification) {
        save(); listener?.cancel(); imageTask?.cancel()
        for ref in shortcuts.values { UnregisterEventHotKey(ref) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

if CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--ui-self-test") {
    let initial: [String: Any] = ["uri": "spotify:track:one", "account": "one", "supported": true, "loved": false, "liked": false]
    let command: [String: Any] = ["id": "test", "uri": initial["uri"]!, "account": initial["account"]!, "action": "love", "value": true]
    let optimistic = displayedState(initial, [command])
    assert(optimistic["loved"] as? Bool == true && optimistic["liked"] as? Bool == true)
    assert(displayedState(initial, [])["loved"] as? Bool == false)
    var selectedState = optimistic
    let unlike: [String: Any] = ["uri": initial["uri"]!, "account": initial["account"]!, "action": "like", "value": false]
    selectedState = displayedState(selectedState, [unlike])
    assert(selectedState["liked"] as? Bool == false && selectedState["loved"] as? Bool == false)
    var removalState = initial
    removalState["removal"] = ["context": "playlist", "itemUid": "entry", "provider": "context", "action": "remove", "enabled": true]
    let remove: [String: Any] = ["uri": initial["uri"]!, "account": initial["account"]!, "action": "remove", "removal": removalState["removal"]!]
    assert((displayedState(removalState, [remove])["removal"] as? [String: Any])?["action"] as? String == "undo")
    removalState["removal"] = ["context": "playlist", "itemUid": "other", "provider": "context", "action": "remove", "enabled": true]
    assert((displayedState(removalState, [remove])["removal"] as? [String: Any])?["action"] as? String == "remove")
    var changed = initial
    changed["uri"] = "spotify:track:two"
    assert(displayedState(changed, [command])["loved"] as? Bool == false)
    changed = initial
    changed["account"] = "two"
    assert(displayedState(changed, [command])["loved"] as? Bool == false)
    if CommandLine.arguments.contains("--ui-self-test") {
        _ = NSApplication.shared
        let testConfig = FileManager.default.temporaryDirectory.appendingPathComponent("mini-feedback-\(UUID().uuidString).json")
        try! JSONSerialization.data(withJSONObject: ["token": String(repeating: "a", count: 64), "port": 47684]).write(to: testConfig)
        defer { try? FileManager.default.removeItem(at: testConfig) }
        let mini = try! Mini(configURL: testConfig)
        mini.makePanel()
        mini.update(initial)
        assert(mini.buttons.allSatisfy { $0.focusRingType == .none })
        mini.panel.makeFirstResponder(mini.buttons[0])
        assert(mini.buttons[0].layer?.borderWidth == 0, "initial or pointer focus must not outline the icon")
        mini.buttons[0].keyboardFocused = true
        assert(mini.buttons[0].layer?.borderWidth == 1.5)
        mini.buttons[2].isEnabled = false
        mini.buttons[2].mouseDown(with: NSEvent())
        assert(mini.buttons[0].layer?.borderWidth == 0, "pointer interaction must clear the keyboard-only outline")
        mini.buttons[2].isEnabled = true
        mini.buttons[0].mouseEntered(with: NSEvent())
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let layer = mini.buttons[0].layer!
            let transform = layer.transform
            assert(abs(transform.m11 - 1.1) < 0.001)
            let center = CGPoint(x: layer.bounds.width * (0.5 - layer.anchorPoint.x),
                                 y: layer.bounds.height * (0.5 - layer.anchorPoint.y))
            assert(abs(center.x * transform.m11 + transform.m41 - center.x) < 0.001)
            assert(abs(center.y * transform.m22 + transform.m42 - center.y) < 0.001)
        }
        mini.buttons[0].mouseExited(with: NSEvent())
        assert(mini.buttons[0].layer!.transform.m11 == 1)
        assert(mini.buttons[0].isEnabled && mini.buttons[1].isEnabled)
        assert(mini.buttons[0].acceptsFirstMouse(for: nil))
        mini.queueAction(1)
        mini.queueAction(2)
        assert(mini.commands.count == 2 && mini.buttons[0].accessibilityValue() as? String == "Off" && mini.buttons[1].accessibilityValue() as? String == "Off", "rapid Unlike must immediately clear both pending fills")
        mini.queueAction(1)
        assert(mini.commands.count == 3 && mini.buttons[0].accessibilityValue() as? String == "On" && mini.buttons[1].accessibilityValue() as? String == "On", "the next click must immediately restore both fills")
        mini.update(initial)
        assert(mini.buttons[0].accessibilityValue() as? String == "On", "older sync must preserve the latest click")
        mini.commands.removeAll()
        mini.refreshPendingButtons()
        var selected = initial
        selected["loved"] = true
        selected["liked"] = true
        mini.update(selected)
        let heartImage = mini.buttons[0].image
        let heartTint = mini.buttons[0].contentTintColor
        selected["loved"] = NSNull()
        selected["liked"] = NSNull()
        mini.update(selected)
        assert(mini.snapshot["loved"] as? Bool == true && mini.snapshot["liked"] as? Bool == true)
        assert(mini.buttons[0].image?.name() == heartImage?.name() && mini.buttons[0].contentTintColor == heartTint)
        mini.buttons[0].hovered = true
        assert(mini.buttons[0].layer?.borderWidth == 0)
        assert((mini.buttons[0].cell as! NSButtonCell).highlightsBy.isEmpty)
        mini.update(initial)
        mini.commands = [command]
        mini.refreshPendingButtons()
        assert(mini.buttons[0].accessibilityHelp()?.contains("Updating Spotify") == true && mini.buttons[1].accessibilityHelp()?.contains("Updating Spotify") == true)
        assert(mini.buttons[0].isEnabled && mini.buttons[0].alphaValue == 1 && mini.buttons[0].contentTintColor == heartTint)
        assert(mini.buttons[0].layer?.borderWidth == 0)
        assert(mini.buttons[0].accessibilityValue() as? String == "On")
        assert(mini.buttons[1].accessibilityValue() as? String == "On")
        mini.update(initial)
        assert(mini.buttons[0].accessibilityValue() as? String == "On", "old sync must not overwrite the immediate toggle")
        mini.complete([["id": "test", "ok": false, "message": "Could not update Love"]])
        assert(mini.notice.stringValue == "Could not update Love" && !mini.notice.drawsBackground)
        assert(mini.notice.frame.minY == 51 && mini.buttons[0].isEnabled && mini.buttons[0].alphaValue == 1)
        assert(mini.buttons[0].accessibilityHelp()?.contains("Updating Spotify") == false && mini.buttons[0].layer?.borderWidth == 0)
        assert(mini.buttons[0].accessibilityValue() as? String == "Off", "failed command must restore confirmed state")
        var partial = initial
        partial["liked"] = true
        mini.update(partial)
        mini.commands = [command]
        mini.refreshPendingButtons()
        mini.complete([["id": "test", "ok": false]])
        assert(mini.buttons[0].accessibilityValue() as? String == "Off" && mini.buttons[1].accessibilityValue() as? String == "On", "partial Love failure must keep the confirmed Like")
        var confirmed = initial
        confirmed["loved"] = true
        confirmed["liked"] = true
        mini.update(confirmed)
        mini.commands = [command]
        mini.complete([["id": "test", "ok": true, "message": "Added to Loved Songs"]])
        assert(mini.notice.stringValue.isEmpty && mini.notice.isHidden)
        mini.showNotice("Newer failure")
        mini.complete([["id": "test", "ok": true]])
        assert(mini.notice.stringValue == "Newer failure", "repeated acknowledgement must not replay feedback")
        mini.commands = [command]
        changed = initial
        changed["uri"] = "spotify:track:two"
        mini.update(changed)
        mini.complete([["id": "test", "ok": false, "message": "Old track failure"]])
        assert(mini.notice.stringValue.isEmpty, "late feedback must not affect the new track")
    }
    let body = Data("{}".utf8)
    let packet = Data("POST /sync HTTP/1.1\r\nContent-Length: 2\r\n\r\n".utf8) + body
    let parsed = try! Request.parse(packet)
    let incomplete = try! Request.parse(packet.dropLast())
    assert(parsed?.body == body)
    assert(incomplete == nil)
    for header in ["Content-Length: -1", "Content-Length: 999999", "Content-Length: 0\r\nContent-Length: 0", "Transfer-Encoding: chunked"] {
        do { _ = try Request.parse(Data("POST /sync HTTP/1.1\r\n\(header)\r\n\r\n".utf8)); fatalError("Accepted unsafe HTTP request") }
        catch {}
    }
    assert(validKeys(["m", "h", "l", "p", "r"], modifiers: UInt32(cmdKey | optionKey | controlKey)))
    assert(!validKeys(["m", "m", "l", "p", "r"], modifiers: UInt32(cmdKey)))
    assert(!validKeys(["1", "h", "l", "p", "r"], modifiers: UInt32(cmdKey)))
    assert(migratedKeys(["m", "h", "l", "p"]) == ["m", "h", "l", "p", "r"])
    assert(migratedKeys(["m", "r", "l", "p"]) == ["m", "r", "l", "p", "u"])
    assert(!validKeys(["m", "h", "l", "p"], modifiers: UInt32(cmdKey)))
    print("Mini Player request, shortcut and button feedback checks passed")
} else {
    guard let path = CommandLine.arguments.dropFirst().first else { fatalError("Pass the private config file") }
    do {
        let app = NSApplication.shared
        let delegate = try Mini(configURL: URL(fileURLWithPath: path))
        app.delegate = delegate
        app.run()
    } catch { fputs("Mini Player config invalid: \(error)\n", stderr); exit(1) }
}
