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

// Soft shoulder: exact identity below 1−k, C1 quadratic knee that reaches
// exactly 1.0 (zero slope) at t = 1+k. This is what lets whites/blacks
// genuinely clip without posterizing at the knee.
static float soft_shoulder(float t, float k) {
    if (t <= 1.0f - k) return t;
    if (t >= 1.0f + k) return 1.0f;
    float u = (t - (1.0f - k)) / (2.0f * k);
    return (1.0f - k) + 2.0f * k * (u - 0.5f * u * u);
}

// Whites/blacks move the clipping points (authority: 0.30 of the range at
// ±100, knee width 0.05), with the negative directions as tone-weighted
// compressions so the opposite end of the range stays put.
static float whites_blacks(float x, float w, float b) {
    float y = x;
    if (w > 0.0f)      y = soft_shoulder(y / (1.0f - 0.30f * w), 0.05f);
    else if (w < 0.0f) y = y + 0.35f * w * y * y;                      // top-weighted pull-down
    if (b < 0.0f)      y = 1.0f - soft_shoulder((1.0f - y) / (1.0f + 0.30f * b), 0.05f);
    else if (b > 0.0f) y = y + 0.25f * b * (1.0f - y) * (1.0f - y);    // bottom-weighted lift
    return y;
}

extern "C" float4 pv2_whites_blacks(coreimage::sample_t s, float whites, float blacks) {
    float3 d = srgb_encode(s.rgb);
    d = float3(whites_blacks(d.x, whites, blacks),
               whites_blacks(d.y, whites, blacks),
               whites_blacks(d.z, whites, blacks));
    return float4(srgb_decode(d), s.a);
}
