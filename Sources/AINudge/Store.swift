import AppKit
import SystemConfiguration

/// Settings, schedule and activity. Everything here runs on the main thread.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var config: Config
    @Published private(set) var state: RunState
    @Published private(set) var log: [String] = []
    @Published private(set) var sending: String?
    @Published private(set) var trusted = Sender.trusted
    @Published private(set) var now = Date()
    @Published private(set) var awakeUntil: KeepAwake.Until?

    let firstRun: Bool
    var showSettingsWindow: (() -> Void)?
    private var timer: Timer?
    private var lockedNoted = false
    private var busyNoted = false
    private let awake = KeepAwake()

    /// AI_NUDGE_DATA=<folder> keeps settings, state and log there instead (for trying things out).
    nonisolated private static let dataOverride = ProcessInfo.processInfo.environment["AI_NUDGE_DATA"].map { URL(fileURLWithPath: $0) }
    nonisolated static let dir = dataOverride ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ai-nudge")
    private let configURL = dir.appendingPathComponent("config.json")
    private let stateURL = dir.appendingPathComponent("state.json")
    private let logURL = dataOverride?.appendingPathComponent("ai-nudge.log")
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ai-nudge.log")

    private init() {
        let data = try? Data(contentsOf: configURL)
        firstRun = data == nil
        config = data.flatMap { try? JSONDecoder.iso.decode(Config.self, from: $0) } ?? Config()
        state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder.iso.decode(RunState.self, from: $0) } ?? RunState()
        log = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n").suffix(50).map(String.init)
        if firstRun { config.nudges = [Nudge(enabled: false)] }
        saveConfig()    // fills in anything missing, like the token
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { Store.shared.check() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Store.shared.check() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            // give the desktop a moment to come back before typing into it
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { Store.shared.check() } }
        }
        check()
    }

    // MARK: Schedule

    func next(_ n: Nudge) -> Date? {
        n.enabled ? Schedule.nextOccurrence(time: n.time, days: n.days, after: now) : nil
    }

    var nextUp: (name: String, date: Date)? {
        config.nudges.compactMap { n in next(n).map { (n.name, $0) } }.min { $0.1 < $1.1 }
    }

    private func handled(_ id: String) -> Date {
        max(state.sent[id] ?? .distantPast, state.armed[id] ?? .distantPast)
    }

    /// Sends the first enabled nudge whose latest time has passed, isn't sent yet and is within the
    /// catch-up window. One at a time; the next goes once this one is done.
    func check() {
        now = Date()
        trusted = Sender.trusted
        if let why = awake.check(stopOnLowBattery: config.awakeStopOnLowBattery) {
            record(why)
            awakeUntil = nil
        }
        guard sending == nil else { return }
        let window = TimeInterval(config.catchUpMinutes * 60)
        for n in config.nudges where n.enabled {
            guard let due = Schedule.lastOccurrence(time: n.time, days: n.days, before: now),
                  now.timeIntervalSince(due) <= window, handled(n.id) < due else { continue }
            // Typing needs an unlocked screen and nobody at the keyboard; the command-line targets don't.
            if !n.target.usesCLI {
                if Sender.screenLocked() {
                    if !lockedNoted { record("\(n.name): screen is locked; will send when it's unlocked") }
                    lockedNoted = true
                    continue
                }
                lockedNoted = false
                // Don't take over while you're using the Mac; try again once you've been idle a moment.
                if Sender.secondsSinceInput() < 30 {
                    if !busyNoted { record("\(n.name): due, waiting until you've stopped using the Mac for 30 s") }
                    busyNoted = true
                    continue    // the 20-second timer checks again
                }
                busyNoted = false
            }
            state.sent[n.id] = now    // recorded first: a failed send isn't retried in a loop
            saveState()
            send(n)
            return
        }
    }

    /// Sends a nudge straight away. The schedule isn't affected.
    func sendNow(_ id: String) {
        guard sending == nil, let n = config.nudges.first(where: { $0.id == id }) else { return }
        send(n)
    }

    private func send(_ n: Nudge) {
        sending = n.name
        Task {
            var failure: String?
            do {
                let reply = try await Sender.send(n, config: config)
                record("\(n.name): sent (\(n.target.label))" + (reply.map { ": \($0)" } ?? ""))
            } catch {
                failure = error.localizedDescription
                record("\(n.name): not sent: \(error.localizedDescription)")
            }
            state.outcomes[n.id] = .init(date: Date(), error: failure)
            saveState()
            sending = nil
            check()
        }
    }

    // MARK: Settings

    /// Takes settings from the web page. The token and port stay as they are, and nudges whose
    /// schedule changed don't catch up on times that already passed.
    func update(_ new: Config) {
        var new = new
        new.token = config.token
        new.port = config.port
        let old = Dictionary(uniqueKeysWithValues: config.nudges.map { ($0.id, $0) })
        for n in new.nudges {
            if let o = old[n.id], o.time == n.time, o.days == n.days, o.enabled == n.enabled { continue }
            state.armed[n.id] = Date()
        }
        let ids = Set(new.nudges.map(\.id))
        state.sent = state.sent.filter { ids.contains($0.key) }
        state.armed = state.armed.filter { ids.contains($0.key) }
        state.outcomes = state.outcomes.filter { ids.contains($0.key) }
        let lanChanged = new.allowLAN != config.allowLAN
        let displayChanged = new.awakeLetDisplaySleep != config.awakeLetDisplaySleep
        config = new
        if displayChanged, let until = awake.until { awake.start(until, letDisplaySleep: config.awakeLetDisplaySleep) }
        saveConfig()
        saveState()
        if lanChanged { WebServer.shared.restart() }
        check()
    }

    /// Changes the settings in place (from the settings window).
    func edit(_ change: (inout Config) -> Void) {
        var new = config
        change(&new)
        update(new)
    }

    func addNudge() {
        edit { $0.nudges.append(Nudge(name: "Nudge \($0.nudges.count + 1)")) }
    }

    // MARK: Keep awake

    /// minutes: nil = indefinitely, 0 = off, -1 = until a few minutes after the next nudge.
    func keepAwake(minutes: Int?) {
        switch minutes {
        case 0:
            awake.stop()
        case -1:
            guard let next = nextUp?.date else { return }
            awake.start(.date(next.addingTimeInterval(5 * 60)), letDisplaySleep: config.awakeLetDisplaySleep)
        case let m?:
            awake.start(.date(Date().addingTimeInterval(TimeInterval(m * 60))), letDisplaySleep: config.awakeLetDisplaySleep)
        case nil:
            awake.start(.forever, letDisplaySleep: config.awakeLetDisplaySleep)
        }
        awakeUntil = awake.until
    }

    /// "Awake until 14:30", "Awake indefinitely", or nil when off.
    var awakeText: String? {
        switch awakeUntil {
        case .forever?: return "Awake indefinitely"
        case .date(let d)?: return "Awake until \(Store.short(d))"
        case nil: return nil
        }
    }

    // MARK: Status text (local time, shared by the menu and both settings screens)

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        return f
    }()

    static func short(_ d: Date) -> String { shortDate.string(from: d) }

    func nextText(_ n: Nudge) -> String { next(n).map(Store.short) ?? "off" }

    /// "never", "sent Thu 09:06", or "failed Thu 09:06: why".
    func lastText(_ n: Nudge) -> String {
        guard let o = state.outcomes[n.id] else { return "never" }
        return o.error.map { "failed \(Store.short(o.date)): \($0)" } ?? "sent \(Store.short(o.date))"
    }

    func lastFailed(_ n: Nudge) -> Bool { state.outcomes[n.id]?.error != nil }

    func refreshTrust() { trusted = Sender.trusted }

    func record(_ line: String) {
        let entry = "\(Store.stamp.string(from: Date())) \(line)"
        log = Array((log + [entry]).suffix(50))
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data((entry + "\n").utf8)); try? h.close()
        } else {
            try? Data((entry + "\n").utf8).write(to: logURL)
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private func saveConfig() { write(config, to: configURL) }
    private func saveState() { write(state, to: stateURL) }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: Store.dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.iso.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Settings page

    var settingsURL: URL { URL(string: "http://127.0.0.1:\(config.port)/?t=\(config.token)")! }

    var lanURL: URL? {
        guard config.allowLAN, let host = SCDynamicStoreCopyLocalHostName(nil) as String? else { return nil }
        return URL(string: "http://\(host).local:\(config.port)/?t=\(config.token)")
    }

    /// The settings page through your own site, when you've set one up (README: "From anywhere").
    var siteURL: URL? {
        var base = config.publicURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return nil }
        if !base.hasSuffix("/") { base += "/" }
        return URL(string: "\(base)?t=\(config.token)")
    }

    func openSettings() { NSWorkspace.shared.open(settingsURL) }
}
