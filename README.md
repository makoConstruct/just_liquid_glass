
# just_liquid_glass

A form of liquid glass for Flutter: blobby, SDF-merged glass shapes with refraction, blur, tint and shine, plus a flat fallback mode that runs on every backend.

It's entirely vibecoded (Fable 5), but it's been tested and iterated and refined and used, and is probably very stable, given the defensive approach we took. Fable was instructed to learn from other flutter libraries and take an approach that dodges some of flutter's bugs, a standout decision resulting from that was to avoid using intermediate textures so animating blobs wouldn't churn GPU memory. The full list is in [Bugs dodged](#bugs-dodged) below.

We do aspire to look like apple's implementation by default, we currently aren't there, but we're not far.

Improvements over flutter_liquid_glass:

- It's possible to fade shine to 0/to interpolate all the way to flatness

- The blob shapes are quite flexible, they can each have corner radius, a hole, start and end angle, and different colors and opacities (when blobs touch, colors blend smoothly from one to the other).

- Blobs can be animated out by shrinking (see "Animating a blob out" in `GlassBlob`'s docs) without crashing. `flutter_liquid_glass` throws when a shape's layout goes to zero ([whynotmake-it#149](https://github.com/whynotmake-it/flutter_liquid_glass/issues/149), open).

- Shapes can be rotated

- The blobs of a layer implicitly form a clip mask on the child. This turns out to often be the right thing for animated entry and edge shaping.

Non-improvements:

- Doesn't support arbitrary shapes, your shapes must compose from our round-capped segments of roundrect-toruses.

- Corner shape is just circular, not apple's continuous shape. We'll probably address this soon.

- Arbitrarily, the number of blobs supported per layer is currently 16.

Flaws that anyone could fix instantly if they wanted to:

- No chromatic aberration. (it could probably be done in just one prompt, mako just didn't want it (it's not actually good!), but would accept it, even as the default setting, if someone else wants to add it)

- Our flat fallback doesn't support the blur. Fixing this would be easy. The reason it isn't in today is that mako kinda firmly recommends using fully opaque blobs on platforms that don't have full glass. Glass is a good way of adding an outline to an otherwise quite indistinct graphical effect. Without that, you probably shouldn't use transparent-blurred substances this much.


**Everything below this line was written by Fable but has been reviewed.**

## Usage

```dart
GlassLayer(
  options: const GlassOptions(
    blendRadius: 32,       // how far apart blobs start fusing
    blurRadius: 6,
    bevelThickness: 16,
    refractionIntensity: 24,
    shineIntensity: 0.4,
    edgeTint: Color(0x26000000), // rim darkening; keeps white-on-white legible
  ),
  blobs: [
    // A circle.
    const GlassBlob(
      center: Offset(120, 160),
      radii: Size(70, 70),
      tint: Color(0x33FFFFFF),
    ),
    // A rotated pill.
    const GlassBlob(
      center: Offset(240, 200),
      radii: Size(90, 36),
      rotation: 0.4,
      tint: Color(0x2200E5FF),
    ),
    // A progress-ring arc segment: ring via holeRadius, sweep via angles.
    GlassBlob(
      center: const Offset(180, 320),
      radii: const Size(64, 64),
      holeRadius: 40,
      startAngle: -math.pi / 2,
      endAngle: -math.pi / 2 + math.pi,
      tint: const Color(0x66B388FF),
    ),
  ],
  child: yourContent,
)
```

Call `GlassLayer.precache()` early (e.g. in `main`) if you want the first
frame to include the glass; otherwise the layer renders its child alone
until the shader programs finish loading.

### Shape model

Each `GlassBlob` is a rounded box with half-extents `radii`, rotated by
`rotation` around `center`:

- `cornerRadius` — corner rounding. The default (`infinity`) clamps to the
  smaller radius, giving a circle or stadium/pill. `0` gives sharp corners.
- `holeRadius` — cuts a circular hole around the center (ring/annulus).
  Default (`-infinity`) means no hole.
- `startAngle` / `endAngle` — clips to an angular sector in the blob's local
  frame (radians from the local +x axis, positive toward +y / clockwise on
  screen). A sweep of `tau` or more disables the clip. When the blob is a
  circular ring segment (circular radii, default corner rounding, and a
  hole), the open ends get circular caps automatically; other sector shapes
  get a hard cut.
- `tint` — the blob color. In glass mode it is mixed over the refracted
  backdrop with strength `tint.a`; in flat mode it is the fill itself.

## Modes and platform support

| Mode | What you get | Where it works |
|---|---|---|
| `GlassMode.glass` (default) | Refraction, blur, tint, shine over the backdrop, falling back to flat where unsupported | Everywhere; true glass on Impeller (iOS, Android, macOS) |
| `GlassMode.flat` | The same merged blobby silhouette as a plain tint fill | Everywhere (Skia and Impeller, including web and desktop) |

Requesting `GlassMode.glass` on a backend without support falls back to flat
rather than throwing. Glass mode uses `BackdropFilter` + `ImageFilter.shader`,
which Flutter only supports on Impeller. Flat mode is an ordinary canvas shader and needs no
backdrop access, so it runs on any backend — it is a deliberate design style
of its own (blobby flat color, possibly translucent), not just a degraded
glass.

Backdrop blur is the engine's own downsampled gaussian, composed under the
glass shader (`ImageFilter.compose`), so `blurRadius` can go as wide as you
like at flat cost. This is why the package requires Flutter 3.41 or newer:
composing `ImageFilter.blur` with `ImageFilter.shader` shifted the shader's
coordinate system until
[flutter#170820](https://github.com/flutter/flutter/issues/170820) was fixed
(see [Bugs dodged](#bugs-dodged)).

## Bugs dodged

Each design decision below traces to a bug you can watch another project hitting:

- **No intermediate textures.** `liquid_glass_renderer` rasterizes shape
  geometry into textures, and [documents](https://github.com/whynotmake-it/flutter_liquid_glass/tree/main/packages/liquid_glass_renderer#%EF%B8%8F-limitations)
  memory spikes when animating shapes because Flutter can't dispose those
  textures promptly ([flutter#138627](https://github.com/flutter/flutter/issues/138627));
  the same texture path crashes outright when geometry bounds collapse to
  zero size ([whynotmake-it#149](https://github.com/whynotmake-it/flutter_liquid_glass/issues/149), open).
  Here the blob field is evaluated analytically in the shader — animating
  blobs is just uniform updates, with nothing to allocate or dispose.
- **The layer's origin is passed as a uniform every paint.**
  `FlutterFragCoord()` is anchored to the render target, not the filtered
  layer, so a glass layer that moves within the target evaluates its field
  in the wrong place — typically ending up invisible or warped. That
  symptom class is on file against `liquid_glass_renderer`: glass and
  contents disappearing when scrolled to the bounds
  ([whynotmake-it#124](https://github.com/whynotmake-it/flutter_liquid_glass/issues/124), open)
  and vertical distortion when scrolling to the top of a feed
  ([whynotmake-it#33](https://github.com/whynotmake-it/flutter_liquid_glass/issues/33), open).
- **Fixed-count loops, no `break`.** Flutter's SkSL transpile mishandles
  loop constructs — `FragmentProgram` fails to compile a plain for loop on
  Skia ([flutter#116850](https://github.com/flutter/flutter/issues/116850), open),
  and during this build `break` compiled silently and rendered garbage. The
  blob loops here run all 16 iterations with an `if` guard, pinned by
  `test/sdf_field_test.dart`.
- **Anti-aliasing without `fwidth`.** Derivative built-ins are rejected at
  runtime on web ([flutter#180959](https://github.com/flutter/flutter/issues/180959), open),
  so edge AA uses the analytic field gradient instead — which also keeps
  the edge band a constant ~1.5 physical pixels wherever merges compress
  the field.
- **Unsupported backends downgrade instead of throwing.** Requesting glass
  where `ImageFilter.shader` isn't available silently falls back to flat;
  compare `liquid_glass_renderer` throwing on unsupported render backends
  ([whynotmake-it#12](https://github.com/whynotmake-it/flutter_liquid_glass/issues/12), open).
