//
//  RSIShareViewController.swift
//  receive_sharing_intent
//
//  Created by Kasem Mohamed on 2024-01-25.
//

import UIKit
import MobileCoreServices
import Photos

// NOTE: This controller used to subclass `SLComposeServiceViewController` from
// the (now deprecated) Social framework. Apple's modern Share Extension is just
// a plain `UIViewController`. To keep the same features that the old compose
// sheet offered, this class hosts a `RSIComposeView` (Cancel / Send buttons, an
// editable message field with placeholder, and a
// media preview). The UI is only shown when `shouldAutoRedirect()` returns
// `false`; otherwise the shared content is processed and we redirect straight
// into the host app with no UI at all.
@available(swift, introduced: 5.0)
open class RSIShareViewController: UIViewController, RSIComposeViewDelegate {
    var hostAppBundleIdentifier = ""
    var appGroupId = ""
    var sharedMedia: [SharedMediaFile] = []

    // MARK: - Public, overridable compose UI API

    /// Override this method to return false if you don't want to redirect to host app automatically
    /// Default is true
    open func shouldAutoRedirect() -> Bool {
        return true
    }

    /// Placeholder shown in the message field while it is empty.
    open var placeholder: String { return "Add a message…" }

    /// Title of the confirm button (top right).
    open var sendButtonTitle: String { return "Send" }

    /// Height of the compact bottom sheet (iOS 16+). Lower values bring the sheet
    /// closer to the bottom of the screen. Override to customise.
    open var preferredSheetHeight: CGFloat { return 200 }

    /// The text the user typed in the message field.
    open var contentText: String { return composeView?.text ?? "" }

    /// Override to enable/disable the Send button based on your own validation.
    /// Default is always valid.
    open func isContentValid() -> Bool { return true }

    /// Called when the user taps Send. Default saves the message and redirects.
    open func didSelectPost() {
        saveAndRedirect(message: contentText)
    }

    /// Called when the user taps Cancel. Default cancels the extension request.
    open func didSelectCancel() {
        cancel()
    }

    // MARK: - Built-in compose UI

    /// The built-in compose UI, present only when `shouldAutoRedirect()` is false.
    private var composeView: RSIComposeView?

    /// Preview to display in the compose UI (first media item), applied on the
    /// main thread once loading finishes.
    private var pendingPreviewImage: UIImage?

    // MARK: - Lifecycle

    open override func viewDidLoad() {
        super.viewDidLoad()

        // load group and app id from build info
        loadIds()

        if !shouldAutoRedirect() {
            setupComposeUI()
        }
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if shouldAutoRedirect() {
            view.backgroundColor = .clear
            // The share extension is presented inside a system sheet container whose
            // background is opaque. Clear the ancestor backgrounds so only our own
            // dim layer + bottom card are visible (and the host shows through).
            var ancestor = view.superview
            while let current = ancestor {
                current.backgroundColor = .clear
                current.isOpaque = false
                ancestor = current.superview
            }
        }
    }

    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // Focus the message field so the keyboard comes up as the sheet opens.
        if !shouldAutoRedirect() {
            composeView?.focusTextView()
        }

        // Process the shared content from the NSExtensionContext attachments.
        // FamChat: every attachment enters the group once and leaves exactly once (whatever it
        // turns out to be, or when it fails), and the share completes when all have.
        let group = DispatchGroup()
        if let content = extensionContext!.inputItems.first as? NSExtensionItem, let contents = content.attachments {
            for (index, attachment) in contents.enumerated() {
                group.enter()
                guard let type = SharedMediaType.allCases.first(where: { attachment.hasItemConformingToTypeIdentifier($0.toUTTypeIdentifier) }) else {
                    // Any other file (a PDF, a document from Files) goes as a file.
                    guard attachment.hasItemConformingToTypeIdentifier("public.data") else {
                        group.leave()
                        continue
                    }
                    attachment.loadItem(forTypeIdentifier: "public.data") { [weak self] data, error in
                        defer { group.leave() }
                        guard let this = self, error == nil else { return }
                        if let url = data as? URL, url.isFileURL {
                            this.handleMedia(forFile: url, type: .file, index: index)
                        } else if let bytes = data as? Data {
                            this.handleMedia(forData: bytes, name: attachment.suggestedName, type: .file, index: index)
                        }
                    }
                    continue
                }
                attachment.loadItem(forTypeIdentifier: type.toUTTypeIdentifier) { [weak self] data, error in
                    defer { group.leave() }
                    guard let this = self, error == nil else { return }
                    switch type {
                    case .text:
                        if let text = data as? String {
                            this.handleMedia(forLiteral: text, type: type, index: index)
                        } else if let url = data as? URL, url.isFileURL {
                            // A text file (.txt, .csv) goes as a file.
                            this.handleMedia(forFile: url, type: .file, index: index)
                        }
                    case .url:
                        if let url = data as? URL {
                            this.handleMedia(forLiteral: url.absoluteString, type: type, index: index)
                        } else if let text = data as? String {
                            this.handleMedia(forLiteral: text, type: type, index: index)
                        }
                    default:
                        if let url = data as? URL {
                            this.handleMedia(forFile: url, type: type, index: index)
                        } else if let image = data as? UIImage {
                            this.handleMedia(forUIImage: image, type: type, index: index)
                        } else if let bytes = data as? Data {
                            this.handleMedia(forData: bytes, name: attachment.suggestedName, type: type, index: index)
                        }
                    }
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.allAttachmentsLoaded()
        }
    }
    
    private func loadIds() {
        // loading Share extension App Id
        let shareExtensionAppBundleIdentifier = Bundle.main.bundleIdentifier!
        
        
        // extract host app bundle id from ShareExtension id
        // by default it's <hostAppBundleIdentifier>.<ShareExtension>
        // for example: "com.kasem.sharing.Share-Extension" -> com.kasem.sharing
        let lastIndexOfPoint = shareExtensionAppBundleIdentifier.lastIndex(of: ".")
        hostAppBundleIdentifier = String(shareExtensionAppBundleIdentifier[..<lastIndexOfPoint!])
        let defaultAppGroupId = "group.\(hostAppBundleIdentifier)"
        
        
        // loading custom AppGroupId from Build Settings or use group.<hostAppBundleIdentifier>
        let customAppGroupId = Bundle.main.object(forInfoDictionaryKey: kAppGroupIdKey) as? String
        
        appGroupId = customAppGroupId ?? defaultAppGroupId
    }
    
    
    /// FamChat: what each attachment gave, by its index; appended from the item providers' threads,
    /// so only on [mediaQueue].
    private let mediaQueue = DispatchQueue(label: "dev.famchat.share.media")
    private var loaded: [(Int, SharedMediaFile)] = []

    private func record(_ file: SharedMediaFile, at index: Int, preview: UIImage? = nil) {
        mediaQueue.sync {
            loaded.append((index, file))
            if pendingPreviewImage == nil, let preview = preview { pendingPreviewImage = preview }
        }
    }

    private func handleMedia(forLiteral item: String, type: SharedMediaType, index: Int) {
        record(SharedMediaFile(
            path: item,
            mimeType: type == .text ? "text/plain": nil,
            type: type
        ), at: index)
    }

    private func handleMedia(forUIImage image: UIImage, type: SharedMediaType, index: Int) {
        // FamChat: a fresh name each, so several images don't overwrite one another.
        let tempPath = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)!.appendingPathComponent("\(UUID().uuidString).png")
        if self.writeTempFile(image, to: tempPath) {
            let newPathDecoded = tempPath.absoluteString.removingPercentEncoding!
            record(SharedMediaFile(
                path: newPathDecoded,
                mimeType: type == .image ? "image/png": nil,
                type: type
            ), at: index, preview: image)
        }
    }

    /// FamChat: an item handed over as bytes, written to a temporary file in the App Group (in a
    /// folder of its own, under its suggested name).
    private func handleMedia(forData bytes: Data, name: String?, type: SharedMediaType, index: Int) {
        let suggested = (name ?? "").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let fileName = suggested.isEmpty || suggested.allSatisfy({ $0 == "." }) ? UUID().uuidString : suggested
        let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)!.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let newPath = folder.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bytes.write(to: newPath)
            record(SharedMediaFile(
                path: newPath.absoluteString.removingPercentEncoding!,
                mimeType: newPath.mimeType(),
                type: type
            ), at: index, preview: type == .image ? UIImage(data: bytes) : nil)
        } catch {
            print("Cannot write shared data: \(error)")
        }
    }

    private func handleMedia(forFile url: URL, type: SharedMediaType, index: Int) {
        // FamChat: files from other apps' storage (Files, iCloud Drive) may need their scope opened.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fileName = getFileName(from: url, type: type)
        let newPath = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)!.appendingPathComponent(fileName)
        
        if copyFile(at: url, to: newPath) {
            // The path should be decoded because Flutter is not expecting url encoded file names
            let newPathDecoded = newPath.absoluteString.removingPercentEncoding!;
            if type == .video {
                // Get video thumbnail and duration
                if let videoInfo = getVideoInfo(from: url) {
                    let thumbnailPathDecoded = videoInfo.thumbnail?.removingPercentEncoding;
                    var thumbImage: UIImage? = nil
                    if let thumb = videoInfo.thumbnail, let thumbURL = URL(string: thumb) {
                        thumbImage = UIImage(contentsOfFile: thumbURL.path)
                    }
                    record(SharedMediaFile(
                        path: newPathDecoded,
                        mimeType: url.mimeType(),
                        thumbnail: thumbnailPathDecoded,
                        duration: videoInfo.duration,
                        type: type
                    ), at: index, preview: thumbImage)
                }
            } else {
                record(SharedMediaFile(
                    path: newPathDecoded,
                    mimeType: url.mimeType(),
                    type: type
                ), at: index, preview: type == .image ? UIImage(contentsOfFile: newPath.path) : nil)
            }
        }
    }

    /// FamChat: called once, on the main queue, after every attachment finished loading (or
    /// failed). Then we either redirect automatically or hand control to the compose UI.
    private func allAttachmentsLoaded() {
        sharedMedia = mediaQueue.sync { loaded.sorted { $0.0 < $1.0 }.map { $0.1 } }
        if shouldAutoRedirect() {
            saveAndRedirect()
        } else {
            didFinishLoadingContent()
        }
    }
    
    
    // MARK: - Built-in compose UI

    private func setupComposeUI() {
        let configuration = RSIComposeView.Configuration(
            placeholder: placeholder,
            sendButtonTitle: sendButtonTitle,
        )
        let composeView = RSIComposeView(configuration: configuration)
        composeView.delegate = self
        composeView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composeView)
        NSLayoutConstraint.activate([
            composeView.topAnchor.constraint(equalTo: view.topAnchor),
            composeView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            composeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        self.composeView = composeView
        updateSendEnabled()
    }

    /// Called on the main thread once all shared content finished loading.
    private func didFinishLoadingContent() {
        guard !shouldAutoRedirect() else { return }
        composeView?.setPreviewImage(pendingPreviewImage)
        updateSendEnabled()
    }

    private func updateSendEnabled() {
        guard let composeView = composeView else { return }
        composeView.setSendEnabled(isContentValid())
    }

    /// Cancels the share extension request.
    open func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "RSIShareViewController", code: 0, userInfo: [NSLocalizedDescriptionKey: "User cancelled"]))
    }

    // MARK: - RSIComposeViewDelegate

    open func composeViewDidSelectPost(_ composeView: RSIComposeView) {
        didSelectPost()
    }

    open func composeViewDidSelectCancel(_ composeView: RSIComposeView) {
        didSelectCancel()
    }

    open func composeViewDidChangeText(_ composeView: RSIComposeView) {
        updateSendEnabled()
    }

    // Save shared media and redirect to host app
    open func saveAndRedirect(message: String? = nil) {
        let userDefaults = UserDefaults(suiteName: appGroupId)
        userDefaults?.set(toData(data: sharedMedia), forKey: kUserDefaultsKey)
        userDefaults?.set(message, forKey: kUserDefaultsMessageKey)
        userDefaults?.synchronize()
        redirectToHostApp()
    }
    
    private func redirectToHostApp() {
        // ids may not loaded yet so we need loadIds here too
        loadIds()
        let url = URL(string: "\(kSchemePrefix)-\(hostAppBundleIdentifier):share")
        var responder = self as UIResponder?
        
        if #available(iOS 18.0, *) {
            // FamChat: UIApplication.open is unavailable to app extensions at compile time
            // (APPLICATION_EXTENSION_API_ONLY), so it's called through the runtime.
            let selector = NSSelectorFromString("openURL:options:completionHandler:")
            typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
            while responder != nil {
                if let application = responder as? UIApplication, application.responds(to: selector), let url = url {
                    let open = unsafeBitCast(application.method(for: selector), to: OpenURL.self)
                    open(application, selector, url as NSURL, NSDictionary(), nil)
                }
                responder = responder?.next
            }
        } else {
            let selectorOpenURL = sel_registerName("openURL:")
            
            while (responder != nil) {
                if (responder?.responds(to: selectorOpenURL))! {
                    _ = responder?.perform(selectorOpenURL, with: url)
                }
                responder = responder!.next
            }
        }

        extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
    }
    
    private func dismissWithError() {
        print("[ERROR] Error loading data!")
        let alert = UIAlertController(title: "Error", message: "Error loading data", preferredStyle: .alert)
        
        let action = UIAlertAction(title: "Error", style: .cancel) { _ in
            self.dismiss(animated: true, completion: nil)
        }
        
        alert.addAction(action)
        present(alert, animated: true, completion: nil)
        extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
    }
    
    private func getFileName(from url: URL, type: SharedMediaType) -> String {
        var name = url.lastPathComponent
        if name.isEmpty {
            switch type {
            case .image:
                name = UUID().uuidString + ".png"
            case .video:
                name = UUID().uuidString + ".mp4"
            case .text:
                name = UUID().uuidString + ".txt"
            default:
                name = UUID().uuidString
            }
        }
        return name
    }

    private func writeTempFile(_ image: UIImage, to dstURL: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: dstURL.path) {
                try FileManager.default.removeItem(at: dstURL)
            }
            let pngData = image.pngData();
            try pngData?.write(to: dstURL);
            return true;
        } catch (let error){
            print("Cannot write to temp file: \(error)");
            return false;
        }
    }
    
    private func copyFile(at srcURL: URL, to dstURL: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: dstURL.path) {
                try FileManager.default.removeItem(at: dstURL)
            }
            try FileManager.default.copyItem(at: srcURL, to: dstURL)
        } catch (let error) {
            print("Cannot copy item at \(srcURL) to \(dstURL): \(error)")
            return false
        }
        return true
    }
    
    private func getVideoInfo(from url: URL) -> (thumbnail: String?, duration: Double)? {
        let asset = AVAsset(url: url)
        let duration = (CMTimeGetSeconds(asset.duration) * 1000).rounded()
        let thumbnailPath = getThumbnailPath(for: url)
        
        if FileManager.default.fileExists(atPath: thumbnailPath.path) {
            return (thumbnail: thumbnailPath.absoluteString, duration: duration)
        }
        
        var saved = false
        let assetImgGenerate = AVAssetImageGenerator(asset: asset)
        assetImgGenerate.appliesPreferredTrackTransform = true
        //        let scale = UIScreen.main.scale
        assetImgGenerate.maximumSize =  CGSize(width: 360, height: 360)
        do {
            let img = try assetImgGenerate.copyCGImage(at: CMTimeMakeWithSeconds(600, preferredTimescale: 1), actualTime: nil)
            try UIImage(cgImage: img).pngData()?.write(to: thumbnailPath)
            saved = true
        } catch {
            saved = false
        }
        
        return saved ? (thumbnail: thumbnailPath.absoluteString, duration: duration): nil
    }
    
    private func getThumbnailPath(for url: URL) -> URL {
        let fileName = Data(url.lastPathComponent.utf8).base64EncodedString().replacingOccurrences(of: "==", with: "")
        let path = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)!
            .appendingPathComponent("\(fileName).jpg")
        return path
    }
    
    private func toData(data: [SharedMediaFile]) -> Data {
        let encodedData = try? JSONEncoder().encode(data)
        return encodedData!
    }
}

extension URL {
    public func mimeType() -> String {
        if #available(iOS 14.0, *) {
            if let mimeType = UTType(filenameExtension: self.pathExtension)?.preferredMIMEType {
                return mimeType
            }
        } else {
            if let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, self.pathExtension as NSString, nil)?.takeRetainedValue() {
                if let mimetype = UTTypeCopyPreferredTagWithClass(uti, kUTTagClassMIMEType)?.takeRetainedValue() {
                    return mimetype as String
                }
            }
        }
        
        return "application/octet-stream"
    }
}
