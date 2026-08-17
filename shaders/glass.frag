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
uniform float uBevelThickness; // 4
uniform float uRefraction;     // 5
// (the smooth-min blend radius is per blob; see uBlobs[i * 6 + 4].w)

// The GlassLayer's origin within the render target, in logical pixels.
// FlutterFragCoord() is anchored to the full render target, but blob centers
// are in GlassLayer-local coordinates; this converts between the two.
uniform vec2 uOrigin;          // 6, 7

// The effective clip of this filter (padded blob bounds intersected with
// the GlassLayer and the render target; set at paint time alongside
// uOrigin), LTRB in logical GlassLayer-local pixels. uTexture has no valid
// content outside it (see uSize note), so backdrop samples are clamped into
// this rect.
uniform vec4 uClip;            // 8..11

// Edge tint: a separate color layered over the base tint near the
// silhouette, strongest at the rim (see the Beer-Lambert note in main).
// Alpha scales the strength; fully transparent disables it.
uniform vec4 uEdgeTint;        // 12..15

// Drop shadow, cast by the same field: (blur radius, peak alpha, offset.x,
// offset.y) in logical pixels. Alpha 0 disables it — and, because the Dart
// side then drops the shadow padding from the clip, costs nothing at all.
uniform vec4 uShadow;          // 16..19

// 6 vec4 per blob, up to 16 blobs (float indices 20..403):
//   [0] center.x, center.y, cos(rotation), sin(rotation)
//   [1] radii.x, radii.y, cornerRadius, holeRadius (<= 0 means no hole)
//   [2] sectorAxis.x, sectorAxis.y, cos(halfAperture) (-2 = full circle),
//       sin(halfAperture) (negative = circular ring segment with round caps)
//   [3] tint r, g, b, a
//   [4] cornerContinuity (0 circular .. 1 continuous),
//       distortion (!= 0 marks a non-rendered distortion blob),
//       distortionRange (falloff distance), blendRadius (already resolved
//       against the layer default on the CPU)
//   [5] corner profile, packed on the CPU with the continuity already lerped
//       in: reach.x, exponent.x, reach.y, exponent.y (see packing.dart)
uniform vec4 uBlobs[96];

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
// blobs — no second code path: their merge distance is lifted out of range,
// which clamps the smin weight h to exactly 0, making the merge a bitwise
// no-op. Their geometric contribution is the bump: a smooth kernel of the
// blob's own field, full strength inside its surface, fading to 0 at
// distortionRange (extra.z) — subtracted from the merged field at the end,
// it pushes every nearby surface outward by up to extra.y px (negative
// dents inward). In scene() their tint still participates, mixed at that
// same kernel weight, so a distorter colors the surfaces it displaces (a
// distorter that should color nothing carries its neighbors' tint — like
// any blob tint, a transparent one fades what it covers). Rendered blobs
// have extra.y == 0, so their bump term is zero. The lift constant stays
// well above the 1e4 sentinel but far from the 1e9 quantization cliff.

// Per-blob blend radius (extra.w). The smooth-min's k is a property of the
// *operation*, not of one operand, so a fold that merged each blob at its own
// k would set every junction's width from whichever blob came later in the
// list. Instead each step merges at min(kAcc, k_i), where kAcc tracks the
// blend radius of whatever currently owns the field: it is carried through
// the same weight h that carries the distance, so it follows the locally
// nearest blob rather than the whole list. Two blobs therefore fuse over the
// smaller of their radii whichever order they are packed in, a blob with
// blendRadius 0 keeps a hard junction against everything, and a crisp blob at
// one end of a layer does not sharpen junctions at the other. kAcc starts at
// the sentinel so the first merge takes that blob's own k, and distortion
// blobs leave it alone for free: their h is exactly 0, which makes both the
// distance and the kAcc step bitwise no-ops.
//
// That step is written `kAcc += (k_i - kAcc) * h` rather than as the
// equivalent mix() so that a layer whose blobs all share one radius — every
// layer that never touches GlassBlob.blendRadius — carries it through the
// fold *exactly*: the difference is 0, so no rounding accumulates and the
// field stays bit-identical to what a single global radius produced.

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

// ---------------------------------------------------------------------------
// Glass rendering
// ---------------------------------------------------------------------------

void main() {
  vec2 fragPx = FlutterFragCoord().xy;
  vec2 p = fragPx / uDpr - uOrigin; // logical GlassLayer-local coordinates

  vec4 tint;
  float d = scene(p, tint);

  // Drop shadow, underneath everything else this pass draws. The same merged
  // field, read on its outside: a gaussian-blurred silhouette's alpha profile
  // across a straight edge is an erfc, and smoothstep over +-radius tracks
  // that closely enough to be indistinguishable at these opacities while
  // having compact support — the shadow is exactly 0 one radius out, so the
  // Dart side can pad the clip by that much and no more. Curvature is not
  // corrected for (a real blur rounds tight corners off further); at a
  // silhouette this soft it does not read.
  //
  // Only the *outside* half is ever seen: the glass composites over it below
  // at its own coverage, so an offset shadow does not show through the glass
  // that casts it — matching iOS, and matching what an opaque tint would do
  // anyway.
  vec4 shadowCol = vec4(0.0);
  if (uShadow.y > 0.0) {
    // An offset shadow reads the field a second time, at the shifted point;
    // an unoffset one is exactly the field already computed.
    float ds = d;
    if (dot(uShadow.zw, uShadow.zw) > 0.0) ds = sceneD(p - uShadow.zw);
    float sr = max(uShadow.x, 1e-3);
    // Premultiplied black: rgb stays 0, so compositing below is alpha-only.
    shadowCol =
        vec4(0.0, 0.0, 0.0, uShadow.y * (1.0 - smoothstep(-sr, sr, ds)));
  }

  // Premultiplied output, and transparent where neither the blobs nor their
  // shadow reach: uTexture may be pre-blurred, and the srcOver composite is
  // what restores the sharp backdrop there — this pass must not repaint it.
  vec4 outCol = shadowCol;

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

    // The shadow is re-composited under the glass at the end of the block,
    // so start the glass's own color from nothing.
    outCol = vec4(0.0);
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
    // srcOver of the glass over its own shadow. Kept in exactly this form —
    // same operands, same order — as flat.frag's matching line: the opaque
    // mode there has to reproduce this pass bit for bit (opaque_path_test),
    // and a rearrangement that lets one program fuse a multiply-add the
    // other doesn't is enough to show up as an off-by-one channel.
    outCol += shadowCol * (1.0 - coverage);
  }

  fragColor = outCol;
}
