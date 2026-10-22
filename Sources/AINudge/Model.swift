import AppKit

/// Where a nudge goes and how it gets there.
enum Target: String, Codable, CaseIterable {
    case claudeApp = "claude-app"
    case claudeAppIncognito = "claude-app-incognito"
    case claudeAppChat = "claude-app-chat"
    case claudeWeb = "claude-web"
    case claudeWebIncognito = "claude-web-incognito"
    case claudeWebChat = "claude-web-chat"
    case chatgptApp = "chatgpt-app"
    case chatgptAppTemp = "chatgpt-app-temp"
    case chatgptWeb = "chatgpt-web"
    case chatgptWebTemp = "chatgpt-web-temp"
    case chatgptWebChat = "chatgpt-web-chat"
    case custom

    var label: String {
        switch self {
        case .claudeApp: return "Claude app: new chat"
        case .claudeAppIncognito: return "Claude app: incognito chat"
        case .claudeAppChat: return "Claude app: a chat you pick"
        case .claudeWeb: return "claude.ai in browser: new chat"
        case .claudeWebIncognito: return "claude.ai in browser: incognito chat"
        case .claudeWebChat: return "claude.ai in browser: a chat you pick"
        case .chatgptApp: return "ChatGPT app: new chat"
        case .chatgptAppTemp: return "ChatGPT app: temporary chat"
        case .chatgptWeb: return "chatgpt.com in browser: new chat"
        case .chatgptWebTemp: return "chatgpt.com in browser: temporary chat"
        case .chatgptWebChat: return "chatgpt.com in browser: a chat you pick"
        case .custom: return "Any link (browser)"
        }
    }

    /// What the `chat` field holds for this target, if anything.
    var chatPrompt: String? {
        switch self {
        case .claudeAppChat, .claudeWebChat: return "Chat link, e.g. https://claude.ai/chat/…"
        case .chatgptWebChat: return "Chat link, e.g. https://chatgpt.com/c/…"
        case .custom: return "Link to open; {message} is replaced with your message"
        default: return nil
        }
    }
}

struct Nudge: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name = "Morning"
    var time = "06:00"
    var days = Array(1...7)
    var target = Target.claudeApp
    var chat = ""
    var message = "hi"
    var enabled = true
}

struct Config: Codable {
    var nudges: [Nudge] = []
    var catchUpMinutes = 180      // how late a missed nudge may still be sent
    var settleSeconds = 4.0       // wait after opening a chat before typing
    var browser = ""              // bundle id; empty means the default browser
    var restoreFocus = true       // go back to the app you were in afterwards
    var allowLAN = false          // serve settings to other devices on the network
    var port = 47823
    var publicURL = ""            // where a reverse proxy on your own site serves the settings page
    var awakeLetDisplaySleep = false   // keep awake: only the Mac, not the screen
    var awakeStopOnLowBattery = true
    var token = Config.newToken()

    static func newToken() -> String {
        (0..<4).map { _ in String(UInt32.random(in: .min ... .max), radix: 36) }.joined()
    }

    init() {}

    // Every key is optional, so older or hand-edited files still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        nudges = try c.decodeIfPresent([Nudge].self, forKey: .nudges) ?? d.nudges
        catchUpMinutes = try c.decodeIfPresent(Int.self, forKey: .catchUpMinutes) ?? d.catchUpMinutes
        settleSeconds = try c.decodeIfPresent(Double.self, forKey: .settleSeconds) ?? d.settleSeconds
        browser = try c.decodeIfPresent(String.self, forKey: .browser) ?? d.browser
        restoreFocus = try c.decodeIfPresent(Bool.self, forKey: .restoreFocus) ?? d.restoreFocus
        allowLAN = try c.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? d.allowLAN
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        publicURL = try c.decodeIfPresent(String.self, forKey: .publicURL) ?? d.publicURL
        awakeLetDisplaySleep = try c.decodeIfPresent(Bool.self, forKey: .awakeLetDisplaySleep) ?? d.awakeLetDisplaySleep
        awakeStopOnLowBattery = try c.decodeIfPresent(Bool.self, forKey: .awakeStopOnLowBattery) ?? d.awakeStopOnLowBattery
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? d.token
    }
}

/// sent: when each nudge last went out. armed: when it was added or its schedule changed; times
/// before that aren't caught up on.
struct RunState: Codable {
    var sent: [String: Date] = [:]
    var armed: [String: Date] = [:]
    var outcomes: [String: Outcome] = [:]   // the last try of each nudge, scheduled or not

    struct Outcome: Codable {
        var date: Date
        var error: String?
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sent = try c.decodeIfPresent([String: Date].self, forKey: .sent) ?? [:]
        armed = try c.decodeIfPresent([String: Date].self, forKey: .armed) ?? [:]
        outcomes = try c.decodeIfPresent([String: Outcome].self, forKey: .outcomes) ?? [:]
    }
}

extension JSONDecoder { static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }
extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
