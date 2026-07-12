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
