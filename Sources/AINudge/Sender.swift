import AppKit
import ApplicationServices

/// Opens the chat, types the message and presses Return, the way you would.
@MainActor
enum Sender {
    static let claudeApp = "com.anthropic.claudefordesktop"
    enum Failure: LocalizedError {
        case noAccessibility, locked, missingChat, badLink(String), appMissing(String), wrongApp(String?), interrupted, unsupported(String)

        var errorDescription: String? {
            switch self {
            case .noAccessibility: return "AI Nudge needs Accessibility permission (menu bar icon › Allow Accessibility…)"
            case .locked: return "the screen is locked"
            case .missingChat: return "no chat link set"
            case .badLink(let s): return "can't use the link \"\(s)\""
            case .appMissing(let id): return "\(id) isn't installed"
            case .wrongApp(let front): return "the chat didn't come to the front (\(front ?? "nothing") did), so nothing was typed"
            case .unsupported(let why): return why
            case .interrupted: return "you clicked or typed while it was sending, so it stopped before typing anything"
            }
        }
    }

    /// What to open, in which app, and whether the message is already in the box when it opens.
    struct Plan {
        var url: URL?
        var app: String
        var prefilled: Bool
        var shortcut: (key: CGKeyCode, flags: CGEventFlags)?   // pressed once the app is in front
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func screenLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    static var defaultBrowser: String {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
            .flatMap { Bundle(url: $0)?.bundleIdentifier } ?? "com.apple.Safari"
    }

    static let knownBrowsers = [
        ("com.apple.Safari", "Safari"), ("com.google.Chrome", "Chrome"), ("company.thebrowser.Browser", "Arc"),
        ("com.brave.Browser", "Brave"), ("com.microsoft.edgemac", "Edge"), ("org.mozilla.firefox", "Firefox"),
    ]

    static var installedBrowsers: [(id: String, name: String)] {
        knownBrowsers.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.0) != nil }
    }

    /// The chat id from a pasted link (…/chat/ID or …/c/ID), or the text itself if it's already an id.
    static func chatID(_ s: String) -> String? {
        let s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let parts = (URL(string: s)?.path ?? s).split(separator: "/").map(String.init)
        if let i = parts.firstIndex(where: { $0 == "chat" || $0 == "c" }), i + 1 < parts.count { return parts[i + 1] }
        return s.contains("/") ? nil : s
    }

    static func plan(for n: Nudge, browser: String) throws -> Plan {
        let q = n.message.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? ""
        let browser = browser.isEmpty ? defaultBrowser : browser
        func chat() throws -> String {
            guard let id = chatID(n.chat) else { throw n.chat.isEmpty ? Failure.missingChat : Failure.badLink(n.chat) }
            return id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        }
        switch n.target {
        case .claudeApp:
            return Plan(url: URL(string: "claude://claude.ai/new?q=\(q)"), app: claudeApp, prefilled: true)
        case .claudeAppIncognito:
            // The deep link can't carry incognito, so open a new chat and switch with ⇧⌘I.
            return Plan(url: URL(string: "claude://claude.ai/new"), app: claudeApp, prefilled: false,
                        shortcut: (34, [.maskCommand, .maskShift]))
        case .claudeAppChat:
            return Plan(url: URL(string: "claude://claude.ai/chat/\(try chat())"), app: claudeApp, prefilled: false)
        case .claudeWeb:
            return Plan(url: URL(string: "https://claude.ai/new?q=\(q)"), app: browser, prefilled: true)
        case .claudeWebIncognito:
            return Plan(url: URL(string: "https://claude.ai/new?incognito"), app: browser, prefilled: false)
        case .claudeWebChat:
            return Plan(url: URL(string: "https://claude.ai/chat/\(try chat())"), app: browser, prefilled: false)
        case .claudeCode, .codex:
            throw Failure.unsupported("sent through the command-line tool, not typed")
        case .custom:
            let link = n.chat.trimmingCharacters(in: .whitespaces)
            guard !link.isEmpty else { throw Failure.missingChat }
            guard let url = URL(string: link.replacingOccurrences(of: "{message}", with: q)), url.scheme != nil
            else { throw Failure.badLink(link) }
            return Plan(url: url, app: browser, prefilled: link.contains("{message}"))
        }
    }

    /// Seconds since the last click, scroll or key press, ours included.
    static func secondsSinceInput() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }

    private static var ownKeys: [Date] = []

    /// Whether someone clicked or typed after `start`, not counting the keys this app pressed.
    /// Both the chats and other conversations can live in the same app, so being in front isn't
    /// enough: a click elsewhere in it would send the typing somewhere else.
    private static func userActed(since start: Date) -> Bool {
        let last = Date().addingTimeInterval(-secondsSinceInput())
        guard last > start.addingTimeInterval(0.2) else { return false }
        return !ownKeys.contains { abs($0.timeIntervalSince(last)) < 0.5 }
    }

    /// Returns the reply when the target gives one (the command-line tools do).
    @discardableResult
    static func send(_ n: Nudge, config: Config) async throws -> String? {
        if n.target.usesCLI { return try await CLITools.send(n) }
        let start = Date()
        ownKeys = []
        guard trusted else { throw Failure.noAccessibility }
        guard !screenLocked() else { throw Failure.locked }
        let plan = try plan(for: n, browser: config.browser)
        let ws = NSWorkspace.shared
        guard let appURL = ws.urlForApplication(withBundleIdentifier: plan.app) else { throw Failure.appMissing(plan.app) }

        let previous = ws.frontmostApplication
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: plan.app).isEmpty
        let open = NSWorkspace.OpenConfiguration()
        open.activates = true
        if let url = plan.url {
            _ = try await ws.open([url], withApplicationAt: appURL, configuration: open)
        } else {
            _ = try await ws.openApplication(at: appURL, configuration: open)
        }
        // A cold start takes longer than switching to an app that's already open.
        try await pause(config.settleSeconds * (wasRunning ? 1 : 3))

        // Only type once the right app is in front, so nothing lands anywhere else.
        NSRunningApplication.runningApplications(withBundleIdentifier: plan.app).first?.activate(options: [])
        try await pause(0.4)
        let front = ws.frontmostApplication?.bundleIdentifier
        guard front == plan.app else { throw Failure.wrongApp(ws.frontmostApplication?.localizedName) }

        if userActed(since: start) { throw Failure.interrupted }
        if let shortcut = plan.shortcut {
            key(shortcut.key, shortcut.flags)
            try await pause(max(1.5, config.settleSeconds / 2))
        }
        var clipboard: [NSPasteboardItem]?
        if userActed(since: start) { throw Failure.interrupted }
        if !plan.prefilled {
            clipboard = copy(n.message)
            key(9, .maskCommand)                  // ⌘V
            try await pause(0.5)
        }
        if userActed(since: start) {
            if let clipboard { restore(clipboard) }
            throw Failure.interrupted
        }
        key(36)                                   // Return
        try await pause(1)
        if let clipboard { restore(clipboard) }
        if config.restoreFocus, let previous, previous.bundleIdentifier != plan.app {
            previous.activate(options: [])
        }
        return nil
    }

    private static func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        ownKeys.append(Date())
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Puts the message on the clipboard and returns what was there, to put back afterwards.
    private static func copy(_ text: String) -> [NSPasteboardItem] {
        let pb = NSPasteboard.general
        let saved = (pb.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let d = item.data(forType: type) { copy.setData(d, forType: type) } }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        return saved
    }

    private static func restore(_ items: [NSPasteboardItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
