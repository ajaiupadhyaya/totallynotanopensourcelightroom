// PV2 tone kernels. All display-referred: each kernel encodes the linear
// working-space sample to sRGB gamma, does its math where the histogram and
// the user's eye live, and decodes back. Sign-preserving transfer functions
// keep extended-range values alive; values above 1.0 pass around the curve
// as a residual so EDR headroom is not flattened.
#include <metal_stdlib>
using namespace metal;
#include <CoreImage/CoreImage.h>

// Duplicated per .ci.metal file on purpose — classic CIKernel metallibs
// cannot link functions across translation units.
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

// Contrast about display middle grey. amount in −1…1.
// Positive blends toward the Hermite S-curve x²(3−2x): pinned at 0 and 1,
// fixed point exactly at 0.5, slope 1.5 there at full strength — steepens
// without ever clipping. Negative blends toward that curve's exact inverse
// (0.5 − sin(asin(1−2y)/3)), which flattens symmetrically.
static float contrast_curve(float x, float amount) {
    float xc = clamp(x, 0.0f, 1.0f);
    float residual = x - xc;                       // EDR / negative headroom
    float shaped;
    if (amount >= 0.0f) {
        float s = xc * xc * (3.0f - 2.0f * xc);
        shaped = mix(xc, s, amount);
    } else {
        float inv = 0.5f - sin(asin(1.0f - 2.0f * xc) / 3.0f);
        shaped = mix(xc, inv, -amount);
    }
    return shaped + residual;
}

extern "C" float4 pv2_contrast(coreimage::sample_t s, float amount) {
    float3 d = srgb_encode(s.rgb);
    d = float3(contrast_curve(d.x, amount),
               contrast_curve(d.y, amount),
               contrast_curve(d.z, amount));
    return float4(srgb_decode(d), s.a);
}
