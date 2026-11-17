// "FamChat" in the iOS share sheet: hands what was shared to the app (through the App Group) and
// opens it, where the Send to screen picks the chat. No UI of its own.
import receive_sharing_intent

class ShareViewController: RSIShareViewController {
    override func shouldAutoRedirect() -> Bool {
        return true
    }
}
