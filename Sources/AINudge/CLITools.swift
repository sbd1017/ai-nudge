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
            (exe, args) = (p, ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral",
                               "--cd", workDir.path, "--output-last-message", replyFile.path, "--", n.message])
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
