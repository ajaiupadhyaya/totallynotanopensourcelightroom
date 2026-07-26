// PV2 effects. Vignette: a superellipse distance field over the cropped
// frame, gain applied in LINEAR light so a protected highlight keeps its
// energy. Grain (Task 13) lives here too.
#include <metal_stdlib>
using namespace metal;
#include <CoreImage/CoreImage.h>

static float srgb_enc1(float c) {
    float a = fabs(c);
    float e = (a <= 0.0031308f) ? a * 12.92f : 1.055f * pow(a, 1.0f / 2.4f) - 0.055f;
    return copysign(e, c);
}
static float srgb_dec1(float c) {
    float a = fabs(c);
    float l = (a <= 0.04045f) ? a / 12.92f : pow((a + 0.055f) / 1.055f, 2.4f);
    return copysign(l, c);
}
static float3 srgb_encode(float3 c) { return float3(srgb_enc1(c.x), srgb_enc1(c.y), srgb_enc1(c.z)); }
static float3 srgb_decode(float3 c) { return float3(srgb_dec1(c.x), srgb_dec1(c.y), srgb_dec1(c.z)); }

extern "C" float4 pv2_vignette(coreimage::sampler src,
                               float cx, float cy, float hw, float hh,
                               float amount, float midpoint, float feather,
                               float shapeN, float highlightPriority,
                               coreimage::destination dest) {
    float2 dc = dest.coord();
    float4 s = sample(src, src.transform(dc));

    float2 p = float2(fabs(dc.x - cx) / max(hw, 1.0f),
                      fabs(dc.y - cy) / max(hh, 1.0f));       // 1.0 at frame edges
    float d = pow(pow(p.x, shapeN) + pow(p.y, shapeN), 1.0f / shapeN);

    float inner = midpoint * 1.3f;                            // 0…1 slider → start radius
    float width = max(0.05f, feather * 1.2f);
    float fall = smoothstep(inner, inner + width, d);

    float g = max(1.0f + amount * fall, 0.0f);                // amount −1…1, linear gain
    if (amount < 0.0f && highlightPriority > 0.0f) {
        // Linear-light luma; >0.5 linear is already a bright highlight.
        float L = dot(max(s.rgb, 0.0f), float3(0.2126f, 0.7152f, 0.0722f));
        float protect = highlightPriority * smoothstep(0.35f, 1.0f, L);
        g = mix(g, 1.0f, protect);
    }
    return float4(s.rgb * g, s.a);
}

// Deterministic value noise. Seedless by design: the same develop settings
// must produce the same grain on every render, preview or export — the
// lattice is anchored to the frame (normalized coordinates), not the pixel
// grid, so resolution only changes how densely the same field is sampled.
static float hash21(float2 p) {
    p = fract(p * float2(123.34f, 456.21f));
    p += dot(p, p + 45.32f);
    return fract(p.x * p.y);
}
static float value_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0f - 2.0f * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0f, 0.0f));
    float c = hash21(i + float2(0.0f, 1.0f));
    float d = hash21(i + float2(1.0f, 1.0f));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

extern "C" float4 pv2_grain(coreimage::sampler src,
                            float cellSize, float amount,
                            float originX, float originY,
                            coreimage::destination dest) {
    float2 dc = dest.coord();
    float4 s = sample(src, src.transform(dc));

    float2 cell = (dc - float2(originX, originY)) / max(cellSize, 0.5f);
    float g = value_noise(cell) - 0.5f;                      // −0.5…0.5

    float3 d = srgb_encode(clamp(s.rgb, 0.0f, 1.0f));
    float L = dot(d, float3(0.2126f, 0.7152f, 0.0722f));
    float w = 4.0f * L * (1.0f - L);                         // midtone-weighted, like emulsion
    d = clamp(d + g * amount * 0.35f * w, 0.0f, 1.0f);
    return float4(srgb_decode(d), s.a);
}
