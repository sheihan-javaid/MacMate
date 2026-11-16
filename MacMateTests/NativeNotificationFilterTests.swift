import Testing
import UserNotifications
@testable import MacMate

@MainActor
struct NativeNotificationFilterTests {
    @Test(arguments: [
        ("WhatsApp", "0|com.whatsapp|12|null|10345", true),
        ("Localized name", "10|com.whatsapp|-12||1010345", true),
        ("WhatsApp", "0|com.instagram.android|12|null|10346", false),
        ("WhatsApp Business", "0|com.whatsapp.w4b|12|null|10347", false),
        ("WhatsApp", "opaque-legacy-id", true),
        (" whatsapp ", "12", true),
        ("WhatsApp Business", "12", false),
        ("Instagram", "12", false),
    ])
    func recognizesOnlyPersonalWhatsApp(name: String, id: String, expected: Bool) {
        #expect(NativeNotificationFilter.isWhatsApp(appName: name, notificationId: id) == expected)
    }

    @Test(arguments: [
        (UNNotificationDefaultActionIdentifier, "WhatsApp", "0|com.whatsapp|12|null|10345", true),
        (UNNotificationDefaultActionIdentifier, "WhatsApp", "legacy-id", true),
        (UNNotificationDefaultActionIdentifier, "", "0|com.whatsapp|12|null|10345", true),
        (UNNotificationDefaultActionIdentifier, "Instagram", "0|com.instagram.android|12|null|10346", false),
        (UNNotificationDefaultActionIdentifier, "WhatsApp Business", "0|com.whatsapp.w4b|12|null|10347", false),
        ("MACMATE_REPLY_ACTION", "WhatsApp", "0|com.whatsapp|12|null|10345", false),
        ("MACMATE_REPLY_ACTION", "WhatsApp", "0|com.whatsapp|12|null|10345", false),
        ("MACMATE_DISMISS_ACTION", "WhatsApp", "0|com.whatsapp|12|null|10345", false),
        ("MACMATE_DISMISS_ACTION", "WhatsApp", "0|com.whatsapp|12|null|10345", false),
        ("MACMATE_COPY_CODE_ACTION", "WhatsApp", "0|com.whatsapp|12|null|10345", false),
        ("MACMATE_COPY_CODE_ACTION", "WhatsApp", "0|com.whatsapp|12|null|10345", false),
        (UNNotificationDismissActionIdentifier, "WhatsApp", "0|com.whatsapp|12|null|10345", false),
    ])
    func opensWhatsAppOnlyForBodyClicks(action: String, name: String, id: String, expected: Bool) {
        let application = NativeNotificationFilter.applicationForDefaultAction(action, appName: name, notificationId: id)
        #expect(application == (expected ? "net.whatsapp.WhatsApp" : nil))
    }

    @Test(arguments: [
        ("0|com.whatsapp|12|null|10345", "com.whatsapp"),
        ("10|org.telegram.messenger|-12||1010345", "org.telegram.messenger"),
        ("0|com.google.android.gm|5|tag1|10001", "com.google.android.gm"),
        ("0|com.Slack|1|null|10002", "com.Slack"),
        ("0|android|1|null|1000", "android"),
        ("0|com.example.app|12|tag|with|bars|10345", "com.example.app"),
        ("0|com.slack|1|channel|123|thread|456|10050", "com.slack"),
    ])
    func extractsPackageNameFromValidKeys(key: String, expected: String) {
        #expect(NativeNotificationFilter.extractPackageName(from: key) == expected)
    }

    @Test(arguments: [
        "abc|com.whatsapp|12|null|10345",
        "0|com.whatsapp|12|null|xyz",
        "0|com.whatsapp|not_an_id|null|10345",
        "",
        "opaque-legacy-id",
        "0|com.whatsapp",
        "0|com.whatsapp|12|null",
        "0||12|tag|10345",
        "||||",
        "0|.com.whatsapp|12|null|10345",
        "0|com..whatsapp|12|null|10345",
        "0|com.whatsapp.|12|null|10345",
        "0|com/whatsapp|12|null|10345",
        "0|com whatsapp|12|null|10345",
        "0|com.what$app|12|null|10345",
    ])
    func rejectsMalformedAndInvalidPackageKeys(key: String) {
        #expect(NativeNotificationFilter.extractPackageName(from: key) == nil)
    }

    @Test
    func verifiesNotificationContentAndIdentifierIntegrity() {
        let itemWithCode = PhoneNotification(
            id: "0|com.whatsapp|12|null|10345",
            deviceId: "phone_xyz",
            appName: "WhatsApp",
            title: "Alex",
            text: "Your code is 987654",
            date: Date(),
            replyId: "reply_123",
            isDismissable: true,
            code: "987654"
        )
        let contentWithCode = NotificationPlugin.makeContent(for: itemWithCode)

        #expect(contentWithCode.threadIdentifier == "phone_xyz:com.whatsapp")
        #expect(contentWithCode.categoryIdentifier == NotificationPlugin.codeCategory)
        #expect(contentWithCode.userInfo["notifId"] as? String == "0|com.whatsapp|12|null|10345")
        #expect(contentWithCode.userInfo["deviceId"] as? String == "phone_xyz")
        #expect(contentWithCode.userInfo["replyId"] as? String == "reply_123")
        #expect(contentWithCode.userInfo["appName"] as? String == "WhatsApp")
        #expect(contentWithCode.userInfo["code"] as? String == "987654")
        #expect(NotificationPlugin.identifier(deviceId: itemWithCode.deviceId, id: itemWithCode.id) == "android:9:phone_xyz0|com.whatsapp|12|null|10345")

        let legacyItem = PhoneNotification(
            id: "legacy_999",
            deviceId: "phone_xyz",
            appName: "Telegram",
            title: "Bob",
            text: "Hello",
            date: Date(),
            replyId: nil,
            isDismissable: true
        )
        let legacyContent = NotificationPlugin.makeContent(for: legacyItem)

        #expect(legacyContent.threadIdentifier == "phone_xyz:Telegram")
        #expect(legacyContent.categoryIdentifier == NotificationPlugin.notificationCategory)
        #expect(legacyContent.userInfo["notifId"] as? String == "legacy_999")
        #expect(legacyContent.userInfo["deviceId"] as? String == "phone_xyz")
        #expect(legacyContent.userInfo["replyId"] as? String == "")
        #expect(legacyContent.userInfo["appName"] as? String == "Telegram")
        #expect(legacyContent.userInfo["code"] as? String == "")
        #expect(NotificationPlugin.identifier(deviceId: legacyItem.deviceId, id: legacyItem.id) == "android:9:phone_xyzlegacy_999")
    }

}
