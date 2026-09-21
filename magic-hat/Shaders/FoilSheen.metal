//
//  FoilSheen.metal
//  magic-hat
//
//  A holographic sheen for foil cards, run on the GPU through SwiftUI's
//  layerEffect. One pass per foil tile; effectively free next to the image
//  decode that already happened. `time` drives a slow drift in the overlay
//  and is 0 in the grid, where the sheen is static.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

static half3 hueToRGB(float h) {
    float r = abs(h * 6.0 - 3.0) - 1.0;
    float g = 2.0 - abs(h * 6.0 - 2.0);
    float b = 2.0 - abs(h * 6.0 - 4.0);
    return half3(saturate(float3(r, g, b)));
}

[[ stitchable ]] half4 foilSheen(float2 position, SwiftUI::Layer layer,
                                 float2 size, float time, float intensity) {
    half4 color = layer.sample(position);
    if (color.a < 0.01h) { return color; }

    float2 uv = position / max(size, float2(1.0));

    // Broad rainbow bands running diagonally — under one full cycle across
    // the card — drifting slowly with time.
    float band = fract((uv.x * 0.9 + uv.y * 0.6) * 0.8 + time * 0.04);
    half3 rainbow = hueToRGB(band);

    // A slow specular sweep decides where the sheen shows. Squared so it
    // reads as a distinct streak rather than an even glaze; a floor keeps a
    // faint shimmer everywhere. Brighter pixels take more, but dark art
    // still gets some so black-bordered foils don't look flat.
    float sweep = 0.5 + 0.5 * sin((uv.x - uv.y) * 6.2832 + time * 0.3);
    float highlight = 0.25 + 0.75 * sweep * sweep;
    float luma = dot(float3(color.rgb), float3(0.299, 0.587, 0.114));
    half amount = half(intensity * highlight * (0.5 + 0.5 * luma));

    // Screen-style blend: adds light without crushing the underlying art.
    half3 mixed = color.rgb + rainbow * amount * (half3(1.0h) - color.rgb);
    return half4(mixed, color.a);
}
