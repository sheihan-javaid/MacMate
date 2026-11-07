import AppKit
import UserNotifications

/// Let the native WhatsApp app deliver its own alerts while it is running,
/// including when hidden or minimized. The mirrored list remains available.
enum NativeNotificationFilter {
    static let whatsAppBundleIdentifier = "net.whatsapp.WhatsApp"

    static func shouldSuppress(_ item: PhoneNotification) -> Bool {
        guard isWhatsApp(appName: item.appName, notificationId: item.id) else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: whatsAppBundleIdentifier)
            .contains { !$0.isTerminated }
    }

    /// Only a click on the notification body opens the native app. Reply,
    /// dismiss and code-copy buttons retain their original behavior.
    static func applicationForDefaultAction(_ action: String, appName: String, notificationId: String) -> String? {
        guard action == UNNotificationDefaultActionIdentifier,
              isWhatsApp(appName: appName, notificationId: notificationId) else { return nil }
        return whatsAppBundleIdentifier
    }

    public static func extractPackageName(from notificationId: String) -> String? {
        let parts = notificationId.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 5,
              Int(parts[0]) != nil,                 // userId
              Int(parts[2]) != nil,                 // notification id
              let last = parts.last, Int(last) != nil // uid
        else { return nil }

        let candidate = String(parts[1])
        guard isValidPackageName(candidate) else { return nil }
        return candidate
    }

    public static func isValidPackageName(_ candidate: String) -> Bool {
        guard !candidate.isEmpty, candidate.count <= 255 else { return false }
        let segments = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { return false }
        for segment in segments {
            guard !segment.isEmpty else { return false }
            guard segment.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return false }
        }
        return true
    }

    static func isWhatsApp(appName: String, notificationId: String) -> Bool {
        // KDE Connect normally forwards StatusBarNotification.key:
        // userId|packageName|notificationId|tag|uid. Prefer its package over a
        // display name, so similarly named apps / WhatsApp Business stay distinct.
        if let package = extractPackageName(from: notificationId) {
            return package == "com.whatsapp"
        }
        // Older / compatible senders can use opaque IDs with only appName.
        return appName.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("WhatsApp") == .orderedSame
    }
}
