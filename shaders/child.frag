#version 460 core

// Child refraction shader: masks the GlassLayer child to the merged blob
// silhouette AND refracts it, in one pass. Applied via ImageFilter.shader on
// an ordinary ImageFilterLayer wrapping the child (Impeller only) — NOT a
// BackdropFilter, so it costs one offscreen texture of the clipped child
// region, never a render-target flip. On the glass path this pass replaces
// the flat.frag mask-mode ShaderMask entirely: coverage is evaluated at the
// destination fragment (the silhouette stays crisp) while the child's color
// is fetched from the displaced source (the content swims inside it), which
// is also exactly what dstIn masking did whenever uRefraction is 0.
//
// Coordinates: for a child (non-backdrop) runtime-effect filter, Impeller
// anchors FlutterFragCoord() and uTexture to the INPUT SNAPSHOT — fragment
// coords run [0, texture size] in physical pixels and uv = fragCoord / uSize
// samples identity (the engine's own runtime_stage_filter_example.frag
// convention; contrast glass.frag, whose backdrop texture is anchored to the
// full render target). The snapshot spans the child's accumulated painted
// bounds, which the Dart side pins to a known rect (uRegion, in
// GlassLayer-local logical px) by clipping the child to it and drawing
// anchor dots in its corners — see _RenderChildGlassFilter. uSize / region
// size is then the physical-per-logical scale, absorbing DPR and any
// ancestor scale per axis. No GLES y-flip: that flip in glass.frag
// compensates the flipped onscreen framebuffer, and filter inputs are
// offscreen snapshots (the engine's example filter samples unflipped).
//
// NOTE: the SDF core (sdBlob / sceneD) is duplicated in glass.frag and
// flat.frag (which additionally carry scene(), the tint variant this pass
// has no use for). Keep all three in sync. See glass.frag for the SkSL
// portability rules (no `break`, no fwidth, small smin sentinels).

#include <flutter/runtime_effect.glsl>

precision highp float;

// Set by the engine: size of the input texture (the child snapshot) in
// physical pixels.
uniform vec2 uSize;

// Set from Dart; float uniform indices start at 2.
uniform float uBlobCount;      // 2
uniform float uBlendRadius;    // 3
uniform float uBevelThickness; // 4
uniform float uRefraction;     // 5 (child refraction, not the backdrop's)

// The rect the input texture spans, LTRB in GlassLayer-local logical px —
// the same region the child is clipped to on the Dart side.
uniform vec4 uRegion;          // 6..9

// 6 vec4 per blob, up to 16 blobs (float indices 10..393).
// Layout identical to glass.frag.
uniform vec4 uBlobs[96];

// Set by the engine: the child, rendered into a texture.
uniform sampler2D uTexture;

out vec4 fragColor;

// ---------------------------------------------------------------------------
// SDF core (keep in sync with glass.frag / flat.frag)
// ---------------------------------------------------------------------------

float sdBlob(vec2 p, vec4 a, vec4 b, vec4 c, float squircle, vec4 se) {
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
    // cornerRadius == min(radii) yields a stadium/circle. A negative r is the
    // exit-lift encoding: it reduces the field to the point field lifted by
    // -min(radii).
    float r = b.z;
    float reach = r;
    vec2 e = abs(q) - (b.xy - vec2(r));
    float corner = length(max(e, vec2(0.0)));
    if (squircle > 0.0) {
      // Apple-style continuous corner, fitted to Flutter's RSuperellipse.
      // A fit, not that curve: Impeller's superellipse-plus-arc corner has
      // no closed-form distance, so it can't be an SDF (see cornerProfile in
      // packing.dart for the budget). It keeps the circular corner's 45°
      // point exactly and spends the continuity on the approach: the curve
      // leaves the flat edge further out, at `reach` rather than r, so
      // curvature ramps up from 0 instead of stepping to 1/r at a tangent
      // point. That is a superellipse of degree `n` > 2 in the corner's
      // local frame; both come from the CPU, which also folds the 0..1
      // continuity into them, so this arm lands exactly on the circular
      // corner as squircle -> 0.
      //
      // The reach depends on the edge's own half-extent (a wide pill gets a
      // long tail lengthwise and an exactly circular end cap), so the two
      // axes carry different profiles. They agree on the corner diagonal —
      // both are pinned to the same 45° point — and are blended across it
      // over a radius' width. Switching outright would instead step the
      // field by ~8% of its own value along that diagonal, straight through
      // the bevel band.
      vec2 room = b.xy - abs(q); // corner-local depth from each edge
      float t = clamp(0.5 + 0.5 * (room.x - room.y) / r, 0.0, 1.0);
      t = t * t * (3.0 - 2.0 * t);
      reach = mix(se.z, se.x, t);
      float n = mix(se.w, se.y, t);
      e = abs(q) - (b.xy - vec2(reach));
      // The floor keeps pow() off exactly 0, where drivers disagree; it
      // shifts the norm by less than the floor itself.
      vec2 e0 = max(e, vec2(1e-6));
      // (x^n + y^n)^(1/n), factored through the larger component: two pow
      // calls instead of three, and the base of the inner one stays in
      // (0, 1] however large n and e0 get.
      float m = max(e0.x, e0.y);
      corner = m * pow(1.0 + pow(min(e0.x, e0.y) / m, n), 1.0 / n);
    }
    d = corner + min(max(e.x, e.y), 0.0) - reach;

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

// Distortion blobs (extra.y != 0) run the exact same loop body as rendered
// blobs; see the matching comment in glass.frag for how the lifted merge
// distance and the subtracted bump work.

float sceneD(vec2 p) {
  float k = max(uBlendRadius, 1e-4);
  float d = 1e4; // sentinel kept small: mix() at 1e9 quantizes to f32 ulp of 64
  float bump = 0.0;
  for (int i = 0; i < 16; i++) {
    if (float(i) < uBlobCount) {
      vec4 extra = uBlobs[i * 6 + 4];
      float di = sdBlob(p, uBlobs[i * 6], uBlobs[i * 6 + 1],
          uBlobs[i * 6 + 2], extra.x, uBlobs[i * 6 + 5]);
      float dm = extra.y == 0.0 ? di : 4e4;
      float h = clamp(0.5 + 0.5 * (d - dm) / k, 0.0, 1.0);
      d = mix(d, dm, h) - k * h * (1.0 - h);
      float t = clamp(1.0 - di / max(extra.z, 1e-4), 0.0, 1.0);
      bump += extra.y * (t * t * (3.0 - 2.0 * t));
    }
  }
  return d - bump;
}

// ---------------------------------------------------------------------------
// Child rendering
// ---------------------------------------------------------------------------

void main() {
  vec2 fragPx = FlutterFragCoord().xy;
  vec2 regionSize = max(uRegion.zw - uRegion.xy, vec2(1e-3));
  // Physical px per logical px, per axis (DPR times any ancestor scale).
  vec2 scale = uSize / regionSize;
  vec2 p = uRegion.xy + fragPx / scale; // logical GlassLayer-local

  float d = sceneD(p);

  // Premultiplied output; transparent outside the blobs erases the child —
  // this pass IS the mask.
  vec4 outCol = vec4(0.0);

  if (d < 2.0) {
    // Gradient of the merged field; same epsilon and unnormalized-magnitude
    // conventions as glass.frag (the pinch fix relies on the dip to zero on
    // merge-neck ridges).
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
    float w = max(0.75 * slope / max(scale.x, 1e-3), 1e-3);
    float coverage = 1.0 - smoothstep(-w, w, d);

    if (coverage > 0.001) {
      // Same inward-looking displacement as glass.frag's backdrop refraction
      // (see the comments there), scaled by the child's own intensity.
      float rim = 1.0 - clamp(-d / max(uBevelThickness, 1e-3), 0.0, 1.0);
      float ease = rim * rim * (3.0 - 2.0 * rim);
      float deflect = ease / sqrt(max(1.0 - rim * rim, 0.04));
      vec2 sp = p - n * (uRefraction * deflect * slope);
      // The texture spans exactly uRegion; clamp displaced samples into it,
      // inset a pixel to keep bilinear taps off the boundary texel (which
      // holds the anchor-dot corners).
      vec2 lo = uRegion.xy + 1.0 / scale;
      sp = clamp(sp, lo, max(uRegion.zw - 1.0 / scale, lo));
      vec4 c = texture(uTexture, (sp - uRegion.xy) / regionSize);
      outCol = c * coverage; // premultiplied in, coverage-masked out
    }
  }

  fragColor = outCol;
}
