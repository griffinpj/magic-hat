//
//  FoilSheen.swift
//  magic-hat
//
//  Holographic sheen for foil printings, drawn by Shaders/FoilSheen.metal
//  through SwiftUI's layerEffect — one GPU pass over the card's own layer.
//  Static in the grid (time is constant, so nothing redraws); the bands drift
//  only on the centred overlay card, via a 30fps TimelineView; and not at
//  all under Reduce Motion.
//

import SwiftUI

struct FoilSheen: ViewModifier {
    var active: Bool
    var animated: Bool = false
    var intensity: Float = 0.16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Until the pipeline is compiled the sheen is skipped rather than
        // paid for: see FoilWarmup.
        if !active || !FoilWarmup.shared.isReady {
            content
        } else if animated && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = Float(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 600))
                content.modifier(FoilShader(time: t, intensity: intensity))
            }
        } else {
            // A fixed phase that puts the highlight band across the art.
            content.modifier(FoilShader(time: 2.4, intensity: intensity))
        }
    }
}

/// RenderBox compiles the sheen's Metal pipeline — specialised for its
/// render state, so `Shader.compile(as:)` alone does not cover it — on the
/// main thread the first time a foil layer is drawn: 0.47s, caught by
/// HangDetector under the first push into the real collection. So the
/// first draw is a 1pt warm-up view in RootView, shortly after launch,
/// and `FoilSheen` draws nothing until it has happened.
@MainActor @Observable
final class FoilWarmup {
    static let shared = FoilWarmup()
    private(set) var isReady = false
    private(set) var isWarming = false

    /// Shows the warm-up view; `didDraw` is called from its onAppear.
    func begin() { if !isReady { isWarming = true } }
    func didDraw() {
        isReady = true
        isWarming = false
    }
}

/// The warm-up view: an image layer under the same modifier and clip a
/// grid tile uses, so RenderBox specialises the same pipeline (a plain
/// colour, or a faded layer, compiled a different one and the tile still
/// paid 0.15s). Drawn at full opacity, 2pt, *behind* the tabs — the
/// screens above are opaque, and Core Animation still renders it.
struct FoilWarmupView: View {
    private var warmup: FoilWarmup { .shared }

    private static let pixel: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }()

    var body: some View {
        if warmup.isWarming {
            // A scroll view holding a grid holding a tile — RenderBox's
            // render state follows the layer tree, so the warm-up is
            // drawn inside the same shape of tree the grid draws in.
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible())], spacing: 0) {
                    ZStack {
                        Image(uiImage: Self.pixel)
                            .resizable()
                            .scaledToFit()
                            .modifier(FoilShader(time: 2.4, intensity: 0.16))
                    }
                    .aspectRatio(488.0 / 680.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 1, style: .continuous))
                    .overlay(alignment: .topLeading) { Text("1").font(.caption2) }
                    .contentShape(Rectangle())
                }
            }
            .frame(width: 3, height: 4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                // A couple of frames for the layer to be committed and drawn.
                try? await Task.sleep(for: .milliseconds(200))
                warmup.didDraw()
            }
        }
    }
}

private struct FoilShader: ViewModifier {
    let time: Float
    let intensity: Float

    func body(content: Content) -> some View {
        content.visualEffect { view, proxy in
            view.layerEffect(
                ShaderLibrary.foilSheen(
                    .float2(proxy.size),
                    .float(time),
                    .float(intensity)
                ),
                maxSampleOffset: .zero
            )
        }
    }
}
