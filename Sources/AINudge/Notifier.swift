import AppKit
import UserNotifications

/// How much AI Nudge tells you through macOS notifications.
enum NotifyLevel: String, Codable, CaseIterable {
    case off, failures, all

    var label: String {
        switch self {
        case .off: return "Off"
        case .failures: return "When a nudge fails"
        case .all: return "Every nudge"
        }
    }
}

/// Posts notifications. They show even while the settings window is in front, and clicking one
/// opens the settings window.
enum Notifier {
    private static let delegate = Delegate()

    static func setUp() { UNUserNotificationCenter.current().delegate = delegate }

    /// Asks macOS for permission (it only asks once) and says whether notifications are allowed.
    static func ask() async -> Bool? {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await allowed()
    }

    /// true: allowed; false: turned off; nil: you haven't answered macOS's question yet.
    /// The banner and Notification Centre switches decide what you see; the overall status can
    /// still say "denied" after you've turned them on in System Settings, so they come first.
    static func allowed() async -> Bool? {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        if s.alertSetting == .enabled || s.notificationCenterSetting == .enabled { return true }
        switch s.authorizationStatus {
        case .authorized, .provisional: return true
        case .denied: return false
        case .notDetermined: return nil
        @unknown default: return true
        }
    }

    static func post(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=local.ai-nudge")!

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
            done([.banner, .list, .sound])
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler done: @escaping () -> Void) {
            DispatchQueue.main.async { MainActor.assumeIsolated { Store.shared.showSettingsWindow?() } }
            done()
        }
    }
}
