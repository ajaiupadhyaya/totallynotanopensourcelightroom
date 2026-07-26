// Build-infrastructure probe. Proves (a) .ci.metal files compile into
// default.metallib with -fcikernel, (b) kernels load at runtime, and
// (c) extended-range values pass through a kernel unclamped — the property
// the whole PV2 design depends on.
#include <metal_stdlib>
using namespace metal;
#include <CoreImage/CoreImage.h>

extern "C" float4 pv2_probe_identity(coreimage::sample_t s) {
    return s;
}
