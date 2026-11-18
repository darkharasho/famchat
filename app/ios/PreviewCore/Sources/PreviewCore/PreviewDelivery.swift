// Hands a notification body to the extension's content handler exactly once.
import Foundation

/// The first `finish` or `expire` delivers; every later call is ignored.
/// `serviceExtensionTimeWillExpire` and a finishing decrypt can race, and
/// iOS needs the content handler called once, with whichever came first.
public final class PreviewDelivery {
    private let lock = NSLock()
    private var deliver: ((String?) -> Void)?

    public init(deliver: @escaping (String?) -> Void) {
        self.deliver = deliver
    }

    /// Delivers `body` (nil means the original content) if nothing has yet.
    public func finish(_ body: String?) {
        lock.lock()
        let pending = deliver
        deliver = nil
        lock.unlock()
        pending?(body)
    }

    /// Out of time: deliver the original content.
    public func expire() {
        finish(nil)
    }
}
