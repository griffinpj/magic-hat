//
//  LaunchPrewarm.swift
//  magic-hat
//
//  First-use costs that used to land on the first tap, moved to launch:
//
//  - Fonts. The Mana and Keyrune fonts are registered at runtime, and the
//    first glyph drawn parses the whole file on the main thread —
//    HangDetector caught 0.79s in CreateFontEntitiesForFile the first time
//    a mana pip rendered, and 0.47s more for the variation instances.
//    CoreText is thread-safe, so a background task creates each font and
//    draws one glyph into a scratch bitmap; the parse is cached by then.
//  - The keyboard. UIKit builds its text-input stack on the first
//    becomeFirstResponder (input preferences, the keyboard scene delegate,
//    the input window). An invisible field with an empty inputView takes
//    that hit half a second after the first frame, so the first search tap
//    only has to show the keys.
//  - SF Symbols. The first resolution of a symbol name reads it out of
//    the system catalog (CoreUI's theme store), and on a cold catalog that
//    is a disk-bound lookup: HangDetector caught 0.44s on the first tap of
//    the Search tab (the bar's symbols) and two 0.3s stalls opening a deck
//    (its rows' status icons). UIImage lookups are thread-safe, so every
//    name the app uses is resolved on a background queue, three seconds
//    after launch so the disk is the launch's while it matters.
//
//  What does NOT belong here, learned on a device: loading a framework
//  on a background thread during launch. dlopen holds dyld's loader lock
//  for the whole load, and every framework the main thread then soft-links
//  (the keyboard, haptics, CFNetwork) queues behind it — a background
//  dlopen of ScreenTime plus CFNetwork's first-use setup put the keyboard
//  prewarm's own dlopen at 4.5s on the main thread. Nor a hidden
//  NavigationStack to "warm" the viewer's types: it built a real bar, a
//  toolbar and a haptics engine behind the tabs (9.8s, and Auto Layout
//  complaints about a 106pt bar in a 90pt container). Framework loads
//  happen where they are needed, once, and the shared URLSession is first
//  touched inside `HTTPClient.requestData`, which is `@concurrent`.
//  - The foil shader. The first foil card drawn compiled the Metal
//    pipeline on the main thread — HangDetector caught 0.47s in
//    RenderBox → MTLCompiler under the first push into the real
//    collection. `Shader.compile(as:)` does it at launch, off-main.
//

import UIKit
import CoreText
import SwiftUI
import SwiftData
import os

enum LaunchPrewarm {
    /// Parses the bundled symbol fonts, and their glyph maps, off the
    /// main thread. The maps are JSON read on first use — 0.11s on the
    /// main thread the first time a set symbol was drawn.
    nonisolated static func fonts() {
        Task.detached(priority: .utility) {
            _ = KeyruneFont.glyph(for: "lea")
            _ = ManaFont.glyph(named: "w")
            for name in [ManaFont.register() ? ManaFont.fontName : nil,
                         KeyruneFont.register() ? KeyruneFont.fontName : nil].compactMap({ $0 }) {
                let font = CTFontCreateWithName(name as CFString, 16, nil)
                var glyph: CGGlyph = 0
                var char: UniChar = 0x0041
                _ = CTFontGetGlyphsForCharacters(font, &char, &glyph, 1)
                // One real draw: the outline path is what the text pipeline
                // asks for first, and it is what triggers the slow parse.
                if let path = CTFontCreatePathForGlyph(font, glyph, nil) {
                    let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
                    ctx?.addPath(path)
                    ctx?.fillPath()
                }
            }
        }
    }

    /// Every SF Symbol the app draws (kept by hand; `symbolNames` is
    /// checked against the source by `LaunchPrewarmTests`).
    static let symbolNames: [String] = [
        "arrow.down",
        "arrow.left.arrow.right",
        "arrow.right",
        "arrow.turn.down.right",
        "arrow.up",
        "arrow.up.arrow.down",
        "arrow.up.right",
        "arrow.uturn.backward",
        "bolt",
        "bookmark",
        "bookmark.badge.plus",
        "bookmark.fill",
        "calendar",
        "chart.bar",
        "chart.bar.xaxis",
        "checkmark",
        "checkmark.circle",
        "checkmark.circle.fill",
        "checkmark.seal.fill",
        "chevron.down",
        "chevron.right",
        "chevron.up.chevron.down",
        "circle.hexagonpath",
        "circle.lefthalf.filled",
        "clock",
        "clock.arrow.circlepath",
        "crown",
        "delete.left",
        "doc",
        "doc.on.clipboard",
        "doc.text",
        "dollarsign",
        "dollarsign.circle",
        "ellipsis",
        "ellipsis.circle",
        "exclamationmark.triangle",
        "exclamationmark.triangle.fill",
        "hammer",
        "info.circle",
        "line.3.horizontal.decrease",
        "line.3.horizontal.decrease.circle",
        "line.3.horizontal.decrease.circle.fill",
        "link",
        "lock",
        "lock.fill",
        "lock.open",
        "magnifyingglass",
        "minus",
        "minus.circle",
        "mountain.2",
        "number",
        "paintbrush",
        "paintpalette",
        "pencil",
        "photo",
        "plus",
        "plus.circle",
        "plus.circle.fill",
        "rectangle.portrait.on.rectangle.portrait",
        "rectangle.stack",
        "rectangle.stack.fill",
        "shield",
        "sparkles",
        "sparkles.rectangle.stack.fill",
        "square.and.arrow.down",
        "square.and.arrow.up",
        "square.grid.3x3.fill",
        "square.stack",
        "square.stack.3d.up",
        "star",
        "tag",
        "target",
        "text.book.closed",
        "textformat",
        "tornado",
        "trash",
        "tray",
        "tray.full",
        "wand.and.stars",
        "wifi.exclamationmark",
        "wifi.slash",
        "xmark",
        "xmark.circle",
    ]

    /// Resolves each symbol once, off-main, so the catalog lookups are
    /// done before a screen needs them. One configuration: the cost is the
    /// name's first lookup in the catalog, not the weight.
    nonisolated static func symbols() {
        DispatchQueue.global(qos: .utility).async {
            let configuration = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            for name in symbolNames {
                _ = UIImage(systemName: name, withConfiguration: configuration)
            }
        }
    }

    /// Compiles the foil sheen's function ahead of use, then draws it once
    /// (FoilWarmupView) so RenderBox builds its specialised pipeline too.
    @MainActor static func shaders() {
        Task {
            let shader = ShaderLibrary.foilSheen(.float2(CGSize(width: 100, height: 140)), .float(2.4), .float(0.16))
            do { try await shader.compile(as: .layerEffect) } catch { log.error("foil shader compile: \(error)") }
            // The one draw that builds RenderBox's pipeline on the main
            // thread: after the keyboard prewarm, so the two never stack.
            try? await Task.sleep(for: .milliseconds(2600))
            FoilWarmup.shared.begin()
        }
    }

    private static let log = Logger(subsystem: "magic-hat", category: "prewarm")

    /// Loads ScreenTime on a background thread, then calls back on the
    /// main actor. For SetSymbolLoader, the moment a set symbol first needs
    /// the WebKit rasterizer — not at launch (see the file comment): the
    /// first WKWebView makes WebKit soft-link ScreenTime, and dyld runs a
    /// framework's load on the calling thread with synchronous XPC inside,
    /// 4.0s on the main thread when it happened there.
    nonisolated static func loadScreenTime(then completion: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.global(qos: .utility).async {
            _ = dlopen("/System/Library/Frameworks/ScreenTime.framework/ScreenTime", RTLD_NOW)
            Task { @MainActor in completion() }
        }
    }

    @MainActor private static var keyboardDone = false

    /// Whether a debugger is attached (Xcode's Run). Under one, every
    /// framework the process loads stops it — every thread — while the
    /// debugger reads the image: measured on a device, the keyboard
    /// prewarm's chain of soft-linked frameworks froze the app for 8.6s
    /// two seconds after launch (0.1s without the debugger), which is where
    /// "nothing responds and the tab says it's adding up" came from.
    nonisolated static let isBeingDebugged: Bool = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }()

    /// Loads the text-input stack without showing a keyboard. Skipped
    /// under a debugger (see `isBeingDebugged`): there the load costs
    /// seconds wherever it lands, and on the first tap into a field it is
    /// at least the field that is slow, not the whole app at launch.
    @MainActor static func keyboard() {
        guard !keyboardDone, !isBeingDebugged,
              let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { return }
        keyboardDone = true
        let field = UITextField(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
        field.inputView = UIView()     // no keys drawn, the stack still loads
        field.autocorrectionType = .no
        field.alpha = 0.02
        window.addSubview(field)
        field.becomeFirstResponder()
        DispatchQueue.main.async {
            field.resignFirstResponder()
            field.removeFromSuperview()
        }
    }
}
