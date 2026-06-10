import Foundation
import UserNotifications

/// Notifications macOS. UNUserNotificationCenter exige un vrai bundle .app ;
/// quand l'app tourne en binaire nu (swift run), on retombe sur osascript.
enum Notifier {
    static func requestPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        if Bundle.main.bundleIdentifier != nil {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req) { error in
                // Permission refusée ou centre indisponible : on passe par osascript.
                if error != nil { osascriptNotify(title: title, body: body) }
            }
        } else {
            osascriptNotify(title: title, body: body)
        }
    }

    private static func osascriptNotify(title: String, body: String) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}
