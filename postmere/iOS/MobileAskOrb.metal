#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// A small sphere of liquid metal for the Ask orb. The surface reflects a soft
// studio sky that slowly flows, tinted toward the accent, with a hot highlight
// and a bright rim. `energy` runs from 0 (resting) to 1 (answering).

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x),
               mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
}

static float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { v += a * noise(p); p = p * 2.03 + 17.1; a *= 0.5; }
    return v;
}

// What a mirror ball sees: a bright sky above, a darker floor below, a band of
// light at the horizon, all bent by the flowing warp.
static float3 studio(float3 r, float t, float3 accent) {
    float2 q = r.xy * 1.6;
    float2 warp = float2(fbm(q + float2(t * 0.11, -t * 0.07)), fbm(q + float2(-t * 0.09, t * 0.13) + 5.2));
    float y = r.y + (warp.y - 0.5) * 0.9 + (warp.x - 0.5) * 0.35;
    float sky = smoothstep(-0.15, 0.85, y);
    float horizon = exp(-pow((y - 0.05) * 5.5, 2.0));
    float3 floorTone = accent * 0.45 + 0.10;
    float3 skyTone = mix(accent * 0.9 + 0.25, float3(0.97, 0.98, 1.0), 0.55);
    float3 c = mix(floorTone, skyTone, sky);
    c += horizon * float3(1.0, 0.98, 0.95) * 0.55;
    // Thin streaks give the brushed, poured-metal feel.
    float streak = smoothstep(0.62, 0.95, fbm(float2(y * 9.0, r.x * 2.0 + t * 0.05)));
    c += streak * 0.18;
    return c;
}

[[ stitchable ]] half4 askOrbMetal(float2 position, half4 color, float2 size, float time, half4 accent, float energy) {
    float2 uv = (position / size) * 2.0 - 1.0;
    float d = length(uv);
    if (d > 1.0) return half4(0);

    float3 n = normalize(float3(uv.x, -uv.y, sqrt(max(0.0, 1.0 - d * d))));
    float3 view = float3(0, 0, 1);
    float3 r = reflect(-view, n);
    float t = time * (0.6 + energy * 1.6);

    float3 tint = float3(accent.rgb);
    float3 c = studio(r, t, tint);

    // Light from the upper left.
    float3 light = normalize(float3(-0.55, 0.7, 0.75));
    float spec = pow(max(0.0, dot(reflect(-light, n), view)), 48.0);
    c += spec * 1.1;

    // A bright rim and a faint shift of hue toward the edge, as polished metal does.
    float fresnel = pow(1.0 - n.z, 3.0);
    c = mix(c, mix(tint, float3(1.0), 0.65), fresnel * 0.55);
    c += fresnel * energy * tint * 0.6;

    // Soft contact shadow toward the bottom keeps it reading as a sphere.
    c *= mix(1.0, 0.78, smoothstep(0.1, 1.0, -uv.y * 0.6 + d * 0.5));

    // Calmer behind the sparkles, so the white mark always reads.
    c = mix(c, tint * 0.55 + 0.12, (1.0 - smoothstep(0.0, 0.55, d)) * 0.35);

    // Antialiased edge.
    float edge = 1.0 - smoothstep(1.0 - 2.0 / size.x, 1.0, d);
    return half4(half3(saturate(c)), 1.0h) * half(edge) * color.a;
}
