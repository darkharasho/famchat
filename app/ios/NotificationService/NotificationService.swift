// Replaces the generic alert body with the decrypted message preview.
// PreviewCore's sources are compiled into this target, so there is no import.
import Foundation
import UserNotifications

class NotificationService: UNNotificationServiceExtension {
    private var delivery: PreviewDelivery?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let original = request.content
        let delivery = PreviewDelivery { body in
            guard let body,
                  let content = original.mutableCopy() as? UNMutableNotificationContent
            else {
                contentHandler(original)
                return
            }
            content.body = body
            contentHandler(content)
        }
        self.delivery = delivery
        let userInfo = original.userInfo
        DispatchQueue.global(qos: .userInitiated).async {
            delivery.finish(Preview.notificationBody(userInfo: userInfo, keyring: KeychainKeyring.load()))
        }
    }

    override func serviceExtensionTimeWillExpire() {
        delivery?.expire()
    }
}
