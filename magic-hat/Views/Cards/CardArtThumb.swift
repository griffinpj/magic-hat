//
//  CardArtThumb.swift
//  magic-hat
//
//  A small landscape crop of a card's art for list rows: Scryfall's
//  art_crop, the illustration alone. Rows that showed the whole card were
//  tall and the card unreadable at 42pt anyway; the art is what identifies
//  a card at a glance. Until the crop arrives, a full card image already
//  decoded for the grid or viewer (memory cache only) stands in, slid up
//  to its art box, so a row never flashes grey for a card just seen.
//

import SwiftUI

struct CardArtThumb: View {
    let artURL: String?
    /// The full card image; used only if already decoded, as a stand-in.
    var fallbackURL: String? = nil
    var width: CGFloat = 56
    var height: CGFloat = 40
    var cornerRadius: CGFloat = 8

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var isCardFace = false

    var body: some View {
        ZStack {
            if let image, isCardFace {
                // A card face scaled to the thumb's width is ~1.39× as tall;
                // the art box is centred about a third of the way down.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: width)
                    .offset(y: -0.24 * width)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: artURL) { await load() }
    }

    private func load() async {
        guard let artURL, !artURL.isEmpty else { image = nil; return }
        let px = max(width, height) * displayScale
        if let cached = ImageMemoryCache.shared.image(ImageMemoryCache.key(artURL, px)) {
            image = cached
            isCardFace = false
            return
        }
        if let fallbackURL,
           let face = [480.0, 150.0].lazy.compactMap({
               ImageMemoryCache.shared.image(ImageMemoryCache.key(fallbackURL, $0 * displayScale))
           }).first {
            image = face
            isCardFace = true
        } else {
            image = nil
        }
        if let art = try? await ImageLoader.shared.image(for: artURL, maxPixel: px) {
            image = art
            isCardFace = false
        }
    }
}
