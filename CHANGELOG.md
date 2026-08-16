# 0.7.0
- Drop shadows, on by default (`GlassOptions.shadowRadius`,
  `shadowIntensity`, `shadowOffset`; `shadowIntensity: 0` restores the old
  look and all of its cost). iOS puts one under every glass control, and
  without it glass over a same-toned backdrop loses its footing. It is cast
  by the same merged distance field the glass is, read on its outside
  instead of its inside, so it follows the blobby silhouette — merge
  bridges, distortion pushes, sector cuts and all — with no second pass, no
  extra texture, and no path to build: the glass pass (or the flat/opaque
  fill, which cast it too) emits it under its own coverage in the same
  fragment. The falloff is a smoothstep across ±radius, which is a blurred
  edge's profile to within a rounding step and has *compact* support, so
  every clip and bounding rect grows by exactly the radius (biased by the
  offset) and no more. A layer usually reaches its own edge, so the shadow
  is drawn outside the `GlassLayer`'s bounds, like every other Flutter
  shadow — an ancestor that clips will cut it.
- Fixed the child shifting about a pixel and jittering back and forth while a
  blob animates (present since 0.6.0, at any `childRefractionIntensity`,
  including 0). The blob-region clip bounds the child's save layer, and
  Impeller sizes and positions that texture in *physical* pixels in global
  space, so the clip has to land on the physical grid — rounding it to whole
  logical pixels, as it did, leaves it off-grid at any fractional device pixel
  ratio (2.625 on a typical Android phone) or fractional layer position, and
  the child gets rasterized at a different subpixel phase every frame the
  bounds move. Both the clip and the child refraction filter's texture rect
  now snap to the physical grid; `test/pixel_snap_test.dart` pins it.
- The child is now refracted too (glass mode): its content bends through the
  bevel like the backdrop does. Strength comes from
  `GlassOptions.childRefractionIntensity`, which defaults to following
  `refractionIntensity`; set it to 0 for the old flat-child look. Costs about
  what the old mask did — the refraction runs in the same single pass (a new
  `child.frag` via an ordinary `ImageFilterLayer`, no backdrop read) that
  replaces the `ShaderMask`, evaluating coverage at the destination pixel
  while fetching color from the displaced source, so the silhouette stays
  crisp while the content swims inside it. Flat mode and non-Impeller
  backends keep the plain mask.

# 0.6.0
- Continuous corners are now fitted to Flutter's `RSuperellipse`
  (`RoundedSuperellipseBorder`, SwiftUI's `.continuous`) instead of an
  exponent-4 superellipse norm.
- Layers whose blob tints are all fully opaque no longer create a
  `BackdropFilter` at all. Nothing of the backdrop survives an opaque tint, so
  the same picture (tint, edge tint, shine, coverage) is drawn as an ordinary
  canvas shader — bit-identical output, pinned by `test/opaque_path_test.dart`
  — and the layer stops paying Impeller's per-backdrop-filter cost, which is a
  full-render-target flip every frame whether or not anything moved. The
  decision is made per frame at paint time, so animating a tint's alpha moves
  a layer between the two paths on its own.
- `GlassLayer.backdropGroupKey` / `GlassLayer.useBackdropGroup` (opt-in, off by
  default): several translucent glass layers can share one backdrop read
  instead of forcing a render-target flip each. Grouped layers all sample what
  was behind the group, so overlapping ones no longer refract each other —
  usually invisible at a decent `blurRadius`, and free for panes that don't
  overlap.
- Flat mode's fill and the shine pass now shade the blob bounds without the
  refraction and blur padding, which only ever widened the *backdrop* read.
- The child mask is clipped to the blob region before it paints. `ShaderMask`
  pushes a save layer over its whole size and evaluates the field across all
  of it, so a small panel in a big layer was paying for a layer-sized
  offscreen and a layer-sized SDF pass every frame, per layer
- Fixed a latent crash: the backdrop's clip layer was held in a bare field
  rather than a `LayerHandle`, so a paint that skipped the clip could leave a
  disposed layer to be reused on the next one.

# 0.5.0
- Added distortion blobs and GlassSwell

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
