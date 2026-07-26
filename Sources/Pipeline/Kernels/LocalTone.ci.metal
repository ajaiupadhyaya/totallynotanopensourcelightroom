// Highlights/shadows via base–detail decomposition. The base arrives from
// CIGuidedFilter (edge-preserving, so the tonal gain cannot bleed across
// edges — that bleed is what a halo is). The kernel retones the BASE only
// and adds the untouched detail back on top.
//
// EDR POLICY (uniform across Tone/LocalTone/Color.ci.metal): per
// display-encoded channel, xc = clamp(x, 0, 1) and residual = x − xc; the
// retone operates on xc alone and the residual is added back at the end, so a
// value above 1.0 (or below 0) is carried through untouched instead of being
// fed to math that was only ever defined on [0, 1].
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

    // The region weights and the (1−L)/L authority factors are defined on the
    // display range only, so the base is split the same way every other PV2
    // kernel splits its input: retone the clamped part, carry the rest.
    float3 bc = clamp(b, 0.0f, 1.0f);
    float3 baseResidual = b - bc;

    float Lc = dot(bc, float3(0.2126f, 0.7152f, 0.0722f));
    float hw = smoothstep(0.35f, 0.85f, Lc);          // highlight region weight
    float sw = 1.0f - smoothstep(0.15f, 0.65f, Lc);   // shadow region weight
    // 0.45 total authority; (1−Lc)/Lc factors keep each control from crossing
    // into the opposite end of the range.
    float newL = Lc
        + shadows * 0.45f * sw * (1.0f - Lc)
        + highlights * 0.45f * hw * Lc;
    // No upper clamp: an EDR frame's clipped base is already at Lc = 1 and
    // clamping newL there would flatten every highlight to white. Negative
    // luma has no meaning, so the floor stays.
    newL = max(newL, 0.0f);
    float gain = newL / max(Lc, 1e-4f);

    float3 outRGB = clamp(bc * gain + baseResidual + detail, -0.1f, 4.0f);
    return float4(srgb_decode(outRGB), s.a);
}
