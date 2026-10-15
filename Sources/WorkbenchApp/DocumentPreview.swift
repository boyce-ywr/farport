import WorkbenchCore
import AppKit
import SwiftUI
import PDFKit
import WebKit

struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument
    let view: PDFView
    func makeNSView(context: Context) -> PDFView {
        view.autoScales = true; view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical; view.document = document
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) { if view.document !== document { view.document = document; view.autoScales = true } }
}

struct PDFDocumentPreview: View {
    let document: PDFDocument
    @ViewState private var pdfView = PDFView()
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { pdfView.goToPreviousPage(nil) } label: { Image(systemName: "chevron.up") }.help(L10n.text("上一页"))
                Button { pdfView.goToNextPage(nil) } label: { Image(systemName: "chevron.down") }.help(L10n.text("下一页"))
                Text(L10n.text("\(document.pageCount) 页")).foregroundStyle(.secondary)
                Spacer()
                Button { pdfView.zoomOut(nil) } label: { Image(systemName: "minus.magnifyingglass") }.help(L10n.text("缩小"))
                Button { pdfView.zoomIn(nil) } label: { Image(systemName: "plus.magnifyingglass") }.help(L10n.text("放大"))
                Button(L10n.text("适合宽度")) { pdfView.autoScales = true }
            }.font(.caption).buttonStyle(.borderless).padding(10)
            PDFPreview(document: document, view: pdfView)
        }
    }
}

struct HTMLPreview: NSViewRepresentable {
    let url: URL
    let allowsScripts: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsScripts
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsMagnification = true
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url; view.load(URLRequest(url: url))
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: URL?
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = navigationAction.request.url, let loaded,
                  target.scheme == "http", target.host == "127.0.0.1", target.port == loaded.port,
                  target.pathComponents.dropFirst().first == loaded.pathComponents.dropFirst().first else { decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
    }
}
