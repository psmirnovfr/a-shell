//
//  BrowserPanel.swift
//  a-Shell — Agentic layer
//
//  The bottom-right pane: a WKWebView with a small URL/address bar used to preview
//  HTML artefacts the agent builds (driven by the `preview_html` tool) or to browse
//  the web.
//

import SwiftUI
import WebKit

/// Owns the preview WKWebView and its address-bar state.
final class BrowserModel: ObservableObject {
    let webView: WKWebView
    @Published var addressText: String = ""
    @Published var canGoBack: Bool = false

    init() {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        if #available(iOS 14.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        // Allow local artefacts to load sibling files (css/js/images).
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        webView = WKWebView(frame: .zero, configuration: config)
        if #available(iOS 16.4, *) { webView.isInspectable = true }
    }

    /// Load a local file (used by the preview_html tool).
    func loadLocal(_ url: URL) {
        addressText = url.lastPathComponent
        // Grant read access to the containing directory so relative assets resolve.
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    /// Load whatever is in the address bar (URL or search-ish string).
    func loadAddress() {
        var text = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if text.hasPrefix("/") || text.hasPrefix("file://") {
            let url = text.hasPrefix("file://") ? URL(string: text)! : URL(fileURLWithPath: text)
            loadLocal(url)
            return
        }
        if !text.contains("://") { text = "https://" + text }
        if let url = URL(string: text) {
            webView.load(URLRequest(url: url))
        }
    }

    func reload() { webView.reload() }
    func goBack() { if webView.canGoBack { webView.goBack() } }
}

/// UIViewRepresentable bridge for the browser's WKWebView.
private struct BrowserWebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserPanel: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: model.goBack) {
                    Image(systemName: "chevron.left")
                }
                Button(action: model.reload) {
                    Image(systemName: "arrow.clockwise")
                }
                TextField("URL or /path/to/file.html", text: $model.addressText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .onSubmit { model.loadAddress() }
            }
            .padding(6)
            .background(.thinMaterial)

            Divider()

            BrowserWebViewRepresentable(webView: model.webView)
        }
    }
}
