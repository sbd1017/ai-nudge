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

    var body: some View {
        let n = nudge
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Toggle("", isOn: field(\.enabled)).toggleStyle(.switch).labelsHidden()
                    TextField("Name", text: field(\.name)).font(.headline)
                    DatePicker("", selection: time, displayedComponents: .hourAndMinute).labelsHidden()
                    Button("Send Now") { store.sendNow(id) }.disabled(store.sending != nil)
                    Button(role: .destructive) {
                        store.edit { $0.nudges.removeAll { $0.id == id } }
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete")
                }
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
                Picker("Send to", selection: field(\.target)) {
                    ForEach(Target.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if let note = n.target.note {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let prompt = n.target.chatPrompt {
                    TextField(prompt, text: field(\.chat))
                }
                TextField("Message", text: field(\.message), axis: .vertical)
                    .lineLimit(2...5)
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
