// Vibrance and saturation, display-referred and luminance-preserving.
// Chroma is scaled about the display-space luma axis, so luma is invariant
// BY CONSTRUCTION; an exponential rolloff toward the maximum feasible scale
// replaces PV1's channel clipping.
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

// 0…1 weight for the skin hue band (~15°–50°), tapered at both edges.
static float skin_weight(float3 c) {
    float mx = max(c.x, max(c.y, c.z));
    float mn = min(c.x, min(c.y, c.z));
    float delta = mx - mn;
    if (delta < 1e-4f) return 0.0f;
    float h;
    if (mx == c.x)      h = (c.y - c.z) / delta;
    else if (mx == c.y) h = (c.z - c.x) / delta + 2.0f;
    else                h = (c.x - c.y) / delta + 4.0f;
    h *= 60.0f;
    if (h < 0.0f) h += 360.0f;
    return smoothstep(8.0f, 18.0f, h) * (1.0f - smoothstep(42.0f, 58.0f, h));
}

extern "C" float4 pv2_vibrance_saturation(coreimage::sample_t s,
                                          float vibrance, float saturation) {
    float3 d = clamp(srgb_encode(s.rgb), 0.0f, 1.0f);
    float L = dot(d, float3(0.2126f, 0.7152f, 0.0722f));
    float3 chroma = d - L;

    float satAmount = max(d.x, max(d.y, d.z)) - min(d.x, min(d.y, d.z));
    float f = 1.0f + saturation;                       // −1…1 → 0…2
    if (vibrance != 0.0f) {
        float muted = clamp(1.0f - satAmount * 1.6f, 0.0f, 1.0f);
        float skin = skin_weight(d);
        f *= 1.0f + vibrance * muted * (1.0f - 0.75f * skin);
    }
    f = max(f, 0.0f);

    if (f > 1.0f) {
        // Largest scale that keeps every channel inside [0, 1].
        float kmax = 1e6f;
        if (chroma.x > 1e-5f) kmax = min(kmax, (1.0f - L) / chroma.x);
        if (chroma.x < -1e-5f) kmax = min(kmax, -L / chroma.x);
        if (chroma.y > 1e-5f) kmax = min(kmax, (1.0f - L) / chroma.y);
        if (chroma.y < -1e-5f) kmax = min(kmax, -L / chroma.y);
        if (chroma.z > 1e-5f) kmax = min(kmax, (1.0f - L) / chroma.z);
        if (chroma.z < -1e-5f) kmax = min(kmax, -L / chroma.z);
        if (kmax < 1e6f) {
            float km = max(kmax, 1.0001f);
            // Asymptotic approach: f=1 → 1, f→∞ → km, monotonic, C1.
            f = 1.0f + (km - 1.0f) * (1.0f - exp(-(f - 1.0f) / (km - 1.0f)));
        }
    }

    float3 outc = L + chroma * f;
    return float4(srgb_decode(clamp(outc, 0.0f, 1.0f)), s.a);
}
