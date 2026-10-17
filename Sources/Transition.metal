// Wallpaper renderer: draws the stacked video (original on the top half,
// glass version on the bottom) aspect-filled to the screen, and the
// transitions between the two halves.
//   style 0: crossfade
//   style 1: storm rewind  - gold clock face, hands spinning backward, a
//            clockwise sweep reveal, sepia + grain, rain that falls upward
//   style 2: world-line shift - nixie-tube digits scramble and lock, then an
//            RGB-split / slice glitch swaps the world underneath
//   style 3: world-line 2 - fast geometric break, perspective flight through
//            mathematical diagrams, then a fractured reveal
// On top of every style: the music glow along the bottom edge, with rising
// embers, driven by Spotify's audio (GlowController.swift).
// Compiled at runtime by TransitionRenderer.swift.
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 viewSize;
    float2 videoSize;   // one half of the stacked file
    float time;         // seconds, drives noise and flicker
    float progress;     // 0..1 through the transition
    float fromSource;   // 0 = original, 1 = glass
    float toSource;
    float style;
    float digitCount;
    float pad0;
    float pad1;
    float4 digits[3];   // 0-9 digits, 10 = decimal point
    float4 glowColorA;  // rgb
    float4 glowColorB;  // rgb
    float4 glowParams;  // presence 0..1, energy 0..1, beat 0..1, ember clock (beats)
    float4 glowShape;   // height (fraction of screen), spark count, intensity, unused
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;  // 0..1, origin top-left
};

constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);

constant float TAU = 6.28318530718;
constant float3 GOLD = float3(1.0, 0.82, 0.52);
constant float3 RAIN = float3(0.85, 0.9, 1.0);
constant float3 NIXIE_CORE = float3(1.0, 0.78, 0.5);
constant float3 NIXIE_GLOW = float3(1.0, 0.36, 0.06);
constant float ATLAS_CELLS = 11.0;
constant float NIXIE_CELL_ASPECT = 96.0 / 144.0;  // matches DigitAtlas cell size
constant float SPARK_SPREAD = 1.2;        // launch angle range, radians (about +-34 degrees)
constant float SPARK_DRAG = 1.6;          // per beat: sparks shoot out, then slow down
constant float SPARK_BUOYANCY = 0.02;     // slow upward float once they've slowed, per beat
constant float SPARK_CURL = 0.02;         // sideways turbulence that grows with age
constant float SPARK_MAX_HEIGHT = 0.45;   // nothing above this, so skip the loop

vertex VertexOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

float hash11(float n) { return fract(sin(n) * 43758.5453); }
float hash21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

// Aspect-fill: screen uv -> uv inside one half of the stacked video
float2 coverUV(float2 uv, constant Uniforms& u) {
    float viewAspect = u.viewSize.x / u.viewSize.y;
    float videoAspect = u.videoSize.x / u.videoSize.y;
    if (viewAspect > videoAspect) return float2(uv.x, 0.5 + (uv.y - 0.5) * videoAspect / viewAspect);
    return float2(0.5 + (uv.x - 0.5) * viewAspect / videoAspect, uv.y);
}

// Clamped inside the chosen half so the other half never bleeds in
// The video arrives as the decoder's own 4:2:0 planes (luma + interleaved
// chroma, BT.709 video range), converted here: about a third of the memory
// of full-color frames, and no conversion pass before the GPU sees it
float3 sampleSource(texture2d<float> luma, texture2d<float> chroma, float2 vuv, float source) {
    float2 st = float2(clamp(vuv.x, 0.0, 1.0), clamp(vuv.y, 0.002, 0.998) * 0.5 + source * 0.5);
    float y = (luma.sample(linearClamp, st).r - 16.0 / 255.0) * (255.0 / 219.0);
    float2 c = (chroma.sample(linearClamp, st).rg - 128.0 / 255.0) * (255.0 / 224.0);
    return saturate(float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x));
}

// Integral of smoothstep(a, b, t) dt from 0 to x
float smoothstepIntegral(float a, float b, float x) {
    if (x <= a) return 0.0;
    float w = b - a;
    if (x >= b) return w * 0.5 + (x - b);
    float t = (x - a) / w;
    return w * (t * t * t - 0.5 * t * t * t * t);
}

// Soft line from the center along a clock angle (0 = 12 o'clock, clockwise)
float clockHand(float2 c, float angle, float len, float width) {
    float2 dir = float2(sin(angle), -cos(angle));
    float h = clamp(dot(c, dir) / len, 0.0, 1.0);
    return exp(-pow(length(c - dir * len * h) / width, 2.0));
}

float3 stormRewind(float2 uv, float2 vuv, texture2d<float> luma, texture2d<float> chroma, constant Uniforms& u) {
    float p = u.progress;
    float env = smoothstep(0.0, 0.15, p) * (1.0 - smoothstep(0.82, 1.0, p));
    float2 c = (uv - 0.5) * float2(u.viewSize.x / u.viewSize.y, 1.0);
    float r = length(c);
    float a = fract(atan2(c.x, -c.y) / TAU + 1.0);

    // Clockwise reveal led by the minute hand
    float sweep = smoothstep(0.12, 0.85, p) * 1.02;
    float reveal = smoothstep(a - 0.006, a + 0.006, sweep);
    float3 col = mix(sampleSource(luma, chroma, vuv, u.fromSource), sampleSource(luma, chroma, vuv, u.toSource), reveal);

    // Sepia "memory" tint and vignette
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = mix(col, float3(lum * 1.07, lum * 0.9, lum * 0.7), 0.55 * env);
    col *= 1.0 - 0.4 * env * smoothstep(0.25, 0.95, r);

    // Clock face: rings, ticks, a minute hand on the sweep, an hour hand spinning backward
    float R = 0.36;
    float rings = exp(-pow((r - R) / 0.0022, 2.0)) * 0.9 + exp(-pow((r - R * 0.9) / 0.0012, 2.0)) * 0.45;
    float minorTick = step(abs(fract(a * 60.0 + 0.5) - 0.5), 0.06) * step(R * 0.93, r) * step(r, R * 0.975);
    float majorTick = step(abs(fract(a * 12.0 + 0.5) - 0.5), 0.02) * step(R * 0.86, r) * step(r, R * 0.975);
    float hands = clockHand(c, sweep * TAU, R * 0.86, 0.0028)
                + clockHand(c, -p * 3.0 * TAU, R * 0.55, 0.004)
                + exp(-pow(r / 0.009, 2.0));
    float clock = (rings + minorTick * 0.5 + majorTick * 0.85 + hands) * env;
    col = col * (1.0 - 0.18 * env * step(r, R)) + GOLD * clock * 0.85;

    // Glow along the sweeping edge
    float edge = fract(a - sweep + 0.5) - 0.5;
    col += GOLD * exp(-abs(edge * TAU * r) * 220.0) * env * 0.5 * step(sweep, 1.0);

    // Rain falls, slows, hangs in the air, then falls upward
    float travel = (p - 2.0 * smoothstepIntegral(0.25, 0.55, p)) * 2.2;
    float rain = 0.0;
    for (int layer = 0; layer < 2; layer++) {
        float columns = layer == 0 ? 90.0 : 160.0;
        float cx = floor(uv.x * columns);
        if (hash11(cx + 3.1 + float(layer) * 7.0) < 0.5) continue;
        float rnd = hash11(cx * 1.7 + float(layer) * 31.0);
        float speed = (0.6 + rnd * 0.8) * (layer == 0 ? 1.0 : 0.6);
        float head = fract(rnd * 7.0 + travel * speed);
        float dist = abs(fract(uv.y - head + 0.5) - 0.5);
        float len = 0.04 + rnd * 0.05;
        float thin = exp(-pow((fract(uv.x * columns) - 0.5) / 0.07, 2.0));
        rain += (1.0 - smoothstep(0.0, len, dist)) * thin * (layer == 0 ? 0.4 : 0.22);
    }
    col += RAIN * rain * env;

    // Film grain and projector flicker
    col += (hash21(uv * u.viewSize + floor(u.time * 24.0)) - 0.5) * 0.09 * env;
    col *= 1.0 + 0.04 * env * sin(u.time * 47.0);
    return col;
}

float sdRoundBox(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

// Row of nixie tubes centered on screen; digits scramble, then lock left to right
float3 nixieTubes(float2 uv, constant Uniforms& u, texture2d<float> atlas, float env) {
    int count = int(u.digitCount);
    float2 c = (uv - 0.5) * float2(u.viewSize.x / u.viewSize.y, 1.0);
    float cellH = 0.13;
    float cellW = cellH * NIXIE_CELL_ASPECT;
    float pitch = cellW * 1.12;
    float lx = c.x + pitch * float(count) * 0.5;
    int i = int(floor(lx / pitch));
    if (i < 0 || i >= count) return float3(0.0);
    float2 local = float2(fract(lx / pitch) * pitch / cellW, (c.y + cellH * 0.5) / cellH);

    // Faint glass tube outline
    float sd = sdRoundBox((local - 0.5) * float2(cellW, cellH), float2(cellW * 0.5, cellH * 0.56), cellW * 0.3);
    float3 light = float3(0.6, 0.55, 0.5) * exp(-pow(sd / 0.0015, 2.0)) * 0.18;
    if (local.x > 1.0 || local.y < 0.0 || local.y > 1.0) return light * env;

    float target = u.digits[i / 4][i % 4];
    float shown = target;
    if (target < 10.0 && u.progress < 0.16 + float(i) * 0.045) {
        shown = floor(hash11(float(i) * 13.1 + floor(u.time * 28.0)) * 10.0);
    }
    float2 glyph = atlas.sample(linearClamp, float2((shown + local.x) / ATLAS_CELLS, local.y)).rg;
    // Unlit cathodes stacked behind the lit one
    float ghost = atlas.sample(linearClamp, float2((8.0 + local.x) / ATLAS_CELLS, local.y)).r * step(target, 9.5);
    float flicker = 0.88 + 0.12 * hash11(float(i) * 3.7 + floor(u.time * 40.0));
    light += (NIXIE_CORE * glyph.r * 1.3 + NIXIE_GLOW * glyph.g * 1.1) * flicker + NIXIE_GLOW * ghost * 0.08;
    return light * env;
}

float3 worldLineShift(float2 uv, float2 vuv, texture2d<float> luma, texture2d<float> chroma, texture2d<float> atlas,
                      constant Uniforms& u) {
    float p = u.progress;
    float dim = smoothstep(0.0, 0.12, p) * (1.0 - smoothstep(0.82, 0.96, p));
    // Tubes stutter as they power down
    float tubes = dim * (p > 0.72 ? step(0.3, hash11(floor(u.time * 22.0))) : 1.0);
    float glitch = exp(-pow((p - 0.6) / 0.07, 2.0));

    // Horizontal slices swap to the new world one by one, jittering sideways
    float frame = floor(u.time * 30.0);
    float band = floor(uv.y * 36.0);
    float source = hash21(float2(band, frame)) < smoothstep(0.52, 0.68, p) ? u.toSource : u.fromSource;
    float jitter = step(0.55, hash21(float2(band * 1.3, floor(u.time * 15.0))));
    float2 g = vuv + float2((hash21(float2(band, frame) + 0.37) - 0.5) * 0.12 * glitch * jitter, 0.0);

    // RGB split, scanlines, static
    float split = 0.012 * glitch + 0.0015 * dim;
    float3 col = float3(sampleSource(luma, chroma, g + float2(split, 0.0), source).r,
                        sampleSource(luma, chroma, g, source).g,
                        sampleSource(luma, chroma, g - float2(split, 0.0), source).b);
    col *= 1.0 - 0.2 * glitch * (0.5 + 0.5 * sin(uv.y * u.viewSize.y * 3.14159));
    col = mix(col, float3(hash21(uv * u.viewSize + u.time * 97.0)), 0.28 * glitch);

    // Dim and warm the scene so the tubes read
    col = mix(col, col * float3(0.75, 0.55, 0.45), 0.55 * dim);
    return col + nixieTubes(uv, u, atlas, tubes);
}

// Signed distance to a finite line segment, used for the etched drafting marks.
float wl2Segment(float2 p, float2 a, float2 b) {
    float2 v = b - a;
    return length(p - a - v * clamp(dot(p - a, v) / max(dot(v, v), 1e-5), 0.0, 1.0));
}

float wl2Stroke(float distance, float width, float pixel) {
    return 1.0 - smoothstep(width, width + pixel * 1.3, distance);
}

// A sheet carries a different construction drawing. The coordinates are in a
// common 3D world: perspective, parallax, and sheets passing the lens therefore
// come from camera motion instead of enlarging a flat image.
float wl2Diagram(float2 q, int kind, float pixel) {
    float2 p = q;
    float r = length(p);
    float a = atan2(p.y, p.x);
    float ink = 0.0;
    float thin = max(pixel * 0.8, 0.004);
    float fine = max(pixel * 0.55, 0.0025);

    // Drafting grid and crosshairs, interrupted by large circular constructs.
    float2 grid = abs(fract(p * (kind == 1 ? 3.0 : 2.0) + 0.5) - 0.5) / (kind == 1 ? 3.0 : 2.0);
    ink += 0.19 * wl2Stroke(min(grid.x, grid.y), fine * 0.55, pixel) * (1.0 - smoothstep(0.8, 1.8, r));
    ink += 0.38 * wl2Stroke(min(abs(p.x), abs(p.y)), thin * 0.55, pixel) * (1.0 - smoothstep(1.6, 2.3, r));

    if (kind == 0) {
        // Concentric arcs, tangent construction, degree spokes and tick scale.
        ink += 0.85 * wl2Stroke(abs(r - 0.72), thin, pixel);
        ink += 0.52 * wl2Stroke(abs(r - 1.12), fine, pixel);
        ink += 0.64 * wl2Stroke(abs(length(p - float2(0.34, -0.22)) - 0.57), fine, pixel);
        float spoke = abs(sin(a * 12.0));
        ink += 0.3 * wl2Stroke(spoke * r, fine * 1.3, pixel) * step(0.74, r) * (1.0 - step(1.2, r));
        float tick = abs(sin(a * 48.0));
        ink += 0.55 * wl2Stroke(tick * r, fine, pixel) * step(1.10, r) * (1.0 - step(1.19, r));
        ink += 0.55 * wl2Stroke(wl2Segment(p, float2(-1.3, -0.65), float2(1.3, 0.65)), thin, pixel);
    } else if (kind == 1) {
        // Phase plot and three families of curves on an analytical grid.
        float y0 = 0.36 * sin(p.x * 3.8 + 0.4);
        float y1 = 0.63 * cos(p.x * 2.1 - 0.6);
        float y2 = 0.17 * p.x * p.x - 0.55;
        float inPlot = (1.0 - step(1.75, abs(p.x))) * (1.0 - step(1.15, abs(p.y)));
        ink += inPlot * (0.95 * wl2Stroke(abs(p.y - y0), thin, pixel)
                       + 0.66 * wl2Stroke(abs(p.y - y1), fine, pixel)
                       + 0.58 * wl2Stroke(abs(p.y - y2), fine, pixel));
        ink += 0.75 * wl2Stroke(abs(max(abs(p.x) - 1.78, abs(p.y) - 1.18)), thin, pixel);
        float2 ticks = abs(fract(p * 5.0 + 0.5) - 0.5) / 5.0;
        ink += 0.45 * wl2Stroke(ticks.x, fine, pixel) * (1.0 - step(0.055, abs(p.y))) * inPlot;
        ink += 0.45 * wl2Stroke(ticks.y, fine, pixel) * (1.0 - step(0.055, abs(p.x))) * inPlot;
    } else if (kind == 2) {
        // Oblique orbital ellipses and a triangulated measurement frame.
        float2 e = float2(p.x * 0.83 + p.y * 0.56, -p.x * 0.56 + p.y * 0.83);
        ink += 0.85 * wl2Stroke(abs(length(e * float2(0.72, 1.43)) - 0.95), thin, pixel);
        ink += 0.66 * wl2Stroke(abs(length(e * float2(1.31, 0.69)) - 1.13), fine, pixel);
        ink += 0.5 * wl2Stroke(abs(r - 0.24), thin, pixel);
        ink += 0.65 * wl2Stroke(wl2Segment(p, float2(-1.35, 0.75), float2(0.0, -1.35)), fine, pixel);
        ink += 0.65 * wl2Stroke(wl2Segment(p, float2(0.0, -1.35), float2(1.35, 0.75)), fine, pixel);
        ink += 0.65 * wl2Stroke(wl2Segment(p, float2(1.35, 0.75), float2(-1.35, 0.75)), fine, pixel);
    } else {
        // Perspective-looking polar lattice and repeating ratio marks.
        ink += 0.80 * wl2Stroke(abs(r - 0.53), thin, pixel);
        ink += 0.52 * wl2Stroke(abs(r - 0.97), fine, pixel);
        ink += 0.40 * wl2Stroke(abs(r - 1.43), fine, pixel);
        ink += 0.43 * wl2Stroke(abs(sin(a * 18.0)) * r, fine, pixel) * step(0.4, r) * (1.0 - step(1.55, r));
        float spiral = r - (0.28 + 0.15 * (a + 3.14159));
        ink += 0.56 * wl2Stroke(abs(spiral), fine, pixel) * step(0.0, spiral + 0.05);
        ink += 0.75 * wl2Stroke(wl2Segment(p, float2(-1.4, -1.0), float2(1.4, 1.0)), fine, pixel);
    }

    // Calibration squares, tiny index bars and registration dots add the fine
    // mathematical texture visible in the reference's white diagram shots.
    float2 cell = fract((p + float2(0.17, 0.11)) * 3.2) - 0.5;
    float2 id = floor((p + float2(0.17, 0.11)) * 3.2);
    float selected = step(0.78, hash21(id + float2(float(kind) * 13.0, 3.7)));
    float indexMark = min(abs(cell.y - 0.23), abs(cell.y - 0.30));
    ink += selected * 0.28 * wl2Stroke(indexMark, fine * 0.4, pixel) * (1.0 - step(0.24, abs(cell.x)));
    ink += selected * 0.32 * wl2Stroke(length(cell + float2(0.32, 0.18)), fine * 1.2, pixel);
    return saturate(ink);
}

// Cells fail at different instants. Their fragments shrink towards their own
// centers and are discarded, so neither background ever slides across screen.
float wl2Breakup(float2 uv, float p, bool entering, float time) {
    float2 cellPos = uv * float2(25.0, 15.0);
    float2 id = floor(cellPos);
    float2 local = fract(cellPos) - 0.5;
    float rnd = hash21(id + 17.0);
    float diagonal = 0.12 * (uv.x - uv.y);
    float threshold = entering ? (0.015 + rnd * 0.095 + diagonal * 0.3)
                               : (0.80 + rnd * 0.12 + diagonal * 0.25);
    float edge = entering ? smoothstep(threshold - 0.014, threshold + 0.014, p)
                          : smoothstep(threshold - 0.016, threshold + 0.016, p);
    float shard = max(abs(local.x), abs(local.y));
    float edgeNoise = hash21(id + floor(time * 28.0) * 0.27);
    float shardMask = smoothstep(0.34, 0.49, shard + edgeNoise * 0.12);
    return saturate(edge + shardMask * 0.11 * exp(-pow((p - threshold) / 0.025, 2.0)));
}

float3 worldLine2(float2 uv, float2 vuv, texture2d<float> luma, texture2d<float> chroma,
                  constant Uniforms& u) {
    float p = u.progress;
    float aspect = u.viewSize.x / u.viewSize.y;
    float frame = floor(u.time * 34.0);
    float2 tile = floor(uv * float2(42.0, 25.0));
    float entryGlitch = exp(-pow((p - 0.105) / 0.042, 2.0));
    float exitGlitch = exp(-pow((p - 0.86) / 0.047, 2.0));
    float midGlitch = 0.48 * exp(-pow((p - 0.39) / 0.022, 2.0))
                    + 0.55 * exp(-pow((p - 0.64) / 0.025, 2.0));
    float glitch = entryGlitch + exitGlitch + midGlitch;
    float band = floor(uv.y * 38.0);
    float bandGate = step(0.34, hash21(float2(band * 1.7, floor(u.time * 19.0))));
    float jitter = (hash21(float2(band, frame)) - 0.5) * 0.095 * glitch * bandGate;
    float2 sourceUV = vuv + float2(jitter, 0.0);
    float3 from = sampleSource(luma, chroma, sourceUV, u.fromSource);
    float3 to = sampleSource(luma, chroma, sourceUV, u.toSource);
    if (glitch > 0.015) {
        float split = (0.003 + 0.018 * glitch) * bandGate;
        from.r = sampleSource(luma, chroma, sourceUV + float2(split, 0.0), u.fromSource).r;
        from.b = sampleSource(luma, chroma, sourceUV - float2(split, 0.0), u.fromSource).b;
        to.r = sampleSource(luma, chroma, sourceUV + float2(split, 0.0), u.toSource).r;
        to.b = sampleSource(luma, chroma, sourceUV - float2(split, 0.0), u.toSource).b;
    }

    // Rapid breakout from the live wallpaper into a clean white drafting void.
    float inMask = wl2Breakup(uv, p, true, u.time);
    float outMask = wl2Breakup(uv, p, false, u.time);
    if (p < 0.005) return from;
    if (p > 0.99) return to;

    float2 screen = (uv - 0.5) * float2(aspect, 1.0);
    float flight = smoothstep(0.08, 0.88, p);
    float acceleration = pow(flight, 1.55);
    float zCamera = -0.9 + 16.4 * acceleration;
    float bank = 0.08 * sin(flight * 7.0) + 0.34 * sin(flight * 3.5 - 0.7);
    float2 banked = float2(screen.x * cos(bank) - screen.y * sin(bank),
                           screen.x * sin(bank) + screen.y * cos(bank));
    float lens = 1.49 - 0.38 * sin(flight * 3.14159) + 0.11 * flight;
    float3 ray = normalize(float3(banked * lens
                                  + float2(0.21 * sin(flight * 8.2), 0.13 * cos(flight * 6.4)),
                                   1.35));
    float2 cameraXY = float2(0.65 * sin(flight * 5.0), 0.48 * sin(flight * 7.2 + 0.7));

    // Far paper stays off-white. Near planes cast pale translucent shadows and
    // dark ink; as each plane passes the camera, the next comes into focus.
    float3 scene = float3(0.972, 0.971, 0.955);
    for (int layer = 7; layer >= 0; layer--) {
        float fi = float(layer);
        float depth = 1.2 + fi * 2.05 - zCamera;
        if (depth < 0.11 || depth > 6.5) continue;
        float2 world = cameraXY + ray.xy * (depth / max(ray.z, 0.12));
        float2 center = float2(0.58 * sin(fi * 2.31), 0.43 * cos(fi * 1.73));
        center += float2(0.18 * sin(flight * (4.0 + fi * 0.19) + fi),
                         0.15 * cos(flight * (3.4 + fi * 0.16) - fi));
        float spin = (layer % 2 == 0 ? 1.0 : -1.0) * (0.31 + 0.055 * fi);
        float angle = 0.22 * sin(fi * 2.0) + 0.2 * fi + spin * flight;
        float2 d = world - center;
        float2 q = float2(d.x * cos(angle) - d.y * sin(angle), d.x * sin(angle) + d.y * cos(angle));
        float edge = max(abs(q.x) / 2.55, abs(q.y) / 1.86);
        float paper = 1.0 - smoothstep(0.94, 1.04, edge);
        if (paper < 0.001) continue;
        float focus = smoothstep(0.12, 0.48, depth);
        float fadeFar = 1.0 - smoothstep(4.5, 6.5, depth);
        float pixel = depth / max(u.viewSize.y, 500.0) * 1.45;
        float ink = wl2Diagram(q, layer % 4, pixel);
        float border = wl2Stroke(abs(edge - 0.95), max(pixel, 0.003), pixel);
        float opacity = paper * focus * fadeFar * 0.86;
        scene = mix(scene, float3(0.988, 0.984, 0.972), opacity * 0.65);
        scene -= float3(0.29, 0.31, 0.34) * (ink * opacity + border * 0.18 * focus * fadeFar);
    }

    // A few free-standing lines produce foreground parallax and high-speed
    // streaks while passing the lens. A little temporal flutter removes the
    // mechanically steady look without replacing the camera's 3D motion.
    float2 fast = screen - float2(0.12 * sin(flight * 5.0), 0.08 * cos(flight * 6.0));
    float radius = length(fast);
    float bearing = atan2(fast.y, fast.x);
    float spoke = exp(-pow((fract(bearing * 23.0 + 0.07 * floor(flight * 72.0)) - 0.5) / 0.075, 2.0));
    float dash = exp(-pow((fract(radius * 3.5 - flight * 29.0) - 0.5) / 0.21, 2.0));
    float travelStreak = spoke * dash * smoothstep(0.13, 0.55, radius)
                       * smoothstep(0.08, 0.35, flight) * (1.0 - smoothstep(0.80, 0.94, flight));
    scene -= float3(0.11, 0.10, 0.13) * travelStreak * 0.38;
    float colorTravel = smoothstep(0.09, 0.30, p) * (1.0 - smoothstep(0.72, 0.91, p));
    float colorBand = 0.5 + 0.5 * sin(bearing * 3.0 + radius * 4.8 - flight * 11.0);
    scene = mix(scene, scene * mix(float3(0.91, 0.96, 1.08), float3(1.08, 0.91, 1.04), colorBand),
                0.43 * colorTravel);
    scene += (hash21(uv * u.viewSize + frame) - 0.5) * 0.075 * glitch;

    // RGB channel error and short white flashes punctuate both changes of
    // world. A block reveal replaces the final sheet with the target wallpaper.
    float flash = 0.26 * exp(-pow((p - 0.105) / 0.010, 2.0))
                + 0.22 * exp(-pow((p - 0.865) / 0.012, 2.0));
    float3 entering = mix(from, scene, inMask);
    float3 exiting = mix(entering, to, outMask);
    exiting += float3(flash) * glitch;
    float errorCell = hash21(tile + frame);
    float blackout = step(0.86, hash21(float2(band, frame * 0.31))) * bandGate;
    exiting *= 1.0 - 0.40 * glitch * blackout;
    exiting.r += 0.30 * glitch * (errorCell - 0.5);
    exiting.g += 0.10 * glitch * (hash21(tile + frame + 1.8) - 0.5);
    exiting.b -= 0.26 * glitch * (hash21(tile + frame + 3.2) - 0.5);
    return saturate(exiting);
}

// Soft elliptical light pool; `radii` in screen-height units
float lightPool(float2 p, float2 center, float2 radii) {
    float2 d = (p - center) / radii;
    return exp(-dot(d, d));
}

// Fire sparks: launched in small bursts on the beat at random angles, slowed by
// drag, then floating and curling in the heat; they cool from white-hot to the
// genre color and burn out early. Time is the ember clock, counted in beats, so
// everything moves at the song's tempo.
float3 embers(float2 p, float aspect, float pixel, constant Uniforms& u) {
    if (p.y > SPARK_MAX_HEIGHT) return float3(0.0);
    float clock = u.glowParams.w;
    float energy = u.glowParams.y;
    float beat = u.glowParams.z;
    float3 light = float3(0.0);
    int count = int(u.glowShape.y);
    for (int i = 0; i < count; i++) {
        float fi = float(i);
        // Whole-beat cycles and offsets, so every launch lands on a beat
        float cycle = 2.0 + floor(hash11(fi * 1.31) * 3.0);
        float local = clock - floor(hash11(fi * 2.17) * 4.0);
        float launch = floor(local / cycle);
        float t = local - launch * cycle;  // beats since launch
        float seed = fi * 17.0 + launch * 131.0;  // new randomness every launch
        float life = cycle * (0.45 + 0.4 * hash11(seed + 1.0));
        if (t > life || hash11(seed + 2.0) > 0.45 + 0.55 * energy) continue;
        float age = t / life;

        float angle = (hash11(seed + 3.0) - 0.5) * SPARK_SPREAD;
        float2 v0 = float2(sin(angle), cos(angle)) * (0.22 + 0.3 * hash11(seed + 4.0));
        float decay = exp(-SPARK_DRAG * t);
        float wobble = hash11(seed + 5.0) * TAU;
        float2 origin = float2(aspect * (0.08 + 0.84 * hash11(seed + 6.0)), 0.01 * hash11(seed + 7.0));
        float2 pos = origin + v0 * (1.0 - decay) / SPARK_DRAG
                   + float2(SPARK_CURL * t * sin(3.0 * t + wobble), SPARK_BUOYANCY * t);
        float2 velocity = v0 * decay + float2(
            SPARK_CURL * (sin(3.0 * t + wobble) + 3.0 * t * cos(3.0 * t + wobble)), SPARK_BUOYANCY);

        // Streak behind the spark along its direction of travel, longer while fast
        float speed = length(velocity);
        float2 dir = velocity / max(speed, 1e-4);
        float2 offset = p - pos;
        float along = dot(offset, dir);
        float across = dot(offset, float2(-dir.y, dir.x));
        float stretch = along < 0.0 ? 1.0 / (1.0 + speed * 25.0) : 1.0;
        float d = length(float2(along * stretch, across));

        float size = (1.0 + 1.6 * hash11(seed + 8.0)) * pixel * (1.0 - 0.5 * age);
        float flicker = 0.6 + 0.4 * sin(u.time * (25.0 + hash11(seed + 9.0) * 30.0) + fi * 7.0);
        float alpha = smoothstep(0.0, 0.03, age) * pow(1.0 - age, 1.5) * flicker * (1.0 + 0.4 * beat);
        float3 halo = mix(u.glowColorA.rgb, u.glowColorB.rgb, hash11(seed + 10.0));
        float3 core = mix(float3(1.0, 0.95, 0.82), halo, age * 0.7);  // cools as it ages
        light += (core * exp(-pow(d / size, 2.0)) * 1.3 + halo * exp(-d / (size * 6.0)) * 0.4) * alpha;
    }
    return light;
}

// Music glow along the bottom edge: drifting light pools that breathe with
// loudness and kick on beats, a bright rim at the very edge, and embers
float3 musicGlow(float2 uv, constant Uniforms& u) {
    float presence = u.glowParams.x;
    if (presence < 0.002) return float3(0.0);
    float energy = u.glowParams.y;
    float beat = u.glowParams.z;
    float aspect = u.viewSize.x / u.viewSize.y;
    float height = u.glowShape.x;
    float2 p = float2(uv.x * aspect, 1.0 - uv.y);  // y = 0 at the bottom edge
    float swell = 1.0 + 0.12 * beat + 0.08 * energy;
    float t = u.time;

    float poolA = lightPool(p, float2(aspect * (0.5 + 0.06 * sin(t * 0.33)), -0.12),
                            float2(aspect * 0.7, height * 0.9) * swell);
    float poolB = lightPool(p, float2(aspect * (0.31 + 0.05 * sin(t * 0.48)), -0.06),
                            float2(aspect * 0.25, height * 0.75) * swell);
    float poolC = lightPool(p, float2(aspect * (0.74 + 0.05 * sin(t * 0.27 + 1.0)), -0.08),
                            float2(aspect * 0.22, height * 0.7) * swell);
    float3 glow = u.glowColorA.rgb * poolA + u.glowColorB.rgb * (poolB + poolC);
    glow += u.glowColorA.rgb * exp(-p.y / 0.004) * 0.6;
    float strength = u.glowShape.z * (0.65 + 0.35 * energy + 0.4 * beat);
    float pixel = 1.0 / 900.0;  // ~1pt in height units on a ~900pt-tall screen
    return (glow * strength + embers(p, aspect, pixel, u)) * presence;
}

fragment float4 transitionFragment(VertexOut in [[stage_in]],
                                   constant Uniforms& u [[buffer(0)]],
                                   texture2d<float> luma [[texture(0)]],
                                   texture2d<float> chroma [[texture(2)]],
                                   texture2d<float> atlas [[texture(1)]]) {
    float2 vuv = coverUV(in.uv, u);
    int style = int(u.style + 0.5);
    float3 col;
    if (style == 1) {
        col = stormRewind(in.uv, vuv, luma, chroma, u);
    } else if (style == 2) {
        col = worldLineShift(in.uv, vuv, luma, chroma, atlas, u);
    // WORLDLINE2_SHADER_V1
    } else if (style == 3) {
        col = worldLine2(in.uv, vuv, luma, chroma, u);
    } else {
        // Idle (both sides the same half): one sample instead of two, same result
        float3 from = sampleSource(luma, chroma, vuv, u.fromSource);
        col = u.fromSource == u.toSource
            ? from
            : mix(from, sampleSource(luma, chroma, vuv, u.toSource), smoothstep(0.0, 1.0, u.progress));
    }
    // Screen blend: light adds without blowing out what's already bright
    float3 glow = saturate(musicGlow(in.uv, u));
    col = 1.0 - (1.0 - saturate(col)) * (1.0 - glow);
    return float4(col, 1.0);
}
