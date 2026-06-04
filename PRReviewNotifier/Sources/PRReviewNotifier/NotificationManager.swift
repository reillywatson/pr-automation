import AppKit
import Foundation
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private var modernCenter: UNUserNotificationCenter?
    private var legacyCenter: NSObject?
    private var isConfigured = false

    func configure() {
        guard !isConfigured else { return }
        isConfigured = true

        if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            modernCenter = center
        } else {
            configureLegacySwiftRunFallback()
        }
    }

    func notify(pr: ReadyPR) {
        if !isConfigured {
            configure()
        }

        if let modernCenter {
            let content = UNMutableNotificationContent()
            content.title = "PR Ready for Review"
            content.subtitle = pr.repoName
            content.body = "\(pr.title)\n\(pr.reviewRequestReason)"
            content.sound = .default
            content.userInfo = ["url": pr.url]

            let request = UNNotificationRequest(
                identifier: "ready-pr-\(pr.id)",
                content: content,
                trigger: nil
            )
            modernCenter.add(request)
        } else {
            notifyUsingLegacySwiftRunFallback(pr: pr)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let urlString = response.notification.request.content.userInfo["url"] as? String {
            open(urlString: urlString)
        }
        completionHandler()
    }

    private func open(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func configureLegacySwiftRunFallback() {
        guard let centerClass = NSClassFromString("NSUserNotificationCenter"),
              let center = (centerClass as AnyObject)
                .perform(NSSelectorFromString("defaultUserNotificationCenter"))?
                .takeUnretainedValue() as? NSObject else {
            return
        }

        center.setValue(self, forKey: "delegate")
        legacyCenter = center
    }

    private func notifyUsingLegacySwiftRunFallback(pr: ReadyPR) {
        guard let legacyCenter,
              let notificationClass = NSClassFromString("NSUserNotification") as? NSObject.Type else {
            return
        }

        let notification = notificationClass.init()
        notification.setValue("ready-pr-\(pr.id)", forKey: "identifier")
        notification.setValue("PR Ready for Review", forKey: "title")
        notification.setValue(pr.repoName, forKey: "subtitle")
        notification.setValue("\(pr.title)\n\(pr.reviewRequestReason)", forKey: "informativeText")
        notification.setValue(["url": pr.url], forKey: "userInfo")

        legacyCenter.perform(NSSelectorFromString("deliverNotification:"), with: notification)
    }

    @objc(userNotificationCenter:shouldPresentNotification:)
    func legacyUserNotificationCenter(_ center: Any, shouldPresent notification: Any) -> Bool {
        true
    }

    @objc(userNotificationCenter:didActivateNotification:)
    func legacyUserNotificationCenter(_ center: Any, didActivate notification: Any) {
        guard let notification = notification as? NSObject,
              let userInfo = notification.value(forKey: "userInfo") as? [String: Any],
              let urlString = userInfo["url"] as? String else {
            return
        }

        open(urlString: urlString)
    }
}
