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

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
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
                        } else {
                            ProgressView()
                        }
                    }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: urlString) { await load() }
    }

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
