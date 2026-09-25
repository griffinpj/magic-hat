//
//  CardImageView.swift
//  magic-hat
//
//  Displays a card image loaded through the two-tier ImageLoader cache,
//  showing a placeholder that already reserves the card's aspect ratio so
//  the grid never reflows when images arrive.
//

import SwiftUI

struct CardImageView: View {
    let urlString: String?
    let aspectRatio: Double
    var cornerRadius: CGFloat = 10
    /// Longest-edge target in points; scaled to pixels for downsampling.
    var targetWidth: CGFloat = 150
    /// A smaller size that may already be decoded (e.g. the grid's), shown
    /// immediately while the larger one decodes so nothing flashes to grey.
    var fallbackTargetWidth: CGFloat? = nil
    /// Holographic sheen for foil printings (see FoilSheen).
    var foil: Bool = false
    var foilAnimated: Bool = false
    var foilIntensity: Double = 0.16

    @Environment(\.displayScale) private var displayScale

    @State private var image: UIImage?
    @State private var didFail = false

    private var maxPixel: CGFloat {
        // 3-wide grid tile is ~130pt; scale to device pixels so images stay
        // crisp without decoding at full resolution.
        targetWidth * displayScale
    }

    /// What's already decoded for this URL, looked up during the body — an
    /// NSCache read, microseconds. `.task` only runs after the first frame
    /// has been committed, so a tile scrolling in used to draw its
    /// placeholder first and swap the image in a frame later, even when the
    /// grid had warmed it; and the viewer's zoom grew out of a grey card.
    private var memoryImage: UIImage? {
        guard let urlString, !urlString.isEmpty else { return nil }
        if let exact = ImageMemoryCache.shared.image(ImageMemoryCache.key(urlString, maxPixel)) { return exact }
        guard let fallbackTargetWidth else { return nil }
        return ImageMemoryCache.shared.image(ImageMemoryCache.key(urlString, fallbackTargetWidth * displayScale))
    }

    var body: some View {
        ZStack {
            if let shown = image ?? memoryImage {
                Image(uiImage: shown)
                    .resizable()
                    .scaledToFit()
                    // Sheen is a layerEffect over the image's own layer, so it
                    // samples the art and is clipped with it below.
                    .modifier(FoilSheen(active: foil, animated: foilAnimated,
                                        intensity: Float(foilIntensity)))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.quaternary)
                    .overlay {
                        if didFail {
                            Image(systemName: "photo")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        } else if targetWidth >= Self.spinnerMinWidth {
                            ProgressView()
                        }
                    }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: urlString) { await load() }
    }

    /// Only a card shown large gets a spinner. A ProgressView is a UIKit
    /// activity indicator sized through Auto Layout, and a grid scrolling
    /// into unloaded tiles built and measured one per tile; small tiles
    /// keep a plain grey card, as Photos does.
    private static let spinnerMinWidth: CGFloat = 300

    private func load() async {
        didFail = false
        guard let urlString, !urlString.isEmpty else { image = nil; return }

        let px = maxPixel
        // Synchronous memory hit: no actor hop, no placeholder flash on reuse.
        if let cached = ImageMemoryCache.shared.image(ImageMemoryCache.key(urlString, px)) {
            image = cached
            return
        }
        if let fallback = fallbackTargetWidth,
           let smaller = ImageMemoryCache.shared.image(
                ImageMemoryCache.key(urlString, fallback * displayScale)) {
            image = smaller           // upscaled briefly; replaced below
        } else {
            image = nil
        }
        do {
            image = try await ImageLoader.shared.image(for: urlString, maxPixel: px)
        } catch {
            didFail = true
        }
    }
}
