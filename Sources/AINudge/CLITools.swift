import Foundation

/// Sends a nudge through Claude Code or Codex, the command-line tools that come inside the Claude
/// and ChatGPT apps. A Codex request is what starts the Work + Codex allowance; a ChatGPT chat
/// doesn't. These need no typing, so no Accessibility permission and no unlocked screen.
enum CLITools {
    enum Failure: LocalizedError {
        case notFound(String), failed(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let tool): return "\(tool) isn't installed (it comes with the \(tool == "codex" ? "ChatGPT" : "Claude") app, or install it on its own)"
            case .failed(let why): return why
            }
        }
    }

    static let workDir = Store.dir.appendingPathComponent("workdir")
    private static let replyFile = Store.dir.appendingPathComponent("last-reply.txt")

    /// Sends the message and returns the reply.
    static func send(_ n: Nudge) async throws -> String {
        let (exe, args): (String, [String])
        switch n.target {
        case .claudeCode:
            guard let p = findClaude() else { throw Failure.notFound("claude") }
            // No tools or MCP servers, nothing saved: a plain reply is all that's wanted.
            (exe, args) = (p, ["-p", n.message, "--tools", "", "--strict-mcp-config", "--no-session-persistence"])
        case .codex:
            guard let p = findCodex() else { throw Failure.notFound("codex") }
            let chat = n.chat.trimmingCharacters(in: .whitespacesAndNewlines)
            if !chat.isEmpty { return try await continueCodexChat(chat, message: n.message, codex: p) }
            (exe, args) = (p, ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral",
                               "--cd", workDir.path, "--output-last-message", replyFile.path, "--", n.message])
        case .command:
            return try startCommand(n)
        default:
            throw Failure.failed("not a command-line target")
        }
        try? FileManager.default.removeItem(at: replyFile)
        let (status, output) = await run(exe, args)
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0 else {
            let last = text.split(separator: "\n").last.map(String.init) ?? "exit \(status)"
            throw Failure.failed("\(n.target == .codex ? "codex" : "claude") failed: \(last.prefix(200))")
        }
        // Codex prints its whole session; the reply itself goes to the file. Claude prints just the reply.
        let reply = (try? String(contentsOf: replyFile, encoding: .utf8)) ?? text
        return reply.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ").prefix(160).description
    }

    // MARK: Codex chats

    struct CodexThread: Identifiable, Equatable {
        let id: String
        let name: String
        let cwd: String
        let updated: Date
    }

    /// Your Codex chats (the ones in the ChatGPT app), newest first.
    static func codexThreads(limit: Int = 25) async -> [CodexThread]? {
        guard let exe = findCodex() else { return nil }
        let messages = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"ai-nudge","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"thread/list","params":{"limit":\#(limit)}}"#,
        ]
        guard let reply = await jsonRPC(exe, ["app-server"], send: messages, wantID: 2),
              let data = (reply["result"] as? [String: Any])?["data"] as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        return data.compactMap { t -> CodexThread? in
            guard let id = t["id"] as? String, seen.insert(id).inserted else { return nil }
            let updated = (t["updatedAt"] as? Double) ?? Double(t["updatedAt"] as? String ?? "") ?? 0
            let name = (t["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (t["preview"] as? String).map { String($0.prefix(40)) } ?? id
            return CodexThread(id: id, name: name, cwd: t["cwd"] as? String ?? "", updated: Date(timeIntervalSince1970: updated))
        }
        .sorted { $0.updated > $1.updated }
    }

    /// Sends the message into an existing Codex chat ("latest" = the most recent one), the way the app
    /// would continue it: in the chat's own folder, allowed to change files there. It can take a while,
    /// so it runs in the background and its reply is logged when it finishes.
    private static func continueCodexChat(_ chat: String, message: String, codex: String) async throws -> String {
        guard let threads = await codexThreads(limit: 50) else { throw Failure.failed("couldn't list your Codex chats") }
        guard let t = chat == "latest" ? threads.first : threads.first(where: { $0.id == chat }) else {
            throw Failure.failed("that Codex chat isn't there any more; pick another in Settings")
        }
        // A chat that's open in the ChatGPT app belongs to the app's own Codex (it holds the chat's
        // lock), so the message goes through the app, like one typed there.
        let (queued, queueOutput) = await run(codex, ["queue", "--thread", t.id, "--message", message], timeout: 60)
        if queued == 0 { return "sent into Codex chat “\(t.name)” through the ChatGPT app" }
        guard queueOutput.contains("No active session") else {
            throw Failure.failed("codex queue failed: \(lastLine(queueOutput))")
        }

        // Not open in the app: continue it directly.
        let folder = FileManager.default.fileExists(atPath: t.cwd) ? t.cwd : workDir.path
        let replyTo = Store.dir.appendingPathComponent("reply-\(t.id).txt")
        let errorsTo = Store.dir.appendingPathComponent("codex-\(t.id).log")
        FileManager.default.createFile(atPath: errorsTo.path, contents: nil)
        try? FileManager.default.removeItem(at: replyTo)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: codex)
        p.arguments = ["exec", "--skip-git-repo-check", "--sandbox", "workspace-write", "--cd", folder,
                       "--output-last-message", replyTo.path, "resume", t.id, "--", message]
        p.currentDirectoryURL = URL(fileURLWithPath: folder)
        let errors = try? FileHandle(forWritingTo: errorsTo)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errors ?? FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let name = t.name
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        p.terminationHandler = { proc in
            killer.cancel()
            let reply = ((try? String(contentsOf: replyTo, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
            try? errors?.close()
            let why = lastLine((try? String(contentsOf: errorsTo, encoding: .utf8)) ?? "")
            let line = proc.terminationStatus == 0
                ? "Codex chat “\(name)” finished: \(reply.prefix(160))"
                : "Codex chat “\(name)” stopped (exit \(proc.terminationStatus)): \(why.isEmpty ? reply.prefix(160).description : why)"
            DispatchQueue.main.async { MainActor.assumeIsolated { Store.shared.record(line) } }
            proc.terminationHandler = nil      // releases the process
        }
        do { try p.run() } catch { throw Failure.failed("couldn't start codex: \(error.localizedDescription)") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3 * 3600, execute: killer)
        return "continuing Codex chat “\(name)”"
    }

    /// The last non-empty line of a tool's output, for error messages.
    private static func lastLine(_ text: String) -> String {
        String(text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "").prefix(200).description
    }

    // MARK: Commands

    /// Runs a nudge's shell command (its message) with zsh in the home folder, in the background,
    /// and logs how it ended.
    private static func startCommand(_ n: Nudge) throws -> String {
        let command = n.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { throw Failure.failed("no command set") }
        let output = Store.dir.appendingPathComponent("command-\(n.id).log")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: output)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", command]
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        env["AI_NUDGE_NAME"] = n.name
        p.environment = env
        p.standardOutput = handle ?? FileHandle.nullDevice
        p.standardError = handle ?? FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let name = n.name
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        p.terminationHandler = { proc in
            killer.cancel()
            try? handle?.close()
            let last = lastLine((try? String(contentsOf: output, encoding: .utf8)) ?? "")
            let line = "\(name): command \(proc.terminationStatus == 0 ? "finished" : "failed (exit \(proc.terminationStatus))")\(last.isEmpty ? "" : ": \(last)")"
            DispatchQueue.main.async { MainActor.assumeIsolated { Store.shared.record(line) } }
            proc.terminationHandler = nil
        }
        do { try p.run() } catch { throw Failure.failed("couldn't run the command: \(error.localizedDescription)") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3600, execute: killer)
        return "command started"
    }

    // MARK: Claude usage

    /// When Claude's usage runs out again: nil while there's usage left, otherwise when the full
    /// window (5-hour session or weekly) resets. From Claude Code's /usage, which reports usage and
    /// sends no message.
    static func claudeOutUntil() async -> Date?? {
        guard let exe = findClaude() else { return nil }
        let (status, out) = await run(exe, ["-p", "/usage", "--tools", "", "--strict-mcp-config", "--no-session-persistence"], timeout: 60)
        guard status == 0, out.contains("Current session") else { return nil }
        var resets: [Date] = []
        for line in out.split(separator: "\n").map(String.init) where line.hasPrefix("Current ") {
            guard let pct = firstMatch(#"(\d+)% used"#, in: line).flatMap({ Int($0[0]) }), pct >= 100 else { continue }
            guard let at = parseReset(line) else { return nil }      // full, but no time we can read: ask again later
            resets.append(at)
        }
        return .some(resets.max())
    }

    /// "… resets Oct 27 at 3am (Europe/London)" or "… resets 4:30pm" → that moment, local time.
    static func parseReset(_ line: String, now: Date = Date(), calendar cal: Calendar = .current) -> Date? {
        guard let m = firstMatch(#"resets (?:([A-Z][a-z]{2}) (\d{1,2}) at )?(\d{1,2})(?::(\d{2}))?\s*(am|pm)"#, in: line),
              var hour = Int(m[2]) else { return nil }
        let minute = Int(m[3]) ?? 0
        if m[4] == "pm", hour < 12 { hour += 12 }
        if m[4] == "am", hour == 12 { hour = 0 }
        var c = cal.dateComponents([.year, .month, .day], from: now)
        c.hour = hour
        c.minute = minute
        if !m[0].isEmpty, let month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].firstIndex(of: m[0]),
           let day = Int(m[1]) {
            c.month = month + 1
            c.day = day
            guard var at = cal.date(from: c) else { return nil }
            if at < now.addingTimeInterval(-2 * 86400) { at = cal.date(byAdding: .year, value: 1, to: at) ?? at }
            return at
        }
        guard var at = cal.date(from: c) else { return nil }
        if at < now { at = cal.date(byAdding: .day, value: 1, to: at) ?? at }
        return at
    }

    /// The capture groups of the first match ("" for groups that didn't take part).
    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
    }

    // MARK: Codex usage

    /// When Codex's usage runs out again: nil while there's usage left, otherwise the time the
    /// exhausted window resets. Asked of Codex's own app server (no request is sent, so nothing is used).
    static func codexOutUntil() async -> Date?? {
        guard let exe = findCodex() else { return nil }
        let messages = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"ai-nudge","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}"#,
        ]
        guard let reply = await jsonRPC(exe, ["app-server"], send: messages, wantID: 2),
              let result = reply["result"] as? [String: Any],
              let limits = result["rateLimits"] as? [String: Any] else { return nil }

        let now = Date()
        let windows = ["primary", "secondary"].compactMap { limits[$0] as? [String: Any] }
        let full = windows.filter { ($0["usedPercent"] as? Double ?? 0) >= 100 }
        let blocked = !(limits["rateLimitReachedType"] is NSNull || limits["rateLimitReachedType"] == nil)
            || (result["ordinaryUsageAllowed"] as? Bool) == false
        guard blocked || !full.isEmpty else { return .some(nil) }
        // The latest reset among the full windows (or the 5-hour one if none says it's full).
        let resets = (full.isEmpty ? Array(windows.prefix(1)) : full)
            .compactMap { ($0["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) } }
            .filter { $0 > now }
        return .some(resets.max())
    }

    /// Writes JSON-RPC lines to a tool's stdin and returns the reply with the given id.
    private static func jsonRPC(_ exe: String, _ args: [String], send: [String], wantID: Int,
                                timeout: TimeInterval = 20) async -> [String: Any]? {
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let input = Pipe(), output = Pipe()
                p.standardInput = input
                p.standardOutput = output
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { done.resume(returning: nil); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                input.fileHandleForWriting.write(Data((send.joined(separator: "\n") + "\n").utf8))

                var buffer = Data()
                var found: [String: Any]?
                while found == nil {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }          // the tool exited (or the timeout ended it)
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[buffer.startIndex..<nl]
                        buffer.removeSubrange(buffer.startIndex...nl)
                        if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                           obj["id"] as? Int == wantID { found = obj; break }
                    }
                }
                killer.cancel()
                if p.isRunning { p.terminate() }
                done.resume(returning: found)
            }
        }
    }

    // MARK: Finding the tools

    private static func executable(_ path: String) -> String? {
        let p = (path as NSString).expandingTildeInPath
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    private static func onPath(_ name: String) -> String? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return dirs.lazy.compactMap { executable("\($0)/\(name)") }.first
    }

    /// On PATH, or the copy the Claude app keeps (newest version first).
    static func findClaude() -> String? {
        if let p = onPath("claude") ?? executable("~/.claude/local/claude") { return p }
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for v in versions {
            for build in (try? fm.contentsOfDirectory(atPath: base.appendingPathComponent(v).path)) ?? [] {
                if let p = executable(base.path + "/\(v)/\(build)/claude.app/Contents/MacOS/claude") { return p }
            }
        }
        return nil
    }

    /// On PATH, or the copy inside the ChatGPT app.
    static func findCodex() -> String? {
        onPath("codex")
            ?? executable("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
            ?? executable("~/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
    }

    // MARK: Running

    private static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 300) async -> (Int32, String) {
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.currentDirectoryURL = workDir     // an empty folder, so no project files get picked up
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { done.resume(returning: (-1, error.localizedDescription)); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                done.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
