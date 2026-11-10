import SwiftUI
import WebKit
import PostvakCore

/// Renders a mail body with scripts off, every remote load blocked until asked for, links opening in the browser,
/// and no navigation away from the mail itself.
struct MessageBodyView: View {
    let message: MailMessage
    let inlineImages: [String: Data]
    /// A mailto: link in the body opens a new mail in Postvak.
    var onMailto: ((String, String) -> Void)?
    @State private var height: CGFloat = 60
    @State private var showRemote = false

    private var hasRemote: Bool {
        (message.bodyHtml ?? "").range(of: #"((src|background|href)\s*=\s*["']?|url\s*\(\s*["']?)https?:"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasRemote && !showRemote {
                HStack(spacing: 6) {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                    Text("Remote images are blocked, because they can tell the sender you opened this.").font(.caption).foregroundStyle(.secondary)
                    Button("Show") { showRemote = true }.buttonStyle(.link).font(.caption)
                }
            }
            MailWebView(html: renderedHTML, allowRemote: showRemote, height: $height, onMailto: onMailto)
                .frame(height: height)
                .background(isHTML ? Color.white : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var isHTML: Bool { message.bodyHtml != nil }

    /// HTML mail is designed for a white page and often hard-codes dark text, so it always gets one.
    /// Plain text follows the system appearance.
    private var renderedHTML: String {
        var body = message.bodyHtml ?? "<div style=\"white-space:pre-wrap\">\(MIMEBuilder.textToHTML(message.bodyText))</div>"
        for (cid, data) in inlineImages {
            body = body.replacingOccurrences(of: "cid:\(cid)", with: "data:image/*;base64,\(data.base64EncodedString())")
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="\(isHTML ? "light" : "light dark")">
        <style>
        html,body{margin:0;padding:\(isHTML ? "4px 8px" : "0");font:14px -apple-system,system-ui;line-height:1.45;word-wrap:break-word;overflow-wrap:anywhere;\(isHTML ? "background:#fff;color:#111" : "")}
        img{max-width:100%;height:auto} table{max-width:100%} blockquote{margin-left:.8ex;padding-left:1ex;border-left:2px solid #8884}
        a{color:#2563eb}
        </style></head><body>\(body)</body></html>
        """
    }
}

struct MailWebView: NSViewRepresentable {
    let html: String
    let allowRemote: Bool
    @Binding var height: CGFloat
    var onMailto: ((String, String) -> Void)?

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MailWebView
        var lastHTML: String?
        var lastRemote: Bool?
        init(_ p: MailWebView) { parent = p }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                if let m = MailtoLink.parse(url), let open = parent.onMailto {
                    await MainActor.run { open(m.to, m.subject) }
                } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                return .cancel
            }
            // Only the HTML Postvak loaded itself renders here. A meta refresh, a form post or an iframe pointing at the
            // web would otherwise show a remote page inside the mail, and tell the sender it was opened.
            if action.targetFrame?.isMainFrame == true, Self.isOwnDocument(action.request.url) { return .allow }
            return .cancel
        }

        static func isOwnDocument(_ url: URL?) -> Bool {
            guard let url else { return true }
            return url.scheme?.lowercased() == "about"
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] value, _ in
                if let h = value as? CGFloat { DispatchQueue.main.async { self?.parent.height = max(24, h + 4) } }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = NoScrollWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.lastHTML != html || context.coordinator.lastRemote != allowRemote else { return }
        context.coordinator.lastHTML = html
        context.coordinator.lastRemote = allowRemote
        let list = allowRemote ? nil : MailContentRules.shared
        Task { @MainActor in
            view.configuration.userContentController.removeAllContentRuleLists()
            if let rules = await list?.compiled() { view.configuration.userContentController.add(rules) }
            view.loadHTMLString(html, baseURL: nil)
        }
    }
}

/// Passes scrolling to the conversation around it.
final class NoScrollWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

@MainActor
final class MailContentRules {
    static let shared = MailContentRules()
    private var cached: WKContentRuleList?

    func compiled() async -> WKContentRuleList? {
        if let cached { return cached }
        // Every kind of remote load, including frames and link pings: nothing reaches the web until the user asks.
        let json = #"[{"trigger":{"url-filter":"^https?://.*","resource-type":["document","image","style-sheet","script","font","media","raw","fetch","ping","popup","websocket","other","svg-document"]},"action":{"type":"block"}}]"#
        let list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "postvak.blockRemote", encodedContentRuleList: json)
        cached = list ?? nil
        return cached
    }
}
