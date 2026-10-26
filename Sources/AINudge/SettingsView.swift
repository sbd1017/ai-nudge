import ServiceManagement
import SwiftUI

/// The settings window on the Mac. The web page has the same settings, for when you're away.
struct SettingsView: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            if !store.trusted { AccessibilityBanner(store: store) }
            TabView {
                NudgesTab(store: store).tabItem { Text("Nudges") }
                GeneralTab(store: store).tabItem { Text("General") }
                ActivityTab(store: store).tabItem { Text("Activity") }
            }
            .padding(12)
        }
        .frame(width: 560, height: 600)
        .onAppear {
            // Don't open with the first nudge's name selected, ready to be typed over.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshTrust()
        }
    }
}

private struct AccessibilityBanner: View {
    @ObservedObject var store: Store

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("AI Nudge can't type yet").bold()
                Text("Turn on AI Nudge in System Settings › Privacy & Security › Accessibility. If it's already on, turn it off and on again.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Settings") {
                Sender.requestTrust()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }
}

// MARK: - Nudges

private struct NudgesTab: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(spacing: 10) {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(store.config.nudges) { n in NudgeEditor(store: store, id: n.id) }
                }
                .padding(2)
            }
            HStack {
                Button("Add Nudge") { store.addNudge() }
                Spacer()
                Button("Open Web Settings") { store.openSettings() }
            }
        }
    }
}

private struct NudgeEditor: View {
    @ObservedObject var store: Store
    let id: String

    private var nudge: Nudge { store.config.nudges.first { $0.id == id } ?? Nudge() }

    /// A binding to one field of this nudge; each change is saved straight away.
    private func field<T>(_ path: WritableKeyPath<Nudge, T>) -> Binding<T> {
        Binding(
            get: { nudge[keyPath: path] },
            set: { value in
                store.edit { c in
                    if let i = c.nudges.firstIndex(where: { $0.id == id }) { c.nudges[i][keyPath: path] = value }
                }
            })
    }

    private var time: Binding<Date> {
        Binding(
            get: {
                let t = Schedule.parseTime(nudge.time) ?? (6, 0)
                return Calendar.current.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                field(\.time).wrappedValue = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            })
    }

    /// Choosing Once starts from the next time this nudge's time comes round; When Codex resets
    /// also switches the target to Codex.
    private var mode: Binding<Repeat> {
        Binding(
            get: { nudge.mode },
            set: { m in
                store.edit { c in
                    guard let i = c.nudges.firstIndex(where: { $0.id == id }) else { return }
                    c.nudges[i].repeats = m
                    if m == .once, c.nudges[i].date == nil {
                        let next = Schedule.nextOccurrence(time: c.nudges[i].time, days: Array(1...7), after: Date()) ?? Date()
                        c.nudges[i].date = Schedule.dayString(next)
                    }
                    // a reset mode needs a target it can work with
                    if m == .reset, !m.fits(c.nudges[i].target) { c.nudges[i].target = .codex; c.nudges[i].chat = "" }
                    if m == .claudeReset, !m.fits(c.nudges[i].target) { c.nudges[i].target = .claudeApp; c.nudges[i].chat = "" }
                }
            })
    }

    /// Changing where a nudge goes clears its chat link or Codex chat, which belonged to the old target.
    private var target: Binding<Target> {
        Binding(
            get: { nudge.target },
            set: { t in
                store.edit { c in
                    guard let i = c.nudges.firstIndex(where: { $0.id == id }), c.nudges[i].target != t else { return }
                    c.nudges[i].target = t
                    c.nudges[i].chat = ""
                }
            })
    }

    private var moment: Binding<Date> {
        Binding(
            get: { nudge.date.flatMap { Schedule.moment(date: $0, time: nudge.time) } ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                let day = Schedule.dayString(d), time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
                store.edit { cfg in
                    guard let i = cfg.nudges.firstIndex(where: { $0.id == id }) else { return }
                    cfg.nudges[i].date = day
                    cfg.nudges[i].time = time
                }
            })
    }

    var body: some View {
        let n = nudge
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Toggle("", isOn: field(\.enabled)).toggleStyle(.switch).labelsHidden()
                    TextField("Name", text: field(\.name)).font(.headline)
                    switch n.mode {
                    case .weekly: DatePicker("", selection: time, displayedComponents: .hourAndMinute).labelsHidden()
                    case .once: DatePicker("", selection: moment, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                    case .reset, .claudeReset: EmptyView()
                    }
                    Button("Send Now") { store.sendNow(id) }.disabled(store.sending != nil)
                    Button(role: .destructive) {
                        store.edit { $0.nudges.removeAll { $0.id == id } }
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete")
                }
                Picker("Repeat", selection: mode) {
                    ForEach(Repeat.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if n.mode == .weekly {
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { day in
                        let on = n.days.contains(day)
                        Button(Calendar.current.shortWeekdaySymbols[day - 1]) {
                            var days = Set(n.days)
                            if on { days.remove(day) } else { days.insert(day) }
                            if !days.isEmpty { field(\.days).wrappedValue = days.sorted() }
                        }
                        .buttonStyle(DayStyle(on: on))
                    }
                }
                }
                Picker("Send to", selection: target) {
                    ForEach(Target.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if let note = n.target.note {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let status = store.resetStatus(n) {
                    Text(status)
                        .font(.caption).foregroundStyle(n.mode.fits(n.target) ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if n.target == .codex {
                    Picker("Codex chat", selection: field(\.chat)) {
                        ForEach(store.codexChatChoices(current: n.chat), id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .onAppear { store.refreshCodexThreads() }
                    if !n.chat.isEmpty {
                        Text("Continues that chat in its own folder, where it can change files, as it would in the app. It runs in the background; its reply shows in Activity.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let prompt = n.target.chatPrompt {
                    TextField(prompt, text: field(\.chat))
                }
                HStack {
                    Text(n.target == .command ? "Command" : n.mode.isReset ? "Resume message" : "Message")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if n.mode.isReset, n.target != .command, n.message != Nudge.resumePrompt {
                        Button("Use detailed resume prompt") { field(\.message).wrappedValue = Nudge.resumePrompt }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                TextField(n.target == .command ? "e.g. ~/bin/after-reset.sh" : "Message", text: field(\.message), axis: .vertical)
                    .lineLimit(2...5)
                    .font(n.target == .command ? .body.monospaced() : .body)
                Text("Next: \(store.nextText(n)) · Last: \(store.lastText(n))")
                    .font(.caption)
                    .foregroundStyle(store.lastFailed(n) ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
            }
            .padding(4)
            .opacity(n.enabled ? 1 : 0.6)
        }
    }
}

private struct DayStyle: ButtonStyle {
    let on: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .frame(width: 44, height: 24)
            .background(on ? Color.accentColor : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(on ? Color.white : Color.secondary)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var store: Store
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    private func setting<T>(_ path: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(get: { store.config[keyPath: path] }, set: { v in store.edit { $0[keyPath: path] = v } })
    }

    var body: some View {
        Form {
            Picker("Browser for web chats", selection: setting(\.browser)) {
                Text("Default").tag("")
                ForEach(Sender.installedBrowsers, id: \.id) { Text($0.name).tag($0.id) }
            }
            Stepper(value: setting(\.settleSeconds), in: 1...30, step: 0.5) {
                Text("Wait after opening a chat: \(store.config.settleSeconds, specifier: "%g") s")
            }
            Stepper(value: setting(\.catchUpMinutes), in: 0...1440, step: 15) {
                Text("Send late if the Mac was asleep, up to \(store.config.catchUpMinutes) min")
            }
            Toggle("Open AI Nudge at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { on in
                    do {
                        try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    } catch {
                        store.record("open at login: \(error.localizedDescription)")
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Toggle("Go back to the app I was using", isOn: setting(\.restoreFocus))
            Section("Keep Awake (from the menu bar)") {
                Toggle("Let the display sleep, just keep the Mac awake", isOn: setting(\.awakeLetDisplaySleep))
                Toggle("Stop when the battery is below 10%", isOn: setting(\.awakeStopOnLowBattery))
                Text("A nudge can only type while the screen is unlocked. If your Mac locks when the display sleeps, keep the display awake too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Let other devices on my network open the web settings", isOn: setting(\.allowLAN))
            if let lan = store.lanURL {
                HStack {
                    Text(lan.absoluteString).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lan.absoluteString, forType: .string)
                    }
                }
                Text("Anyone with this link can change your nudges.").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Address on your own site (optional)", text: setting(\.publicURL), prompt: Text("https://example.com/ainudge/"))
            if let site = store.siteURL {
                HStack {
                    Text(site.absoluteString).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(site.absoluteString, forType: .string)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Activity

private struct ActivityTab: View {
    @ObservedObject var store: Store

    var body: some View {
        ScrollView {
            Text(store.log.reversed().joined(separator: "\n").isEmpty ? "Nothing yet." : store.log.reversed().joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(8)
        }
    }
}
