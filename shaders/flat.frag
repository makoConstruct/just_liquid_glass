#version 460 core

// Flat shader: renders the same smooth-min merged blob field as glass.frag
// in one of three modes:
//   uMode == 0: fill — each blob painted with its (possibly transparent)
//               tint; the every-backend fallback look.
//   uMode == 1: mask — pure coverage alpha, used with ShaderMask(dstIn) to
//               clip the GlassLayer child to the blob silhouette.
//   uMode == 2: shine — the rim highlights only, composited above the masked
//               child in glass mode (premultiplied white; src-over acts as a
//               screen-toward-white blend).
// Runs as an ordinary canvas shader, so it works on every backend
// (Skia and Impeller) including web.
//
// NOTE: the SDF core (sdBlob / sceneD / scene) is duplicated in glass.frag.
// Keep both in sync. See glass.frag for the SkSL portability rules
// (no `break`, no fwidth, small smin sentinels).

#include <flutter/runtime_effect.glsl>

precision highp float;

// Set from Dart; float uniform indices start at 0.
uniform float uBlobCount;      // 0
uniform float uBlendRadius;    // 1
uniform float uMode;           // 2 (0 = fill, 1 = mask, 2 = shine)
uniform float uDpr;            // 3
uniform float uShineIntensity; // 4 (shine mode only)
uniform float uShineDirection; // 5 (shine mode only)
uniform float uBevelThickness; // 6 (shine mode only)

// 4 vec4 per blob, up to 16 blobs (float indices 7..262).
// Layout identical to glass.frag.
uniform vec4 uBlobs[64];

out vec4 fragColor;

// ---------------------------------------------------------------------------
// SDF core (keep in sync with glass.frag)
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

void main() {
  vec2 p = FlutterFragCoord().xy;

  vec4 tint;
  float d = scene(p, tint);

  vec4 outCol = vec4(0.0);
  if (d < 2.0) {
    // Gradient of the merged field; see glass.frag for why the epsilon
    // widens in shine mode and why the magnitude stays unnormalized.
    // Mask mode runs over the whole child layer every frame, so it skips
    // the gradient (4 extra field evaluations) and accepts slightly wider
    // AA where merges compress the field.
    vec2 g = vec2(0.0, 1.0);
    float gm = 1.0;
    if (uMode < 0.5 || uMode > 1.5) {
      float eps = uMode > 1.5 ? max(1.0, 0.4 * uBevelThickness) : 1.0;
      g = vec2(
          sceneD(p + vec2(eps, 0.0)) - sceneD(p - vec2(eps, 0.0)),
          sceneD(p + vec2(0.0, eps)) - sceneD(p - vec2(0.0, eps))) /
          (2.0 * eps);
      gm = length(g);
    }
    float slope = clamp(gm, 0.0, 1.0);

    // AA band scaled by the field gradient: ~1.5 physical px on screen no
    // matter how compressed or relaxed the field is locally.
    float w = max(0.75 * slope / uDpr, 1e-3);
    float coverage = 1.0 - smoothstep(-w, w, d);

    if (uMode > 1.5) {
      // Shine: long thin highlight arcs hugging the rim, iOS-26 style.
      // Follows liquid_glass_renderer's render.glsl conventions: the band is
      // a ~1.5px Lorentzian around d == 0 (radially hard-edged, independent
      // of bevel width), while the angular lobes are broad — influence is
      // dot(n, L) merely squared, with a counter-lobe opposite the light at
      // 0.8x. The outer half of the band is cut by coverage, giving the
      // crisp outer edge.
      vec2 n = g / max(gm, 1e-4);
      vec2 lightDir = vec2(cos(uShineDirection), -sin(uShineDirection));
      float influence = max(dot(n, lightDir), 0.0) +
          0.8 * max(dot(n, -lightDir), 0.0);
      float x = d / 1.5;
      float rimFactor = 1.0 / (1.0 + 0.89 * x * x);
      // slope (unnormalized |gradient|) still zeroes the shine on merge
      // necks — the pinch fix; see glass.frag.
      float s = clamp(1.4 * uShineIntensity * influence * influence *
          rimFactor * slope, 0.0, 1.0) * coverage;
      outCol = vec4(s); // premultiplied white
    } else if (uMode > 0.5) {
      outCol = vec4(coverage); // premultiplied white; dstIn uses the alpha
    } else {
      float alpha = coverage * clamp(tint.a, 0.0, 1.0);
      outCol = vec4(tint.rgb * alpha, alpha); // premultiplied tint fill
    }
  }

  fragColor = outCol;
}
