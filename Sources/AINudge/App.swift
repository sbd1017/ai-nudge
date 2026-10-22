import ServiceManagement
import SwiftUI

@main
struct AINudgeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            MenuIcon(store: store)
        }
        Window("AI Nudge", id: "settings") {
            SettingsView(store: store)
        }
        .windowResizability(.contentSize)
    }
}

/// The menu bar icon. It's on screen from launch, so it also hands the store a way to open the
/// settings window.
struct MenuIcon: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: store.sending != nil ? "paperplane.fill" : store.awakeUntil != nil ? "cup.and.saucer.fill" : "timer")
            .onAppear {
                store.showSettingsWindow = {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                if store.firstRun { store.showSettingsWindow?() }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let store = Store.shared
            WebServer.shared.start()
            store.start()
            if store.firstRun, !Sender.trusted { Sender.requestTrust() }
        }
    }

    /// Opening the app again (Spotlight, Finder) while it's running shows the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { Store.shared.showSettingsWindow?() }
        return false
    }
}

struct MenuContent: View {
    @ObservedObject var store: Store
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        if let s = store.sending {
            Text("Sending \(s)…")
        } else if let next = store.nextUp {
            Text("Next: \(next.name), \(next.date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
        } else {
            Text("Nothing scheduled")
        }
        if let last = store.log.last {
            Text(last.split(separator: " ").dropFirst(2).joined(separator: " ")).lineLimit(1)
        }
        Divider()
        ForEach(store.config.nudges) { n in
            Toggle("\(n.name)  \(n.time)", isOn: Binding(
                get: { n.enabled },
                set: { on in store.edit { c in if let i = c.nudges.firstIndex(where: { $0.id == n.id }) { c.nudges[i].enabled = on } } }))
        }
        Divider()
        if !store.config.nudges.isEmpty {
            Menu("Send Now") {
                ForEach(store.config.nudges) { n in
                    Button(n.name) { store.sendNow(n.id) }
                }
            }
            .disabled(store.sending != nil)
        }
        KeepAwakeMenu(store: store)
        Divider()
        Button("Settings…") { store.showSettingsWindow?() }
            .keyboardShortcut(",")
        Button("Open Web Settings") { store.openSettings() }
        if let site = store.siteURL {
            Button("Copy Link for Your Site") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(site.absoluteString, forType: .string)
            }
        }
        if let lan = store.lanURL {
            Button("Copy Link for Other Devices") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lan.absoluteString, forType: .string)
            }
        }
        if !store.trusted {
            Button("⚠︎ Allow Accessibility…") {
                Sender.requestTrust()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
        Toggle("Open at Login", isOn: $openAtLogin)
            .onChange(of: openAtLogin) { on in
                do {
                    try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                } catch {
                    store.record("open at login: \(error.localizedDescription)")
                    openAtLogin = SMAppService.mainApp.status == .enabled
                }
            }
        Divider()
        Button("Quit AI Nudge") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Theine-style: switch it on indefinitely, or for a while.
struct KeepAwakeMenu: View {
    @ObservedObject var store: Store
    static let durations = [15, 30, 60, 120, 180, 300, 480]

    var body: some View {
        if let text = store.awakeText {
            Text(text)
            Button("Stop Keeping Awake") { store.keepAwake(minutes: 0) }
        }
        Menu("Keep Awake") {
            Button("Indefinitely") { store.keepAwake(minutes: nil) }
            Button("Until After the Next Nudge" + (store.nextUp.map { " (\(Store.short($0.date)))" } ?? "")) {
                store.keepAwake(minutes: -1)
            }
            .disabled(store.nextUp == nil)
            Divider()
            ForEach(Self.durations, id: \.self) { m in
                Button(m < 60 ? "\(m) Minutes" : m == 60 ? "1 Hour" : "\(m / 60) Hours") { store.keepAwake(minutes: m) }
            }
        }
    }
}
