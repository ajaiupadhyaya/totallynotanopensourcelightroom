// Highlights/shadows via base–detail decomposition. The base arrives from
// CIGuidedFilter (edge-preserving, so the tonal gain cannot bleed across
// edges — that bleed is what a halo is). The kernel retones the BASE only
// and adds the untouched detail back on top.
//
// Duplicated per .ci.metal file on purpose — classic CIKernel metallibs
// cannot link functions across translation units, so this is a separate
// translation unit from Tone.ci.metal and needs its own copy of the sRGB
// helpers.
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

extern "C" float4 pv2_local_tone(coreimage::sample_t s, coreimage::sample_t base,
                                 float highlights, float shadows) {
    float3 img = srgb_encode(s.rgb);
    float3 b = srgb_encode(base.rgb);
    float3 detail = img - b;

    float L = dot(b, float3(0.2126f, 0.7152f, 0.0722f));
    float hw = smoothstep(0.35f, 0.85f, L);          // highlight region weight
    float sw = 1.0f - smoothstep(0.15f, 0.65f, L);   // shadow region weight
    // 0.45 total authority; (1−L)/L factors keep each control from crossing
    // into the opposite end of the range.
    float newL = L
        + shadows * 0.45f * sw * (1.0f - L)
        + highlights * 0.45f * hw * L;
    newL = clamp(newL, 0.0f, 1.0f);
    float gain = (L > 1e-4f) ? newL / L : 1.0f;

    float3 outRGB = clamp(b * gain + detail, -0.1f, 4.0f);
    return float4(srgb_decode(outRGB), s.a);
}
