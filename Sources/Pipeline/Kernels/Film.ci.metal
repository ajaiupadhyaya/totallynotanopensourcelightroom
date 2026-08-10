// The print engine's density-to-paper conversion. Runs on LINEAR working-space
// values — the opposite of every kernel in Tone.ci.metal, and deliberately so:
// log10 of linear transmittance is the physically meaningful density, and the
// paper curve is defined on the linear print value. No sRGB bracketing here.
//
// This kernel mirrors PaperResponse.swift line for line, and
// FilmDensityConverterTests.testKernelAgreesWithTheSwiftModel is the contract
// that keeps the two in step. Change one, change both.
#include <metal_stdlib>
using namespace metal;
#include <CoreImage/CoreImage.h>

// softknee(x,k) = x·(1+x^k)^(−1/k): identity near 0, asymptote 1, never clips.
//
// Clamped one ULP below 1 — mirrors PaperResponse.softknee (Swift). Past a
// few decades in x the true value is closer to 1 than `float` can resolve,
// and an unclamped result rounds to exactly 1.0: a real clip, and (via
// paper_curve below) the boundedness guarantee every caller relies on to
// know the shoulder never fully clips and the pipeline never sees a NaN.
static float softknee(float x, float k) {
    if (x <= 0.0f) return 0.0f;
    return min(x / pow(1.0f + pow(x, k), 1.0f / k), nextafter(1.0f, 0.0f));
}

// Shoulder into white; toe (the same knee on the complement) out of black.
// No outer clamp here: softknee's own clamp above is what keeps this < 1, so
// a second clamp on the result would be redundant.
static float paper_curve(float n, float p, float q) {
    return 1.0f - softknee(1.0f - softknee(n, p), q);
}

extern "C" float4 film_density_print(coreimage::sample_t s,
                                     float3 dmin, float3 dmax, float3 gam,
                                     float3 printOffset, float p, float q,
                                     float shoulderStart, float highlightDesat,
                                     float satScale,
                                     float3 trimS, float3 trimM, float3 trimH,
                                     float punch, float fade, float glow,
                                     float toeChroma, float targetMid,
                                     float toeStart, float toeEnd,
                                     float3 zoneEdges, float zoneHighFull) {
    // Stage 1+2: density relative to the base, then the paper's straight line.
    // gam arrives with the grade scale already folded in (CPU side).
    // printOffset is per-channel: printEV·log10(2) plus filtration (the
    // enlarger color pack) — see PaperResponse.printOffsets, which mirrors
    // this fold exactly.
    float3 t = max(s.rgb, float3(1e-5f));
    float3 D = log10(max(dmin, float3(1e-4f)) / t);
    float3 sp = pow(float3(10.0f), gam * (D - dmax) + printOffset);

    // Zone trims: weights from the PRE-trim paper-output norm (mirrors
    // PaperResponse.develop — evaluated once, untrimmed, no circularity).
    // zoneEdges = (zoneShadowEnd, zoneShadowFade, zoneHighStart); targetMid /
    // toeStart / toeEnd arrive as arguments rather than duplicated literals
    // so the Swift constants stay the single source.
    if (any(trimS != 0.0f) || any(trimM != 0.0f) || any(trimH != 0.0f)) {
        float n0 = max(sp.x, max(sp.y, sp.z));
        float pn0 = paper_curve(n0, p, q);
        float wS = 1.0f - smoothstep(zoneEdges.x, zoneEdges.y, pn0);
        float wH = smoothstep(zoneEdges.z, zoneHighFull, pn0);
        float wM = max(1.0f - wS - wH, 0.0f);
        sp *= pow(float3(10.0f), wS * trimS + wM * trimM + wH * trimH);
    }

    // Stage 3: the paper acts on the max-channel norm — the channel that
    // would otherwise clip — and the others follow by ratio. max3 is not
    // available in this Metal environment; max(x, max(y, z)) is the safe form
    // (see the other .ci.metal kernels for the same pattern).
    float n = max(sp.x, max(sp.y, sp.z));
    float3 ratio = n > 0.0f ? sp / n : float3(1.0f);
    ratio = max(1.0f + (ratio - 1.0f) * satScale, float3(0.0f));
    float pn = paper_curve(n, p, q);
    // Punch: monotone cubic S about the mid target (see PaperResponse).
    pn = pn + punch * pn * (1.0f - pn) * (pn - targetMid);
    // Fade/glow: endpoint remap — raised black, lowered white.
    pn = fade + pn * (1.0f - fade - glow);

    // Stage 4: hue-preserving rolloff. One weight for all three channels
    // scales every inter-channel difference equally, so hue cannot rotate.
    // The toe's mirror weight compresses shadow chroma the same way.
    float w = smoothstep(shoulderStart, 1.0f, pn) * highlightDesat;
    float wToe = (1.0f - smoothstep(toeStart, toeEnd, pn)) * toeChroma;
    float3 outc = pn * mix(ratio, float3(1.0f), min(w + wToe, 1.0f));
    return float4(outc, s.a);
}
