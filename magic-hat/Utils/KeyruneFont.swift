//
//  KeyruneFont.swift
//  magic-hat
//
//  Set symbols rendered as text from the bundled Keyrune font (SIL OFL,
//  Resources/KEYRUNE-LICENSE.txt). Deterministic, offline, tintable, and
//  drawn by the text pipeline — none of WebKit's "is this view visible
//  enough to paint" ambiguity. `keyrune-map.json` maps a set code to its
//  glyph and is generated from Keyrune's CSS.
//
//  The font is registered at runtime with CoreText, so no Info.plist entry
//  is needed. Sets newer than the bundled font fall back to the WebKit
//  rasterizer in SetSymbolLoader.
//

import Foundation
import CoreText
import UIKit

enum KeyruneFont {
    /// PostScript name of the registered font, or nil if registration failed.
    nonisolated(unsafe) private(set) static var fontName: String? = nil

    /// Set code (lowercase) -> single-character glyph string.
    static let glyphs: [String: String] = {
        guard let url = Bundle.main.url(forResource: "keyrune-map", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        var out: [String: String] = [:]
        out.reserveCapacity(raw.count)
        for (code, hex) in raw {
            if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                out[code] = String(Character(scalar))
            }
        }
        return out
    }()

    private static let registration: Bool = {
        guard let url = Bundle.main.url(forResource: "keyrune", withExtension: "ttf") else { return false }
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        // Already-registered (e.g. tests + app in one process) is fine.
        let alreadyRegistered = (error?.takeRetainedValue() as Error?).map {
            ($0 as NSError).code == CTFontManagerError.alreadyRegistered.rawValue
        } ?? false
        guard ok || alreadyRegistered else { return false }

        if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
           let first = descriptors.first,
           let name = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String {
            fontName = name
            return true
        }
        return false
    }()

    /// Registers the font once. Safe to call repeatedly.
    @discardableResult
    static func register() -> Bool { registration }

    /// Glyph for a Scryfall set code, if Keyrune has it. Promo ("p…") and
    /// token ("t…") sets use their parent set's symbol, which is also what
    /// Keyrune does, so those fall back to the parent code.
    static func glyph(for setCode: String) -> String? {
        guard register() else { return nil }
        let code = setCode.lowercased()
        if let g = glyphs[code] { return g }
        if code.count > 3, code.hasPrefix("p") || code.hasPrefix("t"),
           let g = glyphs[String(code.dropFirst())] {
            return g
        }
        return nil
    }
}
