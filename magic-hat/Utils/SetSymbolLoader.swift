//
//  SetSymbolLoader.swift
//  magic-hat
//
//  Scryfall set symbols are SVG-only (no raster form), and SwiftUI can't
//  decode a remote SVG. This rasterizes the SVG once via an offscreen
//  WKWebView snapshot, caches the result, and exposes it as a tintable
//  template image. `SetSymbolView` is the drop-in SwiftUI view.
//

import SwiftUI
import WebKit

@MainActor
final class SetSymbolLoader {
    static let shared = SetSymbolLoader()

    private var svgURLByCode: [String: String] = [:]
    private let imageCache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var failed: Set<String> = []

    /// Returns a white, transparent-background raster of the set symbol at
    /// `size` pixels, suitable for use as a `.template` image. Nil on failure.
    func symbol(setCode: String, size: CGFloat) async -> UIImage? {
        let code = setCode.lowercased()
        let key = "\(code)|\(Int(size))"
        if let cached = imageCache.object(forKey: key as NSString) { return cached }
        if failed.contains(key) { return nil }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task { () -> UIImage? in
            let svgURLString: String
            if let known = svgURLByCode[code] {
                svgURLString = known
            } else if let set = try? await ScryfallClient.shared.set(code: code),
                      let uri = set.iconSVGURI {
                svgURLByCode[code] = uri
                svgURLString = uri
            } else {
                return nil
            }

            guard let url = URL(string: svgURLString) else { return nil }
            var request = URLRequest(url: url)
            request.setValue("MagicHat/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("image/svg+xml,*/*", forHTTPHeaderField: "Accept")
            guard let (data, _) = try? await URLSession.shared.data(for: request) else {
                return nil
            }
            let image = await SVGRasterizer.rasterize(svgData: data, size: size)
            if let image { imageCache.setObject(image, forKey: key as NSString) }
            return image
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if result == nil { failed.insert(key) }
        return result
    }
}

/// Renders SVG data to a UIImage via an offscreen WKWebView snapshot.
@MainActor
private final class SVGRasterizer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let size: CGFloat
    private var completion: ((UIImage?) -> Void)?
    private var keepAlive: SVGRasterizer?

    static func rasterize(svgData: Data, size: CGFloat) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let r = SVGRasterizer(size: size)
            r.render(svgData: svgData) { continuation.resume(returning: $0) }
        }
    }

    private init(size: CGFloat) {
        self.size = size
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: size, height: size), configuration: config)
        super.init()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = self
    }

    private func render(svgData: Data, completion: @escaping (UIImage?) -> Void) {
        self.completion = completion
        self.keepAlive = self

        // WebKit only paints a web view that lives in a window, but an
        // alpha-faded view snapshots faded (the old 0.02 alpha is why symbols
        // came out invisible). Render at full alpha into a dedicated window
        // sitting behind the app's own, so nothing is ever visible on screen.
        guard let window = SVGRasterizer.hostWindow else {
            finish(nil)
            return
        }
        webView.frame = CGRect(x: 0, y: 0, width: size, height: size)
        webView.alpha = 1
        window.addSubview(webView)

        let svg = String(data: svgData, encoding: .utf8) ?? ""
        let px = Int(size)
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=\(px)">
        <style>html,body{margin:0;padding:0;background:transparent}
        svg,svg *{fill:#ffffff !important}
        svg{width:\(px)px;height:\(px)px}</style></head>
        <body>\(svg)</body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Let layout + paint settle before snapshotting the SVG.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: self.size, height: self.size)
            config.afterScreenUpdates = true
            self.webView.takeSnapshot(with: config) { image, _ in
                self.finish(image)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    private func finish(_ image: UIImage?) {
        webView.removeFromSuperview()
        completion?(image)
        completion = nil
        keepAlive = nil
    }

    /// Offscreen-by-layering render host: a real window (so WebKit paints)
    /// placed below the app's window, so the user never sees it.
    private static var hostWindow: UIWindow? = {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return nil }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal - 1
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        window.frame = CGRect(x: 0, y: 0, width: 512, height: 512)
        window.isHidden = false
        return window
    }()
}

/// SwiftUI view that shows a set symbol, tinted. Falls back to a system glyph
/// while loading or on failure.
struct SetSymbolView: View {
    let setCode: String
    var size: CGFloat = 22
    var tint: Color = .secondary

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(tint)
            } else {
                Image(systemName: "square.stack.3d.up")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(tint.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .task(id: setCode) {
            image = await SetSymbolLoader.shared.symbol(setCode: setCode, size: size)
        }
    }
}
