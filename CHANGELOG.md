# 0.4.0
- Continuous corners are now controlled with a double that lerps from round corners instead of an enum flag.
- `blobBuilder` allows positioning blobs relative to current layout, pretty important for implementing Widgets!

# 0.3.0
- Apple-style continuous ("squircle") corners: `GlassBlob.cornerContinuity`
  blends the corner profile from circular arcs (0) to continuous corners (1).
  It's a plain lerpable double, so the silhouette can be animated — e.g. a
  fully rounded blob morphs from a true circle to an Apple-squircle.

# 0.2.0
- Edge tint (`GlassOptions.edgeTint`, opt-in — default transparent): a color
  spread across the bevel band, deepening toward the silhouette like the
  absorption of real tinted glass; keeps the outline legible over
  same-colored backdrops (white on white).

# 0.1.0

- Initial release: `GlassLayer` with SDF smooth-min merged `GlassBlob`s
  (rotation, elliptical half-extents, corner rounding, annular holes, angular
  sectors, per-blob tint).
- Glass mode (Impeller): single-pass refraction, tint and rim shine via
  `BackdropFilter` + `ImageFilter.shader`; backdrop blur composed as an inner
  engine `ImageFilter.blur`, so wide radii stay clean and flat-cost. Requires
  Flutter >= 3.41
  ([flutter#170820](https://github.com/flutter/flutter/issues/170820) fixed
  by [flutter#177687](https://github.com/flutter/flutter/pull/177687)).
- Flat mode (all backends): the merged blobby silhouette as a plain tint
  fill. `GlassMode.glass` resolves per-backend at runtime, falling back to
  flat where shader backdrop filters are unavailable.
- Motion shine (`GlassOptions.motionShine`, default on): the rim highlight
  tracks device roll via the accelerometer, keeping the light anchored in
  world space like iOS 26's Liquid Glass. One shared, ref-counted sensor
  subscription; ticks repaint only the shine pass. Falls back to the static
  `shineDirection` under reduced motion, without an accelerometer, in flat
  mode, or when backgrounded.
