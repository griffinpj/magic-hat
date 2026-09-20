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

    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
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
        image = nil
        didFail = false
        guard let urlString, !urlString.isEmpty else { return }

        if let cached = await ImageLoader.shared.cachedImage(for: urlString) {
            image = cached
            return
        }
        do {
            image = try await ImageLoader.shared.image(for: urlString)
        } catch {
            didFail = true
        }
    }
}
