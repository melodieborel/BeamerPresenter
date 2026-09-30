import SwiftUI
import PDFKit
import WebKit

/// Overlays a live web page (`\webmark{file}` + the `\href{https://...}` after
/// it, see MediaMarks.swift) on its screenshot placeholder -- e.g. Pinpoint
/// running in place on the "Chronic implant" frame.
///
/// Unlike movies and 3D objects, a web page can't be mirrored: a `WKWebView`
/// lives in one view at a time and a second instance would be a separate,
/// unsynced session. So the one live page is only shown by the audience
/// window's `SlideView` (`liveWeb: true`) and is driven with the mouse there;
/// the presenter's panes keep showing the PDF's own screenshot. `F` toggles
/// between the placeholder's rect and the whole slide.
struct WebOverlay: View {
    @EnvironmentObject var state: PresentationState
    let pageIndex: Int
    let marks: [WebMark]
    let deckFolder: URL

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(placed.enumerated()), id: \.offset) { _, item in
                let rect = state.webExpanded ? CGRect(x: 0, y: 0, width: 1, height: 1) : item.rect
                WebViewHost(webView: state.webPage(for: item.mark, deckFolder: deckFolder).webView)
                    .frame(width: geo.size.width * rect.width, height: geo.size.height * rect.height)
                    .position(x: geo.size.width * rect.midX, y: geo.size.height * rect.midY)
            }
        }
    }

    private var placed: [(mark: WebMark, rect: CGRect)] {
        guard let page = state.slideDoc?.page(at: pageIndex) else { return [] }
        let links = linkAnnotations(on: page)
        return marks.compactMap { mark in
            guard let link = placeholderLink(in: links, mark.matches),
                  let rect = unitRect(of: link, on: page) else { return nil }
            return (mark, rect)
        }
    }
}

/// One live page for a `WebMark`, created when the deck loads (so a slow app
/// like Pinpoint has finished loading by the time its slide comes up) and kept
/// for the whole talk, so coming back to the slide doesn't reload it. Uses the
/// persistent default data store, like Mentimeter: whatever the page saves in
/// the browser (Pinpoint's imported experiments, preferences) survives
/// relaunches. Answers the page's file pickers with the mark's file.
final class WebPage: NSObject, WKUIDelegate {
    let webView: WKWebView
    private let fileURL: URL?

    init(url: URL, fileURL: URL?) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        self.fileURL = fileURL
        super.init()
        webView.uiDelegate = self
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        if let fileURL {
            completionHandler([fileURL])
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
    }
}

/// Hosts a shared `WKWebView` in a container, so the web view itself is never
/// owned by one SwiftUI view: re-rendering the slide re-parents it instead of
/// rebuilding it. Scales the page down with the container (`pageZoom`) so an
/// app's full UI still fits a placeholder a third of the slide wide.
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> Container { Container() }

    func updateNSView(_ container: Container, context: Context) {
        container.host(webView)
    }

    final class Container: NSView {
        /// Width (in points) the page is laid out at 100 % zoom.
        private let designWidth: CGFloat = 1280

        func host(_ webView: WKWebView) {
            if webView.superview !== self {
                webView.removeFromSuperview()
                webView.frame = bounds
                webView.autoresizingMask = [.width, .height]
                addSubview(webView)
            }
            needsLayout = true
        }

        override func layout() {
            super.layout()
            guard let webView = subviews.first as? WKWebView, bounds.width > 0 else { return }
            webView.pageZoom = min(1, max(0.35, bounds.width / designWidth))
        }
    }
}

extension NSView {
    /// Whether this view is a `WKWebView` or sits inside one (the page's own
    /// focused element is an internal subview).
    var isInsideWebView: Bool {
        var view: NSView? = self
        while let v = view {
            if v is WKWebView { return true }
            view = v.superview
        }
        return false
    }
}
