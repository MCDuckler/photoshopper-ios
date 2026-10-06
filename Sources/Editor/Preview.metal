// Live edit preview. Mirrors photo-edit/server/app/pipeline.py render_array op
// for op (same order, same constants) so the server render that replaces it a
// moment later looks the same. Not here: halation, bloom, grain, sharpening and
// the overlays (leak, border, date) — the server preview brings those.
//
// Parameters arrive as one flat float array; indices match PreviewParams in
// MetalPreview.swift.

#include <metal_stdlib>
using namespace metal;

#define P_EXPOSURE 0
#define P_BRIGHTNESS 1
#define P_CONTRAST 2
#define P_TEMP 3
#define P_TINT 4
#define P_HIGHLIGHTS 5
#define P_SHADOWS 6
#define P_WHITES 7
#define P_BLACKS 8
#define P_SATURATION 9
#define P_VIBRANCE 10
#define P_DEHAZE 11
#define P_MATTE 12
#define P_BW 13
#define P_SPLIT_BAL 14
#define P_VIG_AMOUNT 15
#define P_VIG_FEATHER 16
#define P_VIG_MID 17
#define P_VIG_ROUND 18
#define P_SRC_ASPECT 19
#define P_LUT_AMOUNT 20
#define P_LUT_N 21
#define P_USE_CURVE 22
#define P_USE_LUT 23
#define P_USE_HSL 24
#define P_USE_MIXER 25
#define P_ROTATION 26
#define P_ORIGINAL 27
#define P_SPLIT_SH 28   // 3 floats, already (hex - 0.5) * sat
#define P_SPLIT_HI 31   // 3 floats
#define P_CROP 34       // x y w h in rotated space
#define P_HSL 38        // 24 floats
#define P_MIXER 62      // 8 floats
#define P_COUNT 70

constant float3 LUMA = float3(0.2126, 0.7152, 0.0722);
constant float HUE_CENTERS[8] = { 0.0, 30.0, 60.0, 120.0, 180.0, 210.0, 270.0, 300.0 };

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

vertex VOut p3k_vertex(uint vid [[vertex_id]]) {
    // One triangle that covers the viewport.
    float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
    VOut o;
    o.pos = float4(p, 0.0, 1.0);
    o.uv = float2((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);
    return o;
}

static float ss(float a, float b, float x) {
    float t = clamp((x - a) / max(b - a, 1e-6), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// Python's % (floored), which the server's hue math relies on.
static float fmodp(float x, float m) { return x - m * floor(x / m); }

static float3 srgb2lin(float3 s) {
    s = max(s, float3(0.0));
    float3 lo = s / 12.92;
    float3 hi = pow((s + 0.055) / 1.055, float3(2.4));
    return select(hi, lo, s <= 0.04045);
}

static float3 lin2srgb(float3 l) {
    l = max(l, float3(0.0));
    float3 lo = l * 12.92;
    float3 hi = 1.055 * pow(l, float3(1.0 / 2.4)) - 0.055;
    return select(hi, lo, l <= 0.0031308);
}

static float3 softShoulder(float3 c) {
    const float a = 0.8;
    float3 over = (c - a) / (1.0 - a);
    float3 comp = a + (1.0 - a) * tanh(over);
    return select(c, comp, c > a);
}

static float3 rgb2hsl(float3 c) {
    float mx = max(max(c.r, c.g), c.b);
    float mn = min(min(c.r, c.g), c.b);
    float l = (mx + mn) * 0.5;
    float d = mx - mn;
    float s = d == 0.0 ? 0.0 : d / (1.0 - fabs(2.0 * l - 1.0) + 1e-6);
    float h = 0.0;
    if (d > 0.0) {
        // Same precedence as the server's chained np.where: blue, then green, then red.
        if (mx == c.b) h = (c.r - c.g) / d + 4.0;
        else if (mx == c.g) h = (c.b - c.r) / d + 2.0;
        else h = fmodp((c.g - c.b) / d, 6.0);
        h *= 60.0;
        if (h < 0.0) h += 360.0;
    }
    return float3(h, s, l);
}

static float3 hsl2rgb(float3 hsl) {
    float h = fmodp(hsl.x, 360.0);
    float s = clamp(hsl.y, 0.0, 1.0);
    float l = clamp(hsl.z, 0.0, 1.0);
    float c = (1.0 - fabs(2.0 * l - 1.0)) * s;
    float hp = h / 60.0;
    float x = c * (1.0 - fabs(fmodp(hp, 2.0) - 1.0));
    float3 rgb;
    if (hp < 1.0) rgb = float3(c, x, 0.0);
    else if (hp < 2.0) rgb = float3(x, c, 0.0);
    else if (hp < 3.0) rgb = float3(0.0, c, x);
    else if (hp < 4.0) rgb = float3(0.0, x, c);
    else if (hp < 5.0) rgb = float3(x, 0.0, c);
    else rgb = float3(c, 0.0, x);
    return rgb + (l - c * 0.5);
}

static float bandWeight(float h, int i) {
    float delta = fmodp(h - HUE_CENTERS[i] + 180.0, 360.0) - 180.0;
    return clamp(1.0 - fabs(delta) / 60.0, 0.0, 1.0);
}

fragment float4 p3k_fragment(VOut in [[stage_in]],
                             texture2d<float> image [[texture(0)]],
                             texture3d<float> lut [[texture(1)]],
                             constant float *P [[buffer(0)]],
                             constant float *curve [[buffer(1)]]) {
    constexpr sampler smp(address::clamp_to_edge, filter::linear);

    // Geometry: output point (rotated + cropped frame) → source texture point.
    float2 r = float2(P[P_CROP], P[P_CROP + 1]) + in.uv * float2(P[P_CROP + 2], P[P_CROP + 3]);
    int rot = int(P[P_ROTATION] + 0.5);
    float2 q = r;
    if (rot == 90) q = float2(r.y, 1.0 - r.x);
    else if (rot == 180) q = float2(1.0 - r.x, 1.0 - r.y);
    else if (rot == 270) q = float2(1.0 - r.y, r.x);

    float3 c = image.sample(smp, q).rgb;
    if (P[P_ORIGINAL] > 0.5) return float4(c, 1.0);

    // White balance in linear light
    float t = P[P_TEMP], tint = P[P_TINT];
    if (t != 0.0 || tint != 0.0) {
        float3 lin = srgb2lin(c);
        lin *= float3(1.0 + 0.4 * t, 1.0 - 0.3 * tint, 1.0 - 0.4 * t);
        c = lin2srgb(lin);
    }

    // Exposure: a real EV step in linear light
    if (P[P_EXPOSURE] != 0.0) c = lin2srgb(srgb2lin(c) * exp2(P[P_EXPOSURE]));

    // Brightness: midtone gamma that pins black and white
    if (P[P_BRIGHTNESS] != 0.0) c = pow(max(c, float3(0.0)), float3(exp2(-P[P_BRIGHTNESS] * 0.7)));

    // Highlights / shadows
    if (P[P_HIGHLIGHTS] != 0.0 || P[P_SHADOWS] != 0.0) {
        float lu = dot(c, LUMA);
        c *= 1.0 + 0.5 * P[P_HIGHLIGHTS] * ss(0.5, 1.0, lu) + 0.5 * P[P_SHADOWS] * (1.0 - ss(0.0, 0.5, lu));
    }

    // Whites / blacks
    if (P[P_WHITES] != 0.0 || P[P_BLACKS] != 0.0) {
        float lu = dot(c, LUMA);
        c += 0.4 * P[P_WHITES] * ss(0.7, 1.0, lu) + 0.4 * P[P_BLACKS] * (1.0 - ss(0.0, 0.3, lu));
    }

    // Contrast around mid grey (gamma space, like Lightroom)
    if (P[P_CONTRAST] != 0.0) c = (c - 0.5) * (1.0 + P[P_CONTRAST]) + 0.5;

    // Tone curve: 256-entry table, floor index like numpy's astype(int)
    if (P[P_USE_CURVE] > 0.5) {
        int3 i = int3(clamp(c * 255.0, float3(0.0), float3(255.0)));
        c = float3(curve[i.r], curve[i.g], curve[i.b]);
    }

    if (P[P_SATURATION] != 0.0) {
        float lu = dot(c, LUMA);
        c = lu + (c - lu) * (1.0 + P[P_SATURATION]);
    }

    if (P[P_VIBRANCE] != 0.0) {
        float lu = dot(c, LUMA);
        float mx = max(max(c.r, c.g), c.b), mn = min(min(c.r, c.g), c.b);
        float sat = (mx - mn) / (mx + 1e-6);
        c = lu + (c - lu) * (1.0 + P[P_VIBRANCE] * (1.0 - sat) * 1.5);
    }

    // Colour mix: hue shift / saturation / luminance per band
    if (P[P_USE_HSL] > 0.5) {
        float3 hsl = rgb2hsl(c);
        float hs = 0.0, sm = 1.0, ls = 0.0;
        for (int i = 0; i < 8; i++) {
            float w = bandWeight(hsl.x, i);
            hs += w * P[P_HSL + i * 3] * 30.0;
            sm += w * P[P_HSL + i * 3 + 1];
            ls += w * P[P_HSL + i * 3 + 2] * 0.5;
        }
        c = hsl2rgb(float3(fmodp(hsl.x + hs, 360.0), clamp(hsl.y * sm, 0.0, 1.0), clamp(hsl.z + ls, 0.0, 1.0)));
    }

    // Dehaze
    if (P[P_DEHAZE] != 0.0) {
        float a = P[P_DEHAZE];
        float3 o = (c - 0.5) * (1.0 + 0.7 * a) + 0.5;
        float lu = dot(o, LUMA);
        o = lu + (o - lu) * (1.0 + 0.5 * a);
        float sw = clamp(1.0 - dot(c, LUMA), 0.0, 1.0);
        c = o + float3(-0.04, 0.0, 0.04) * (a * sw * 0.5);
    }

    // 3D LUT (HaldCLUT volume), sampled on cell centres
    if (P[P_USE_LUT] > 0.5) {
        float n = P[P_LUT_N];
        float3 cc = saturate(c);
        float3 l = lut.sample(smp, cc * ((n - 1.0) / n) + 0.5 / n).rgb;
        c = c + (l - c) * clamp(P[P_LUT_AMOUNT], 0.0, 1.0);
    }

    // Black & white, optionally weighted per hue band
    if (P[P_BW] > 0.0) {
        float lu = dot(c, LUMA);
        float mono = lu;
        if (P[P_USE_MIXER] > 0.5) {
            float3 hsl = rgb2hsl(c);
            float g = lu;
            for (int i = 0; i < 8; i++) g += bandWeight(hsl.x, i) * P[P_MIXER + i] * hsl.y * 0.30;
            mono = clamp(g, 0.0, 1.0);
        }
        float a = clamp(P[P_BW], 0.0, 1.0);
        c = c * (1.0 - a) + float3(mono) * a;
    }

    // Split toning
    float3 sh = float3(P[P_SPLIT_SH], P[P_SPLIT_SH + 1], P[P_SPLIT_SH + 2]);
    float3 hi = float3(P[P_SPLIT_HI], P[P_SPLIT_HI + 1], P[P_SPLIT_HI + 2]);
    if (any(sh != 0.0) || any(hi != 0.0)) {
        float lu = dot(c, LUMA);
        float pivot = clamp(0.5 + 0.4 * P[P_SPLIT_BAL], 0.05, 0.95);
        c += sh * (1.0 - ss(0.0, pivot, lu)) + hi * ss(pivot, 1.0, lu);
    }

    // Matte
    if (P[P_MATTE] > 0.0) {
        float m = clamp(P[P_MATTE], 0.0, 1.0);
        c = m + (1.0 - m) * c;
    }

    // Vignette — on the whole frame, before rotation and crop (as the server does)
    if (P[P_VIG_AMOUNT] != 0.0) {
        float rx = (q.x - 0.5) * 2.0, ry = (q.y - 0.5) * 2.0;
        rx *= 1.0 + (P[P_SRC_ASPECT] - 1.0) * (1.0 - P[P_VIG_ROUND]);
        float rr = sqrt(rx * rx + ry * ry);
        float feather = max(0.05, P[P_VIG_FEATHER]);
        float inner = P[P_VIG_MID] - feather * 0.5, outer = P[P_VIG_MID] + feather * 0.5;
        c *= 1.0 + P[P_VIG_AMOUNT] * ss(inner, outer, rr);
    }

    c = softShoulder(c);
    return float4(saturate(c), 1.0);
}
