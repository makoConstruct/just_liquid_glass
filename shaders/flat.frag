#version 460 core

// Flat shader: renders the same smooth-min merged blob field as glass.frag
// in one of four modes:
//   uMode == 0: fill — each blob painted with its (possibly transparent)
//               tint; the every-backend fallback look.
//   uMode == 1: mask — pure coverage alpha, used with ShaderMask(dstIn) to
//               clip the GlassLayer child to the blob silhouette.
//   uMode == 2: shine — the rim highlights only, drawn in glass mode above
//               the masked child, OUTSIDE the mask (premultiplied white;
//               src-over acts as a screen-toward-white blend). Its outer cut
//               sits half a band outside the silhouette so it fully covers
//               the glass edge's AA fringe.
//   uMode == 3: opaque fill — what the glass path renders when every tint is
//               fully opaque, drawn as an ordinary canvas shader with no
//               BackdropFilter at all. See the mode's branch in main().
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
uniform float uMode;           // 1 (0 = fill, 1 = mask, 2 = shine, 3 = opaque)
uniform float uDpr;            // 2
uniform float uShineIntensity; // 3 (shine mode only)
uniform float uShineDirection; // 4 (shine mode only)
uniform float uBevelThickness; // 5 (shine and opaque modes)
// (the smooth-min blend radius is per blob; see uBlobs[i * 6 + 4].w)

// Rim darkening across the bevel band; opaque-fill mode only, where it
// stands in for glass.frag's uEdgeTint. Same meaning, same weighting.
uniform vec4 uEdgeTint;        // 6..9

// Drop shadow: (blur radius, peak alpha, offset.x, offset.y) in logical
// pixels; see glass.frag. Drawn by the two modes that stand in for the glass
// pass — fill and opaque fill — and by neither of the two that draw *over*
// it (the child mask and the shine).
uniform vec4 uShadow;          // 10..13

// 6 vec4 per blob, up to 16 blobs (float indices 14..397).
// Layout identical to glass.frag.
uniform vec4 uBlobs[96];

out vec4 fragColor;

// ---------------------------------------------------------------------------
// SDF core (keep in sync with glass.frag)
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
// distance and the subtracted bump work — and, just below it, for why the
// per-blob blend radius (extra.w) folds in as min(kAcc, k_i) with kAcc
// carried through h.

float sceneD(vec2 p) {
  float d = 1e4; // sentinel kept small: mix() at 1e9 quantizes to f32 ulp of 64
  float kAcc = 1e4;
  float bump = 0.0;
  for (int i = 0; i < 16; i++) {
    if (float(i) < uBlobCount) {
      vec4 extra = uBlobs[i * 6 + 4];
      float di = sdBlob(p, uBlobs[i * 6], uBlobs[i * 6 + 1],
          uBlobs[i * 6 + 2], extra.x, uBlobs[i * 6 + 5]);
      float dm = extra.y == 0.0 ? di : 4e4;
      float k = max(min(kAcc, extra.w), 1e-4);
      float h = clamp(0.5 + 0.5 * (d - dm) / k, 0.0, 1.0);
      d = mix(d, dm, h) - k * h * (1.0 - h);
      kAcc += (extra.w - kAcc) * h;
      float t = clamp(1.0 - di / max(extra.z, 1e-4), 0.0, 1.0);
      bump += extra.y * (t * t * (3.0 - 2.0 * t));
    }
  }
  return d - bump;
}

float scene(vec2 p, out vec4 tint) {
  float d = 1e4; // sentinel kept small: mix() at 1e9 quantizes to f32 ulp of 64
  float kAcc = 1e4;
  float bump = 0.0;
  tint = vec4(0.0);
  for (int i = 0; i < 16; i++) {
    if (float(i) < uBlobCount) {
      vec4 extra = uBlobs[i * 6 + 4];
      float di = sdBlob(p, uBlobs[i * 6], uBlobs[i * 6 + 1],
          uBlobs[i * 6 + 2], extra.x, uBlobs[i * 6 + 5]);
      float dm = extra.y == 0.0 ? di : 4e4;
      float k = max(min(kAcc, extra.w), 1e-4);
      float h = clamp(0.5 + 0.5 * (d - dm) / k, 0.0, 1.0);
      d = mix(d, dm, h) - k * h * (1.0 - h);
      kAcc += (extra.w - kAcc) * h;
      float t = clamp(1.0 - di / max(extra.z, 1e-4), 0.0, 1.0);
      float s = t * t * (3.0 - 2.0 * t);
      bump += extra.y * s;
      // ease-in-out so the tint gradient is C1 at the blend-band edges;
      // geometry must keep linear h (polynomial smin assumes it).
      // Distortion blobs tint at their kernel weight instead — the same
      // weight that drives the push (their h is exactly 0, and rendered
      // blobs never take the s arm, whose t is meaningless for them).
      float hc = extra.y == 0.0 ? h * h * (3.0 - 2.0 * h) : s;
      tint = mix(tint, uBlobs[i * 6 + 3], hc);
    }
  }
  return d - bump;
}

void main() {
  vec2 p = FlutterFragCoord().xy;

  vec4 tint;
  float d = scene(p, tint);

  // Drop shadow (fill and opaque-fill modes only — the mask and the shine
  // draw above the glass, not below it). Kept identical to glass.frag's
  // block; see it for the falloff.
  vec4 shadowCol = vec4(0.0);
  if (uShadow.y > 0.0 && (uMode < 0.5 || uMode > 2.5)) {
    float ds = d;
    if (dot(uShadow.zw, uShadow.zw) > 0.0) ds = sceneD(p - uShadow.zw);
    float sr = max(uShadow.x, 1e-3);
    shadowCol =
        vec4(0.0, 0.0, 0.0, uShadow.y * (1.0 - smoothstep(-sr, sr, ds)));
  }

  vec4 outCol = shadowCol;
  if (d < 2.0) {
    // Gradient of the merged field; see glass.frag for why the epsilon
    // widens in the bevel-aware modes (shine, opaque fill — the latter
    // matching glass.frag exactly, since it stands in for it) and why the
    // magnitude stays unnormalized.
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

    if (uMode > 2.5) {
      // Opaque fill: the glass path's picture for a layer whose every tint
      // is fully opaque, with no BackdropFilter behind it. Legitimate
      // because at tint.a == 1 glass.frag's mix(bg.rgb, tint.rgb, tint.a)
      // multiplies the sampled backdrop out entirely — refraction and blur
      // displace and smear a texture that then contributes nothing — so all
      // that survives of that pass is the tint, the edge tint and the same
      // coverage. Everything below is copied from glass.frag's rim block
      // with the bg term dropped; keep them in sync.
      float rim = 1.0 - clamp(-d / max(uBevelThickness, 1e-3), 0.0, 1.0);
      float ease = rim * rim * (3.0 - 2.0 * rim);
      vec3 col = mix(tint.rgb, uEdgeTint.rgb,
          clamp(uEdgeTint.a, 0.0, 1.0) * ease * slope);
      // tint.a is 1 wherever the field is covered (every blob is opaque, and
      // the merge only ever mixes opaque tints together), so this matches
      // glass.frag's alpha == coverage; it is written out the long way so a
      // stray translucent blob degrades toward the fill look rather than
      // punching an opaque hole.
      float alpha = coverage * clamp(tint.a, 0.0, 1.0);
      outCol = vec4(min(col, vec3(1.0)) * alpha, alpha);
    } else if (uMode > 1.5) {
      // Shine: long thin highlight arcs hugging the rim, iOS-26 style.
      // Follows liquid_glass_renderer's render.glsl conventions: the band is
      // a thin (~1px) Lorentzian near d == 0 (radially hard-edged,
      // independent of bevel width), while the angular lobes are broad —
      // influence is dot(n, L) merely squared, with an equal counter-lobe
      // opposite the light (iOS lights the bottom edge as brightly as the
      // top: light enters the top edge and exits the bottom one).
      vec2 n = g / max(gm, 1e-4);
      vec2 lightDir = vec2(cos(uShineDirection), -sin(uShineDirection));
      float influence = max(dot(n, lightDir), 0.0) +
          max(dot(n, -lightDir), 0.0);
      // Half-Lorentzian with a flat top: full brightness from 0.6px inside
      // the silhouette outward, decaying only inward. A symmetric band
      // centered on d == 0 loses half its peak to the outer cut and reads
      // washed out.
      float x = min((d + 0.6) / 0.9, 0.0);
      float rimFactor = 1.0 / (1.0 + 0.89 * x * x);
      // Outer cut shifted one half-band OUTWARD of the glass/mask coverage:
      // this pass draws ABOVE the GlassLayer mask, and the highlight must
      // fully cover the glass edge's own AA fringe. Any cut at or inside
      // the glass coverage leaves fringe pixels where the (possibly dark)
      // tinted glass shows with less shine than the peak — a jaggy dark
      // hairline capping the shine on dark-tint-over-light scenes. Shifted
      // outward, the line owns the outermost pixels and its own edge blends
      // shine-over-backdrop with no dark component.
      float covOut = 1.0 - smoothstep(-w, w, d - w);
      // slope (unnormalized |gradient|) still zeroes the shine on merge
      // necks — the pinch fix; see glass.frag.
      float s = clamp(1.4 * uShineIntensity * influence * influence *
          rimFactor * slope, 0.0, 1.0) * covOut;
      outCol = vec4(s); // premultiplied white
    } else if (uMode > 0.5) {
      outCol = vec4(coverage); // premultiplied white; dstIn uses the alpha
    } else {
      float alpha = coverage * clamp(tint.a, 0.0, 1.0);
      outCol = vec4(tint.rgb * alpha, alpha); // premultiplied tint fill
    }
    // srcOver of the pass over its shadow. Occluded by `coverage`, not by
    // the fill's own alpha: a translucent (or fully transparent) tint hides
    // its shadow's interior exactly like the glass path's opaque coverage
    // does, so the two paths cast the same visible halo. Zero in the mask
    // and shine modes, where shadowCol is 0. Keep the arithmetic identical
    // to glass.frag's — opaque_path_test compares the two bit for bit.
    outCol += shadowCol * (1.0 - coverage);
  }

  fragColor = outCol;
}
