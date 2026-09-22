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
        if !active {
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
