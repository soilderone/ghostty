import AppKit
import SwiftUI
import WebKit

/// What the preview page renders.
struct FilePreviewDocument: Equatable {
    enum Kind: String {
        case markdown
        case code
        case text

        /// Delimited text (CSV, TSV) shown as a table.
        case table
    }

    let kind: Kind
    let text: String

    /// The highlight.js language, when known.
    let language: String?

    /// What separates the cells of a table.
    var delimiter: String = ","

    /// The file's folder, so relative links and images resolve.
    let base: URL
}

/// Renders markdown, code and text in the bundled preview page (`macos/Preview`) with marked,
/// highlight.js and mermaid.
///
/// Previewed files never run scripts: raw HTML in markdown is shown as text, the page's
/// content security policy blocks inline scripts and the network, and link clicks open outside
/// the page.
struct FilePreviewWebView: NSViewRepresentable {
    let document: FilePreviewDocument
    let allowLocalFiles: Bool

    /// Called for links to local files.
    let onOpenFile: (URL) -> Void

    init(
        document: FilePreviewDocument,
        allowLocalFiles: Bool = true,
        onOpenFile: @escaping (URL) -> Void
    ) {
        self.document = document
        self.allowLocalFiles = allowLocalFiles
        self.onOpenFile = onOpenFile
    }

    @Environment(\.colorScheme) private var colorScheme

    /// The preview page in the app bundle.
    static let pageURL: URL? = {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("ghostty/preview/preview.html")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }()

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenFile: onOpenFile)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView

        if let page = Self.pageURL {
            // Local previews can load images next to the file. Remote previews must not read
            // arbitrary local files referenced by remote Markdown.
            let readAccess = allowLocalFiles ? URL(fileURLWithPath: "/") : page.deletingLastPathComponent()
            webView.loadFileURL(page, allowingReadAccessTo: readAccess)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOpenFile = onOpenFile
        context.coordinator.show(document, dark: colorScheme == .dark)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var onOpenFile: (URL) -> Void

        private var isLoaded = false
        private var pending: (document: FilePreviewDocument, dark: Bool)?
        private var shown: (document: FilePreviewDocument, dark: Bool)?

        init(onOpenFile: @escaping (URL) -> Void) {
            self.onOpenFile = onOpenFile
        }

        func show(_ document: FilePreviewDocument, dark: Bool) {
            if let shown, shown.document == document, shown.dark == dark { return }
            pending = (document, dark)
            renderPending()
        }

        private func renderPending() {
            guard isLoaded, let webView, let pending else { return }
            self.pending = nil
            shown = pending

            let payload: [String: Any] = [
                "kind": pending.document.kind.rawValue,
                "text": pending.document.text,
                "language": pending.document.language ?? "",
                "delimiter": pending.document.delimiter,
                "base": pending.document.base.absoluteString,
                "dark": pending.dark,
            ]
            webView.callAsyncJavaScript(
                "window.ghosttyPreview.render(payload)",
                arguments: ["payload": payload],
                in: nil,
                in: .page,
                completionHandler: nil)
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            renderPending()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Only the preview page itself loads here; anchors within it scroll.
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if let current = webView.url, url.absoluteString.hasPrefix(current.absoluteString + "#") || url.fragment != nil && url.path == current.path {
                decisionHandler(.allow)
                return
            }

            decisionHandler(.cancel)
            switch url.scheme?.lowercased() {
            case "http", "https", "mailto":
                NSWorkspace.shared.open(url)
            case "file", "ssh":
                onOpenFile(url)
            default:
                break
            }
        }
    }
}
