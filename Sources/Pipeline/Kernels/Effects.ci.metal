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
