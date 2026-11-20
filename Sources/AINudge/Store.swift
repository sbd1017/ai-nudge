import AppKit
import SystemConfiguration

/// Settings, schedule and activity. Everything here runs on the main thread.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var config: Config {
        didSet { if config.notify != oldValue.notify, config.notify != .off { refreshNotifications(ask: true) } }
    }
    @Published private(set) var notificationsAllowed: Bool?     // nil: not checked, or not answered yet
    @Published private(set) var state: RunState
    @Published private(set) var log: [String] = []
    @Published private(set) var sending: String?
    @Published private(set) var trusted = Sender.trusted
    @Published private(set) var now = Date()
    @Published private(set) var awakeUntil: KeepAwake.Until?
    @Published private(set) var shake: CGFloat = 0     // the menu bar bubble jiggles while sending
    @Published private(set) var codexOutUntil: Date?    // from Codex's own usage data
    @Published private(set) var codexCheckedAt: Date?
    @Published private(set) var claudeOutUntil: Date?   // from Claude Code's /usage
    @Published private(set) var claudeCheckedAt: Date?
    @Published private(set) var claudeProblem: String?        // why Claude's usage can't be read, if it can't
    @Published private(set) var claudeLoginEnds: Date?        // when Claude Code's sign-in runs out
    private var claudeLoginCheckedAt: Date?
    private var claudeLoginWarned: Date?                       // the end date we've already warned about

    /// "18 Dec, 17:48": a date and time for things days away.
    static func day(_ d: Date) -> String { d.formatted(.dateTime.day().month(.abbreviated).hour().minute()) }

    /// Claude Code's sign-in runs out within 3 days: time to sign in again.
    var claudeLoginEndingSoon: Bool {
        claudeLoginEnds.map { $0.timeIntervalSince(now) < 3 * 86400 } ?? false
    }
    @Published private(set) var codexThreads: [CLITools.CodexThread] = []   // for the "Codex chat" pickers
    private var threadsCheckedAt: Date?

    let firstRun: Bool
    var showSettingsWindow: (() -> Void)?
    private var timer: Timer?
    private var lockedNoted = false
    private var busyNoted = false
    private let awake = KeepAwake()
    private var shakeTimer: Timer?
    private var codexChecking = false
    private var claudeChecking = false

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
        Notifier.setUp()
        refreshNotifications(ask: config.notify != .off)
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
        guard n.enabled else { return nil }
        switch n.mode {
        case .weekly:
            return Schedule.nextOccurrence(time: n.time, days: n.days, after: now)
        case .once:
            return n.date.flatMap { Schedule.moment(date: $0, time: n.time) }.flatMap { $0 > now ? $0 : nil }
        case .reset:
            guard n.mode.fits(n.target), let at = state.codexResumeAt, at > now else { return nil }
            return at
        case .claudeReset:
            guard n.mode.fits(n.target), let at = state.claudeResumeAt, at > now else { return nil }
            return at
        }
    }

    /// The latest moment this nudge was due at or before now.
    private func due(_ n: Nudge) -> Date? {
        switch n.mode {
        case .weekly:
            return Schedule.lastOccurrence(time: n.time, days: n.days, before: now)
        case .once:
            return n.date.flatMap { Schedule.moment(date: $0, time: n.time) }.flatMap { $0 <= now ? $0 : nil }
        case .reset:
            guard n.mode.fits(n.target), let at = state.codexResumeAt, at <= now else { return nil }
            return at
        case .claudeReset:
            guard n.mode.fits(n.target), let at = state.claudeResumeAt, at <= now else { return nil }
            return at
        }
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
        if config.notify != .off { refreshNotifications() }    // you may change it in System Settings
        refreshCodex()
        refreshClaude()
        if let why = awake.check(stopOnLowBattery: config.awakeStopOnLowBattery) {
            record(why)
            awakeUntil = nil
        }
        guard sending == nil else { return }
        let window = TimeInterval(config.catchUpMinutes * 60)
        for n in config.nudges where n.enabled || retries[n.id] != nil {   // a once-nudge switches off when sent
            let retry = retries[n.id].map { $0.at <= now } ?? false
            guard retry || (due(n).map { now.timeIntervalSince($0) <= window && handled(n.id) < $0 } ?? false)
            else { continue }
            // Typing needs an unlocked screen and nobody at the keyboard; the command-line targets don't.
            if !n.target.usesCLI {
                if Sender.screenLocked() {
                    if !lockedNoted {
                        record("\(n.name): screen is locked; will send when it's unlocked")
                        notify("\(n.name) is waiting", "The screen is locked, so it can't type. It will send when you unlock the Mac.", failed: true)
                    }
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
            if n.mode == .reset { state.codexResumeAt = nil }
            if n.mode == .claudeReset { state.claudeResumeAt = nil }
            saveState()
            send(n, scheduled: true)
            if n.mode == .once {      // done: switch it off
                edit { c in if let i = c.nudges.firstIndex(where: { $0.id == n.id }) { c.nudges[i].enabled = false } }
            }
            return
        }
    }

    /// Sends a nudge straight away. The schedule isn't affected.
    func sendNow(_ id: String) {
        guard sending == nil, let n = config.nudges.first(where: { $0.id == id }) else { return }
        send(n)
    }

    /// A scheduled nudge that typed but couldn't be confirmed (or didn't send) is tried again, two
    /// minutes apart, up to three tries in all. Kept in memory: an app restart starts afresh.
    private var retries: [String: (tries: Int, at: Date)] = [:]
    static let maxTries = 3
    static let retryGap: TimeInterval = 120

    private static func retryable(_ error: Error) -> Bool {
        switch error as? Sender.Failure {
        case .notSent, .notPasted, .unconfirmed, .wrongApp, .interrupted, .locked: return true
        default: return false
        }
    }

    private func send(_ n: Nudge, scheduled: Bool = false) {
        sending = n.name
        startShaking()
        Task {
            var failure: String?
            do {
                let reply = try await Sender.send(n, config: config)
                let tries = (retries[n.id]?.tries ?? 0) + 1
                retries[n.id] = nil
                record("\(n.name): sent (\(n.target.label))" + (reply.map { ": \($0)" } ?? "") + (tries > 1 ? " (try \(tries))" : ""))
                notify("\(n.name) sent", n.target.label + (reply.map { ": \($0)" } ?? ""), failed: false)
            } catch {
                failure = error.localizedDescription
                let tries = (retries[n.id]?.tries ?? 0) + 1
                if scheduled, Store.retryable(error), tries < Store.maxTries {
                    let at = Date().addingTimeInterval(Store.retryGap)
                    retries[n.id] = (tries, at)
                    record("\(n.name): not sent (try \(tries) of \(Store.maxTries)): \(error.localizedDescription); trying again at \(Store.short(at))")
                } else {
                    retries[n.id] = nil
                    record("\(n.name): not sent\(tries > 1 ? " after \(tries) tries" : ""): \(error.localizedDescription)")
                    notify("\(n.name) wasn't sent", error.localizedDescription.prefix(1).uppercased() + error.localizedDescription.dropFirst(), failed: true)
                }
            }
            state.outcomes[n.id] = .init(date: Date(), error: failure)
            saveState()
            sending = nil
            stopShaking()
            if n.target == .codex { refreshCodex(force: true) }
            if n.target.isClaude { refreshClaude(force: true) }
            check()
        }
    }

    /// A nudge, like the old messenger kind: a quick jiggle, a pause, again, until the send is done.
    private func startShaking() {
        let frames = NudgeIcon.shakeFrames + Array(repeating: 0, count: 10)
        var i = 0
        shakeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                Store.shared.shake = frames[i % frames.count]
                i += 1
            }
        }
    }

    private func stopShaking() {
        shakeTimer?.invalidate()
        shakeTimer = nil
        shake = 0
    }

    // MARK: Settings

    /// Takes settings from the web page. The token and port stay as they are, and nudges whose
    /// schedule changed don't catch up on times that already passed.
    func update(_ new: Config, fromWeb: Bool = false) {
        var new = new
        new.token = config.token
        new.port = config.port
        if fromWeb { protectCommands(&new) }
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
        refreshCodex(force: true)
        refreshClaude(force: true)
        check()
    }

    /// Asks Codex when its usage runs out, for "When Codex resets" nudges: at most every 10 minutes,
    /// and only while there's such a nudge. The resume time is kept until that nudge goes, so a
    /// check just after the reset (usage back) doesn't lose it.
    private func refreshCodex(force: Bool = false) {
        guard !codexChecking,
              config.nudges.contains(where: { $0.enabled && $0.mode == .reset && $0.mode.fits($0.target) }) else { return }
        if !force, let last = codexCheckedAt, now.timeIntervalSince(last) < 600 { return }
        codexChecking = true
        Task {
            let answer = await CLITools.codexOutUntil()
            codexChecking = false
            codexCheckedAt = Date()
            guard let outUntil = answer else { return }      // couldn't ask; the next check tries again
            codexOutUntil = outUntil
            if let until = outUntil {
                let resume = until.addingTimeInterval(60)
                if state.codexResumeAt != resume {
                    state.codexResumeAt = resume
                    saveState()
                    record("Codex is out of usage until \(Store.short(until)); resume nudge at \(Store.short(resume))")
                }
            }
            check()
        }
    }

    /// Refreshes the list of your Codex chats (at most once a minute unless forced).
    func refreshCodexThreads(force: Bool = false) {
        if !force, let t = threadsCheckedAt, Date().timeIntervalSince(t) < 60 { return }
        threadsCheckedAt = Date()
        Task { if let list = await CLITools.codexThreads() { codexThreads = list } }
    }

    /// The choices for a Codex nudge's chat: (value, label).
    func codexChatChoices(current: String) -> [(String, String)] {
        var choices = [("", "New unsaved session (only starts the window)"), ("latest", "Most recent chat")]
        choices += codexThreads.map { ($0.id, "\($0.name) · \(Store.short($0.updated))") }
        if !current.isEmpty, !choices.contains(where: { $0.0 == current }) { choices.append((current, "Saved chat")) }
        return choices
    }

    /// Asks Claude Code when Claude's usage runs out, for "When Claude resets" nudges (same rules as
    /// for Codex: at most every 10 minutes, only while there's such a nudge, the resume time kept).
    /// Reads Claude's usage through Claude Code: every 10 minutes while a "When Claude resets" nudge
    /// is on, and every 6 hours while a Claude Code nudge is (to spot a signed-out Claude Code early).
    private func refreshClaude(force: Bool = false) {
        let resetNudge = config.nudges.contains(where: { $0.enabled && $0.mode == .claudeReset && $0.mode.fits($0.target) })
        let codeNudge = config.nudges.contains(where: { $0.enabled && $0.target == .claudeCode })
        guard !claudeChecking, resetNudge || codeNudge else { return }
        if !force, let last = claudeCheckedAt, now.timeIntervalSince(last) < (resetNudge ? 600 : 6 * 3600) { return }
        claudeChecking = true
        Task {
            let answer = await CLITools.claudeUsage()
            claudeChecking = false
            claudeCheckedAt = Date()
            let problem: String?
            switch answer {
            case .signedOut: problem = "Claude Code is signed out"
            case .unreadable(let why): problem = "Claude's usage couldn't be read (\(why))"
            case .out: problem = nil
            }
            if problem != claudeProblem {
                claudeProblem = problem
                if let problem {
                    record("\(problem); \(resetNudge ? "When Claude resets nudges can't tell when to go" : "Claude Code nudges will fail")")
                    notify(problem, problem == "Claude Code is signed out"
                           ? "Sign in from the AI Nudge menu › Sign in to Claude Code…"
                           : "When Claude resets nudges can't tell when to go.", failed: true)
                } else {
                    record("Claude's usage can be read again")
                }
            }
            guard case .out(let outUntil) = answer else { return }
            // Signed in: see when the sign-in runs out (twice a day), and warn 3 days ahead.
            if claudeLoginCheckedAt.map({ Date().timeIntervalSince($0) > 12 * 3600 }) ?? true {
                claudeLoginCheckedAt = Date()
                claudeLoginEnds = await CLITools.claudeLoginEnds()
                if claudeLoginEndingSoon, let ends = claudeLoginEnds, claudeLoginWarned != ends {
                    claudeLoginWarned = ends
                    record("Claude Code's sign-in runs out \(Store.day(ends)); sign in again from the menu")
                    notify("Claude Code's sign-in runs out \(Store.day(ends))",
                           "Sign in again from the AI Nudge menu › Sign in to Claude Code…, or Claude nudges that use it will stop.", failed: true)
                }
            }
            claudeOutUntil = outUntil
            if let until = outUntil {
                let resume = until.addingTimeInterval(60)
                if state.claudeResumeAt != resume {
                    state.claudeResumeAt = resume
                    saveState()
                    record("Claude is out of usage until \(Store.short(until)); resume nudge at \(Store.short(resume))")
                }
            }
            check()
        }
    }

    /// What a "When Claude resets" nudge is waiting for, in words.
    var claudeStatusText: String {
        if let at = state.claudeResumeAt, at > now {
            let until = claudeOutUntil.map { Store.short($0) } ?? Store.short(at.addingTimeInterval(-60))
            return "Claude is out of usage until \(until), so this goes at \(Store.short(at))."
        }
        guard claudeCheckedAt != nil else { return "Checking Claude's usage…" }
        if let claudeProblem {
            return claudeProblem == "Claude Code is signed out"
                ? "Claude Code is signed out, so this can't tell when Claude resets. Sign in from the menu bar icon › Sign in to Claude Code…"
                : "\(claudeProblem), so this can't tell when Claude resets."
        }
        return "Claude has usage left. This goes a minute after it next runs out and resets."
    }

    /// The status line for a reset nudge, or why it can't work with its target.
    func resetStatus(_ n: Nudge) -> String? {
        guard n.mode.isReset else { return nil }
        guard n.mode.fits(n.target) else {
            return n.mode == .reset ? "Codex resets only works with the Codex target (or a command)."
                                    : "Claude resets only works with a Claude target (or a command)."
        }
        return n.mode == .reset ? codexStatusText : claudeStatusText
    }

    /// What a "When Codex resets" nudge is waiting for, in words.
    var codexStatusText: String {
        if let at = state.codexResumeAt, at > now {
            let until = codexOutUntil.map { Store.short($0) } ?? Store.short(at.addingTimeInterval(-60))
            return "Codex is out of usage until \(until), so this goes at \(Store.short(at))."
        }
        guard codexCheckedAt != nil else { return "Checking Codex's usage…" }
        return "Codex has usage left. This goes a minute after it next runs out and resets."
    }

    /// The web page may switch command nudges on and off, reschedule or delete them, but never set a
    /// command: a nudge that runs one keeps its command, and nothing else can become one.
    private func protectCommands(_ new: inout Config) {
        let old = Dictionary(uniqueKeysWithValues: config.nudges.map { ($0.id, $0) })
        new.nudges = new.nudges.compactMap { n in
            var n = n
            guard let o = old[n.id] else { return n.target == .command ? nil : n }
            if o.target == .command {
                n.target = .command
                n.message = o.message
            } else if n.target == .command {
                n.target = o.target
            }
            return n
        }
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

    /// When a nudge goes, short, for its switch in the menu.
    func menuWhen(_ n: Nudge) -> String {
        switch n.mode {
        case .weekly: return n.time
        case .once: return next(n).map(Store.short) ?? "once (done)"
        case .reset: return next(n).map { "after Codex resets, \(Store.short($0))" } ?? "after Codex resets"
        case .claudeReset: return next(n).map { "after Claude resets, \(Store.short($0))" } ?? "after Claude resets"
        }
    }

    func nextText(_ n: Nudge) -> String {
        if let d = next(n) { return Store.short(d) }
        guard n.enabled else { return "off" }
        switch n.mode {
        case .weekly: return "off"
        case .once: return "time has passed"
        case .reset: return n.mode.fits(n.target) ? "when Codex next resets" : "only works with Codex"
        case .claudeReset: return n.mode.fits(n.target) ? "when Claude next resets" : "only works with Claude"
        }
    }

    /// "never", "sent Thu 09:06", or "failed Thu 09:06: why".
    func lastText(_ n: Nudge) -> String {
        guard let o = state.outcomes[n.id] else { return "never" }
        return o.error.map { "failed \(Store.short(o.date)): \($0)" } ?? "sent \(Store.short(o.date))"
    }

    func lastFailed(_ n: Nudge) -> Bool { state.outcomes[n.id]?.error != nil }

    func refreshTrust() { trusted = Sender.trusted }

    /// Opens Terminal on Claude Code's sign-in, and checks again a little later.
    func signInToClaudeCode() {
        if !CLITools.openClaudeSignIn() { record("couldn't open Claude Code's sign-in") }
        claudeLoginCheckedAt = nil
        for delay in [60.0, 180, 600] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { Store.shared.refreshClaude(force: true) } }
        }
    }

    /// Posts a notification if the setting covers it: failures, or every nudge.
    func notify(_ title: String, _ body: String, failed: Bool) {
        guard config.notify == .all || (failed && config.notify == .failures) else { return }
        Notifier.post(title, body)
    }

    /// Checks whether macOS lets AI Nudge notify, asking first if `ask` (macOS only asks once).
    func refreshNotifications(ask: Bool = false) {
        Task {
            let ok = ask ? await Notifier.ask() : await Notifier.allowed()
            if notificationsAllowed != ok { notificationsAllowed = ok }
        }
    }

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
