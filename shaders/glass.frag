#version 460 core

// Full liquid-glass backdrop shader. Applied via ImageFilter.shader inside a
// BackdropFilter (Impeller only). Blob geometry is evaluated analytically as
// a smooth-min merged signed distance field; refraction and tint happen in
// this single pass, so no intermediate textures are created by this library.
//
// Blur is NOT done here: the Dart side composes this filter with an inner
// ImageFilter.blur, so uTexture arrives pre-blurred by the engine's
// downsampled gaussian (which stays sharp-cost at any radius, unlike a
// tap loop in this pass). The output is premultiplied coverage: transparent
// outside the blobs, so the BackdropFilter's srcOver composite keeps the
// sharp, unblurred backdrop visible there. Requires Flutter >= 3.41
// (flutter#170820, fixed by flutter#177687: composing blur with a runtime
// effect used to shift the shader's coordinate system).
//
// NOTE: the SDF core (sdBlob / sceneD / scene) is duplicated in flat.frag.
// Keep both in sync.
//
// SkSL portability (verified by test/sdf_field_test.dart and probes):
//  * `break` in loops is silently miscompiled — guard iterations with `if`.
//  * fwidth/dFdx are unavailable — AA uses the analytic field gradient.
//  * Keep smooth-min sentinels small: mix() near 1e9 quantizes to f32 ulp 64.

#include <flutter/runtime_effect.glsl>

precision highp float;

// Set by the engine: size of the backdrop texture in physical pixels.
// The filter is clipped to the blobs' bounding region for performance, but
// on Impeller both this texture and FlutterFragCoord() stay anchored to the
// full render target — the clip only limits which fragments run, so it
// needs no compensation in the *coordinate* mapping. It does limit the
// texture's *content*: with the composed inner blur, uTexture is the blur's
// output, which the engine only computes inside the clip — beyond it (the
// texture can span the whole clip even where the clip overhangs the render
// target) lie uninitialized texels. Sampling must stay inside uClip below.
// The GlassLayer's own offset within the render target also needs
// compensating: that's uOrigin (a GlassLayer away from the target origin
// otherwise evaluates the field in the wrong place — usually entirely
// outside the clip, i.e. invisible).
uniform vec2 uSize;

// Set from Dart; float uniform indices start at 2.
// (Shine is rendered by flat.frag in shine mode, composited above the
// masked child, so it is not part of this pass.)
uniform float uDpr;            // 2
uniform float uBlobCount;      // 3
uniform float uBlendRadius;    // 4
uniform float uBevelThickness; // 5
uniform float uRefraction;     // 6

// The GlassLayer's origin within the render target, in logical pixels.
// FlutterFragCoord() is anchored to the full render target, but blob centers
// are in GlassLayer-local coordinates; this converts between the two.
uniform vec2 uOrigin;          // 7, 8

// The effective clip of this filter (padded blob bounds intersected with
// the GlassLayer and the render target; set at paint time alongside
// uOrigin), LTRB in logical GlassLayer-local pixels. uTexture has no valid
// content outside it (see uSize note), so backdrop samples are clamped into
// this rect.
uniform vec4 uClip;            // 9..12

// Edge tint: a separate color layered over the base tint near the
// silhouette, strongest at the rim (see the Beer-Lambert note in main).
// Alpha scales the strength; fully transparent disables it.
uniform vec4 uEdgeTint;        // 13..16

// 4 vec4 per blob, up to 16 blobs (float indices 17..272):
//   [0] center.x, center.y, cos(rotation), sin(rotation)
//   [1] radii.x, radii.y, cornerRadius, holeRadius (<= 0 means no hole)
//   [2] sectorAxis.x, sectorAxis.y, cos(halfAperture) (-2 = full circle),
//       sin(halfAperture) (negative = circular ring segment with round caps)
//   [3] tint r, g, b, a
uniform vec4 uBlobs[64];

// Set by the engine: the backdrop, pre-blurred by the composed inner
// ImageFilter.blur when blurRadius > 0.
uniform sampler2D uTexture;

out vec4 fragColor;

vec4 sampleBg(vec2 uv) {
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(uTexture, clamp(uv, vec2(0.0), vec2(1.0)));
}

// ---------------------------------------------------------------------------
// SDF core (keep in sync with flat.frag)
// ---------------------------------------------------------------------------

float sdBlob(vec2 p, vec4 a, vec4 b, vec4 c) {
  // Into the blob's local frame.
  vec2 q = p - a.xy;
  q = vec2(a.z * q.x + a.w * q.y, -a.w * q.x + a.z * q.y);

  // Sector frame: component along the sector axis, |perpendicular| (folded).
  float along = c.x * q.x + c.y * q.y;
  float perp = abs(c.x * q.y - c.y * q.x);

  float d;
  if (c.w < 0.0) {
    // Circular ring segment with round end caps: distance to the centerline
    // arc minus half the ring thickness (iq's sdArc).
    float rOut = min(b.x, b.y);
    float ra = 0.5 * (rOut + b.w); // centerline radius
    float rb = 0.5 * (rOut - b.w); // half thickness
    vec2 w2 = vec2(perp, along);
    vec2 sc = vec2(abs(c.w), c.z); // (sin, cos) of half aperture
    float dc = (sc.y * w2.x > sc.x * w2.y)
        ? length(w2 - sc * ra) // past the angular extent: nearest endpoint
        : abs(length(w2) - ra);
    d = dc - rb;
  } else {
    // Rounded box; cornerRadius is pre-clamped to min(radii) on the CPU, so
    // cornerRadius == min(radii) yields a stadium/circle.
    float r = b.z;
    vec2 e = abs(q) - (b.xy - vec2(r));
    d = length(max(e, vec2(0.0))) + min(max(e.x, e.y), 0.0) - r;

    // Circular hole around the blob center.
    if (b.w > 0.0) {
      d = max(d, b.w - length(q));
    }

    // Angular sector clip (hard cut) for non-circular or hole-less blobs.
    if (c.z > -1.5) {
      vec2 w2 = vec2(along, perp);
      vec2 ray = vec2(c.z, c.w); // boundary ray at +halfAperture
      float t = max(dot(w2, ray), 0.0);
      float dist = length(w2 - ray * t);
      float side = ray.x * w2.y - ray.y * w2.x;
      d = max(d, side > 0.0 ? dist : -dist);
    }
  }
  return d;
}

float sceneD(vec2 p) {
  float k = max(uBlendRadius, 1e-4);
  float d = 1e4; // sentinel kept small: mix() at 1e9 quantizes to f32 ulp of 64
  for (int i = 0; i < 16; i++) {
    if (float(i) < uBlobCount) {
      float di =
          sdBlob(p, uBlobs[i * 4], uBlobs[i * 4 + 1], uBlobs[i * 4 + 2]);
      float h = clamp(0.5 + 0.5 * (d - di) / k, 0.0, 1.0);
      d = mix(d, di, h) - k * h * (1.0 - h);
    }
  }
  return d;
}

float scene(vec2 p, out vec4 tint) {
  float k = max(uBlendRadius, 1e-4);
  float d = 1e4; // sentinel kept small: mix() at 1e9 quantizes to f32 ulp of 64
  tint = vec4(0.0);
  for (int i = 0; i < 16; i++) {
    if (float(i) < uBlobCount) {
      float di =
          sdBlob(p, uBlobs[i * 4], uBlobs[i * 4 + 1], uBlobs[i * 4 + 2]);
      float h = clamp(0.5 + 0.5 * (d - di) / k, 0.0, 1.0);
      d = mix(d, di, h) - k * h * (1.0 - h);
      // ease-in-out so the tint gradient is C1 at the blend-band edges;
      // geometry must keep linear h (polynomial smin assumes it)
      float hc = h * h * (3.0 - 2.0 * h);
      tint = mix(tint, uBlobs[i * 4 + 3], hc);
    }
  }
  return d;
}

// ---------------------------------------------------------------------------
// Glass rendering
// ---------------------------------------------------------------------------

void main() {
  vec2 fragPx = FlutterFragCoord().xy;
  vec2 p = fragPx / uDpr - uOrigin; // logical GlassLayer-local coordinates

  vec4 tint;
  float d = scene(p, tint);

  // Premultiplied output. Transparent outside the blobs: uTexture may be
  // pre-blurred, and the srcOver composite is what restores the sharp
  // backdrop there — this pass must not repaint it.
  vec4 outCol = vec4(0.0);

  if (d < 2.0) {
    // Gradient of the merged field. The epsilon widens with the bevel so the
    // medial-axis ridge inside thin necks is sampled smoothly, and we keep
    // the *unnormalized* magnitude: it dips to zero on ridges (where the two
    // sides' bevels meet), so refraction and shine fade out there instead of
    // flipping into a spike.
    float eps = max(1.0, 0.4 * uBevelThickness);
    vec2 g = vec2(
        sceneD(p + vec2(eps, 0.0)) - sceneD(p - vec2(eps, 0.0)),
        sceneD(p + vec2(0.0, eps)) - sceneD(p - vec2(0.0, eps))) /
        (2.0 * eps);
    float gm = length(g);
    vec2 n = g / max(gm, 1e-4);
    float slope = clamp(gm, 0.0, 1.0);

    // AA band scaled by the field gradient: ~1.5 physical px on screen no
    // matter how compressed or relaxed the field is locally.
    float w = max(0.75 * slope / uDpr, 1e-3);
    float coverage = 1.0 - smoothstep(-w, w, d);

    if (coverage > 0.001) {
      // Rim factor: 1 at the silhouette, falling to 0 at bevelThickness in.
      float rim = 1.0 - clamp(-d / max(uBevelThickness, 1e-3), 0.0, 1.0);

      // Refraction: look BACK into the blob, not outward. A thick slab with
      // a rounded edge bends the view toward the interior, squeezing inside
      // content into the rim band; with a circular edge profile the
      // deflection diverges at the silhouette (the 1/sqrt term, capped by
      // its epsilon). The smoothstepped numerator keeps the onset C1 where
      // the bevel band starts — a plain `rim` kinks visibly there. Sampling
      // inward also keeps displaced samples away from the clip/screen edge.
      // `slope` still zeroes it on merge necks (the pinch fix).
      float ease = rim * rim * (3.0 - 2.0 * rim);
      float deflect = ease / sqrt(max(1.0 - rim * rim, 0.04));
      vec2 sp = p - n * (uRefraction * deflect * slope);
      // The texture has no valid content outside uClip (see its note), so
      // clamp the sample into it, inset a pixel to keep bilinear taps off
      // the boundary texel.
      vec2 lo = uClip.xy + 1.0;
      sp = clamp(sp, lo, max(uClip.zw - 1.0, lo));
      vec4 bg = sampleBg((sp + uOrigin) * uDpr / uSize);

      vec3 col = mix(bg.rgb, tint.rgb, clamp(tint.a, 0.0, 1.0));

      // Edge tint: deepens toward the silhouette like the absorption of
      // real tinted glass — which is also what keeps the silhouette legible
      // over a same-colored backdrop (white on white), where refraction
      // alone vanishes. Weighted by the eased rim, NOT the refraction's
      // diverging deflect curve: that one concentrates everything in the
      // last couple of pixels, while `ease` spreads the tint evenly across
      // the whole bevel band (bevelThickness is the width knob). `slope`
      // fades it on merge necks like everything else.
      col = mix(col, uEdgeTint.rgb,
          clamp(uEdgeTint.a, 0.0, 1.0) * ease * slope);

      outCol = vec4(min(col, vec3(1.0)) * coverage, coverage);
    }
  }

  fragColor = outCol;
}
