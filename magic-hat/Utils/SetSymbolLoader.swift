//
//  SetSymbolLoader.swift
//  magic-hat
//
//  Scryfall set symbols are SVG-only, and SwiftUI can't decode a remote SVG,
//  so they are rasterized through WebKit. Three things make that cheap:
//
//   * ONE persistent WKWebView, fed by a serial queue. The previous version
//     created a web view per symbol; a detail screen listing 25 sets spun up
//     25 web views on the main thread during the push, which was the jank.
//   * Two-level disk cache under Caches/SetSymbols: the SVG bytes (so a set
//     is fetched from Scryfall exactly once) and the rasterized PNG per size
//     and scale (so after the first render a symbol never touches WebKit
//     again, across launches).
//   * Negative caching, so a failing set doesn't retry on every appearance.
//
//  Rendered white on transparent and shown as a `.template` image, so it
//  tints with `.primary` and adapts to light/dark.
//

import SwiftUI
import WebKit

@MainActor
final class SetSymbolLoader {
    static let shared = SetSymbolLoader()

    private var memory: [String: UIImage] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var failed: Set<String> = []
    private var svgURLByCode: [String: String] = [:]

    private let fm = FileManager.default
    private let directory: URL
    private let rasterizer = SVGRasterizer()

    private init() {
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("SetSymbols", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// A tintable raster of the set symbol at `size` points. Nil on failure.
    func symbol(setCode: String, size: CGFloat) async -> UIImage? {
        let code = setCode.lowercased()
        let scale = rasterizer.scale
        let key = "\(code)@\(Int(size))@\(Int(scale))"

        if let cached = memory[key] { return cached }
        if failed.contains(key) { return nil }
        if let existing = inFlight[key] { return await existing.value }

        let pngURL = directory.appendingPathComponent("\(key).png")
        let task = Task { () -> UIImage? in
            // 1. Rasterized before (any launch).
            if let data = try? Data(contentsOf: pngURL), let image = UIImage(data: data, scale: scale) {
                return image
            }
            // 2. SVG bytes, from disk or Scryfall.
            guard let svg = await svgData(for: code) else { return nil }
            // 3. Rasterize on the shared web view, one at a time.
            guard let image = await rasterizer.rasterize(svg: svg, size: size) else { return nil }
            if let data = image.pngData() { try? data.write(to: pngURL, options: .atomic) }
            return image
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result { memory[key] = result } else { failed.insert(key) }
        return result
    }

    private func svgData(for code: String) async -> Data? {
        let svgURL = directory.appendingPathComponent("\(code).svg")
        if let data = try? Data(contentsOf: svgURL), !data.isEmpty { return data }

        let uriString: String
        if let known = svgURLByCode[code] {
            uriString = known
        } else if let set = try? await ScryfallClient.shared.set(code: code), let uri = set.iconSVGURI {
            svgURLByCode[code] = uri
            uriString = uri
        } else {
            return nil
        }
        guard let url = URL(string: uriString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("MagicHat/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("image/svg+xml,*/*", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request), !data.isEmpty else { return nil }
        try? data.write(to: svgURL, options: .atomic)
        return data
    }
}

/// One WKWebView, one job at a time. WebKit only paints a web view that is
/// in a window, and `takeSnapshot` captures at the view's own alpha, so the
/// host is a real window layered *behind* the app at full alpha.
@MainActor
private final class SVGRasterizer: NSObject, WKNavigationDelegate {
    private struct Job {
        let svg: Data
        let size: CGFloat
        let resume: (UIImage?) -> Void
    }

    private var host: UIWindow?
    private var webView: WKWebView?
    private var queue: [Job] = []
    private var current: Job?

    var scale: CGFloat { host?.screen.scale ?? UITraitCollection.current.displayScale }

    func rasterize(svg: Data, size: CGFloat) async -> UIImage? {
        await withCheckedContinuation { continuation in
            queue.append(Job(svg: svg, size: size) { continuation.resume(returning: $0) })
            pump()
        }
    }

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        current = job
        guard let webView = ensureWebView() else { finish(nil); return }

        let px = Int(job.size)
        webView.frame = CGRect(x: 0, y: 0, width: job.size, height: job.size)
        let svg = String(data: job.svg, encoding: .utf8) ?? ""
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=\(px)">
        <style>html,body{margin:0;padding:0;background:transparent}
        svg,svg *{fill:#ffffff !important}
        svg{width:\(px)px;height:\(px)px}</style></head>
        <body>\(svg)</body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func ensureWebView() -> WKWebView? {
        if let webView { return webView }
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
        host = window

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.navigationDelegate = self
        window.addSubview(view)
        webView = view
        return view
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Let layout + paint settle before snapshotting the SVG.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, let job = self.current else { return }
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: job.size, height: job.size)
            config.afterScreenUpdates = true
            webView.takeSnapshot(with: config) { image, _ in
                Task { @MainActor in self.finish(image) }
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
        let job = current
        current = nil
        job?.resume(image)
        pump()
    }
}

/// SwiftUI view that shows a set symbol, tinted. Keyrune glyph when the font
/// has the set (instant, offline); otherwise the WebKit-rasterized SVG;
/// otherwise a system glyph.
struct SetSymbolView: View {
    let setCode: String
    var size: CGFloat = 22
    var tint: Color = .secondary

    @State private var image: UIImage?

    var body: some View {
        if let glyph = KeyruneFont.glyph(for: setCode), let font = KeyruneFont.fontName {
            Text(glyph)
                .font(.custom(font, size: size * 0.92))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .accessibilityLabel(setCode.uppercased())
        } else {
            rasterized
        }
    }

    private var rasterized: some View {
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
