#include <CoreImage/CoreImage.h>
using namespace metal;

// Core Image kernels, compiled into the app's default.metallib at build time ([[stitchable]] needs no
// special build flags) and loaded by name in PhotoRenderer. iOS can't compile Metal source at runtime.

// Film grain. `s` is sRGB encoded; `fine`/`coarse` are blurred random noise whose RGB average has
// std ≈ 0.068 around 0.5, so `n` has unit std. Added equally to R, G and B; strongest in midtones.
[[stitchable]] float4 filmGrain(coreimage::sample_t s, coreimage::sample_t fine,
                                coreimage::sample_t coarse, float strength) {
    float n = ((dot(fine.rgb, float3(1.0 / 3.0)) - 0.5) + 0.6 * (dot(coarse.rgb, float3(1.0 / 3.0)) - 0.5)) * 12.6;
    float y = clamp(dot(s.rgb, float3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
    float w = (0.35 + 2.6 * y * (1.0 - y)) * (1.0 - y * y * y * y);
    return float4(clamp(s.rgb + strength * n * w, 0.0, 1.0), s.a);
}

// Halation glow source: linear luminance above ~0.45 (about 70% on screen) ramps to full at 0.8,
// tinted red-orange. Darker pixels give exactly nothing.
[[stitchable]] float4 halationSource(coreimage::sample_t s) {
    float y = dot(s.rgb, float3(0.2126, 0.7152, 0.0722));
    float h = clamp((y - 0.45) / 0.35, 0.0, 1.0);
    return float4(h, h * 0.28, h * 0.06, 1.0);
}

// Photo + blurred glow, keeping the photo's alpha.
[[stitchable]] float4 halationAdd(coreimage::sample_t s, coreimage::sample_t wide,
                                  coreimage::sample_t tight, float strength) {
    return float4(s.rgb + (wide.rgb + tight.rgb) * strength, s.a);
}


// Split toning for the recipe filters: tints shadows and highlights by luminance. The shadow tint fades
// out toward pure black, so night skies and deep shadows stay neutral instead of turning a color.
[[stitchable]] float4 lookSplitTone(coreimage::sample_t s, float3 shadows, float3 highlights) {
    float m = clamp(dot(s.rgb, float3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
    return float4(s.rgb + shadows * (1.0 - m) * min(1.0, m * 12.0) + highlights * m, s.a);
}

// Color Grade: tint the shadows and the highlights separately (display values). Pure black and pure white
// stay neutral (the tints fade out toward both ends). `balance` moves the split toward shadows (-) or highlights (+).
[[stitchable]] float4 colorGrade(coreimage::sample_t s, float3 shadowTint, float3 highlightTint, float balance) {
    float3 c = pow(clamp(s.rgb, 0.0, 1.0), float3(1.0 / 2.2));
    float y = dot(c, float3(0.2126, 0.7152, 0.0722));
    float split = 0.5 + 0.25 * balance;
    float ws = smoothstep(0.0, 0.18, y) * (1.0 - smoothstep(split - 0.25, split + 0.1, y));
    float wh = smoothstep(split - 0.1, split + 0.25, y) * (1.0 - smoothstep(0.92, 1.0, y));
    float3 graded = c + shadowTint * ws + highlightTint * wh;
    // Keep each pixel's brightness: tint changes color, not exposure.
    graded += y - dot(graded, float3(0.2126, 0.7152, 0.0722));
    return float4(pow(clamp(graded, 0.0, 1.0), float3(2.2)), s.a);
}
